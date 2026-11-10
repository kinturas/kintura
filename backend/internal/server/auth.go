package server

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"net/mail"
	"strings"
	"time"

	"github.com/kinturas/kintura/backend/internal/database"
)

const (
	loginTTL        = 15 * time.Minute
	sessionTTL      = 90 * 24 * time.Hour
	maxCodeAttempts = 5
	maxOpenRequests = 5 // per email address within loginTTL
)

func normalizeEmail(raw string) (string, error) {
	email := strings.ToLower(strings.TrimSpace(raw))
	addr, err := mail.ParseAddress(email)
	// The internal domain stands for accounts without a mailbox, which no login can ask for.
	if err != nil || addr.Address != email || isInternalEmail(email) {
		return "", fail(http.StatusBadRequest, "Ungültige E-Mail-Adresse")
	}
	return email, nil
}

func hashCode(requestID, code string) string { return hashToken(requestID + ":" + code) }

// authRequest starts a login. New and known addresses are treated identically,
// so the response does not reveal whether an account exists.
func (s *Server) authRequest(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Email string `json:"email"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	email, err := normalizeEmail(in.Email)
	if err != nil {
		return err
	}
	if email == adminEmail {
		return fail(http.StatusBadRequest, "Ungültige E-Mail-Adresse")
	}
	ctx := r.Context()
	var open int
	cutoff := time.Now().UTC().Add(-loginTTL).Format(timeFormat)
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM login_requests WHERE email = ? AND created_at > ?`, email, cutoff).Scan(&open); err != nil {
		return err
	}
	if open >= maxOpenRequests {
		return fail(http.StatusTooManyRequests, "Zu viele Versuche. Bitte in ein paar Minuten erneut versuchen.")
	}

	code, err := randomCode()
	if err != nil {
		return err
	}
	requestID, linkToken := randomHex(32), randomHex(32)
	expires := time.Now().UTC().Add(loginTTL)
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO login_requests (id_hash, email, code_hash, link_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		hashToken(requestID), email, hashCode(requestID, code), hashToken(linkToken), expires.Format(timeFormat), now()); err != nil {
		return err
	}

	body := fmt.Sprintf("Hallo,\n\ndein Anmeldecode für Kintura lautet:\n\n    %s\n\n"+
		"Alternativ kannst du die Anmeldung über diesen Link bestätigen:\n%s/login?token=%s\n\n"+
		"Code und Link sind 15 Minuten gültig. Falls du das nicht warst, ignoriere diese Mail einfach.\n",
		code, s.publicURL, linkToken)
	if err := s.mailer.Send(email, "Dein Anmeldecode für Kintura", body); err != nil {
		scopeOf(r).email = email
		return &apiError{http.StatusBadGateway, "Die E-Mail konnte nicht versendet werden.", fmt.Errorf("Anmelde-Mail: %w", err)}
	}
	writeJSON(w, http.StatusOK, map[string]string{"request_id": requestID, "expires_at": expires.Format(timeFormat)})
	return nil
}

type loginRequest struct {
	idHash, email, codeHash string
	attempts                int
	verified                bool
}

// openRequest loads a login request that is neither expired nor consumed.
func (s *Server) openRequest(ctx context.Context, requestID string) (*loginRequest, error) {
	lr := &loginRequest{idHash: hashToken(requestID)}
	var verifiedAt sql.NullString
	err := s.db.QueryRowContext(ctx,
		`SELECT email, code_hash, attempts, verified_at FROM login_requests
		 WHERE id_hash = ? AND consumed_at IS NULL AND expires_at > ?`, lr.idHash, now()).
		Scan(&lr.email, &lr.codeHash, &lr.attempts, &verifiedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fail(http.StatusGone, "Die Anmeldung ist abgelaufen. Bitte neu starten.")
	}
	if err != nil {
		return nil, err
	}
	lr.verified = verifiedAt.Valid
	return lr, nil
}

func (s *Server) authVerify(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		RequestID string `json:"request_id"`
		Code      string `json:"code"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	lr, err := s.openRequest(ctx, in.RequestID)
	if err != nil {
		return err
	}
	if !lr.verified {
		// Count the attempt before comparing, so parallel guesses cannot exceed the limit.
		res, err := s.db.ExecContext(ctx,
			`UPDATE login_requests SET attempts = attempts + 1 WHERE id_hash = ? AND attempts < ?`, lr.idHash, maxCodeAttempts)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return fail(http.StatusTooManyRequests, "Zu viele Fehlversuche. Bitte neuen Code anfordern.")
		}
		given := hashCode(in.RequestID, strings.TrimSpace(in.Code))
		if subtle.ConstantTimeCompare([]byte(given), []byte(lr.codeHash)) != 1 {
			return fail(http.StatusBadRequest, "Der Code ist falsch.")
		}
		if _, err := s.db.ExecContext(ctx, `UPDATE login_requests SET verified_at = ? WHERE id_hash = ?`, now(), lr.idHash); err != nil {
			return err
		}
	}
	return s.finishVerified(w, r, lr)
}

// authPoll lets the app wait for the user to confirm the mail link, which works
// on every platform and even when the mail is opened on another device.
func (s *Server) authPoll(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		RequestID string `json:"request_id"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	lr, err := s.openRequest(r.Context(), in.RequestID)
	if err != nil {
		return err
	}
	if !lr.verified {
		writeJSON(w, http.StatusOK, map[string]string{"status": "pending"})
		return nil
	}
	return s.finishVerified(w, r, lr)
}

