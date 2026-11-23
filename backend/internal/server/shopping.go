package server

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/kinturas/kintura/backend/internal/database"
)

// Einkaufen: shopping lists with a color, the people they are for and who may see them,
// as with events. The catalog of articles lives in the app; the server keeps the
// articles a circle made itself and what it changed about catalog articles.

// shoppingCategories are the keys of the fixed categories in the app, plus own articles.
var shoppingCategories = []string{
	"obst_gemuese", "brot_gebaeck", "milch_kaese", "fleisch_fisch", "gewuerze_zutaten", "fertig_tiefkuehl",
	"getreide", "suesswaren_snacks", "getraenke", "haushalt", "pflege_gesundheit", "tierbedarf", "baumarkt_garten",
	"eigene",
}

var shoppingUrgencies = []string{"", "urgent", "offer", "optional"}

const (
	maxShoppingPhotos    = 6
	maxShoppingPhotoSize = 3 << 20
)

// shoppingListVisible limits a query on shopping lists l to what a user may see, as
// eventVisible does for events. It takes the user id twice.
const shoppingListVisible = ` AND (l.visibility = 'all' OR l.assignees_all = 1 OR l.created_by = ?
	OR EXISTS (SELECT 1 FROM shopping_list_assignees a WHERE a.list_id = l.id AND a.user_id = ?)) `

func (s *Server) shoppingListAccess(ctx context.Context, c reqCtx, id string) error {
	var found int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM shopping_lists l WHERE l.id = ? AND l.family_id = ?`+shoppingListVisible,
		id, c.familyID, c.userID, c.userID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	return err
}

// shoppingListChangeAccess is for the settings of a list and deleting it: whoever sees a
// list may add and check off articles, but the list itself is up to its creator and
// the managers.
func (s *Server) shoppingListChangeAccess(ctx context.Context, c reqCtx, id string) error {
	if err := s.shoppingListAccess(ctx, c, id); err != nil {
		return err
	}
	if c.isManager() || c.isAdmin {
		return nil
	}
	var creator sql.NullString
	if err := s.db.QueryRowContext(ctx, `SELECT created_by FROM shopping_lists WHERE id = ?`, id).Scan(&creator); err != nil {
		return err
	}
	if creator.String != c.userID {
		return fail(http.StatusForbidden, "Listen anderer Mitglieder können nur Manager ändern.")
	}
	return nil
}

// shoppingListWriter limits a query on shopping lists l to those whose articles the user
// may change: the ones it concerns, that is its creator and the people it is for. A list
// that is only visible to everyone is read-only for the others. It takes the user id twice.
const shoppingListWriter = ` AND (l.assignees_all = 1 OR l.created_by = ?
	OR EXISTS (SELECT 1 FROM shopping_list_assignees a WHERE a.list_id = l.id AND a.user_id = ?)) `

const shoppingReadOnly = "Diese Einkaufsliste kannst du nur ansehen. Ändern können sie die Personen, die sie betrifft."

// shoppingListWriteAccess is for putting articles on a list, checking them off and their
// notes and photos. Managers and admins may, as they may change the list itself.
func (s *Server) shoppingListWriteAccess(ctx context.Context, c reqCtx, id string) error {
	if err := s.shoppingListAccess(ctx, c, id); err != nil {
		return err
	}
	if c.isManager() || c.isAdmin {
		return nil
	}
	var found int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM shopping_lists l WHERE l.id = ?`+shoppingListWriter,
		id, c.userID, c.userID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return fail(http.StatusForbidden, shoppingReadOnly)
	}
	return err
}

// shoppingItemList returns the list of an item the user may see, or change with write.
func (s *Server) shoppingItemList(ctx context.Context, c reqCtx, itemID string, write bool) (string, error) {
	var listID string
	err := s.db.QueryRowContext(ctx, `SELECT list_id FROM shopping_items WHERE id = ? AND family_id = ?`, itemID, c.familyID).Scan(&listID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", errNotFound
	}
	if err != nil {
		return "", err
	}
	if write {
		return listID, s.shoppingListWriteAccess(ctx, c, listID)
	}
	return listID, s.shoppingListAccess(ctx, c, listID)
}

