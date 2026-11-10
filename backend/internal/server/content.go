package server

import (
	"database/sql"
	"errors"
	"net/http"
)

// --- Lists ---

func (s *Server) listLists(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	rows, err := queryRows(r.Context(), s.db,
		`SELECT l.id, l.name, l.kind,
			(SELECT COUNT(*) FROM list_items i WHERE i.list_id = l.id AND i.done = 0) AS open_items
		 FROM lists l WHERE l.family_id = ? ORDER BY l.kind, l.name`, c.familyID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

func (s *Server) createList(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Name string `json:"name"`
		Kind string `json:"kind"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	name, err := required(in.Name, "Name", 100)
	if err != nil {
		return err
	}
	if in.Kind != "shopping" && in.Kind != "tasks" {
		return fail(http.StatusBadRequest, "Ungültiger Listentyp")
	}
	id := newID()
	if _, err := s.db.ExecContext(r.Context(), `INSERT INTO lists (id, family_id, name, kind, created_at) VALUES (?, ?, ?, ?, ?)`,
		id, c.familyID, name, in.Kind, now()); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

func (s *Server) deleteList(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM lists WHERE id = ? AND family_id = ?`, r.PathValue("id"), c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) listItems(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	rows, err := queryRows(r.Context(), s.db,
		`SELECT i.id, i.title, i.note, i.done, i.due_date, i.assignee_id, COALESCE(m.name, u.name) AS assignee_name
		 FROM list_items i LEFT JOIN users u ON u.id = i.assignee_id
		 LEFT JOIN memberships m ON m.user_id = i.assignee_id AND m.family_id = i.family_id
		 WHERE i.list_id = ? AND i.family_id = ?
		 ORDER BY i.done, i.due_date IS NULL, i.due_date, i.created_at`, r.PathValue("id"), c.familyID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

type itemInput struct {
	Title      string `json:"title"`
	Note       string `json:"note"`
	Done       bool   `json:"done"`
	DueDate    string `json:"due_date"`
	AssigneeID string `json:"assignee_id"`
}

func (s *Server) readItem(w http.ResponseWriter, r *http.Request, c reqCtx) (itemInput, error) {
	var in itemInput
	if err := readJSON(w, r, &in); err != nil {
		return in, err
	}
	var err error
	if in.Title, err = required(in.Title, "Titel", 200); err != nil {
		return in, err
	}
	if in.DueDate != "" && !validDate(in.DueDate) {
		return in, fail(http.StatusBadRequest, "Ungültiges Datum")
	}
	if in.AssigneeID != "" {
		var n int
		if err := s.db.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM memberships WHERE family_id = ? AND user_id = ?`,
			c.familyID, in.AssigneeID).Scan(&n); err != nil {
			return in, err
		}
		if n == 0 {
			return in, fail(http.StatusBadRequest, "Diese Person gehört nicht "+familyTypes[c.familyType].to+".")
		}
	}
	return in, nil
}

func (s *Server) createItem(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := s.readItem(w, r, c)
	if err != nil {
		return err
	}
	ctx := r.Context()
	listID := r.PathValue("id")
	var exists string
	err = s.db.QueryRowContext(ctx, `SELECT id FROM lists WHERE id = ? AND family_id = ?`, listID, c.familyID).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	id := newID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO list_items (id, family_id, list_id, title, note, done, due_date, assignee_id, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, c.familyID, listID, in.Title, in.Note, in.Done, nullable(in.DueDate), nullable(in.AssigneeID), now()); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

func (s *Server) updateItem(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := s.readItem(w, r, c)
	if err != nil {
		return err
	}
	res, err := s.db.ExecContext(r.Context(),
		`UPDATE list_items SET title = ?, note = ?, done = ?, due_date = ?, assignee_id = ? WHERE id = ? AND family_id = ?`,
		in.Title, in.Note, in.Done, nullable(in.DueDate), nullable(in.AssigneeID), r.PathValue("id"), c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) deleteItem(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM list_items WHERE id = ? AND family_id = ?`, r.PathValue("id"), c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

// --- Meals ---

func (s *Server) listMeals(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	from, to := r.URL.Query().Get("from"), r.URL.Query().Get("to")
	if !validDate(from) || !validDate(to) {
		return fail(http.StatusBadRequest, "Ungültiges Datum")
	}
	rows, err := queryRows(r.Context(), s.db,
		`SELECT date, slot, title, note FROM meals WHERE family_id = ? AND date >= ? AND date <= ? ORDER BY date`,
		c.familyID, from, to)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

// putMeal sets the meal for a date and slot; an empty title clears it.
func (s *Server) putMeal(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	date, slot := r.PathValue("date"), r.PathValue("slot")
	if !validDate(date) {
		return fail(http.StatusBadRequest, "Ungültiges Datum")
	}
	if slot != "breakfast" && slot != "lunch" && slot != "dinner" {
		return fail(http.StatusBadRequest, "Ungültige Mahlzeit")
	}
	var in struct {
		Title string `json:"title"`
		Note  string `json:"note"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	if in.Title == "" {
		_, err := s.db.ExecContext(ctx, `DELETE FROM meals WHERE family_id = ? AND date = ? AND slot = ?`, c.familyID, date, slot)
		if err != nil {
			return err
		}
		return noContent(w)
	}
	title, err := required(in.Title, "Titel", 200)
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO meals (family_id, date, slot, title, note) VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT (family_id, date, slot) DO UPDATE SET title = excluded.title, note = excluded.note`,
		c.familyID, date, slot, title, in.Note); err != nil {
		return err
	}
	return noContent(w)
}

// --- Messages ---

func (s *Server) listMessages(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	rows, err := queryRows(r.Context(), s.db,
		`SELECT id, sender_id, sender_name, body, created_at FROM (
			SELECT m.id, m.sender_id, COALESCE(s.name, u.name) AS sender_name, m.body, m.created_at, m.seq
			FROM messages m JOIN users u ON u.id = m.sender_id
			LEFT JOIN memberships s ON s.user_id = m.sender_id AND s.family_id = m.family_id
			WHERE m.family_id = ? ORDER BY m.created_at DESC, m.seq DESC LIMIT 200
		 ) AS recent ORDER BY created_at, seq`, c.familyID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

func (s *Server) createMessage(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Body string `json:"body"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	body, err := required(in.Body, "Nachricht", 4000)
	if err != nil {
		return err
	}
	id := newID()
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO messages (id, family_id, sender_id, body, created_at, seq)
		 VALUES (?1, ?2, ?3, ?4, ?5, (SELECT COALESCE(MAX(seq), 0) + 1 FROM messages WHERE family_id = ?2))`,
		id, c.familyID, c.userID, body, now()); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

// --- Special days ---

func (s *Server) listSpecialDays(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	rows, err := queryRows(r.Context(), s.db,
		`SELECT id, title, kind, date, yearly, note FROM special_days WHERE family_id = ? ORDER BY substr(date, 6), title`, c.familyID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

type specialDayInput struct {
	Title  string `json:"title"`
	Kind   string `json:"kind"`
	Date   string `json:"date"`
	Yearly bool   `json:"yearly"`
	Note   string `json:"note"`
}

func readSpecialDay(w http.ResponseWriter, r *http.Request) (specialDayInput, error) {
	var in specialDayInput
	if err := readJSON(w, r, &in); err != nil {
		return in, err
	}
	var err error
	if in.Title, err = required(in.Title, "Titel", 200); err != nil {
		return in, err
	}
	switch in.Kind {
	case "feast", "memorial", "birthday", "other":
	default:
		return in, fail(http.StatusBadRequest, "Ungültige Art")
	}
	if !validDate(in.Date) {
		return in, fail(http.StatusBadRequest, "Ungültiges Datum")
	}
	return in, nil
}

func (s *Server) createSpecialDay(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := readSpecialDay(w, r)
	if err != nil {
		return err
	}
	id := newID()
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO special_days (id, family_id, title, kind, date, yearly, note) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, c.familyID, in.Title, in.Kind, in.Date, in.Yearly, in.Note); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

func (s *Server) updateSpecialDay(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := readSpecialDay(w, r)
	if err != nil {
		return err
	}
	res, err := s.db.ExecContext(r.Context(),
		`UPDATE special_days SET title = ?, kind = ?, date = ?, yearly = ?, note = ? WHERE id = ? AND family_id = ?`,
		in.Title, in.Kind, in.Date, in.Yearly, in.Note, r.PathValue("id"), c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) deleteSpecialDay(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM special_days WHERE id = ? AND family_id = ?`, r.PathValue("id"), c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}
