package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/kinturas/kintura/backend/internal/database"
	"github.com/kinturas/kintura/backend/internal/mail"
	"github.com/kinturas/kintura/backend/internal/storage"
)

const timeFormat = "2006-01-02T15:04:05Z"

type Server struct {
	db        *database.DB
	mailer    mail.Mailer
	files     storage.Store
	publicURL string
	corsOrig  string
	adminKey  string
	timezone  string // default time zone of events, see defaultZone
	version   string
	webDir    string // relative to the working directory, overridden in tests

	placesURL  string // overrides the address search in tests
	placesMu   sync.Mutex
	placesLast time.Time

	holidaysURL       string // overrides the holiday service in tests
	allowPrivateFeeds bool   // lets tests fetch calendars from their local server
}

// apiError is an error whose message is safe to show to the client. The optional
// cause is only written to the error log.
type apiError struct {
	status int
	msg    string
	cause  error
}

func (e *apiError) Error() string { return e.msg }

func fail(status int, msg string) error { return &apiError{status: status, msg: msg} }

var errNotFound = fail(http.StatusNotFound, "Nicht gefunden")

const restrictedRole = "restrict_user"

// reqCtx identifies the caller; familyID, familyType, role and isAdmin are only set on family routes.
type reqCtx struct {
	userID, familyID, familyType, role string
	isAdmin                            bool
}

func (c reqCtx) isManager() bool { return c.role == "manager" }

type handlerFunc func(w http.ResponseWriter, r *http.Request) error
type authedFunc func(w http.ResponseWriter, r *http.Request, c reqCtx) error

func (s *Server) wrap(h handlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r = r.WithContext(context.WithValue(r.Context(), logScopeKey{}, &logScope{}))
		// Deferred cleanups of the handler have run by now, so the log may use s.db.
		defer func() {
			v := recover()
			if v == nil {
				return
			}
			if v == http.ErrAbortHandler {
				panic(v)
			}
			s.logError(r, http.StatusInternalServerError, fmt.Sprintf("panic: %v", v))
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Interner Fehler"})
		}()
		err := h(w, r)
		if err == nil {
			return
		}
		var ae *apiError
		var tooBig *http.MaxBytesError
		switch {
		case errors.As(err, &ae):
			if ae.status >= http.StatusInternalServerError {
				msg := ae.msg
				if ae.cause != nil {
					msg = ae.cause.Error()
				}
				s.logError(r, ae.status, msg)
			}
			writeJSON(w, ae.status, map[string]string{"error": ae.msg})
		case errors.As(err, &tooBig):
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "Datei ist zu groß"})
		default:
			// A client that hung up is not a server error.
			if !errors.Is(err, context.Canceled) {
				s.logError(r, http.StatusInternalServerError, err.Error())
			}
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Interner Fehler"})
		}
	}
}

// authed requires a valid session.
func (s *Server) authed(h authedFunc) http.HandlerFunc {
	return s.wrap(func(w http.ResponseWriter, r *http.Request) error {
		userID, err := s.sessionUser(r)
		if err != nil {
			return err
		}
		scopeOf(r).userID = userID
		return h(w, r, reqCtx{userID: userID})
	})
}

// member requires a session and membership in the family from the {fid} path
// value. This is the tenant boundary: handlers must scope queries to c.familyID.
func (s *Server) member(h authedFunc) http.HandlerFunc {
	return s.authed(func(w http.ResponseWriter, r *http.Request, c reqCtx) error {
		c.familyID = r.PathValue("fid")
		err := s.db.QueryRowContext(r.Context(),
			`SELECT m.is_admin, m.role, f.type FROM memberships m JOIN families f ON f.id = m.family_id
			 WHERE m.family_id = ? AND m.user_id = ?`, c.familyID, c.userID).Scan(&c.isAdmin, &c.role, &c.familyType)
		if errors.Is(err, sql.ErrNoRows) {
			return errNotFound
		}
		if err != nil {
			return err
		}
		scopeOf(r).familyID = c.familyID
		return h(w, r, c)
	})
}

// admin additionally requires the admin flag.
func (s *Server) admin(h authedFunc) http.HandlerFunc {
	return s.member(func(w http.ResponseWriter, r *http.Request, c reqCtx) error {
		if !c.isAdmin {
			return fail(http.StatusForbidden, "Nur für Admins erlaubt")
		}
		return h(w, r, c)
	})
}

