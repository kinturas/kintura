package server

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"

	"github.com/kinturas/kintura/backend/internal/database"
)

// familyTerms is the German wording for a family type.
type familyTerms struct {
	nameLabel, to, into string
}

var familyTypes = map[string]familyTerms{
	"family":    {"Name der Familie", "zur Familie", "in die Familie"},
	"friends":   {"Name des Freundeskreises", "zum Freundeskreis", "in den Freundeskreis"},
	"relatives": {"Name der Verwandtschaft", "zur Verwandtschaft", "in die Verwandtschaft"},
	"workgroup": {"Name der Arbeitsgruppe", "zur Arbeitsgruppe", "in die Arbeitsgruppe"},
}

// validFamilyType returns fallback for an empty type and rejects unknown ones.
func validFamilyType(raw, fallback string) (string, error) {
	if raw == "" {
		return fallback, nil
	}
	if _, ok := familyTypes[raw]; !ok {
		return "", fail(http.StatusBadRequest, "Ungültiger Typ")
	}
	return raw, nil
}

// assignableRoles leaves out guest, which is reserved for the coming kiosk mode.
var assignableRoles = map[string]bool{"manager": true, "user": true, "restrict_user": true}

// insertFamily makes the creator an admin manager of the new family.
func insertFamily(ctx context.Context, q dbtx, name, familyType, userID string) (string, error) {
	familyID := newID()
	if _, err := q.ExecContext(ctx, `INSERT INTO families (id, name, type, created_at) VALUES (?, ?, ?, ?)`, familyID, name, familyType, now()); err != nil {
		return "", err
	}
	if _, err := q.ExecContext(ctx, `INSERT INTO memberships (family_id, user_id, role, is_admin, name, birthday)
		SELECT ?, id, 'manager', 1, name, birthday FROM users WHERE id = ?`,
		familyID, userID); err != nil {
		return "", err
	}
	return familyID, insertInitialCategories(ctx, q, familyID)
}

func (s *Server) getMe(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	var email, name, birthday string
	var notifications, managed bool
	var lastFamily *string
	if err := s.db.QueryRowContext(ctx, `SELECT email, name, last_family_id, birthday, notifications, is_managed FROM users WHERE id = ?`, c.userID).
		Scan(&email, &name, &lastFamily, &birthday, &notifications, &managed); err != nil {
		return err
	}
	// Sessions live for weeks, so invitations are also picked up here.
	if err := acceptInvitations(ctx, s.db, c.userID, email); err != nil {
		return err
	}
	// The internal address means nothing to anyone.
	if managed {
		email = ""
	}
	families, err := queryRows(ctx, s.db,
		`SELECT f.id, f.name, f.type, m.role, m.is_admin, m.color, m.can_change_color, m.name AS member_name FROM memberships m JOIN families f ON f.id = m.family_id
		 WHERE m.user_id = ? ORDER BY f.name`, c.userID)
	if err != nil {
		return err
	}
	// The last family may be gone if the user was removed from it.
	var current any
	for _, f := range families {
		if lastFamily != nil && f["id"] == *lastFamily {
			current = *lastFamily
		}
	}
	if current == nil && len(families) > 0 {
		current = families[0]["id"]
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id": c.userID, "email": email, "name": name, "birthday": birthday, "notifications": notifications, "managed": managed,
		"families": families, "last_family_id": current,
	})
	return nil
}

