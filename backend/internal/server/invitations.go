package server

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// An invitation can be answered in two ways: the person logs in with the address, or
// passes the code from the mail to an admin, who enters it for them. The code proves
// the mailbox just like a login does, but people read such a mail later than one they
// asked for, so it lasts longer.
const (
	invitationCodeTTL    = 7 * 24 * time.Hour
	invitationMailWindow = 24 * time.Hour
)

// noteInvitationMail refuses another mail to an address that got enough of them from
// this family. The count outlives the invitation: every mail means a new code to guess
// and an inbox someone else chose, and withdrawing and inviting again must not reset it.
func (s *Server) noteInvitationMail(ctx context.Context, familyID, email string) error {
	var sent int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM invitation_mails WHERE family_id = ? AND email = ? AND expires_at > ?`,
		familyID, email, now()).Scan(&sent); err != nil {
		return err
	}
	if sent >= maxOpenRequests {
		return fail(http.StatusTooManyRequests, "An diese Adresse gingen heute schon genug Einladungen. Bitte morgen erneut versuchen.")
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO invitation_mails (family_id, email, expires_at) VALUES (?, ?, ?)`,
		familyID, email, time.Now().UTC().Add(invitationMailWindow).Format(timeFormat))
	return err
}

func (s *Server) invitationMailBody(ctx context.Context, c reqCtx, code string) (string, error) {
	var familyName string
	if err := s.db.QueryRowContext(ctx, `SELECT name FROM families WHERE id = ?`, c.familyID).Scan(&familyName); err != nil {
		return "", err
	}
	return fmt.Sprintf("Hallo,\n\ndu wurdest bei Kintura %s \"%s\" eingeladen.\n\n"+
		"Öffne die App und melde dich mit dieser E-Mail-Adresse an, um beizutreten.\n\n"+
		"Alternativ kannst du diesen Code an die Person weitergeben, die dich eingeladen hat:\n\n    %s\n\n"+
		"Wer ihn eingibt, nimmt dich dort auf. Gib ihn also nur weiter, wenn du das möchtest. Er ist 7 Tage gültig.\n"+
		"Falls du nichts davon weißt, ignoriere diese Mail einfach.\n", familyTypes[c.familyType].into, familyName, code), nil
}

func invitationCodeExpiry() string {
	return time.Now().UTC().Add(invitationCodeTTL).Format(timeFormat)
}

// resendInvitation sends a mail with a new code. The old code only ends once the new
// one is on its way, so a failed mail takes nothing away.
func (s *Server) resendInvitation(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	var email string
	err := s.db.QueryRowContext(ctx, `SELECT email FROM invitations WHERE id = ? AND family_id = ?`, id, c.familyID).Scan(&email)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	if err := s.noteInvitationMail(ctx, c.familyID, email); err != nil {
		return err
	}
	code, err := randomCode()
	if err != nil {
		return err
	}
	body, err := s.invitationMailBody(ctx, c, code)
	if err != nil {
		return err
	}
	if err := s.mailer.Send(email, "Einladung zu Kintura", body); err != nil {
		return &apiError{http.StatusBadGateway, "Die E-Mail konnte nicht versendet werden.", fmt.Errorf("Einladungs-Mail: %w", err)}
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE invitations SET code_hash = ?, code_attempts = 0, code_expires_at = ? WHERE id = ?`,
		hashCode(id, code), invitationCodeExpiry(), id); err != nil {
		return err
	}
	return noContent(w)
}

// confirmInvitation lets an admin answer the invitation with the code from its mail.
// Whether the address has an account only comes out once the code was right; if it has
// none, the app asks for the name it needs and sends the code again.
func (s *Server) confirmInvitation(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Code string `json:"code"`
		Name string `json:"name"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx, id := r.Context(), r.PathValue("id")
	var email, codeHash string
	var valid bool
	err := s.db.QueryRowContext(ctx,
		`SELECT email, code_hash, code_expires_at > ? FROM invitations WHERE id = ? AND family_id = ?`,
		now(), id, c.familyID).Scan(&email, &codeHash, &valid)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	if !valid {
		return fail(http.StatusGone, "Der Code ist abgelaufen. Bitte die Einladung erneut senden.")
	}
	// Count the attempt before comparing, so parallel guesses cannot exceed the limit.
	res, err := s.db.ExecContext(ctx, `UPDATE invitations SET code_attempts = code_attempts + 1 WHERE id = ? AND code_attempts < ?`, id, maxCodeAttempts)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fail(http.StatusTooManyRequests, "Zu viele Fehlversuche. Bitte die Einladung erneut senden.")
	}
	given := hashCode(id, strings.TrimSpace(in.Code))
	if subtle.ConstantTimeCompare([]byte(given), []byte(codeHash)) != 1 {
		return fail(http.StatusBadRequest, "Der Code ist falsch.")
	}

	var account string
	err = s.db.QueryRowContext(ctx, `SELECT id FROM users WHERE email = ?`, email).Scan(&account)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	isNew := account == ""
	var name string
	if isNew {
		if strings.TrimSpace(in.Name) == "" {
			// The code was right, so asking for the name must not use up the attempts.
			if _, err := s.db.ExecContext(ctx, `UPDATE invitations SET code_attempts = 0 WHERE id = ?`, id); err != nil {
				return err
			}
			writeJSON(w, http.StatusOK, map[string]string{"status": "name_required"})
			return nil
		}
		if name, err = required(in.Name, "Name", 100); err != nil {
			return err
		}
		account = newID()
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if isNew {
		if err := insertUser(ctx, tx, account, email, name); err != nil {
			if isUniqueViolation(err) {
				return fail(http.StatusConflict, "Diese E-Mail-Adresse ist gerade registriert worden. Bitte erneut versuchen.")
			}
			return err
		}
	}
	// Only this family: the other invitations of the address were not part of the code.
	if err := acceptInvitationsOf(ctx, tx, account, email, c.familyID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}

	var familyName string
	if err := s.db.QueryRowContext(ctx, `SELECT name FROM families WHERE id = ?`, c.familyID).Scan(&familyName); err != nil {
		return err
	}
	// Whoever was taken in should hear about it, in case they did not pass the code on.
	notice := fmt.Sprintf("Hallo,\n\ndu wurdest bei Kintura %s \"%s\" aufgenommen. Melde dich mit dieser E-Mail-Adresse an, um dabei zu sein.\n\n"+
		"Falls du das nicht möchtest, kannst du den Kreis in der App wieder verlassen.\n", familyTypes[c.familyType].into, familyName)
	if err := s.mailer.Send(email, "Du bist jetzt bei Kintura dabei", notice); err != nil {
		s.logError(r, http.StatusBadGateway, fmt.Sprintf("Hinweis zur Aufnahme an %s: %v", email, err))
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "joined"})
	return nil
}
