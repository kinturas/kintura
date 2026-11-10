package server

import (
	"context"
	"net/http"
	"slices"
)

// initialCategories are created together with every family.
var initialCategories = []struct{ name, color string }{
	{"Allgemein", "#A5D6A7"},
	{"Wichtig", "#D32F2F"},
}

func insertInitialCategories(ctx context.Context, q dbtx, familyID string) error {
	for i, category := range initialCategories {
		if _, err := q.ExecContext(ctx, `INSERT INTO categories (id, family_id, name, color, position) VALUES (?, ?, ?, ?, ?)`,
			newID(), familyID, category.name, category.color, i); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) listCategories(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	categories, err := queryRows(r.Context(), s.db,
		`SELECT id, name, color, EXISTS (SELECT 1 FROM events e WHERE e.category_id = categories.id) AS used
		 FROM categories WHERE family_id = ? ORDER BY position`, c.familyID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"categories": categories})
	return nil
}

type categoryInput struct {
	Name  string `json:"name"`
	Color string `json:"color"`
}

// readCategory validates the fields of a category. An empty color means none.
func (s *Server) readCategory(w http.ResponseWriter, r *http.Request, c reqCtx) (categoryInput, error) {
	var in categoryInput
	if err := readJSON(w, r, &in); err != nil {
		return in, err
	}
	name, err := required(in.Name, "Name der Kategorie", 50)
	if err != nil {
		return in, err
	}
	in.Name = name
	if in.Color != "" {
		if err := s.checkFamilyColor(r.Context(), c.familyID, in.Color); err != nil {
			return in, err
		}
	}
	return in, nil
}

var errCategoryExists = fail(http.StatusConflict, "Diese Kategorie gibt es bereits.")

func (s *Server) createCategory(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := s.readCategory(w, r, c)
	if err != nil {
		return err
	}
	id := newID()
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO categories (id, family_id, name, color, position)
		 VALUES (?1, ?2, ?3, ?4, (SELECT COALESCE(MAX(position) + 1, 0) FROM categories WHERE family_id = ?2))`,
		id, c.familyID, in.Name, in.Color); err != nil {
		if isUniqueViolation(err) {
			return errCategoryExists
		}
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

func (s *Server) updateCategory(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := s.readCategory(w, r, c)
	if err != nil {
		return err
	}
	res, err := s.db.ExecContext(r.Context(), `UPDATE categories SET name = ?, color = ? WHERE id = ? AND family_id = ?`,
		in.Name, in.Color, r.PathValue("id"), c.familyID)
	if isUniqueViolation(err) {
		return errCategoryExists
	}
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

// deleteCategory only removes categories that no event uses.
func (s *Server) deleteCategory(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var used bool
	if err := s.db.QueryRowContext(r.Context(), `SELECT EXISTS (SELECT 1 FROM events WHERE category_id = ? AND family_id = ?)`,
		r.PathValue("id"), c.familyID).Scan(&used); err != nil {
		return err
	}
	if used {
		return fail(http.StatusConflict, "Diese Kategorie wird noch von Terminen verwendet.")
	}
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM categories WHERE id = ? AND family_id = ?`, r.PathValue("id"), c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

// reorderCategories expects all categories of the family in their new order.
func (s *Server) reorderCategories(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		IDs []string `json:"ids"`
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
	rows, err := queryRows(ctx, tx, `SELECT id FROM categories WHERE family_id = ? ORDER BY id`, c.familyID)
	if err != nil {
		return err
	}
	known := make([]string, len(rows))
	for i, row := range rows {
		known[i] = row["id"].(string)
	}
	sorted := slices.Sorted(slices.Values(in.IDs))
	if !slices.Equal(sorted, known) {
		return fail(http.StatusBadRequest, "Ungültige Reihenfolge")
	}
	for i, id := range in.IDs {
		if _, err := tx.ExecContext(ctx, `UPDATE categories SET position = ? WHERE id = ? AND family_id = ?`, i, id, c.familyID); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}
