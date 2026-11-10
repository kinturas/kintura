package server

import (
	"context"
	"crypto/subtle"
	"embed"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	logPageSize   = 100
	logMaxMessage = 2000
	logMaxEntries = 10000
	logRetention  = 90 * 24 * time.Hour

	// adminEmail is the account behind the token login. It has no mailbox, so
	// the mail login refuses it.
	adminEmail        = "admin@kintura"
	adminSessionTTL   = 12 * time.Hour
	minAdminKeyLength = 16
	maxKeyFailures    = 10 // for all callers together within keyFailureWindow
	keyFailureWindow  = 15 * time.Minute
	keyFailureMessage = "Falscher API-Token"
)

//go:embed admin
var adminFiles embed.FS

// adminAsset serves a file of the dashboard. The strict policy keeps the session
// token out of reach even if a logged message ever slipped past the escaping.
func adminAsset(name, contentType string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		content, err := adminFiles.ReadFile("admin/" + name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", contentType)
		w.Header().Set("Content-Security-Policy",
			"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-cache")
		w.Write(content)
	}
}

type logScopeKey struct{}

// logScope collects who a request belongs to while it passes the middlewares.
type logScope struct {
	userID, familyID, email string
}

func scopeOf(r *http.Request) *logScope {
	scope, _ := r.Context().Value(logScopeKey{}).(*logScope)
	return scope
}

// logError writes to the server log and the error log of the dashboard. The
// endpoint is the route pattern, so tokens in the path never reach the log. r may
// be nil for background work. Never call this while a transaction is open.
func (s *Server) logError(r *http.Request, status int, msg string) {
	var endpoint string
	scope := &logScope{}
	if r != nil {
		endpoint = r.Pattern
		if sc := scopeOf(r); sc != nil {
			scope = sc
		}
	}
	s.logEntry(endpoint, *scope, status, msg)
}

// logEntry is logError for work that does not belong to a request.
func (s *Server) logEntry(endpoint string, scope logScope, status int, msg string) {
	log.Printf("%s: %s", endpoint, msg)
	if runes := []rune(msg); len(runes) > logMaxMessage {
		msg = string(runes[:logMaxMessage])
	}
	// The request may already be canceled, which must not lose the entry.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO error_log (created_at, email, family_name, endpoint, status, message) VALUES (?,
			COALESCE(NULLIF(?, ''), (SELECT email FROM users WHERE id = ?), ''),
			COALESCE((SELECT name FROM families WHERE id = ?), ''), ?, ?, ?)`,
		now(), scope.email, scope.userID, scope.familyID, endpoint, status, msg); err != nil {
		log.Printf("error log: %v", err)
	}
}

// trimErrorLog limits the age of the personal data in the log and its size, since
// failed logins can add entries without an account.
func (s *Server) trimErrorLog(ctx context.Context) {
	cutoff := time.Now().UTC().Add(-logRetention).Format(timeFormat)
	if _, err := s.db.ExecContext(ctx, `DELETE FROM error_log WHERE created_at <= ?`, cutoff); err != nil {
		s.logError(nil, 0, "cleanup: "+err.Error())
	}
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM error_log WHERE id <= (SELECT MAX(id) FROM error_log) - ?`, logMaxEntries); err != nil {
		s.logError(nil, 0, "cleanup: "+err.Error())
	}
}

// sysadmin requires the sysadmin flag.
func (s *Server) sysadmin(h authedFunc) http.HandlerFunc {
	return s.authed(func(w http.ResponseWriter, r *http.Request, c reqCtx) error {
		var flag bool
		if err := s.db.QueryRowContext(r.Context(), `SELECT is_sysadmin FROM users WHERE id = ?`, c.userID).Scan(&flag); err != nil {
			return err
		}
		if !flag {
			return fail(http.StatusForbidden, "Nur für den Sysadmin erlaubt")
		}
		return h(w, r, c)
	})
}

// dashboard additionally requires that the sysadmin has entered the API key once.
func (s *Server) dashboard(h authedFunc) http.HandlerFunc {
	return s.sysadmin(func(w http.ResponseWriter, r *http.Request, c reqCtx) error {
		var activated bool
		if err := s.db.QueryRowContext(r.Context(),
			`SELECT admin_verified_at IS NOT NULL FROM users WHERE id = ?`, c.userID).Scan(&activated); err != nil {
			return err
		}
		if !activated {
			return fail(http.StatusForbidden, "Das Dashboard ist noch nicht freigeschaltet")
		}
		return h(w, r, c)
	})
}

func (s *Server) adminStatus(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var name, email string
	var activated bool
	if err := s.db.QueryRowContext(r.Context(),
		`SELECT name, email, admin_verified_at IS NOT NULL FROM users WHERE id = ?`, c.userID).Scan(&name, &email, &activated); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name": name, "email": email, "activated": activated, "key_configured": s.adminKey != "",
	})
	return nil
}

