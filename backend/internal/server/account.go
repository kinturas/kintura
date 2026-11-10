package server

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"
)

const maxFeedbackLength = 5000

// requestEmailChange sends a code to the new address. The account only moves once
// that code comes back, which proves the mailbox.
func (s *Server) requestEmailChange(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if err := s.refuseManaged(r, c, "Eine E-Mail-Adresse kann dir ein Admin hinzufügen."); err != nil {
		return err
	}
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
	ctx := r.Context()
	var current string
	if err := s.db.QueryRowContext(ctx, `SELECT email FROM users WHERE id = ?`, c.userID).Scan(&current); err != nil {
		return err
	}
	// The account behind the token login has no mailbox, and logs in by its address.
	if current == adminEmail {
		return fail(http.StatusConflict, "Die Adresse dieses Kontos lässt sich nicht ändern.")
	}
	if email == current {
		return fail(http.StatusBadRequest, "Das ist bereits deine E-Mail-Adresse.")
	}
	var taken int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE email = ?`, email).Scan(&taken); err != nil {
		return err
	}
	if taken > 0 {
		return fail(http.StatusConflict, "Diese E-Mail-Adresse wird bereits verwendet.")
	}

	code, err := s.newEmailCode(ctx, c.userID, email)
	if err != nil {
		return err
	}
	body := fmt.Sprintf("Hallo,\n\ndein Code zum Ändern der E-Mail-Adresse bei Kintura lautet:\n\n    %s\n\n"+
		"Er ist 15 Minuten gültig. Falls du das nicht warst, ignoriere diese Mail einfach.\n", code)
	if err := s.mailer.Send(email, "Neue E-Mail-Adresse bestätigen", body); err != nil {
		return &apiError{http.StatusBadGateway, "Die E-Mail konnte nicht versendet werden.", fmt.Errorf("Adressänderung: %w", err)}
	}
	return noContent(w)
}

func (s *Server) confirmEmailChange(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Code string `json:"code"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	email, err := s.checkEmailCode(ctx, c.userID, in.Code)
	if err != nil {
		return err
	}
	var current string
	if err := s.db.QueryRowContext(ctx, `SELECT email FROM users WHERE id = ?`, c.userID).Scan(&current); err != nil {
		return err
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// Someone may have registered with the address in the meantime.
	if _, err := tx.ExecContext(ctx, `UPDATE users SET email = ? WHERE id = ?`, email, c.userID); err != nil {
		if isUniqueViolation(err) {
			return fail(http.StatusConflict, "Diese E-Mail-Adresse wird bereits verwendet.")
		}
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM email_changes WHERE user_id = ?`, c.userID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	// Whoever had the old address should hear about it, in case it was not them.
	notice := fmt.Sprintf("Hallo,\n\ndie Anmeldung bei Kintura läuft ab jetzt über %s statt über diese Adresse.\n\n"+
		"Falls du das nicht warst, wende dich bitte an den Betreiber.\n", email)
	if err := s.mailer.Send(current, "Deine E-Mail-Adresse wurde geändert", notice); err != nil {
		s.logError(r, http.StatusBadGateway, fmt.Sprintf("Hinweis zur Adressänderung an %s: %v", current, err))
	}
	return noContent(w)
}

// randomCode makes the six digits someone reads from a mail and types in.
func randomCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// newEmailCode prepares a code that proves the mailbox of email, for userID. Every
// code means a mail to an address someone chose, so their number is limited.
func (s *Server) newEmailCode(ctx context.Context, userID, email string) (string, error) {
	var sends int
	err := s.db.QueryRowContext(ctx, `SELECT sends FROM email_changes WHERE user_id = ? AND expires_at > ?`, userID, now()).Scan(&sends)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if sends >= maxOpenRequests {
		return "", fail(http.StatusTooManyRequests, "Zu viele Versuche. Bitte in ein paar Minuten erneut versuchen.")
	}
	code, err := randomCode()
	if err != nil {
		return "", err
	}
	expires := time.Now().UTC().Add(loginTTL).Format(timeFormat)
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO email_changes (user_id, email, code_hash, attempts, sends, expires_at) VALUES (?, ?, ?, 0, ?, ?)
		 ON CONFLICT (user_id) DO UPDATE SET email = excluded.email, code_hash = excluded.code_hash, attempts = 0,
			sends = excluded.sends, expires_at = excluded.expires_at`,
		userID, email, hashCode(userID, code), sends+1, expires); err != nil {
		return "", err
	}
	return code, nil
}

// checkEmailCode returns the address a code for userID was sent to, if it is right.
func (s *Server) checkEmailCode(ctx context.Context, userID, code string) (string, error) {
	var email, codeHash string
	err := s.db.QueryRowContext(ctx, `SELECT email, code_hash FROM email_changes WHERE user_id = ? AND expires_at > ?`, userID, now()).Scan(&email, &codeHash)
	if errors.Is(err, sql.ErrNoRows) {
		return "", fail(http.StatusGone, "Der Code ist abgelaufen. Bitte neu anfordern.")
	}
	if err != nil {
		return "", err
	}
	// Count the attempt before comparing, so parallel guesses cannot exceed the limit.
	res, err := s.db.ExecContext(ctx, `UPDATE email_changes SET attempts = attempts + 1 WHERE user_id = ? AND attempts < ?`, userID, maxCodeAttempts)
	if err != nil {
		return "", err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return "", fail(http.StatusTooManyRequests, "Zu viele Fehlversuche. Bitte neuen Code anfordern.")
	}
	given := hashCode(userID, strings.TrimSpace(code))
	if subtle.ConstantTimeCompare([]byte(given), []byte(codeHash)) != 1 {
		return "", fail(http.StatusBadRequest, "Der Code ist falsch.")
	}
	return email, nil
}

// setNotifications decides whether the user gets reminders by mail. What the account
// itself needs, like login codes, still arrives.
func (s *Server) setNotifications(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	// Reminders go by mail, and the internal address is nobody's mailbox.
	if err := s.refuseManaged(r, c, "Ohne E-Mail-Adresse gibt es keine Mitteilungen."); err != nil {
		return err
	}
	var in struct {
		Enabled bool `json:"enabled"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(r.Context(), `UPDATE users SET notifications = ? WHERE id = ?`, in.Enabled, c.userID); err != nil {
		return err
	}
	return noContent(w)
}

// sendFeedback mails the text to everyone with the sysadmin flag. It counts as sent
// if it reached at least one of them.
func (s *Server) sendFeedback(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Text string `json:"text"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	text, err := required(in.Text, "Text", maxFeedbackLength)
	if err != nil {
		return err
	}
	ctx := r.Context()
	var name, email string
	if err := s.db.QueryRowContext(ctx, `SELECT name, email FROM users WHERE id = ?`, c.userID).Scan(&name, &email); err != nil {
		return err
	}
	if isInternalEmail(email) {
		email = "ohne E-Mail-Adresse"
	}
	// The account behind the token login has no mailbox.
	admins, err := queryRows(ctx, s.db, `SELECT email FROM users WHERE is_sysadmin = 1 AND email <> ?`, adminEmail)
	if err != nil {
		return err
	}
	body := fmt.Sprintf("Feedback von %s <%s>:\n\n%s\n", name, email, text)
	sent := false
	for _, admin := range admins {
		to := admin["email"].(string)
		if err := s.mailer.Send(to, "Feedback zu Kintura", body); err != nil {
			s.logError(r, http.StatusBadGateway, fmt.Sprintf("Feedback an %s: %v", to, err))
			continue
		}
		sent = true
	}
	if !sent {
		return fail(http.StatusBadGateway, "Das Feedback konnte nicht versendet werden.")
	}
	return noContent(w)
}
