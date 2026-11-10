package server

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/kinturas/kintura/backend/internal/database"
)

// maxPageLength limits a page in characters, far beyond what a privacy notice needs.
const maxPageLength = 100_000

//go:embed pages
var pageFiles embed.FS

// defaultPages are the texts the app links to. Each one is created with the example
// text in pages/<slug>.md and then edited in the admin dashboard. A new page needs
// an entry here, a file and a link in the app.
var defaultPages = []struct{ slug, title string }{
	{"impressum", "Impressum"},
	{"datenschutz", "Datenschutzerklärung"},
}

// Page is a text in Markdown: paragraphs, ## headings, lists, **bold** and links.
// A single line break stays a line break, as in an address.
type Page struct {
	Slug      string `json:"slug"`
	Title     string `json:"title"`
	Content   string `json:"content"`
	UpdatedAt string `json:"updated_at"`
}

func defaultPageContent(slug string) (string, error) {
	content, err := pageFiles.ReadFile("pages/" + slug + ".md")
	return string(content), err
}

// createPages adds the pages that are still missing and leaves edited ones alone.
func createPages(ctx context.Context, db database.Querier) error {
	for _, page := range defaultPages {
		content, err := defaultPageContent(page.slug)
		if err != nil {
			return err
		}
		if _, err := db.ExecContext(ctx, `INSERT INTO pages (slug, title, content, updated_at) VALUES (?, ?, ?, ?)
			ON CONFLICT DO NOTHING`, page.slug, page.title, content, now()); err != nil {
			return err
		}
		var current string
		if err := db.QueryRowContext(ctx, `SELECT content FROM pages WHERE slug = ?`, page.slug).Scan(&current); err != nil {
			return err
		}
		if current == content {
			log.Printf("WARNUNG: Die Seite %s enthält noch die Beispieldaten - im Admin-Dashboard unter Seiten anpassen", page.title)
		}
	}
	return nil
}

// getPage needs no session: people have to be able to read the imprint and the
// privacy notice before signing up.
func (s *Server) getPage(w http.ResponseWriter, r *http.Request) error {
	var page Page
	err := s.db.QueryRowContext(r.Context(), `SELECT slug, title, content, updated_at FROM pages WHERE slug = ?`,
		r.PathValue("slug")).Scan(&page.Slug, &page.Title, &page.Content, &page.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, page)
	return nil
}

func (s *Server) adminPages(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	rows, err := s.db.QueryContext(r.Context(), `SELECT slug, title, content, updated_at FROM pages`)
	if err != nil {
		return err
	}
	defer rows.Close()
	bySlug := map[string]Page{}
	for rows.Next() {
		var page Page
		if err := rows.Scan(&page.Slug, &page.Title, &page.Content, &page.UpdatedAt); err != nil {
			return err
		}
		bySlug[page.Slug] = page
	}
	if err := rows.Err(); err != nil {
		return err
	}
	// In the order of defaultPages, as the app shows them.
	pages := []Page{}
	for _, page := range defaultPages {
		if found, ok := bySlug[page.slug]; ok {
			pages = append(pages, found)
		}
	}
	writeJSON(w, http.StatusOK, pages)
	return nil
}

func (s *Server) adminUpdatePage(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Content string `json:"content"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	content, err := required(strings.ReplaceAll(in.Content, "\r\n", "\n"), "Inhalt", maxPageLength)
	if err != nil {
		return err
	}
	updated := now()
	res, err := s.db.ExecContext(r.Context(), `UPDATE pages SET content = ?, updated_at = ? WHERE slug = ?`,
		content+"\n", updated, r.PathValue("slug"))
	if err := requireAffected(res, err); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"updated_at": updated})
	return nil
}
