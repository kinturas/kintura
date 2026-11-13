package server

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/kinturas/kintura/backend/internal/database"
)

// A managed member is someone in a family without an address of their own, a small
// child for example. They appear like any other member, but no mail reaches them and
// they can only log in with a code an admin hands them. An admin looks after their
// profile, until an address proven by a code turns them into a real account.
//
// The email column has to be unique and filled, so they get an address in the domain
// that normalizeEmail refuses, which no login can ask for.
const internalEmailDomain = "@kintura"

func (s *Server) createManagedMember(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Name           string `json:"name"`
		Role           string `json:"role"`
		Color          string `json:"color"`
		CanChangeColor *bool  `json:"can_change_color"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	name, err := required(in.Name, "Name", 100)
	if err != nil {
		return err
	}
	if !assignableRoles[in.Role] {
		return fail(http.StatusBadRequest, "Ungültige Rolle")
	}
	ctx := r.Context()
	if err := s.checkMemberColor(ctx, c.familyID, in.Color); err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	id := newID()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO users (id, email, name, created_at, is_managed, notifications) VALUES (?, ?, ?, ?, 1, 0)`,
		id, "managed-"+id+internalEmailDomain, name, now()); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO memberships (family_id, user_id, role, is_admin, name, color, can_change_color) VALUES (?, ?, ?, 0, ?, ?, ?)`,
		c.familyID, id, in.Role, name, in.Color, in.CanChangeColor == nil || *in.CanChangeColor); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

// managedMember guards the routes that act for someone else: they only ever reach a
// managed member of this family, never a person with an account of their own.
func (s *Server) managedMember(ctx context.Context, c reqCtx, userID string) error {
	var managed bool
	err := s.db.QueryRowContext(ctx,
		`SELECT u.is_managed FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.family_id = ? AND m.user_id = ?`,
		c.familyID, userID).Scan(&managed)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	if !managed {
		return fail(http.StatusForbidden, "Dieses Mitglied verwaltet sich selbst.")
	}
	return nil
}

// getMemberProfile lets everyone in a family read the profile of any member there,
// as it shows on their page. Changing it stays with the member, or an admin for a
// managed one, see putMemberProfile.
func (s *Server) getMemberProfile(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var found int
	err := s.db.QueryRowContext(r.Context(), `SELECT 1 FROM memberships WHERE family_id = ? AND user_id = ?`,
		c.familyID, r.PathValue("uid")).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	return s.writeProfile(w, r, c.familyID, r.PathValue("uid"))
}

func (s *Server) putMemberProfile(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if err := s.managedMember(r.Context(), c, r.PathValue("uid")); err != nil {
		return err
	}
	return s.saveProfile(w, r, c.familyID, r.PathValue("uid"))
}

// requestMemberEmail sends the code for an address to give a managed member. The
// address may already have an account elsewhere, as long as it is not in this family.
func (s *Server) requestMemberEmail(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, target := r.Context(), r.PathValue("uid")
	if err := s.managedMember(ctx, c, target); err != nil {
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
	if err := s.checkFreeInFamily(ctx, s.db, c.familyID, email); err != nil {
		return err
	}
	code, err := s.newEmailCode(ctx, target, email)
	if err != nil {
		return err
	}
	var family string
	if err := s.db.QueryRowContext(ctx, `SELECT name FROM families WHERE id = ?`, c.familyID).Scan(&family); err != nil {
		return err
	}
	// Whoever passes this code on joins the family, so the mail has to say that.
	body := fmt.Sprintf("Hallo,\n\ndiese Adresse soll bei Kintura einem Mitglied im Kreis \"%s\" zugeordnet werden. Der Code dafür lautet:\n\n    %s\n\n"+
		"Gib ihn nur weiter, wenn du das möchtest: Wer ihn eingibt, verbindet diese Adresse und ein vorhandenes Konto dazu mit dem Kreis.\n"+
		"Er ist 15 Minuten gültig. Falls du nichts davon weißt, ignoriere diese Mail einfach.\n", family, code)
	if err := s.mailer.Send(email, "Adresse für Kintura bestätigen", body); err != nil {
		return &apiError{http.StatusBadGateway, "Die E-Mail konnte nicht versendet werden.", fmt.Errorf("Adresse für Mitglied: %w", err)}
	}
	return noContent(w)
}

func (s *Server) checkFreeInFamily(ctx context.Context, q dbtx, familyID, email string) error {
	var taken int
	if err := q.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.family_id = ? AND u.email = ?`,
		familyID, email).Scan(&taken); err != nil {
		return err
	}
	if taken > 0 {
		return fail(http.StatusConflict, "Diese E-Mail-Adresse gehört schon zu einem Mitglied dieses Kreises.")
	}
	return nil
}