// --- Lists ---

func (s *Server) listShoppingLists(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	rows, err := queryRows(ctx, s.db,
		`SELECT l.id, l.name, l.color, l.created_by, l.assignees_all, l.visibility, l.due_date,
			COALESCE(l.category_id, '') AS category_id, COALESCE(k.name, '') AS category_name, COALESCE(k.color, '') AS category_color,
			(SELECT COUNT(*) FROM shopping_items i WHERE i.list_id = l.id AND i.done = 0) AS open_items,
			EXISTS (SELECT 1 FROM shopping_lists w WHERE w.id = l.id`+strings.ReplaceAll(shoppingListWriter, "l.", "w.")+`) AS concerns_me
		 FROM shopping_lists l LEFT JOIN categories k ON k.id = l.category_id
		 WHERE l.family_id = ?`+shoppingListVisible+`ORDER BY l.name, l.id`,
		c.userID, c.userID, c.familyID, c.userID, c.userID)
	if err != nil {
		return err
	}
	assignees, err := queryRows(ctx, s.db,
		`SELECT a.list_id, a.user_id FROM shopping_list_assignees a JOIN shopping_lists l ON l.id = a.list_id
		 WHERE l.family_id = ? ORDER BY a.user_id`, c.familyID)
	if err != nil {
		return err
	}
	byList := map[string][]string{}
	for _, a := range assignees {
		byList[a["list_id"].(string)] = append(byList[a["list_id"].(string)], a["user_id"].(string))
	}
	for _, row := range rows {
		ids := byList[row["id"].(string)]
		if ids == nil {
			ids = []string{}
		}
		row["assignee_ids"] = ids
		creator, _ := row["created_by"].(string)
		row["can_edit"] = c.isManager() || c.isAdmin || creator == c.userID
		// EXISTS comes as a number from SQLite and as a bool from Postgres.
		concerns := row["concerns_me"] == true || row["concerns_me"] == int64(1)
		delete(row, "concerns_me")
		row["can_write"] = c.isManager() || c.isAdmin || concerns
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

type shoppingListInput struct {
	Name         string   `json:"name"`
	Color        string   `json:"color"`
	AssigneesAll *bool    `json:"assignees_all"`
	AssigneeIDs  []string `json:"assignee_ids"`
	Visibility   string   `json:"visibility"`
	CategoryID   string   `json:"category_id"`
	DueDate      string   `json:"due_date"`
	everyone     bool
}

func (s *Server) readShoppingList(w http.ResponseWriter, r *http.Request, c reqCtx) (shoppingListInput, error) {
	var in shoppingListInput
	if err := readJSON(w, r, &in); err != nil {
		return in, err
	}
	var err error
	if in.Name, err = required(in.Name, "Name", 100); err != nil {
		return in, err
	}
	if in.Color != "" && !hexColor.MatchString(in.Color) {
		return in, fail(http.StatusBadRequest, "Ungültige Farbe")
	}
	in.Color = strings.ToUpper(in.Color)
	// Only for the people it concerns, unless made visible to everyone, read-only.
	if in.Visibility == "" {
		in.Visibility = "participants"
	}
	if in.Visibility != "all" && in.Visibility != "participants" {
		return in, fail(http.StatusBadRequest, "Ungültige Sichtbarkeit")
	}
	in.everyone = in.AssigneesAll == nil || *in.AssigneesAll
	if in.everyone {
		in.AssigneeIDs = nil
	} else if len(in.AssigneeIDs) == 0 {
		return in, fail(http.StatusBadRequest, "Bitte mindestens eine Person auswählen.")
	}
	slices.Sort(in.AssigneeIDs)
	in.AssigneeIDs = slices.Compact(in.AssigneeIDs)
	for _, id := range in.AssigneeIDs {
		var found int
		err := s.db.QueryRowContext(r.Context(), `SELECT 1 FROM memberships WHERE family_id = ? AND user_id = ?`, c.familyID, id).Scan(&found)
		if errors.Is(err, sql.ErrNoRows) {
			return in, fail(http.StatusBadRequest, "Diese Person gehört nicht "+familyTypes[c.familyType].to+".")
		}
		if err != nil {
			return in, err
		}
	}
	// Both optional: a category of the calendar, and a day by which to have shopped.
	if in.CategoryID != "" {
		var found int
		err := s.db.QueryRowContext(r.Context(), `SELECT 1 FROM categories WHERE id = ? AND family_id = ?`, in.CategoryID, c.familyID).Scan(&found)
		if errors.Is(err, sql.ErrNoRows) {
			return in, fail(http.StatusBadRequest, "Unbekannte Kategorie")
		}
		if err != nil {
			return in, err
		}
	}
	if in.DueDate != "" {
		if _, err := time.Parse("2006-01-02", in.DueDate); err != nil {
			return in, fail(http.StatusBadRequest, "Ungültiges Fälligkeitsdatum")
		}
	}
	return in, nil
}

func setShoppingAssignees(ctx context.Context, tx *database.Tx, listID string, ids []string) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM shopping_list_assignees WHERE list_id = ?`, listID); err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := tx.ExecContext(ctx, `INSERT INTO shopping_list_assignees (list_id, user_id) VALUES (?, ?)`, listID, id); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) createShoppingList(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := s.readShoppingList(w, r, c)
	if err != nil {
		return err
	}
	ctx := r.Context()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	id := newID()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO shopping_lists (id, family_id, name, color, created_by, assignees_all, visibility, created_at, category_id, due_date)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, c.familyID, in.Name, in.Color, c.userID, in.everyone, in.Visibility, now(), nullable(in.CategoryID), in.DueDate); err != nil {
		return err
	}
	if err := setShoppingAssignees(ctx, tx, id, in.AssigneeIDs); err != nil {
		return err
	}
	people, err := shoppingListPeople(ctx, tx, c.familyID, id)
	if err != nil {
		return err
	}
	kind := activityListAdded
	if in.everyone {
		kind = activityListAll
	}
	if err := addActivity(ctx, tx, c.familyID, c.userID, kind, id, in.Name, people); err != nil {
		return err
	}
	readers, err := shoppingListReaders(ctx, tx, c.familyID, id, people)
	if err != nil {
		return err
	}
	if err := addActivity(ctx, tx, c.familyID, c.userID, activityListReadable, id, in.Name, readers); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

func (s *Server) updateShoppingList(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.shoppingListChangeAccess(ctx, c, id); err != nil {
		return err
	}
	in, err := s.readShoppingList(w, r, c)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	oldPeople, err := shoppingListPeople(ctx, tx, c.familyID, id)
	if err != nil {
		return err
	}
	oldReaders, err := shoppingListReaders(ctx, tx, c.familyID, id, oldPeople)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE shopping_lists SET name = ?, color = ?, assignees_all = ?, visibility = ?, category_id = ?, due_date = ? WHERE id = ? AND family_id = ?`,
		in.Name, in.Color, in.everyone, in.Visibility, nullable(in.CategoryID), in.DueDate, id, c.familyID); err != nil {
		return err
	}
	if err := setShoppingAssignees(ctx, tx, id, in.AssigneeIDs); err != nil {
		return err
	}
	people, err := shoppingListPeople(ctx, tx, c.familyID, id)
	if err != nil {
		return err
	}
	if err := addActivity(ctx, tx, c.familyID, c.userID, activityListAdded, id, in.Name, minus(people, oldPeople)); err != nil {
		return err
	}
	// Someone who could change it before and now only look at it is not told anything new.
	readers, err := shoppingListReaders(ctx, tx, c.familyID, id, people)
	if err != nil {
		return err
	}
	newReaders := minus(minus(readers, oldReaders), oldPeople)
	if err := addActivity(ctx, tx, c.familyID, c.userID, activityListReadable, id, in.Name, newReaders); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) deleteShoppingList(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.shoppingListChangeAccess(ctx, c, id); err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	people, err := shoppingListPeople(ctx, tx, c.familyID, id)
	if err != nil {
		return err
	}
	var name string
	if err := tx.QueryRowContext(ctx, `SELECT name FROM shopping_lists WHERE id = ? AND family_id = ?`, id, c.familyID).Scan(&name); err != nil {
		return err
	}
	res, err := tx.ExecContext(ctx, `DELETE FROM shopping_lists WHERE id = ? AND family_id = ?`, id, c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	if err := addActivity(ctx, tx, c.familyID, c.userID, activityListDeleted, id, name, people); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

// --- Items ---

// listShoppingItems returns the open articles of a list first, then the ones done, the
// most recent first, which the app shows as recently used.
func (s *Server) listShoppingItems(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, listID := r.Context(), r.PathValue("id")
	if err := s.shoppingListAccess(ctx, c, listID); err != nil {
		return err
	}
	rows, err := queryRows(ctx, s.db,
		`SELECT i.id, i.name, i.amount, i.note, i.urgency, i.done, i.done_at, i.created_at,
			COALESCE(m.name, u.name) AS added_by_name
		 FROM shopping_items i LEFT JOIN users u ON u.id = i.added_by
		 LEFT JOIN memberships m ON m.user_id = i.added_by AND m.family_id = i.family_id
		 WHERE i.list_id = ? ORDER BY i.done, i.done_at DESC, i.created_at, i.name`, listID)
	if err != nil {
		return err
	}
	photos, err := queryRows(ctx, s.db,
		`SELECT p.id, p.item_id FROM shopping_item_photos p JOIN shopping_items i ON i.id = p.item_id
		 WHERE i.list_id = ? ORDER BY p.created_at, p.id`, listID)
	if err != nil {
		return err
	}
	byItem := map[string][]string{}
	for _, p := range photos {
		byItem[p["item_id"].(string)] = append(byItem[p["item_id"].(string)], p["id"].(string))
	}
	for _, row := range rows {
		ids := byItem[row["id"].(string)]
		if ids == nil {
			ids = []string{}
		}
		row["photo_ids"] = ids
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

// addShoppingItem puts an article on a list. One that was done before comes back with
// what was noted about it; one already open stays as it is.
func (s *Server) addShoppingItem(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, listID := r.Context(), r.PathValue("id")
	if err := s.shoppingListWriteAccess(ctx, c, listID); err != nil {
		return err
	}
	var in struct {
		Name string `json:"name"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	name, err := required(in.Name, "Name", 100)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	status := http.StatusOK
	var id string
	err = tx.QueryRowContext(ctx, `SELECT id FROM shopping_items WHERE list_id = ? AND name = ?`, listID, name).Scan(&id)
	switch {
	case err == nil:
		res, err := tx.ExecContext(ctx,
			`UPDATE shopping_items SET done = 0, done_at = '', added_by = ?, created_at = ? WHERE id = ? AND done = 1`,
			c.userID, now(), id)
		if err != nil {
			return err
		}
		// Already on the list: nothing new to tell anyone.
		if n, err := res.RowsAffected(); err != nil || n == 0 {
			writeJSON(w, status, map[string]string{"id": id})
			return err
		}
	case errors.Is(err, sql.ErrNoRows):
		id, status = newID(), http.StatusCreated
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO shopping_items (id, family_id, list_id, name, added_by, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
			id, c.familyID, listID, name, c.userID, now()); err != nil {
			return err
		}
	default:
		return err
	}
	var listName string
	if err := tx.QueryRowContext(ctx, `SELECT name FROM shopping_lists WHERE id = ?`, listID).Scan(&listName); err != nil {
		return err
	}
	people, err := shoppingListPeople(ctx, tx, c.familyID, listID)
	if err != nil {
		return err
	}
	if err := addGatheredActivity(ctx, tx, c.familyID, c.userID, activityItemsAdded, listID, listName, name, people); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, status, map[string]string{"id": id})
	return nil
}

// checkShoppingItem checks an article off a list by its name. The app checks off this
// way, also what it kept while offline: an article put on the list there has no id yet,
// and only done changes, so that notes others made meanwhile stay. An article that is
// not open on the list, as one someone else checked off or deleted, stays as it is.
func (s *Server) checkShoppingItem(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, listID := r.Context(), r.PathValue("id")
	if err := s.shoppingListWriteAccess(ctx, c, listID); err != nil {
		return err
	}
	var in struct {
		Name string `json:"name"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	name, err := required(in.Name, "Name", 100)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx,
		`UPDATE shopping_items SET done = 1, done_at = ? WHERE list_id = ? AND name = ? AND done = 0`,
		now(), listID, name)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil {
		return err
	} else if n > 0 {
		if err := s.noteItemDone(ctx, tx, c, listID, name, true); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

// noteItemDone tells the people of the list that an article was checked off, or takes
// it out of that news again when it is taken back soon after.
func (s *Server) noteItemDone(ctx context.Context, tx dbtx, c reqCtx, listID, name string, done bool) error {
	if !done {
		return ungatherActivity(ctx, tx, c.familyID, c.userID, activityItemsDone, listID, name)
	}
	var listName string
	if err := tx.QueryRowContext(ctx, `SELECT name FROM shopping_lists WHERE id = ?`, listID).Scan(&listName); err != nil {
		return err
	}
	people, err := shoppingListPeople(ctx, tx, c.familyID, listID)
	if err != nil {
		return err
	}
	return addGatheredActivity(ctx, tx, c.familyID, c.userID, activityItemsDone, listID, listName, name, people)
}

// updateShoppingItem saves what is noted about an article, checks it off or takes it
// back, and moves it to another list. A list that has the article already takes over
// the notes, and the entry here goes.
func (s *Server) updateShoppingItem(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	listID, err := s.shoppingItemList(ctx, c, id, true)
	if err != nil {
		return err
	}
	var in struct {
		Amount  string `json:"amount"`
		Note    string `json:"note"`
		Urgency string `json:"urgency"`
		Done    bool   `json:"done"`
		ListID  string `json:"list_id"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	in.Amount, in.Note = strings.TrimSpace(in.Amount), strings.TrimSpace(in.Note)
	if utf8.RuneCountInString(in.Amount) > 50 {
		return fail(http.StatusBadRequest, "Menge ist zu lang")
	}
	if utf8.RuneCountInString(in.Note) > 1000 {
		return fail(http.StatusBadRequest, "Beschreibung ist zu lang")
	}
	if !slices.Contains(shoppingUrgencies, in.Urgency) {
		return fail(http.StatusBadRequest, "Ungültige Dringlichkeit")
	}
	if in.ListID == "" {
		in.ListID = listID
	}
	if in.ListID != listID {
		if err := s.shoppingListWriteAccess(ctx, c, in.ListID); err != nil {
			if errors.Is(err, errNotFound) {
				return fail(http.StatusBadRequest, "Diese Liste gibt es nicht.")
			}
			return err
		}
	}
	doneAt := ""
	if in.Done {
		doneAt = now()
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var name, wasDoneAt string
	var wasDone bool
	if err := tx.QueryRowContext(ctx, `SELECT name, done, done_at FROM shopping_items WHERE id = ?`, id).Scan(&name, &wasDone, &wasDoneAt); err != nil {
		return err
	}
	// Saving the notes of an article done keeps it where it is among the recent ones.
	if in.Done && wasDone {
		doneAt = wasDoneAt
	}
	if in.ListID != listID {
		var other string
		err := tx.QueryRowContext(ctx, `SELECT id FROM shopping_items WHERE list_id = ? AND name = ?`, in.ListID, name).Scan(&other)
		switch {
		case err == nil:
			if _, err := tx.ExecContext(ctx, `UPDATE shopping_item_photos SET item_id = ? WHERE item_id = ?`, other, id); err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, `DELETE FROM shopping_items WHERE id = ?`, id); err != nil {
				return err
			}
			id = other
		case !errors.Is(err, sql.ErrNoRows):
			return err
		}
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE shopping_items SET list_id = ?, amount = ?, note = ?, urgency = ?, done = ?, done_at = ? WHERE id = ?`,
		in.ListID, in.Amount, in.Note, in.Urgency, in.Done, doneAt, id); err != nil {
		return err
	}
	if in.Done != wasDone {
		if err := s.noteItemDone(ctx, tx, c, in.ListID, name, in.Done); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": id})
	return nil
}

func (s *Server) deleteShoppingItem(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if _, err := s.shoppingItemList(ctx, c, id, true); err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, `DELETE FROM shopping_items WHERE id = ?`, id)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

// --- Photos ---

var shoppingPhotoTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/webp": true}

// uploadShoppingPhoto stores a photo of an article in the database, like the profile
// photos. The app makes it small before it sends it.
func (s *Server) uploadShoppingPhoto(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, itemID := r.Context(), r.PathValue("id")
	if _, err := s.shoppingItemList(ctx, c, itemID, true); err != nil {
		return err
	}
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM shopping_item_photos WHERE item_id = ?`, itemID).Scan(&count); err != nil {
		return err
	}
	if count >= maxShoppingPhotos {
		return fail(http.StatusBadRequest, "Mehr als "+strconv.Itoa(maxShoppingPhotos)+" Fotos gehen nicht.")
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxShoppingPhotoSize+64<<10)
	mr, err := r.MultipartReader()
	if err != nil {
		return fail(http.StatusBadRequest, "Ungültiger Upload")
	}
	part, err := mr.NextPart()
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			return fail(http.StatusRequestEntityTooLarge, "Das Foto ist zu groß.")
		}
		return fail(http.StatusBadRequest, "Ungültiger Upload")
	}
	defer part.Close()
	data, err := io.ReadAll(io.LimitReader(part, maxShoppingPhotoSize+1))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			return fail(http.StatusRequestEntityTooLarge, "Das Foto ist zu groß.")
		}
		return err
	}
	if len(data) > maxShoppingPhotoSize {
		return fail(http.StatusRequestEntityTooLarge, "Das Foto ist zu groß.")
	}
	if len(data) == 0 {
		return fail(http.StatusBadRequest, "Die Datei ist leer.")
	}
	contentType := http.DetectContentType(data)
	if !shoppingPhotoTypes[contentType] {
		return fail(http.StatusBadRequest, "Nur JPEG, PNG und WebP werden unterstützt.")
	}
	id := newID()
	if _, err := s.db.ExecContext(ctx, `INSERT INTO shopping_item_photos (id, item_id, mime, data, created_at) VALUES (?, ?, ?, ?, ?)`,
		id, itemID, contentType, data, now()); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

func (s *Server) shoppingPhotoItem(ctx context.Context, c reqCtx, id string, write bool) error {
	var itemID string
	err := s.db.QueryRowContext(ctx,
		`SELECT p.item_id FROM shopping_item_photos p JOIN shopping_items i ON i.id = p.item_id WHERE p.id = ? AND i.family_id = ?`,
		id, c.familyID).Scan(&itemID)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	_, err = s.shoppingItemList(ctx, c, itemID, write)
	return err
}

func (s *Server) getShoppingPhoto(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.shoppingPhotoItem(ctx, c, id, false); err != nil {
		return err
	}
	var contentType string
	var data []byte
	if err := s.db.QueryRowContext(ctx, `SELECT mime, data FROM shopping_item_photos WHERE id = ?`, id).Scan(&contentType, &data); err != nil {
		return err
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, err := w.Write(data)
	return err
}

func (s *Server) deleteShoppingPhoto(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.shoppingPhotoItem(ctx, c, id, true); err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, `DELETE FROM shopping_item_photos WHERE id = ?`, id)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

// --- Articles ---

func (s *Server) listShoppingArticles(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	rows, err := queryRows(r.Context(), s.db,
		`SELECT name, custom, icon, category FROM shopping_articles WHERE family_id = ? ORDER BY name`, c.familyID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

// capitalized starts a name with a capital letter, as the app shows articles.
func capitalized(name string) string {
	first, size := utf8.DecodeRuneInString(name)
	return string(unicode.ToUpper(first)) + name[size:]
}

type shoppingArticleInput struct {
	Name     string `json:"name"`
	Icon     string `json:"icon"`
	Category string `json:"category"`
}

func readShoppingArticle(w http.ResponseWriter, r *http.Request) (shoppingArticleInput, error) {
	var in shoppingArticleInput
	if err := readJSON(w, r, &in); err != nil {
		return in, err
	}
	var err error
	if in.Name, err = required(in.Name, "Name", 100); err != nil {
		return in, err
	}
	if in.Category != "" && !slices.Contains(shoppingCategories, in.Category) {
		return in, fail(http.StatusBadRequest, "Ungültige Kategorie")
	}
	if len(in.Icon) > 40 || strings.IndexFunc(in.Icon, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_')
	}) >= 0 {
		return in, fail(http.StatusBadRequest, "Ungültiges Symbol")
	}
	return in, nil
}

// createShoppingArticle adds an article of the circle's own, with a capital first letter.
func (s *Server) createShoppingArticle(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := readShoppingArticle(w, r)
	if err != nil {
		return err
	}
	in.Name = capitalized(in.Name)
	if in.Category == "" {
		in.Category = "eigene"
	}
	_, err = s.db.ExecContext(r.Context(),
		`INSERT INTO shopping_articles (family_id, name, custom, icon, category, created_at) VALUES (?, ?, 1, ?, ?, ?)`,
		c.familyID, in.Name, in.Icon, in.Category, now())
	if isUniqueViolation(err) {
		return fail(http.StatusConflict, "Diesen Artikel gibt es bereits.")
	}
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"name": in.Name})
	return nil
}

// putShoppingArticle changes the symbol and category of an article for the whole circle.
// For an article of the catalog it records what differs from the app.
func (s *Server) putShoppingArticle(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := readShoppingArticle(w, r)
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO shopping_articles (family_id, name, custom, icon, category, created_at) VALUES (?, ?, 0, ?, ?, ?)
		 ON CONFLICT (family_id, name) DO UPDATE SET icon = excluded.icon, category = excluded.category`,
		c.familyID, in.Name, in.Icon, in.Category, now()); err != nil {
		return err
	}
	return noContent(w)
}

// deleteShoppingArticle removes an article the circle made itself. Lists keep entries
// of it; they show the first letter from then on.
func (s *Server) deleteShoppingArticle(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM shopping_articles WHERE family_id = ? AND name = ? AND custom = 1`,
		c.familyID, r.URL.Query().Get("name"))
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

// deleteMemberShopping is the part of deleteMemberData for shopping lists, which works
// like that for events: a private list of the member alone goes, others stay.
func deleteMemberShopping(ctx context.Context, tx *database.Tx, familyID, userID string) error {
	const ownLists = `SELECT l.id FROM shopping_lists l WHERE l.family_id = ?1 AND l.created_by = ?2 AND l.visibility = 'participants'
		AND l.assignees_all = 0 AND NOT EXISTS (SELECT 1 FROM shopping_list_assignees a WHERE a.list_id = l.id AND a.user_id <> ?2)`
	const inFamily = `list_id IN (SELECT id FROM shopping_lists WHERE family_id = ?1)`
	const abandoned = `FROM shopping_lists l WHERE l.family_id = ?1 AND l.assignees_all = 0
		AND NOT EXISTS (SELECT 1 FROM shopping_list_assignees a WHERE a.list_id = l.id)`
	for _, query := range []string{
		`DELETE FROM shopping_lists WHERE id IN (` + ownLists + `)`,
		`DELETE FROM shopping_list_assignees WHERE user_id = ?2 AND ` + inFamily,
		`UPDATE shopping_lists SET created_by = NULL WHERE family_id = ?1 AND created_by = ?2`,
		`UPDATE shopping_items SET added_by = NULL WHERE family_id = ?1 AND added_by = ?2`,
	} {
		if _, err := tx.ExecContext(ctx, query, familyID, userID); err != nil {
			return err
		}
	}
	for _, query := range []string{
		`DELETE FROM shopping_lists WHERE id IN (SELECT l.id ` + abandoned + ` AND l.visibility = 'participants' AND l.created_by IS NULL)`,
		`INSERT INTO shopping_list_assignees (list_id, user_id) SELECT l.id, l.created_by ` + abandoned + ` AND l.visibility = 'participants' ON CONFLICT DO NOTHING`,
		`UPDATE shopping_lists SET assignees_all = 1 WHERE family_id = ?1 AND assignees_all = 0
		 AND NOT EXISTS (SELECT 1 FROM shopping_list_assignees a WHERE a.list_id = shopping_lists.id)`,
	} {
		if _, err := tx.ExecContext(ctx, query, familyID); err != nil {
			return err
		}
	}
	return nil
}

// --- The last list ---

// lastShoppingList is GET /shopping/last: the list the user had open last, for the app
// to go there straight away. Empty if there is none, or none the user still sees.
func (s *Server) lastShoppingList(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	var listID string
	err := s.db.QueryRowContext(ctx, `SELECT list_id FROM shopping_last WHERE family_id = ? AND user_id = ?`, c.familyID, c.userID).Scan(&listID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if listID != "" {
		if err := s.shoppingListAccess(ctx, c, listID); errors.Is(err, errNotFound) {
			listID = ""
		} else if err != nil {
			return err
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"list_id": listID})
	return nil
}

// setLastShoppingList is PUT /shopping/last, when the app opens a list.
func (s *Server) setLastShoppingList(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		ListID string `json:"list_id"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	if err := s.shoppingListAccess(ctx, c, in.ListID); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO shopping_last (family_id, user_id, list_id) VALUES (?, ?, ?)
		 ON CONFLICT (family_id, user_id) DO UPDATE SET list_id = excluded.list_id`,
		c.familyID, c.userID, in.ListID); err != nil {
		return err
	}
	return noContent(w)
}

// --- Due lists in the calendar ---

// dueShoppingLists returns the shopping lists the user sees with a due date from first
// to last, for the calendar "Geplante Aufgaben", with what is still open on them.
func (s *Server) dueShoppingLists(ctx context.Context, c reqCtx, first, last string) ([]map[string]any, error) {
	return queryRows(ctx, s.db,
		`SELECT l.id, l.name, l.due_date, COALESCE(k.name, '') AS category_name, COALESCE(k.color, '') AS category_color,
			(SELECT COUNT(*) FROM shopping_items i WHERE i.list_id = l.id AND i.done = 0) AS open_items
		 FROM shopping_lists l LEFT JOIN categories k ON k.id = l.category_id
		 WHERE l.family_id = ? AND l.due_date <> '' AND l.due_date >= ? AND l.due_date <= ?`+shoppingListVisible+
			`ORDER BY l.due_date, l.name`,
		c.familyID, first, last, c.userID, c.userID)
}

func shoppingListEntryTitle(list map[string]any) string {
	return "Einkaufen: " + list["name"].(string)
}

func shoppingListEntryNote(list map[string]any) string {
	note := "Einkaufsliste"
	switch n := list["open_items"].(int64); n {
	case 0:
		note += ", nichts offen"
	case 1:
		note += ", 1 Artikel offen"
	default:
		note += fmt.Sprintf(", %d Artikel offen", n)
	}
	if category := list["category_name"].(string); category != "" {
		note += " · " + category
	}
	return note
}