// finishVerified logs in a known user or asks the app to show the registration.
// The mailbox is proven at this point, so revealing the account state is safe.
func (s *Server) finishVerified(w http.ResponseWriter, r *http.Request, lr *loginRequest) error {
	ctx := r.Context()
	var userID string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM users WHERE email = ?`, lr.email).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		invited, err := queryRows(ctx, s.db,
			`SELECT f.name FROM invitations i JOIN families f ON f.id = i.family_id WHERE i.email = ? ORDER BY f.name`, lr.email)
		if err != nil {
			return err
		}
		names := []any{}
		for _, row := range invited {
			names = append(names, row["name"])
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"status": "registration_required", "email": lr.email, "invited_families": names,
		})
		return nil
	}
	if err != nil {
		return err
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := consumeRequest(ctx, tx, lr.idHash); err != nil {
		return err
	}
	token, err := createSession(ctx, tx, userID, sessionTTL)
	if err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "authenticated", "token": token})
	return nil
}

func consumeRequest(ctx context.Context, tx *database.Tx, idHash string) error {
	res, err := tx.ExecContext(ctx,
		`UPDATE login_requests SET consumed_at = ? WHERE id_hash = ? AND consumed_at IS NULL`, now(), idHash)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fail(http.StatusGone, "Die Anmeldung ist abgelaufen. Bitte neu starten.")
	}
	return nil
}

func createSession(ctx context.Context, q dbtx, userID string, ttl time.Duration) (string, error) {
	token := randomHex(32)
	_, err := q.ExecContext(ctx, `INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (?, ?, ?)`,
		hashToken(token), userID, time.Now().UTC().Add(ttl).Format(timeFormat))
	return token, err
}

// acceptInvitations turns pending invitations into memberships. The address was
// proven at login, so an invitation for it can only reach its owner.
func acceptInvitations(ctx context.Context, q dbtx, userID, email string) error {
	return acceptInvitationsOf(ctx, q, userID, email, "")
}

// acceptInvitationsOf limits that to one family, unless familyID is empty.
func acceptInvitationsOf(ctx context.Context, q dbtx, userID, email, familyID string) error {
	if _, err := q.ExecContext(ctx,
		`INSERT INTO memberships (family_id, user_id, role, is_admin, color, can_change_color, name, birthday, family_role, contact_email, profile_fields)
		 SELECT i.family_id, u.id, i.role, i.is_admin, COALESCE(NULLIF(i.color, ''), f.color, ''), i.can_change_color,
			COALESCE(f.name, u.name), COALESCE(f.birthday, u.birthday), COALESCE(f.family_role, ''), COALESCE(f.contact_email, ''), COALESCE(f.profile_fields, '[]')
		 FROM invitations i JOIN users u ON u.id = ?1
		 LEFT JOIN former_memberships f ON f.family_id = i.family_id AND f.user_id = u.id
		 WHERE i.email = ?2 AND ?3 IN ('', i.family_id)
		 ON CONFLICT DO NOTHING`, userID, email, familyID); err != nil {
		return err
	}
	if _, err := q.ExecContext(ctx,
		`DELETE FROM former_memberships WHERE user_id = ?1 AND family_id IN (SELECT family_id FROM memberships WHERE user_id = ?1)`, userID); err != nil {
		return err
	}
	_, err := q.ExecContext(ctx, `DELETE FROM invitations WHERE email = ?1 AND ?2 IN ('', family_id)`, email, familyID)
	return err
}

// insertUser adds an account. The first real account of the system becomes its sysadmin.
func insertUser(ctx context.Context, q dbtx, id, email, name string) error {
	_, err := q.ExecContext(ctx, `INSERT INTO users (id, email, name, created_at, is_sysadmin)
		VALUES (?, ?, ?, ?, CASE WHEN EXISTS (SELECT 1 FROM users WHERE email <> ?) THEN 0 ELSE 1 END)`,
		id, email, name, now(), adminEmail)
	return err
}

func (s *Server) authRegister(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		RequestID  string `json:"request_id"`
		Name       string `json:"name"`
		FamilyName string `json:"family_name"`
		FamilyType string `json:"family_type"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	lr, err := s.openRequest(ctx, in.RequestID)
	if err != nil {
		return err
	}
	if !lr.verified {
		return fail(http.StatusForbidden, "Die E-Mail-Adresse ist noch nicht bestätigt.")
	}
	name, err := required(in.Name, "Name", 100)
	if err != nil {
		return err
	}
	var invited int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM invitations WHERE email = ?`, lr.email).Scan(&invited); err != nil {
		return err
	}
	// Invited users join an existing family and need not create their own.
	familyName := strings.TrimSpace(in.FamilyName)
	createFamily := familyName != "" || invited == 0
	var familyType string
	if createFamily {
		if familyType, err = validFamilyType(in.FamilyType, "family"); err != nil {
			return err
		}
		if familyName, err = required(in.FamilyName, familyTypes[familyType].nameLabel, 100); err != nil {
			return err
		}
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := consumeRequest(ctx, tx, lr.idHash); err != nil {
		return err
	}
	userID := newID()
	if err := insertUser(ctx, tx, userID, lr.email, name); err != nil {
		if isUniqueViolation(err) {
			return fail(http.StatusConflict, "Diese E-Mail-Adresse ist bereits registriert.")
		}
		return err
	}
	if err := acceptInvitations(ctx, tx, userID, lr.email); err != nil {
		return err
	}
	if createFamily {
		familyID, err := insertFamily(ctx, tx, familyName, familyType, userID)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE users SET last_family_id = ? WHERE id = ?`, familyID, userID); err != nil {
			return err
		}
	}
	token, err := createSession(ctx, tx, userID, sessionTTL)
	if err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"status": "authenticated", "token": token})
	return nil
}

