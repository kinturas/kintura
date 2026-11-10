package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testAdminKey = "test-admin-key-0123456789"

// activatedAdmin registers the first user and unlocks the dashboard for them.
func (e *testEnv) activatedAdmin() string {
	e.t.Helper()
	e.server.adminKey = testAdminKey
	token := e.register("first@example.de", "First", "Erster")
	e.expect(204, "POST", "/api/admin/activate", token, obj{"key": testAdminKey})
	return token
}

func (e *testEnv) logEntries(token string) []any {
	e.t.Helper()
	return e.expect(200, "GET", "/api/admin/log", token, nil)["entries"].([]any)
}

func TestOnlyFirstUserIsSysadmin(t *testing.T) {
	e := newEnv(t)
	first := e.register("first@example.de", "First", "Erster")
	second := e.register("second@example.de", "Second", "Zweiter")
	if status := e.expect(200, "GET", "/api/admin/status", first, nil); status["activated"] != false {
		t.Errorf("first user must still unlock the dashboard: %v", status)
	}
	e.expect(403, "GET", "/api/admin/status", second, nil)
	e.expect(403, "POST", "/api/admin/activate", second, obj{"key": testAdminKey})
	e.expect(401, "GET", "/api/admin/status", "", nil)
}

func TestDashboardNeedsActivation(t *testing.T) {
	e := newEnv(t)
	token := e.register("first@example.de", "First", "Erster")
	for _, path := range []string{"/api/admin/families", "/api/admin/users", "/api/admin/log"} {
		e.expect(403, "GET", path, token, nil)
	}

	e.expect(503, "POST", "/api/admin/activate", token, obj{"key": ""})
	e.server.adminKey = testAdminKey
	e.expect(403, "POST", "/api/admin/activate", token, obj{"key": "falsch"})
	e.expect(403, "GET", "/api/admin/families", token, nil)
	e.expect(204, "POST", "/api/admin/activate", token, obj{"key": testAdminKey})
	e.expect(200, "GET", "/api/admin/families", token, nil)

	// Activation lasts, also for a new session and without the key.
	id, code := e.startLogin("first@example.de")
	again := e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})["token"].(string)
	e.server.adminKey = ""
	if status := e.expect(200, "GET", "/api/admin/status", again, nil); status["activated"] != true {
		t.Errorf("activation lost: %v", status)
	}
}

func TestTokenLoginAsAdminAccount(t *testing.T) {
	e := newEnv(t)
	e.expect(401, "POST", "/api/auth/token", "", obj{"token": ""})
	e.expect(401, "POST", "/api/auth/token", "", obj{"token": testAdminKey})

	e.server.adminKey = testAdminKey
	e.expect(401, "POST", "/api/auth/token", "", obj{"token": "falsch"})
	token := e.expect(200, "POST", "/api/auth/token", "", obj{"token": testAdminKey})["token"].(string)
	status := e.expect(200, "GET", "/api/admin/status", token, nil)
	if status["email"] != adminEmail || status["activated"] != true {
		t.Errorf("status: %v", status)
	}
	e.expect(200, "GET", "/api/admin/users", token, nil)

	// The admin account does not take the place of the first real user.
	first := e.register("first@example.de", "First", "Erster")
	e.expect(200, "GET", "/api/admin/status", first, nil)
	second := e.register("second@example.de", "Second", "Zweiter")
	e.expect(403, "GET", "/api/admin/status", second, nil)

	// The account has no mailbox, so the mail login must not reach it.
	e.expect(400, "POST", "/api/auth/request", "", obj{"email": adminEmail})
}

func TestTokenLoginSessionIsShort(t *testing.T) {
	e := newEnv(t)
	e.server.adminKey = testAdminKey
	token := e.expect(200, "POST", "/api/auth/token", "", obj{"token": testAdminKey})["token"].(string)
	var expires string
	if err := e.server.db.QueryRow(`SELECT expires_at FROM sessions WHERE token_hash = ?`, hashToken(token)).Scan(&expires); err != nil {
		t.Fatal(err)
	}
	limit := time.Now().UTC().Add(adminSessionTTL + time.Minute).Format(timeFormat)
	if expires > limit {
		t.Errorf("session lasts until %s", expires)
	}
}

