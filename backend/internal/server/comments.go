package server

import (
	"context"
	"net/http"
)

// commentTable is where the comments on one kind of thing are kept: events and
// shopping lists. Both are written, changed and deleted the same way.
type commentTable struct {
	table, parent string
	// activity is the kind of the Aktuelles entries that quote the comments.
	activity string
	// edited and deleted are the kinds of the entries that tell of a change.
	edited, deleted string
	// title is the query for the name of the thing, by its id.
	title string
	// people are whom Aktuelles tells of its comments.
	people func(ctx context.Context, q dbtx, familyID, parentID string) ([]string, error)
}

var (
	eventComments = commentTable{
		"event_comments", "event_id", activityEventComment, activityEventCommentEdited, activityEventCommentDeleted,
		`SELECT title FROM events WHERE id = ?`, commentPeople,
	}
	shoppingComments = commentTable{
		"shopping_list_comments", "list_id", activityListComment, activityListCommentEdited, activityListCommentDeleted,
		`SELECT name FROM shopping_lists WHERE id = ?`, shoppingCommentPeople,
	}
)

// tell puts a change of a comment into Aktuelles, for those its comments concern.
func (t commentTable) tell(ctx context.Context, tx dbtx, c reqCtx, kind, parentID, detail string) error {
	var title string
	if err := tx.QueryRowContext(ctx, t.title, parentID).Scan(&title); err != nil {
		return err
	}
	people, err := t.people(ctx, tx, c.familyID, parentID)
	if err != nil {
		return err
	}
	return addActivityWith(ctx, tx, c.familyID, c.userID, kind, parentID, title, detail, people)
}

// columns takes the family id twice. Whoever left has no name any more; a deleted
// comment keeps no text, only who deleted it.
func (t commentTable) columns() string {
	return `SELECT c.id, CASE WHEN c.deleted_at IS NULL THEN c.body ELSE '' END AS body, c.created_at,
		c.edited_at, c.deleted_at, COALESCE(c.user_id, '') AS author_id, COALESCE(m.name, '') AS author_name,
		COALESCE(d.name, '') AS deleted_by_name FROM ` + t.table + ` c
		LEFT JOIN memberships m ON m.user_id = c.user_id AND m.family_id = ?
		LEFT JOIN memberships d ON d.user_id = c.deleted_by AND d.family_id = ? `
}

// query returns the comments matching where, each with what the caller may do with it:
// change their own, and delete their own or, as admin, anyone's.
func (t commentTable) query(ctx context.Context, q dbtx, c reqCtx, where string, args ...any) ([]map[string]any, error) {
	rows, err := queryRows(ctx, q, t.columns()+where, append([]any{c.familyID, c.familyID}, args...)...)
	if err != nil {
		return nil, err
	}
	for _, row := range rows {
		deleted := row["deleted_at"] != nil
		own := row["author_id"] == c.userID
		row["deleted"] = deleted
		row["can_edit"] = !deleted && own
		row["can_delete"] = !deleted && (own || c.isAdmin)
	}
	return rows, nil
}

// list returns the comments on a thing, the oldest first.
func (t commentTable) list(ctx context.Context, q dbtx, c reqCtx, parentID string) ([]map[string]any, error) {
	return t.query(ctx, q, c, `WHERE c.`+t.parent+` = ? ORDER BY c.created_at, c.seq`, parentID)
}

// one returns a comment on the given thing, or errNotFound.
func (t commentTable) one(ctx context.Context, q dbtx, c reqCtx, parentID, id string) (map[string]any, error) {
	rows, err := t.query(ctx, q, c, `WHERE c.id = ? AND c.`+t.parent+` = ?`, id, parentID)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, errNotFound
	}
	return rows[0], nil
}

// requoteActivities puts the new words of a comment, or none for a deleted one, into
// the Aktuelles entries that quote it, so that they do not keep what was taken back.
func (t commentTable) requoteActivities(ctx context.Context, tx dbtx, c reqCtx, parentID, authorID, before, after string) error {
	if authorID == "" {
		return nil
	}
	_, err := tx.ExecContext(ctx, `UPDATE activities SET detail = ? WHERE family_id = ? AND kind = ? AND ref_id = ?
		AND actor_id = ? AND detail = ?`, after, c.familyID, t.activity, parentID, authorID, commentSnippet(before))
	return err
}