// checkAdminKey compares a given token with the key the backend was started with.
// The token login needs no account, so failures are limited for all callers
// together: a client address behind a proxy would not identify anyone. The limit
// can block the token login for a while, but never the mail login.
func (s *Server) checkAdminKey(r *http.Request, given string, failStatus int) error {
	var failures int
	cutoff := time.Now().UTC().Add(-keyFailureWindow).Format(timeFormat)
	if err := s.db.QueryRowContext(r.Context(),
		`SELECT COUNT(*) FROM error_log WHERE message = ? AND created_at > ?`, keyFailureMessage, cutoff).Scan(&failures); err != nil {
		return err
	}
	if failures >= maxKeyFailures {
		return fail(http.StatusTooManyRequests, "Zu viele Versuche. Bitte in ein paar Minuten erneut versuchen.")
	}
	// Comparing hashes keeps the comparison independent of the key length.
	hash := hashToken(strings.TrimSpace(given))
	if s.adminKey == "" || subtle.ConstantTimeCompare([]byte(hash), []byte(hashToken(s.adminKey))) != 1 {
		s.logError(r, failStatus, keyFailureMessage)
		return fail(failStatus, "Der API-Token ist falsch.")
	}
	return nil
}

// authToken logs in as the admin account with nothing but the API token.
func (s *Server) authToken(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Token string `json:"token"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if err := s.checkAdminKey(r, in.Token, http.StatusUnauthorized); err != nil {
		return err
	}
	ctx := r.Context()
	var userID string
	if err := s.db.QueryRowContext(ctx, `SELECT id FROM users WHERE email = ?`, adminEmail).Scan(&userID); err != nil {
		return err
	}
	token, err := createSession(ctx, s.db, userID, adminSessionTTL)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"token": token})
	return nil
}

// adminActivate unlocks the dashboard for good once the sysadmin proves to know
// the key the backend was started with. Mailbox access alone is not enough.
func (s *Server) adminActivate(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Key string `json:"key"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if s.adminKey == "" {
		return fail(http.StatusServiceUnavailable, "Am Backend ist kein gültiger ADMIN_API_KEY gesetzt.")
	}
	if err := s.checkAdminKey(r, in.Key, http.StatusForbidden); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(r.Context(), `UPDATE users SET admin_verified_at = ? WHERE id = ?`, now(), c.userID); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) adminFamilies(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	families, err := queryRows(ctx, s.db, `SELECT id, name, type, created_at FROM families ORDER BY LOWER(name), id`)
	if err != nil {
		return err
	}
	members, err := queryRows(ctx, s.db,
		`SELECT m.family_id, u.id, u.name, u.email, m.role, m.is_admin, u.is_sysadmin
		 FROM memberships m JOIN users u ON u.id = m.user_id
		 ORDER BY m.is_admin DESC, CASE m.role WHEN 'manager' THEN 0 WHEN 'user' THEN 1 WHEN 'restrict_user' THEN 2 ELSE 3 END, LOWER(u.name)`)
	if err != nil {
		return err
	}
	byFamily := map[any][]map[string]any{}
	for _, member := range members {
		byFamily[member["family_id"]] = append(byFamily[member["family_id"]], member)
	}
	for _, family := range families {
		family["members"] = []map[string]any{}
		if list := byFamily[family["id"]]; list != nil {
			family["members"] = list
		}
	}
	writeJSON(w, http.StatusOK, families)
	return nil
}

func (s *Server) adminUsers(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	users, err := queryRows(ctx, s.db, `SELECT id, name, email, created_at, is_sysadmin FROM users ORDER BY LOWER(name), id`)
	if err != nil {
		return err
	}
	memberships, err := queryRows(ctx, s.db,
		`SELECT m.user_id, f.name, f.type, m.role, m.is_admin
		 FROM memberships m JOIN families f ON f.id = m.family_id ORDER BY LOWER(f.name)`)
	if err != nil {
		return err
	}
	byUser := map[any][]map[string]any{}
	for _, membership := range memberships {
		byUser[membership["user_id"]] = append(byUser[membership["user_id"]], membership)
	}
	for _, user := range users {
		user["families"] = []map[string]any{}
		if list := byUser[user["id"]]; list != nil {
			user["families"] = list
		}
	}
	writeJSON(w, http.StatusOK, users)
	return nil
}

// adminLog returns one page of the error log, newest first. ?before=<id> continues
// after the last entry of the previous page.
func (s *Server) adminLog(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	before := int64(0)
	if raw := r.URL.Query().Get("before"); raw != "" {
		var err error
		if before, err = strconv.ParseInt(raw, 10, 64); err != nil {
			return fail(http.StatusBadRequest, "Ungültige Anfrage")
		}
	}
	entries, err := queryRows(r.Context(), s.db,
		`SELECT id, created_at, email, family_name, endpoint, status, message FROM error_log
		 WHERE ? = 0 OR id < ? ORDER BY id DESC LIMIT ?`, before, before, logPageSize+1)
	if err != nil {
		return err
	}
	hasMore := len(entries) > logPageSize
	if hasMore {
		entries = entries[:logPageSize]
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "has_more": hasMore})
	return nil
}
