package server

import (
	"strings"
	"testing"
)

func TestFilesLieInTheFolderOfTheirFamily(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	status, out := e.upload(token, fid, "document", "brief.txt", []byte("Hallo"))
	if status != 201 {
		t.Fatalf("upload: %d %v", status, out)
	}
	id := out["id"].(string)
	if key := e.files.keyOf(id); key != fid+"/"+id {
		t.Fatalf("key %q, want %q", key, fid+"/"+id)
	}
	if status, body := e.getRaw("/api/families/"+fid+"/files/"+id+"/content", token); status != 200 || body != "Hallo" {
		t.Fatalf("content: %d %q", status, body)
	}
	link := e.expect(200, "POST", "/api/families/"+fid+"/files/"+id+"/link", token, nil)["url"].(string)
	if status, body := e.getRaw(strings.TrimPrefix(link, "http://test"), ""); status != 200 || body != "Hallo" {
		t.Fatalf("download: %d %q", status, body)
	}
	e.expect(204, "DELETE", "/api/families/"+fid+"/files/"+id, token, nil)
	if e.fileStored(id) {
		t.Fatal("still stored")
	}
}