// confirmMemberEmail gives a managed member the proven address. If it has an account
// already, that account takes over the membership and everything done so far.
func (s *Server) confirmMemberEmail(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, target := r.Context(), r.PathValue("uid")
	if err := s.managedMember(ctx, c, target); err != nil {
		return err
	}
	var in struct {
		Code string `json:"code"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	email, err := s.checkEmailCode(ctx, target, in.Code)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// Someone may have joined with the address in the meantime.
	if err := s.checkFreeInFamily(ctx, tx, c.familyID, email); err != nil {
		return err
	}
	var account string
	err = tx.QueryRowContext(ctx, `SELECT id FROM users WHERE email = ?`, email).Scan(&account)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		if _, err := tx.ExecContext(ctx, `UPDATE users SET email = ?, is_managed = 0, notifications = 1 WHERE id = ?`, email, target); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM email_changes WHERE user_id = ?`, target); err != nil {
			return err
		}
		// From now on the address is the way in.
		if _, err := tx.ExecContext(ctx, `DELETE FROM login_codes WHERE user_id = ?`, target); err != nil {
			return err
		}
	case err != nil:
		return err
	default:
		if err := mergeManagedMember(ctx, tx, c.familyID, target, account); err != nil {
			return err
		}
	}
	// An open invitation for the address has done its job.
	if _, err := tx.ExecContext(ctx, `DELETE FROM invitations WHERE family_id = ? AND email = ?`, c.familyID, email); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

// mergeManagedMember moves everything of a managed member to an existing account, and
// then removes the row that only stood in for that person.
func mergeManagedMember(ctx context.Context, tx *database.Tx, familyID, managed, account string) error {
	for _, query := range []string{
		`UPDATE memberships SET user_id = ?1 WHERE user_id = ?2`,
		`DELETE FROM event_participants WHERE user_id = ?1 AND event_id IN (SELECT event_id FROM event_participants WHERE user_id = ?2)`,
		`UPDATE event_participants SET user_id = ?1 WHERE user_id = ?2`,
		`DELETE FROM reminder_sent WHERE user_id = ?1 AND EXISTS (SELECT 1 FROM reminder_sent o WHERE o.user_id = ?2
			AND o.event_id = reminder_sent.event_id AND o.minutes = reminder_sent.minutes AND o.occurrence = reminder_sent.occurrence)`,
		`UPDATE reminder_sent SET user_id = ?1 WHERE user_id = ?2`,
		`UPDATE events SET created_by = ?1 WHERE created_by = ?2`,
		`UPDATE events SET updated_by = ?1 WHERE updated_by = ?2`,
		`UPDATE event_comments SET user_id = ?1 WHERE user_id = ?2`,
		`UPDATE list_items SET assignee_id = ?1 WHERE assignee_id = ?2`,
		`UPDATE messages SET sender_id = ?1 WHERE sender_id = ?2`,
		`UPDATE files SET uploaded_by = ?1 WHERE uploaded_by = ?2`,
		// What they set up for themselves while logged in with a login code.
		`DELETE FROM calendar_settings WHERE user_id = ?1 AND EXISTS (SELECT 1 FROM calendar_settings o WHERE o.user_id = ?2
			AND o.family_id = calendar_settings.family_id AND o.key = calendar_settings.key)`,
		`UPDATE calendar_settings SET user_id = ?1 WHERE user_id = ?2`,
		`DELETE FROM calendar_prefs WHERE user_id = ?1 AND EXISTS (SELECT 1 FROM calendar_prefs o WHERE o.user_id = ?2 AND o.family_id = calendar_prefs.family_id)`,
		`UPDATE calendar_prefs SET user_id = ?1 WHERE user_id = ?2`,
		`DELETE FROM calendar_shares WHERE user_id = ?1 AND EXISTS (SELECT 1 FROM calendar_shares o WHERE o.user_id = ?2
			AND o.family_id = calendar_shares.family_id AND o.key = calendar_shares.key)`,
		`UPDATE calendar_shares SET user_id = ?1 WHERE user_id = ?2`,
		`UPDATE calendar_feeds SET user_id = ?1 WHERE user_id = ?2`,
	} {
		if _, err := tx.ExecContext(ctx, query, account, managed); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM former_memberships WHERE family_id = ? AND user_id = ?`, familyID, account); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `DELETE FROM users WHERE id = ?`, managed)
	return err
}

// deleteManagedMember removes a managed member for good. Nobody could ever invite them
// back without an address, so unlike everyone else they are not kept for a return.
func (s *Server) deleteManagedMember(w http.ResponseWriter, r *http.Request, c reqCtx, userID string) error {
	ctx := r.Context()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	files, err := deleteMemberData(ctx, tx, c.familyID, userID)
	if err != nil {
		return err
	}
	// The user row only ever stood for this one membership, which goes along with it.
	if _, err := tx.ExecContext(ctx, `DELETE FROM users WHERE id = ? AND is_managed = 1`, userID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	for _, id := range files {
		s.removeStoredFile(r, id)
	}
	return noContent(w)
}

func isInternalEmail(email string) bool { return strings.HasSuffix(email, internalEmailDomain) }
