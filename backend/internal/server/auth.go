package server

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
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
	requestID := randomHex(32)
	expires := time.Now().UTC().Add(loginTTL)
	// link_hash is left from the login links that mails once carried; it only has to be unique.
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO login_requests (id_hash, email, code_hash, link_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		hashToken(requestID), email, hashCode(requestID, code), hashToken(randomHex(32)), expires.Format(timeFormat), now()); err != nil {
		return err
	}

	// The code alone: it is typed into the app, and no link in a mail logs anyone in.
	body := fmt.Sprintf("Hallo,\n\ndein Anmeldecode für Kintura lautet:\n\n    %s\n\n"+
		"Gib ihn in der App ein. Er ist 15 Minuten gültig. Falls du das nicht warst, ignoriere diese Mail einfach.\n\n%s",
		code, s.appLinks())
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

// finishVerified logs in a known user or asks the app to show the registration.
// The mailbox is proven at this point, so revealing the account state is safe.
func (s *Server) finishVerified(w http.ResponseWriter, r *http.Request, lr *loginRequest) error {
	ctx := r.Context()
	var userID string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM users WHERE email = ?`, lr.email).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		names, err := s.invitedFamilyNames(ctx, lr.email)
		if err != nil {
			return err
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

// invitedFamilyNames are the families that invited someone about to register, the
// earliest first: that one they join with the registration, see firstInvitation.
func (s *Server) invitedFamilyNames(ctx context.Context, email string) ([]any, error) {
	invited, err := queryRows(ctx, s.db,
		`SELECT f.name FROM invitations i JOIN families f ON f.id = i.family_id WHERE i.email = ? ORDER BY i.created_at, i.id`, email)
	if err != nil {
		return nil, err
	}
	names := []any{}
	for _, row := range invited {
		names = append(names, row["name"])
	}
	return names, nil
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

// acceptInvitationsOf turns the invitation of one family into a membership. Each one
// takes the owner's yes: at the registration for the first, in the app for the others,
// or the code from the mail. With an empty familyID it would take them all.
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
	// Invited users join an existing family and need not create their own: the one
	// that asked first. Any others wait in the app, to be accepted like by anyone.
	var firstInvitation string
	err = s.db.QueryRowContext(ctx, `SELECT family_id FROM invitations WHERE email = ? ORDER BY created_at, id LIMIT 1`, lr.email).Scan(&firstInvitation)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	familyName := strings.TrimSpace(in.FamilyName)
	createFamily := familyName != "" || firstInvitation == ""
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
	if firstInvitation != "" {
		if err := acceptInvitationsOf(ctx, tx, userID, lr.email, firstInvitation); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE users SET last_family_id = ? WHERE id = ?`, firstInvitation, userID); err != nil {
			return err
		}
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
