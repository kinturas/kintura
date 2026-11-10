package server

import (
	"strings"
	"testing"
)

func TestPagesNeedNoLogin(t *testing.T) {
	e := newEnv(t)
	for _, page := range defaultPages {
		got := e.expect(200, "GET", "/api/pages/"+page.slug, "", nil)
		if got["title"] != page.title || !strings.Contains(got["content"].(string), "Max Mustermann") {
			t.Errorf("%s: %v", page.slug, got)
		}
	}
	e.expect(404, "GET", "/api/pages/gibtsnicht", "", nil)
}

func TestAdminEditsPages(t *testing.T) {
	e := newEnv(t)
	token := e.activatedAdmin()
	member := e.register("second@example.de", "Second", "Zweiter")
	e.expect(403, "PUT", "/api/admin/pages/impressum", member, obj{"content": "Eigener Text"})
	e.expect(401, "PUT", "/api/admin/pages/impressum", "", obj{"content": "Eigener Text"})

	var pages []Page
	if err := e.getJSON("/api/admin/pages", token, &pages); err != nil {
		t.Fatal(err)
	}
	if len(pages) != len(defaultPages) || pages[0].Slug != "impressum" {
		t.Fatalf("pages: %+v", pages)
	}

	e.expect(400, "PUT", "/api/admin/pages/impressum", token, obj{"content": "  "})
	e.expect(404, "PUT", "/api/admin/pages/gibtsnicht", token, obj{"content": "Text"})
	e.expect(200, "PUT", "/api/admin/pages/impressum", token, obj{"content": "Erika Beispiel\r\nWeg 2\n"})
	if got := e.expect(200, "GET", "/api/pages/impressum", "", nil); got["content"] != "Erika Beispiel\nWeg 2\n" {
		t.Errorf("content: %q", got["content"])
	}

	// A restart must keep the edited text.
	if err := createPages(t.Context(), e.server.db); err != nil {
		t.Fatal(err)
	}
	if got := e.expect(200, "GET", "/api/pages/impressum", "", nil); got["content"] != "Erika Beispiel\nWeg 2\n" {
		t.Errorf("content after restart: %q", got["content"])
	}
}