func (s *Server) createFamily(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if err := s.refuseManaged(r, c, "Ohne E-Mail-Adresse kannst du keinen Kreis anlegen."); err != nil {
		return err
	}
	var in struct {
		Name string `json:"name"`
		Type string `json:"type"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	familyType, err := validFamilyType(in.Type, "family")
	if err != nil {
		return err
	}
	name, err := required(in.Name, familyTypes[familyType].nameLabel, 100)
	if err != nil {
		return err
	}
	ctx := r.Context()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	familyID, err := insertFamily(ctx, tx, name, familyType, c.userID)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE users SET last_family_id = ? WHERE id = ?`, familyID, c.userID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": familyID})
	return nil
}

func (s *Server) selectFamily(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if _, err := s.db.ExecContext(r.Context(), `UPDATE users SET last_family_id = ? WHERE id = ?`, c.familyID, c.userID); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) updateFamily(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Name string `json:"name"`
		Type string `json:"type"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	familyType, err := validFamilyType(in.Type, c.familyType)
	if err != nil {
		return err
	}
	name, err := required(in.Name, familyTypes[familyType].nameLabel, 100)
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(r.Context(), `UPDATE families SET name = ?, type = ? WHERE id = ?`, name, familyType, c.familyID); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) listMembers(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	members, err := queryRows(ctx, s.db,
		`SELECT u.id, m.name, CASE WHEN u.is_managed = 1 THEN '' ELSE u.email END AS email, u.is_managed AS managed,
			m.role, m.is_admin, m.color, m.can_change_color FROM memberships m JOIN users u ON u.id = m.user_id
		 WHERE m.family_id = ?
		 ORDER BY m.is_admin DESC, CASE m.role WHEN 'manager' THEN 0 WHEN 'user' THEN 1 WHEN 'restrict_user' THEN 2 ELSE 3 END, m.name`, c.familyID)
	if err != nil {
		return err
	}
	invitations := []map[string]any{}
	former := []map[string]any{}
	if c.isAdmin {
		invitations, err = queryRows(ctx, s.db,
			`SELECT id, email, role, is_admin, color, can_change_color FROM invitations WHERE family_id = ? ORDER BY email`, c.familyID)
		if err != nil {
			return err
		}
		// Someone invited again is already listed as that.
		former, err = queryRows(ctx, s.db,
			`SELECT f.user_id AS id, f.name, u.email, f.color, f.left_at FROM former_memberships f JOIN users u ON u.id = f.user_id
			 WHERE f.family_id = ?1 AND u.is_managed = 0 AND u.email NOT IN (SELECT email FROM invitations WHERE family_id = ?1)
			 ORDER BY f.name`, c.familyID)
		if err != nil {
			return err
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"members": members, "invitations": invitations, "former": former})
	return nil
}

// deleteFormerMember is the end of what leaving kept: the data of someone who left
// goes for good. The account stays, it may well be in other families.
func (s *Server) deleteFormerMember(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, target := r.Context(), r.PathValue("uid")
	var found int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM former_memberships WHERE family_id = ? AND user_id = ?`, c.familyID, target).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	files, err := deleteMemberData(ctx, tx, c.familyID, target)
	if err != nil {
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

// lastAdminError explains why a change to target affected no row: two admins
// demoted each other at the same moment, or target is not a member.
func (s *Server) lastAdminError(ctx context.Context, c reqCtx, target string) error {
	var exists int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM memberships WHERE family_id = ? AND user_id = ?`, c.familyID, target).Scan(&exists); err != nil {
		return err
	}
	if exists > 0 {
		return fail(http.StatusConflict, "Es muss mindestens ein Admin bleiben.")
	}
	return errNotFound
}

// updateMember changes role and admin flag. Admins cannot revoke their own
// flag, so a family always keeps the admin who made the change.
func (s *Server) updateMember(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Role    string `json:"role"`
		IsAdmin bool   `json:"is_admin"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if !assignableRoles[in.Role] {
		return fail(http.StatusBadRequest, "Ungültige Rolle")
	}
	ctx := r.Context()
	target := r.PathValue("uid")
	if target == c.userID && !in.IsAdmin {
		return fail(http.StatusConflict, "Du kannst dir die Admin-Rechte nicht selbst entziehen.")
	}
	// An admin has to be reachable, and to get back in without another admin's help.
	if in.IsAdmin {
		var managed int
		if err := s.db.QueryRowContext(ctx, `SELECT is_managed FROM users WHERE id = ?`, target).Scan(&managed); err == nil && managed == 1 {
			return fail(http.StatusBadRequest, "Ein Benutzer ohne E-Mail-Adresse kann kein Admin sein.")
		}
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE memberships SET role = ?1, is_admin = ?2 WHERE family_id = ?3 AND user_id = ?4 AND (
			?2 = 1 OR is_admin = 0 OR
			(SELECT COUNT(*) FROM memberships WHERE family_id = ?3 AND is_admin = 1) > 1
		)`, in.Role, in.IsAdmin, c.familyID, target)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return s.lastAdminError(ctx, c, target)
	}
	// Those links end for good, and do not come back with another role later.
	if in.Role == restrictedRole {
		if _, err := s.db.ExecContext(ctx, `DELETE FROM calendar_shares WHERE family_id = ? AND user_id = ? AND `+notSharedByRestricted, c.familyID, target); err != nil {
			return err
		}
	}
	return noContent(w)
}

// archiveMember ends a membership but keeps the profile, so that a later invitation
// brings it back. Everything else the member left behind stays where it is anyway.
func archiveMember(ctx context.Context, tx *database.Tx, familyID, userID string) error {
	_, err := tx.ExecContext(ctx,
		`INSERT INTO former_memberships (family_id, user_id, color, name, birthday, family_role, contact_email, profile_fields, left_at)
		 SELECT family_id, user_id, color, name, birthday, family_role, contact_email, profile_fields, ?
		 FROM memberships WHERE family_id = ? AND user_id = ?
		 ON CONFLICT (family_id, user_id) DO UPDATE SET color = excluded.color, name = excluded.name, birthday = excluded.birthday,
			family_role = excluded.family_role, contact_email = excluded.contact_email, profile_fields = excluded.profile_fields, left_at = excluded.left_at`, now(), familyID, userID)
	return err
}

// leaveFamily is how a member leaves on their own, with or without their data. The
// last admin can only go once nobody else depends on them.
func (s *Server) leaveFamily(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if err := s.refuseManaged(r, c, "Ohne E-Mail-Adresse kann dich nur ein Admin aus dem Kreis entfernen."); err != nil {
		return err
	}
	var in struct {
		DeleteData bool `json:"delete_data"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var members, admins int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(SUM(is_admin), 0) FROM memberships WHERE family_id = ?`, c.familyID).
		Scan(&members, &admins); err != nil {
		return err
	}
	if c.isAdmin && admins == 1 && members > 1 {
		var candidates int
		if err := tx.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.family_id = ? AND m.user_id <> ? AND u.is_managed = 0`,
			c.familyID, c.userID).Scan(&candidates); err != nil {
			return err
		}
		// Nobody without an address can become an admin, so the usual advice would lead nowhere.
		if candidates == 0 {
			return fail(http.StatusConflict, "Du bist der letzte Admin. Gib einem anderen Mitglied eine E-Mail-Adresse und mache es zum Admin, oder lösche die anderen Mitglieder.")
		}
		return fail(http.StatusConflict, "Du bist der letzte Admin. Mache zuerst ein anderes Mitglied zum Admin.")
	}
	// Nobody could look after those who left, or ever let them back in.
	if c.isAdmin && admins == 1 {
		var former int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM former_memberships WHERE family_id = ?`, c.familyID).Scan(&former); err != nil {
			return err
		}
		if former > 0 {
			return fail(http.StatusConflict, "Du bist der letzte Admin. Lösche zuerst unter Einstellungen → Mitglieder alle, die den Kreis verlassen haben, und ziehe ihre offenen Einladungen zurück.")
		}
	}
	alone := members == 1
	var files []string
	switch {
	case in.DeleteData && alone:
		// Nobody is left whom anything could still be for.
		if files, err = fileIDs(ctx, tx, `SELECT id FROM files WHERE family_id = ?`, c.familyID); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM families WHERE id = ?`, c.familyID); err != nil {
			return err
		}
	case in.DeleteData:
		if files, err = deleteMemberData(ctx, tx, c.familyID, c.userID); err != nil {
			return err
		}
	default:
		if err := archiveMember(ctx, tx, c.familyID, c.userID); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM memberships WHERE family_id = ? AND user_id = ?`, c.familyID, c.userID); err != nil {
		return err
	}
	// Without an admin nobody could look after those who would still join.
	if alone {
		if _, err := tx.ExecContext(ctx, `DELETE FROM invitations WHERE family_id = ?`, c.familyID); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	for _, id := range files {
		s.removeStoredFile(r, id)
	}
	return noContent(w)
}

func fileIDs(ctx context.Context, q dbtx, query string, args ...any) ([]string, error) {
	rows, err := queryRows(ctx, q, query, args...)
	if err != nil {
		return nil, err
	}
	ids := []string{}
	for _, row := range rows {
		ids = append(ids, row["id"].(string))
	}
	return ids, nil
}

// deleteMemberData removes what belongs to one member of a family, and returns the
// files to take off the disk. What the others still use stays without a name: events
// for several people and lists. Events only the member could see go.
func deleteMemberData(ctx context.Context, tx *database.Tx, familyID, userID string) ([]string, error) {
	const ownEvents = `SELECT e.id FROM events e WHERE e.family_id = ?1 AND e.created_by = ?2 AND e.visibility = 'participants' AND e.participants_all = 0
		AND NOT EXISTS (SELECT 1 FROM event_participants p WHERE p.event_id = e.id AND p.user_id <> ?2)`
	files, err := fileIDs(ctx, tx,
		`SELECT id FROM files WHERE family_id = ?1 AND (uploaded_by = ?2 OR event_id IN (`+ownEvents+`))`, familyID, userID)
	if err != nil {
		return nil, err
	}
	const inFamily = `event_id IN (SELECT id FROM events WHERE family_id = ?1)`
	for _, query := range []string{
		`DELETE FROM events WHERE id IN (` + ownEvents + `)`,
		`DELETE FROM files WHERE family_id = ?1 AND uploaded_by = ?2`,
		`DELETE FROM messages WHERE family_id = ?1 AND sender_id = ?2`,
		`DELETE FROM event_comments WHERE user_id = ?2 AND ` + inFamily,
		`DELETE FROM event_participants WHERE user_id = ?2 AND ` + inFamily,
		`DELETE FROM reminder_sent WHERE user_id = ?2 AND ` + inFamily,
		`UPDATE events SET created_by = NULL WHERE family_id = ?1 AND created_by = ?2`,
		`UPDATE events SET updated_by = NULL WHERE family_id = ?1 AND updated_by = ?2`,
		`UPDATE list_items SET assignee_id = NULL WHERE family_id = ?1 AND assignee_id = ?2`,
		`DELETE FROM calendar_settings WHERE family_id = ?1 AND user_id = ?2`,
		`DELETE FROM calendar_prefs WHERE family_id = ?1 AND user_id = ?2`,
		`DELETE FROM calendar_shares WHERE family_id = ?1 AND user_id = ?2`,
		`DELETE FROM calendar_feeds WHERE family_id = ?1 AND user_id = ?2`,
		`DELETE FROM former_memberships WHERE family_id = ?1 AND user_id = ?2`,
	} {
		if _, err := tx.ExecContext(ctx, query, familyID, userID); err != nil {
			return nil, err
		}
	}

	// An event nobody takes part in any more would be stuck in the form. A private one
	// stays with its creator, and goes if there is none, for nobody could see it. It
	// must never become visible to everyone.
	const abandoned = `FROM events e WHERE e.family_id = ?1 AND e.participants_all = 0 AND e.visibility = 'participants'
		AND NOT EXISTS (SELECT 1 FROM event_participants p WHERE p.event_id = e.id)`
	orphans, err := fileIDs(ctx, tx, `SELECT id FROM files WHERE event_id IN (SELECT e.id `+abandoned+` AND e.created_by IS NULL)`, familyID)
	if err != nil {
		return nil, err
	}
	files = append(files, orphans...)
	for _, query := range []string{
		`DELETE FROM events WHERE id IN (SELECT e.id ` + abandoned + ` AND e.created_by IS NULL)`,
		`INSERT INTO event_participants (event_id, user_id) SELECT e.id, e.created_by ` + abandoned + ` ON CONFLICT DO NOTHING`,
		`UPDATE events SET participants_all = 1 WHERE family_id = ?1 AND participants_all = 0 AND visibility = 'all'
		 AND NOT EXISTS (SELECT 1 FROM event_participants p WHERE p.event_id = events.id)`,
	} {
		if _, err := tx.ExecContext(ctx, query, familyID); err != nil {
			return nil, err
		}
	}
	return files, nil
}

// removeMember lets admins remove others and non-admins leave by themselves.
// Admins leave through leaveFamily, which looks after the last admin.
func (s *Server) removeMember(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	target := r.PathValue("uid")
	if target != c.userID && !c.isAdmin {
		return fail(http.StatusForbidden, "Nur für Admins erlaubt")
	}
	if target == c.userID && c.isAdmin {
		return fail(http.StatusConflict, "Als Admin kannst du nicht austreten. Ein anderer Admin muss dir zuerst die Admin-Rechte entziehen.")
	}
	if target == c.userID {
		if err := s.refuseManaged(r, c, "Ohne E-Mail-Adresse kann dich nur ein Admin aus dem Kreis entfernen."); err != nil {
			return err
		}
	}
	ctx := r.Context()
	var managed bool
	err := s.db.QueryRowContext(ctx,
		`SELECT u.is_managed FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.family_id = ? AND m.user_id = ?`,
		c.familyID, target).Scan(&managed)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if managed {
		return s.deleteManagedMember(w, r, c, target)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := archiveMember(ctx, tx, c.familyID, target); err != nil {
		return err
	}
	res, err := tx.ExecContext(ctx,
		`DELETE FROM memberships WHERE family_id = ?1 AND user_id = ?2 AND (
			is_admin = 0 OR
			(SELECT COUNT(*) FROM memberships WHERE family_id = ?1 AND is_admin = 1) > 1
		)`, c.familyID, target)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		// Only one connection exists, and lastAdminError needs it.
		if err := tx.Rollback(); err != nil {
			return err
		}
		return s.lastAdminError(ctx, c, target)
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) createInvitation(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Email          string `json:"email"`
		Role           string `json:"role"`
		IsAdmin        bool   `json:"is_admin"`
		Color          string `json:"color"`
		CanChangeColor *bool  `json:"can_change_color"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	email, err := normalizeEmail(in.Email)
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
	canChangeColor := in.CanChangeColor == nil || *in.CanChangeColor
	var already int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.family_id = ? AND u.email = ?`,
		c.familyID, email).Scan(&already); err != nil {
		return err
	}
	if already > 0 {
		return fail(http.StatusConflict, "Diese Person gehört bereits "+familyTypes[c.familyType].to+".")
	}
	var invited int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM invitations WHERE family_id = ? AND email = ?`, c.familyID, email).Scan(&invited); err != nil {
		return err
	}
	if invited > 0 {
		return fail(http.StatusConflict, "Diese Person wurde bereits eingeladen.")
	}
	if err := s.noteInvitationMail(ctx, c.familyID, email); err != nil {
		return err
	}
	code, err := randomCode()
	if err != nil {
		return err
	}
	id := newID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO invitations (id, family_id, email, role, is_admin, created_at, color, can_change_color, code_hash, code_expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, c.familyID, email, in.Role, in.IsAdmin, now(), in.Color, canChangeColor, hashCode(id, code), invitationCodeExpiry()); err != nil {
		if isUniqueViolation(err) {
			return fail(http.StatusConflict, "Diese Person wurde bereits eingeladen.")
		}
		return err
	}
	body, err := s.invitationMailBody(ctx, c, code)
	if err != nil {
		return err
	}
	mailSent := true
	if err := s.mailer.Send(email, "Einladung zu Kintura", body); err != nil {
		// The invitation still works; the app tells the admin to pass it on personally.
		s.logError(r, http.StatusBadGateway, fmt.Sprintf("Einladungs-Mail an %s: %v", email, err))
		mailSent = false
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "mail_sent": mailSent})
	return nil
}

func (s *Server) deleteInvitation(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM invitations WHERE id = ? AND family_id = ?`, r.PathValue("id"), c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}