func (s *Server) sessionUser(r *http.Request) (string, error) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || token == "" {
		return "", fail(http.StatusUnauthorized, "Nicht angemeldet")
	}
	var userID string
	err := s.db.QueryRowContext(r.Context(),
		`SELECT user_id FROM sessions WHERE token_hash = ? AND expires_at > ?`, hashToken(token), now()).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", fail(http.StatusUnauthorized, "Nicht angemeldet")
	}
	return userID, err
}

func (s *Server) getVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"version": s.version})
}

// webApp serves the Flutter web build. Without the directory, as in development,
// every path is simply not found.
func (s *Server) webApp(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// File names stay the same across releases.
	w.Header().Set("Cache-Control", "no-cache")
	http.FileServer(http.Dir(s.webDir)).ServeHTTP(w, r)
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /", s.webApp)
	mux.HandleFunc("GET /api/version", s.getVersion)
	mux.Handle("GET /api/pages/{slug}", s.wrap(s.getPage))

	mux.Handle("POST /api/auth/request", s.wrap(s.authRequest))
	mux.Handle("POST /api/auth/verify", s.wrap(s.authVerify))
	mux.Handle("POST /api/auth/poll", s.wrap(s.authPoll))
	mux.Handle("POST /api/auth/code", s.wrap(s.authCode))
	mux.Handle("POST /api/auth/register", s.wrap(s.authRegister))
	mux.Handle("POST /api/auth/logout", s.authed(s.authLogout))
	mux.HandleFunc("GET /login", s.loginPage)
	mux.HandleFunc("POST /login", s.loginConfirm)

	mux.Handle("GET /api/me", s.authed(s.getMe))
	mux.Handle("POST /api/me/email", s.authed(s.requestEmailChange))
	mux.Handle("POST /api/me/email/confirm", s.authed(s.confirmEmailChange))
	mux.Handle("PUT /api/me/notifications", s.authed(s.setNotifications))
	mux.Handle("POST /api/feedback", s.authed(s.sendFeedback))
	mux.Handle("POST /api/families", s.authed(s.createFamily))
	mux.Handle("POST /api/families/{fid}/select", s.member(s.selectFamily))
	mux.Handle("PUT /api/families/{fid}", s.admin(s.updateFamily))
	mux.Handle("GET /api/families/{fid}/members", s.member(s.listMembers))
	mux.Handle("GET /api/families/{fid}/colors", s.member(s.listColors))
	mux.Handle("POST /api/families/{fid}/colors", s.admin(s.createColor))
	mux.Handle("PUT /api/families/{fid}/colors/{id}", s.admin(s.updateColor))
	mux.Handle("DELETE /api/families/{fid}/colors/{id}", s.admin(s.deleteColor))
	mux.Handle("PUT /api/families/{fid}/color", s.member(s.setOwnColor))
	mux.Handle("GET /api/families/{fid}/profile", s.member(s.getProfile))
	mux.Handle("PUT /api/families/{fid}/profile", s.member(s.putProfile))
	mux.Handle("GET /api/families/{fid}/categories", s.member(s.listCategories))
	mux.Handle("POST /api/families/{fid}/categories", s.admin(s.createCategory))
	mux.Handle("PUT /api/families/{fid}/categories/order", s.admin(s.reorderCategories))
	mux.Handle("PUT /api/families/{fid}/categories/{id}", s.admin(s.updateCategory))
	mux.Handle("DELETE /api/families/{fid}/categories/{id}", s.admin(s.deleteCategory))
	mux.Handle("PUT /api/families/{fid}/members/{uid}", s.admin(s.updateMember))
	mux.Handle("PUT /api/families/{fid}/members/{uid}/color", s.admin(s.setMemberColor))
	mux.Handle("POST /api/families/{fid}/members", s.admin(s.createManagedMember))
	mux.Handle("GET /api/families/{fid}/members/{uid}/profile", s.admin(s.getMemberProfile))
	mux.Handle("PUT /api/families/{fid}/members/{uid}/profile", s.admin(s.putMemberProfile))
	mux.Handle("POST /api/families/{fid}/members/{uid}/login-code", s.admin(s.createLoginCode))
	mux.Handle("POST /api/families/{fid}/members/{uid}/email", s.admin(s.requestMemberEmail))
	mux.Handle("POST /api/families/{fid}/members/{uid}/email/confirm", s.admin(s.confirmMemberEmail))
	mux.Handle("DELETE /api/families/{fid}/members/{uid}", s.member(s.removeMember))
	mux.Handle("POST /api/families/{fid}/leave", s.member(s.leaveFamily))
	mux.Handle("DELETE /api/families/{fid}/former/{uid}", s.admin(s.deleteFormerMember))
	mux.Handle("POST /api/families/{fid}/invitations", s.admin(s.createInvitation))
	mux.Handle("DELETE /api/families/{fid}/invitations/{id}", s.admin(s.deleteInvitation))
	mux.Handle("POST /api/families/{fid}/invitations/{id}/resend", s.admin(s.resendInvitation))
	mux.Handle("POST /api/families/{fid}/invitations/{id}/confirm", s.admin(s.confirmInvitation))

	mux.Handle("GET /api/families/{fid}/lists", s.member(s.listLists))
	mux.Handle("POST /api/families/{fid}/lists", s.member(s.createList))
	mux.Handle("DELETE /api/families/{fid}/lists/{id}", s.member(s.deleteList))
	mux.Handle("GET /api/families/{fid}/lists/{id}/items", s.member(s.listItems))
	mux.Handle("POST /api/families/{fid}/lists/{id}/items", s.member(s.createItem))
	mux.Handle("PUT /api/families/{fid}/items/{id}", s.member(s.updateItem))
	mux.Handle("DELETE /api/families/{fid}/items/{id}", s.member(s.deleteItem))

	mux.Handle("GET /api/families/{fid}/events", s.member(s.listEvents))
	mux.Handle("POST /api/families/{fid}/events", s.member(s.createEvent))
	mux.Handle("GET /api/families/{fid}/events/{id}", s.member(s.getEvent))
	mux.Handle("PUT /api/families/{fid}/events/{id}", s.member(s.updateEvent))
	mux.Handle("DELETE /api/families/{fid}/events/{id}", s.member(s.deleteEvent))
	mux.Handle("PUT /api/families/{fid}/events/{id}/creator", s.member(s.setEventCreator))
	mux.Handle("POST /api/families/{fid}/events/{id}/comments", s.member(s.addEventComment))
	mux.Handle("POST /api/families/{fid}/events/{id}/copy", s.member(s.copyEvent))
	mux.Handle("GET /api/families/{fid}/events/{id}/ics", s.member(s.eventICS))
	mux.Handle("POST /api/families/{fid}/calendar-entries/ics", s.member(s.entryICS))
	mux.Handle("POST /api/families/{fid}/events/{id}/attachments", s.member(s.uploadAttachment))
	mux.Handle("POST /api/families/{fid}/events/{id}/attachments/{fileId}/link", s.member(s.attachmentLink))
	mux.Handle("DELETE /api/families/{fid}/events/{id}/attachments/{fileId}", s.member(s.deleteAttachment))
	mux.Handle("GET /api/families/{fid}/calendars", s.member(s.getCalendars))
	mux.Handle("PUT /api/families/{fid}/calendars/{key}", s.member(s.putCalendar))
	mux.Handle("POST /api/families/{fid}/calendars/{key}/share", s.member(s.createShare))
	mux.Handle("DELETE /api/families/{fid}/calendars/{key}/share", s.member(s.deleteShare))
	mux.Handle("GET /api/families/{fid}/calendar-entries", s.member(s.calendarEntries))
	mux.Handle("GET /api/families/{fid}/calendar-prefs", s.member(s.getCalendarPrefs))
	mux.Handle("PUT /api/families/{fid}/calendar-prefs", s.member(s.putCalendarPrefs))
	mux.Handle("PUT /api/families/{fid}/calendar-cleanup", s.admin(s.putCleanup))
	mux.Handle("POST /api/families/{fid}/calendar-feeds", s.member(s.createFeed))
	mux.Handle("POST /api/families/{fid}/calendar-feeds/{id}/refresh", s.member(s.refreshFeed))
	mux.Handle("DELETE /api/families/{fid}/calendar-feeds/{id}", s.member(s.deleteFeed))
	mux.HandleFunc("GET /cal/{token}", s.shareCalendar)
	mux.Handle("GET /api/timezones", s.authed(s.listTimezones))
	mux.Handle("GET /api/places", s.authed(s.searchPlaces))

	mux.Handle("GET /api/families/{fid}/meals", s.member(s.listMeals))
	mux.Handle("PUT /api/families/{fid}/meals/{date}/{slot}", s.member(s.putMeal))

	mux.Handle("GET /api/families/{fid}/messages", s.member(s.listMessages))
	mux.Handle("POST /api/families/{fid}/messages", s.member(s.createMessage))

	mux.Handle("GET /api/families/{fid}/special-days", s.member(s.listSpecialDays))
	mux.Handle("POST /api/families/{fid}/special-days", s.member(s.createSpecialDay))
	mux.Handle("PUT /api/families/{fid}/special-days/{id}", s.member(s.updateSpecialDay))
	mux.Handle("DELETE /api/families/{fid}/special-days/{id}", s.member(s.deleteSpecialDay))

	mux.Handle("GET /api/families/{fid}/files", s.member(s.listFiles))
	mux.Handle("POST /api/families/{fid}/files", s.member(s.uploadFile))
	mux.Handle("GET /api/families/{fid}/files/{id}/content", s.member(s.fileContent))
	mux.Handle("POST /api/families/{fid}/files/{id}/link", s.member(s.fileLink))
	mux.Handle("DELETE /api/families/{fid}/files/{id}", s.member(s.deleteFile))
	mux.HandleFunc("GET /dl/{token}", s.download)

	mux.HandleFunc("GET /admin", adminAsset("index.html", "text/html; charset=utf-8"))
	mux.HandleFunc("GET /admin/admin.js", adminAsset("admin.js", "text/javascript; charset=utf-8"))
	mux.HandleFunc("GET /admin/admin.css", adminAsset("admin.css", "text/css; charset=utf-8"))
	mux.HandleFunc("GET /admin/token.js", adminAsset("token.js", "text/javascript; charset=utf-8"))
	mux.HandleFunc("GET /login/token", adminAsset("token.html", "text/html; charset=utf-8"))
	mux.Handle("POST /api/auth/token", s.wrap(s.authToken))
	mux.Handle("GET /api/admin/status", s.sysadmin(s.adminStatus))
	mux.Handle("POST /api/admin/activate", s.sysadmin(s.adminActivate))
	mux.Handle("GET /api/admin/families", s.dashboard(s.adminFamilies))
	mux.Handle("GET /api/admin/users", s.dashboard(s.adminUsers))
	mux.Handle("GET /api/admin/log", s.dashboard(s.adminLog))
	mux.Handle("GET /api/admin/pages", s.dashboard(s.adminPages))
	mux.Handle("PUT /api/admin/pages/{slug}", s.dashboard(s.adminUpdatePage))

	return s.cors(mux)
}