// edit changes the words of a comment. Only its author may, admins included.
func (t commentTable) edit(w http.ResponseWriter, r *http.Request, s *Server, c reqCtx, parentID string) error {
	ctx, id := r.Context(), r.PathValue("cid")
	var in struct {
		Body string `json:"body"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	body, err := required(in.Body, "Kommentar", 2000)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var before string
	comment, err := t.one(ctx, tx, c, parentID, id)
	if err != nil {
		return err
	}
	if comment["deleted"] == true {
		return fail(http.StatusConflict, "Der Kommentar wurde gelöscht.")
	}
	if comment["author_id"] != c.userID {
		return fail(http.StatusForbidden, "Nur eigene Kommentare lassen sich bearbeiten.")
	}
	if err := tx.QueryRowContext(ctx, `SELECT body FROM `+t.table+` WHERE id = ?`, id).Scan(&before); err != nil {
		return err
	}
	if body != before {
		if _, err := tx.ExecContext(ctx, `UPDATE `+t.table+` SET body = ?, edited_at = ? WHERE id = ?`, body, now(), id); err != nil {
			return err
		}
		if err := t.requoteActivities(ctx, tx, c, parentID, c.userID, before, commentSnippet(body)); err != nil {
			return err
		}
		if err := t.tell(ctx, tx, c, t.edited, parentID, commentSnippet(body)); err != nil {
			return err
		}
	}
	if comment, err = t.one(ctx, tx, c, parentID, id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, comment)
	return nil
}

// delete takes a comment back: its author may, and an admin may delete anyone's. It
// stays in its place as a note of who deleted it, without its words.
func (t commentTable) delete(w http.ResponseWriter, r *http.Request, s *Server, c reqCtx, parentID string) error {
	ctx, id := r.Context(), r.PathValue("cid")
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	comment, err := t.one(ctx, tx, c, parentID, id)
	if err != nil {
		return err
	}
	if comment["deleted"] == true {
		writeJSON(w, http.StatusOK, comment)
		return nil
	}
	author, _ := comment["author_id"].(string)
	if author != c.userID && !c.isAdmin {
		return fail(http.StatusForbidden, "Kommentare anderer können nur Admins löschen.")
	}
	var before string
	if err := tx.QueryRowContext(ctx, `SELECT body FROM `+t.table+` WHERE id = ?`, id).Scan(&before); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE `+t.table+` SET body = '', deleted_at = ?, deleted_by = ? WHERE id = ?`,
		now(), c.userID, id); err != nil {
		return err
	}
	if err := t.requoteActivities(ctx, tx, c, parentID, author, before, ""); err != nil {
		return err
	}
	// Whose it was, when an admin deletes another's; the author hears of it too.
	whose := ""
	if author != c.userID {
		whose, _ = comment["author_name"].(string)
	}
	if err := t.tell(ctx, tx, c, t.deleted, parentID, whose); err != nil {
		return err
	}
	if comment, err = t.one(ctx, tx, c, parentID, id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, comment)
	return nil
}

func (s *Server) editEventComment(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	eventID := r.PathValue("id")
	if err := s.eventAccess(r.Context(), c, eventID); err != nil {
		return err
	}
	return eventComments.edit(w, r, s, c, eventID)
}

func (s *Server) deleteEventComment(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	eventID := r.PathValue("id")
	if err := s.eventAccess(r.Context(), c, eventID); err != nil {
		return err
	}
	return eventComments.delete(w, r, s, c, eventID)
}

func (s *Server) editShoppingComment(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	listID := r.PathValue("id")
	if err := s.shoppingListAccess(r.Context(), c, listID); err != nil {
		return err
	}
	return shoppingComments.edit(w, r, s, c, listID)
}

func (s *Server) deleteShoppingComment(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	listID := r.PathValue("id")
	if err := s.shoppingListAccess(r.Context(), c, listID); err != nil {
		return err
	}
	return shoppingComments.delete(w, r, s, c, listID)
}