func TestTokenFailuresAreLimited(t *testing.T) {
	e := newEnv(t)
	e.server.adminKey = testAdminKey
	for range maxKeyFailures {
		e.expect(401, "POST", "/api/auth/token", "", obj{"token": "falsch"})
	}
	// Once the limit is reached, even the right token is refused and the log stops growing.
	e.expect(429, "POST", "/api/auth/token", "", obj{"token": testAdminKey})
	e.expect(429, "POST", "/api/auth/token", "", obj{"token": "falsch"})
	var n int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM error_log`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != maxKeyFailures {
		t.Errorf("log entries: %d", n)
	}

	// The mail login keeps working, and the limit ends with its time window.
	token := e.register("first@example.de", "First", "Erster")
	e.expect(200, "GET", "/api/admin/status", token, nil)
	old := time.Now().UTC().Add(-keyFailureWindow - time.Minute).Format(timeFormat)
	if _, err := e.server.db.Exec(`UPDATE error_log SET created_at = ?`, old); err != nil {
		t.Fatal(err)
	}
	e.expect(200, "POST", "/api/auth/token", "", obj{"token": testAdminKey})
}

func TestAdminListsAllFamiliesAndMembers(t *testing.T) {
	e := newEnv(t)
	admin := e.activatedAdmin()
	other := e.register("other@example.de", "Other", "Fremd")
	fid := e.firstFamily(other)
	e.expect(201, "POST", "/api/families/"+fid+"/invitations", other, obj{"email": "kid@example.de", "role": "restrict_user"})
	e.register("kid@example.de", "Kid", "")

	var families, users []obj
	if err := e.getJSON("/api/admin/families", admin, &families); err != nil {
		t.Fatal(err)
	}
	if err := e.getJSON("/api/admin/users", admin, &users); err != nil {
		t.Fatal(err)
	}
	if len(families) != 2 || families[0]["name"] != "Erster" || families[1]["name"] != "Fremd" {
		t.Fatalf("families: %v", families)
	}
	members := families[1]["members"].([]any)
	if len(members) != 2 || members[0].(obj)["email"] != "other@example.de" || members[0].(obj)["is_admin"] != true ||
		members[1].(obj)["email"] != "kid@example.de" || members[1].(obj)["role"] != "restrict_user" {
		t.Errorf("members: %v", members)
	}
	byEmail := map[any]obj{}
	for _, user := range users {
		byEmail[user["email"]] = user
	}
	if len(users) != 4 || byEmail["first@example.de"]["is_sysadmin"] != true || byEmail["other@example.de"]["is_sysadmin"] != false {
		t.Errorf("users: %v", users)
	}
	if in := byEmail["kid@example.de"]["families"].([]any); len(in) != 1 || in[0].(obj)["name"] != "Fremd" {
		t.Errorf("kid: %v", in)
	}
	if in := byEmail[adminEmail]["families"].([]any); len(in) != 0 {
		t.Errorf("admin account: %v", in)
	}
}

// getJSON reads a response whose top level is a list, which call cannot decode.
func (e *testEnv) getJSON(path, token string, out any) error {
	req, _ := http.NewRequest("GET", e.srv.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	return json.NewDecoder(res.Body).Decode(out)
}

func TestErrorLog(t *testing.T) {
	e := newEnv(t)
	admin := e.activatedAdmin()
	if entries := e.logEntries(admin); len(entries) != 0 {
		t.Fatalf("log not empty: %v", entries)
	}

	// Mistakes of a user are not errors.
	id, _ := e.startLogin("first@example.de")
	e.expect(400, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": "nope"})
	if entries := e.logEntries(admin); len(entries) != 0 {
		t.Errorf("user mistake logged: %v", entries)
	}

	e.mailer.err = errors.New("535 Incorrect authentication data")
	e.expect(502, "POST", "/api/auth/request", "", obj{"email": "New@Example.de"})
	fid := e.firstFamily(admin)
	e.expect(201, "POST", "/api/families/"+fid+"/invitations", admin, obj{"email": "guest@example.de", "role": "user"})
	e.mailer.err = nil

	entries := e.logEntries(admin)
	if len(entries) != 2 {
		t.Fatalf("entries: %v", entries)
	}
	invite, login := entries[0].(obj), entries[1].(obj)
	if login["email"] != "new@example.de" || login["endpoint"] != "POST /api/auth/request" || login["status"] != float64(502) ||
		login["family_name"] != "" || !strings.Contains(login["message"].(string), "535") {
		t.Errorf("login mail entry: %v", login)
	}
	if invite["email"] != "first@example.de" || invite["family_name"] != "Erster" ||
		invite["endpoint"] != "POST /api/families/{fid}/invitations" || !strings.Contains(invite["message"].(string), "guest@example.de") {
		t.Errorf("invitation mail entry: %v", invite)
	}
}

func TestErrorLogKeepsSecretsOut(t *testing.T) {
	e := newEnv(t)
	admin := e.activatedAdmin()
	e.expect(401, "POST", "/api/auth/token", "", obj{"token": "geheimer-versuch"})
	e.mailer.err = errors.New("kaputt")
	e.expect(502, "POST", "/api/auth/request", "", obj{"email": "x@example.de"})
	e.mailer.err = nil

	// The download token is part of the path, so a failure there must only store the pattern.
	req := httptest.NewRequest("GET", "/dl/geheimer-link", nil)
	req.Pattern = "GET /dl/{token}"
	e.server.logError(req, 500, "Download: kaputt")

	for _, entry := range e.logEntries(admin) {
		text := fmt.Sprint(entry)
		if strings.Contains(text, "geheim") {
			t.Errorf("secret in log: %s", text)
		}
	}
}

func TestPanicIsLoggedAndAnswered(t *testing.T) {
	e := newEnv(t)
	admin := e.activatedAdmin()
	handler := e.server.wrap(func(w http.ResponseWriter, r *http.Request) error { panic("kaputt") })
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("GET", "/x", nil))
	if rec.Code != 500 || !strings.Contains(rec.Body.String(), "Interner Fehler") || strings.Contains(rec.Body.String(), "kaputt") {
		t.Errorf("response: %d %s", rec.Code, rec.Body.String())
	}
	entries := e.logEntries(admin)
	if len(entries) != 1 || !strings.Contains(entries[0].(obj)["message"].(string), "panic: kaputt") {
		t.Errorf("entries: %v", entries)
	}
}

func TestErrorLogPagesAndTrim(t *testing.T) {
	e := newEnv(t)
	admin := e.activatedAdmin()
	for i := range logPageSize + 5 {
		e.server.logError(nil, 0, fmt.Sprintf("Fehler %d", i))
	}
	page := e.expect(200, "GET", "/api/admin/log", admin, nil)
	entries := page["entries"].([]any)
	if len(entries) != logPageSize || page["has_more"] != true {
		t.Fatalf("page: %d %v", len(entries), page["has_more"])
	}
	if entries[0].(obj)["message"] != fmt.Sprintf("Fehler %d", logPageSize+4) {
		t.Errorf("newest first: %v", entries[0])
	}
	last := int64(entries[logPageSize-1].(obj)["id"].(float64))
	page = e.expect(200, "GET", fmt.Sprintf("/api/admin/log?before=%d", last), admin, nil)
	if len(page["entries"].([]any)) != 5 || page["has_more"] != false {
		t.Errorf("second page: %v", page)
	}
	e.expect(400, "GET", "/api/admin/log?before=x", admin, nil)

	e.server.logError(nil, 0, strings.Repeat("x", logMaxMessage+50))
	long := e.logEntries(admin)[0].(obj)["message"].(string)
	if len(long) != logMaxMessage {
		t.Errorf("message length: %d", len(long))
	}

	old := time.Now().UTC().Add(-logRetention - time.Hour).Format(timeFormat)
	if _, err := e.server.db.Exec(`UPDATE error_log SET created_at = ? WHERE message = 'Fehler 0'`, old); err != nil {
		t.Fatal(err)
	}
	e.server.cleanup(context.Background())
	var n int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM error_log WHERE message = 'Fehler 0'`).Scan(&n); err != nil || n != 0 {
		t.Errorf("old entry kept: %d %v", n, err)
	}
	if _, err := e.server.db.Exec(`INSERT INTO error_log (id, created_at, message) VALUES (?, ?, 'neu')`, logMaxEntries+1000, now()); err != nil {
		t.Fatal(err)
	}
	e.server.cleanup(context.Background())
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM error_log WHERE message LIKE 'Fehler %'`).Scan(&n); err != nil || n != 0 {
		t.Errorf("entries over the limit kept: %d %v", n, err)
	}
}

func TestAdminPagesAreServed(t *testing.T) {
	e := newEnv(t)
	for _, tc := range []struct{ path, contains string }{
		{"/admin", "Kintura Admin"},
		{"/admin/admin.js", "/api/admin/status"},
		{"/admin/admin.css", "--accent"},
		{"/login/token", "API-Token"},
		{"/admin/token.js", "/api/auth/token"},
	} {
		res, err := http.Get(e.srv.URL + tc.path)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != 200 || !strings.Contains(string(body), tc.contains) {
			t.Errorf("%s: %d", tc.path, res.StatusCode)
		}
		if !strings.Contains(res.Header.Get("Content-Security-Policy"), "script-src 'self'") {
			t.Errorf("%s: no policy", tc.path)
		}
	}
}