// cors allows the Flutter web build to call the API. Auth uses bearer tokens,
// never cookies, so a wildcard origin does not expose sessions.
func (s *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", s.corsOrig)
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) cleanup(ctx context.Context) {
	t := now()
	for _, q := range []string{
		`DELETE FROM sessions WHERE expires_at <= ?`,
		`DELETE FROM login_requests WHERE expires_at <= ?`,
		`DELETE FROM download_tokens WHERE expires_at <= ?`,
		`DELETE FROM invitation_mails WHERE expires_at <= ?`,
		`DELETE FROM login_codes WHERE expires_at <= ?`,
		// Only future occurrences are ever reminded of.
		`DELETE FROM reminder_sent WHERE occurrence <= ?`,
	} {
		if _, err := s.db.ExecContext(ctx, q, t); err != nil {
			s.logError(nil, 0, "cleanup: "+err.Error())
		}
	}
	s.trimErrorLog(ctx)
	s.cleanupEvents(ctx)
}

func now() string { return time.Now().UTC().Format(timeFormat) }

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func newID() string { return randomHex(16) }

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func noContent(w http.ResponseWriter) error {
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func readJSON(w http.ResponseWriter, r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			return err
		}
		return fail(http.StatusBadRequest, "Ungültige Anfrage")
	}
	return nil
}

// requireAffected turns an update or delete that matched no row into a 404.
func requireAffected(res sql.Result, err error) error {
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		return errNotFound
	}
	return nil
}

// nullable stores empty optional strings as NULL.
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// required trims a mandatory text field and enforces its maximum length.
func required(value, label string, maxLen int) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fail(http.StatusBadRequest, label+" fehlt")
	}
	if len([]rune(value)) > maxLen {
		return "", fail(http.StatusBadRequest, label+" ist zu lang")
	}
	return value, nil
}

func validDate(s string) bool {
	_, err := time.Parse("2006-01-02", s)
	return err == nil
}

func normalizeTime(s string) (string, error) {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return "", fail(http.StatusBadRequest, "Ungültiger Zeitpunkt")
	}
	return t.UTC().Format(timeFormat), nil
}