func (s *Server) authLogout(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if _, err := s.db.ExecContext(r.Context(), `DELETE FROM sessions WHERE token_hash = ?`, hashToken(token)); err != nil {
		return err
	}
	return noContent(w)
}

var loginTemplate = template.Must(template.New("login").Parse(`<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kintura Anmeldung</title>
<style>
body{font-family:system-ui,sans-serif;background:#f4f6f5;color:#1c2421;display:flex;justify-content:center;padding:48px 16px;margin:0}
main{background:#fff;border-radius:16px;padding:32px;max-width:420px;width:100%;box-shadow:0 2px 12px #0001}
h1{font-size:1.4rem;margin-top:0}
button{background:#2e6b57;color:#fff;border:0;border-radius:24px;padding:12px 24px;font-size:1rem;cursor:pointer;width:100%}
</style></head><body><main>
{{if eq .State "confirm"}}
<h1>Anmeldung bestätigen</h1>
<p>Für <strong>{{.Email}}</strong> wurde eine Anmeldung bei Kintura gestartet.</p>
<p>Bestätige nur, wenn du das gerade selbst warst.</p>
<form method="post" action="/login"><input type="hidden" name="token" value="{{.Token}}"><button type="submit">Ja, das war ich</button></form>
{{else if eq .State "done"}}
<h1>Bestätigt</h1><p>Du kannst dieses Fenster schließen und zu Kintura zurückkehren.</p>
{{else}}
<h1>Link ungültig</h1><p>Dieser Link ist abgelaufen oder wurde bereits verwendet. Bitte starte die Anmeldung in der App neu.</p>
{{end}}
</main></body></html>`))

func (s *Server) renderLogin(w http.ResponseWriter, status int, state, email, token string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(status)
	if err := loginTemplate.Execute(w, map[string]string{"State": state, "Email": email, "Token": token}); err != nil {
		log.Printf("login page: %v", err)
	}
}

// loginPage only shows a confirmation: mail scanners fetch links, so a plain GET
// must not verify anything.
func (s *Server) loginPage(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	var email string
	err := s.db.QueryRowContext(r.Context(),
		`SELECT email FROM login_requests WHERE link_hash = ? AND consumed_at IS NULL AND verified_at IS NULL AND expires_at > ?`,
		hashToken(token), now()).Scan(&email)
	if err != nil {
		s.renderLogin(w, http.StatusGone, "invalid", "", "")
		return
	}
	s.renderLogin(w, http.StatusOK, "confirm", email, token)
}

func (s *Server) loginConfirm(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	res, err := s.db.ExecContext(r.Context(),
		`UPDATE login_requests SET verified_at = ?
		 WHERE link_hash = ? AND consumed_at IS NULL AND verified_at IS NULL AND expires_at > ?`,
		now(), hashToken(r.PostFormValue("token")), now())
	if err != nil {
		s.logError(r, http.StatusInternalServerError, "Anmeldung bestätigen: "+err.Error())
		s.renderLogin(w, http.StatusInternalServerError, "invalid", "", "")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		s.renderLogin(w, http.StatusGone, "invalid", "", "")
		return
	}
	s.renderLogin(w, http.StatusOK, "done", "", "")
}
