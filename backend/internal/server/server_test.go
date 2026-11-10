package server

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/kinturas/kintura/backend/internal/database"
	"github.com/kinturas/kintura/backend/internal/storage"
)

type fakeMailer struct {
	mu   sync.Mutex
	last string
	to   []string
	err  error
}

func (m *fakeMailer) Send(to, subject, body string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.err != nil {
		return m.err
	}
	m.last = body
	m.to = append(m.to, to)
	return nil
}

type testEnv struct {
	t      *testing.T
	srv    *httptest.Server
	mailer *fakeMailer
	server *Server
}

func newEnv(t *testing.T) *testEnv {
	t.Helper()
	mailer := &fakeMailer{}
	s, err := New(t.Context(), Config{
		DB: testDatabase(t), Files: testFiles(t), Mailer: mailer, PublicURL: "http://test", CORSOrigin: "*",
	})
	if err != nil {
		t.Fatal(err)
	}
	// No test may reach the real holiday service.
	holidays := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "[]")
	}))
	t.Cleanup(holidays.Close)
	s.holidaysURL = holidays.URL
	srv := httptest.NewServer(s.routes())
	t.Cleanup(srv.Close)
	return &testEnv{t, srv, mailer, s}
}

func TestVersionNeedsNoLogin(t *testing.T) {
	env := newEnv(t)
	env.server.version = "1.2.3+4"

	res, err := http.Get(env.srv.URL + "/api/version")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var body struct {
		Version string `json:"version"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != http.StatusOK || body.Version != "1.2.3+4" {
		t.Errorf("status %d, version %q", res.StatusCode, body.Version)
	}
}

func TestWebAppLeavesOtherRoutesAlone(t *testing.T) {
	env := newEnv(t)
	env.server.webDir = t.TempDir()
	env.server.version = "1.2.3+4"
	if err := os.WriteFile(filepath.Join(env.server.webDir, "index.html"), []byte("<title>App</title>"), 0o600); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		path   string
		status int
		want   string
	}{
		{"/", http.StatusOK, "<title>App</title>"},
		{"/api/version", http.StatusOK, "1.2.3+4"},
		{"/gibt-es-nicht.js", http.StatusNotFound, ""},
	} {
		res, err := http.Get(env.srv.URL + tc.path)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != tc.status || !strings.Contains(string(body), tc.want) {
			t.Errorf("%s: status %d, body %q", tc.path, res.StatusCode, body)
		}
	}
}

// testDatabase is an empty SQLite file, or with TEST_DATABASE_URL a schema of its own
// in that Postgres, see compose.test.yaml.
func testDatabase(t *testing.T) *database.DB {
	t.Helper()
	cfg := database.Config{Driver: database.SQLite, Path: filepath.Join(t.TempDir(), "test.db")}
	if address := os.Getenv("TEST_DATABASE_URL"); address != "" {
		admin, err := sql.Open("pgx", address)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { admin.Close() })
		schema := "test_" + newID()
		if _, err := admin.Exec(`CREATE SCHEMA ` + schema); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if _, err := admin.Exec(`DROP SCHEMA ` + schema + ` CASCADE`); err != nil {
				t.Error(err)
			}
		})
		parsed, err := url.Parse(address)
		if err != nil {
			t.Fatal(err)
		}
		query := parsed.Query()
		query.Set("search_path", schema)
		parsed.RawQuery = query.Encode()
		cfg = database.Config{Driver: database.Postgres, URL: parsed.String()}
	}
	db, err := database.Open(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// testFiles is an empty directory, or with TEST_S3_ENDPOINT a prefix of its own in that
// bucket, see compose.test.yaml.
func testFiles(t *testing.T) storage.Store {
	t.Helper()
	if endpoint := os.Getenv("TEST_S3_ENDPOINT"); endpoint != "" {
		files, err := storage.NewS3(context.Background(), storage.S3Config{
			Endpoint: endpoint, Bucket: os.Getenv("TEST_S3_BUCKET"), Prefix: "test-" + newID(), Region: "us-east-1", PathStyle: true, CreateBucket: true,
			AccessKey: os.Getenv("TEST_S3_ACCESS_KEY"), SecretKey: os.Getenv("TEST_S3_SECRET_KEY"),
		})
		if err != nil {
			t.Fatal(err)
		}
		return files
	}
	files, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return files
}

// fileStored says whether the file itself is there, whatever the database says.
func (e *testEnv) fileStored(id string) bool {
	e.t.Helper()
	content, _, err := e.server.files.Get(context.Background(), id)
	if errors.Is(err, storage.ErrNotFound) {
		return false
	}
	if err != nil {
		e.t.Fatal(err)
	}
	content.Close()
	return true
}

type obj = map[string]any

func (e *testEnv) call(method, path, token string, body any) (int, obj) {
	e.t.Helper()
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.srv.URL+path, reader)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	out := obj{}
	if err := json.Unmarshal(raw, &out); err != nil {
		out["raw"] = string(raw)
	}
	return res.StatusCode, out
}

func (e *testEnv) expect(want int, method, path, token string, body any) obj {
	e.t.Helper()
	status, out := e.call(method, path, token, body)
	if status != want {
		e.t.Fatalf("%s %s: status %d, want %d: %v", method, path, status, want, out)
	}
	return out
}

var codePattern = regexp.MustCompile(`\n    (\d{6})\n`)
var linkPattern = regexp.MustCompile(`token=([0-9a-f]+)`)

// startLogin requests a login and returns the request id and the mailed code.
func (e *testEnv) startLogin(email string) (string, string) {
	e.t.Helper()
	out := e.expect(200, "POST", "/api/auth/request", "", obj{"email": email})
	return out["request_id"].(string), codePattern.FindStringSubmatch(e.mailer.last)[1]
}

func (e *testEnv) register(email, name, family string) string {
	e.t.Helper()
	id, code := e.startLogin(email)
	out := e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
	if out["status"] != "registration_required" {
		e.t.Fatalf("expected registration_required, got %v", out)
	}
	out = e.expect(201, "POST", "/api/auth/register", "", obj{
		"request_id": id, "name": name, "family_name": family,
	})
	return out["token"].(string)
}

func (e *testEnv) firstFamily(token string) string {
	e.t.Helper()
	return e.expect(200, "GET", "/api/me", token, nil)["last_family_id"].(string)
}

func TestRegistrationCreatesFamilyWithAdmin(t *testing.T) {
	e := newEnv(t)
	token := e.register("Anna@Example.de", "Anna", "Müller")
	me := e.expect(200, "GET", "/api/me", token, nil)
	if me["email"] != "anna@example.de" {
		t.Errorf("email not normalized: %v", me["email"])
	}
	families := me["families"].([]any)
	if len(families) != 1 {
		t.Fatalf("families: %v", families)
	}
	f := families[0].(obj)
	if f["name"] != "Müller" || f["role"] != "manager" || f["is_admin"] != true {
		t.Errorf("family: %v", f)
	}
	if me["last_family_id"] != f["id"] {
		t.Errorf("new family not selected: %v", me)
	}
}

func TestKnownUserLogsInWithCode(t *testing.T) {
	e := newEnv(t)
	e.register("a@example.de", "A", "F")
	id, code := e.startLogin("a@example.de")
	out := e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
	if out["status"] != "authenticated" || out["token"] == "" {
		t.Fatalf("got %v", out)
	}
	// A login can only be used once.
	e.expect(410, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
}

func TestLinkFlowNeedsExplicitConfirmation(t *testing.T) {
	e := newEnv(t)
	e.register("a@example.de", "A", "F")
	id, _ := e.startLogin("a@example.de")
	token := linkPattern.FindStringSubmatch(e.mailer.last)[1]

	// Opening the link, as a mail scanner would, must not log anybody in.
	res, err := http.Get(e.srv.URL + "/login?token=" + token)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if out := e.expect(200, "POST", "/api/auth/poll", "", obj{"request_id": id}); out["status"] != "pending" {
		t.Fatalf("GET confirmed the login: %v", out)
	}

	res, err = http.PostForm(e.srv.URL+"/login", url.Values{"token": {token}})
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 200 {
		t.Fatalf("confirm status %d", res.StatusCode)
	}
	if out := e.expect(200, "POST", "/api/auth/poll", "", obj{"request_id": id}); out["status"] != "authenticated" {
		t.Fatalf("got %v", out)
	}
}

func TestCodeAttemptsAreLimited(t *testing.T) {
	e := newEnv(t)
	id, code := e.startLogin("a@example.de")
	wrong := "000000"
	if code == wrong {
		wrong = "000001"
	}
	for range maxCodeAttempts {
		e.expect(400, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": wrong})
	}
	e.expect(429, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
}

func TestLoginRequestsAreRateLimited(t *testing.T) {
	e := newEnv(t)
	for range maxOpenRequests {
		e.expect(200, "POST", "/api/auth/request", "", obj{"email": "a@example.de"})
	}
	e.expect(429, "POST", "/api/auth/request", "", obj{"email": "a@example.de"})
}

func TestRegisterRequiresVerifiedRequest(t *testing.T) {
	e := newEnv(t)
	id, _ := e.startLogin("a@example.de")
	e.expect(403, "POST", "/api/auth/register", "", obj{
		"request_id": id, "name": "A", "family_name": "F",
	})
}

func TestInvitationJoinsFamilyAsChild(t *testing.T) {
	e := newEnv(t)
	parent := e.register("p@example.de", "P", "F")
	fid := e.firstFamily(parent)
	e.expect(201, "POST", "/api/families/"+fid+"/invitations", parent, obj{"email": "k@example.de", "role": "restrict_user"})

	id, code := e.startLogin("k@example.de")
	out := e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
	if fmt.Sprint(out["invited_families"]) != "[F]" {
		t.Fatalf("invited_families: %v", out)
	}
	child := e.expect(201, "POST", "/api/auth/register", "", obj{"request_id": id, "name": "K"})["token"].(string)
	if got := e.firstFamily(child); got != fid {
		t.Fatalf("child in family %v, want %v", got, fid)
	}

	// Children can use content but not administer the family.
	e.expect(201, "POST", "/api/families/"+fid+"/lists", child, obj{"name": "Einkauf", "kind": "shopping"})
	e.expect(403, "PUT", "/api/families/"+fid, child, obj{"name": "X"})
	e.expect(403, "POST", "/api/families/"+fid+"/invitations", child, obj{"email": "x@example.de", "role": "manager"})
}

func TestAdminCannotLeaveOrRevokeOwnFlag(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	me := e.expect(200, "GET", "/api/me", admin, nil)
	fid, adminID := me["last_family_id"].(string), me["id"].(string)
	e.expect(201, "POST", "/api/families/"+fid+"/invitations", admin, obj{"email": "b@example.de", "role": "manager", "is_admin": true})
	id, code := e.startLogin("b@example.de")
	e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
	second := e.expect(201, "POST", "/api/auth/register", "", obj{"request_id": id, "name": "B"})["token"].(string)

	// A second admin does not change the rules for oneself.
	e.expect(409, "DELETE", "/api/families/"+fid+"/members/"+adminID, admin, nil)
	e.expect(409, "PUT", "/api/families/"+fid+"/members/"+adminID, admin, obj{"role": "manager", "is_admin": false})
	// The own role may change as long as the flag stays.
	e.expect(204, "PUT", "/api/families/"+fid+"/members/"+adminID, admin, obj{"role": "user", "is_admin": true})

	// Another admin can revoke the flag, after which leaving works.
	e.expect(204, "PUT", "/api/families/"+fid+"/members/"+adminID, second, obj{"role": "user", "is_admin": false})
	e.expect(204, "DELETE", "/api/families/"+fid+"/members/"+adminID, admin, nil)
	if got := e.expect(200, "GET", "/api/me", admin, nil)["families"].([]any); len(got) != 0 {
		t.Fatalf("still a member: %v", got)
	}
}

func TestAdminCanRemoveOtherAdmin(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	e.expect(201, "POST", "/api/families/"+fid+"/invitations", admin, obj{"email": "b@example.de", "role": "manager", "is_admin": true})
	id, code := e.startLogin("b@example.de")
	e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
	second := e.expect(201, "POST", "/api/auth/register", "", obj{"request_id": id, "name": "B"})["token"].(string)
	secondID := e.expect(200, "GET", "/api/me", second, nil)["id"].(string)
	e.expect(204, "DELETE", "/api/families/"+fid+"/members/"+secondID, admin, nil)
}

func TestSelectedFamilyIsRemembered(t *testing.T) {
	e := newEnv(t)
	token := e.register("p@example.de", "P", "Erste")
	first := e.firstFamily(token)
	second := e.expect(201, "POST", "/api/families", token, obj{"name": "Zweite"})["id"].(string)
	if got := e.firstFamily(token); got != second {
		t.Fatalf("new family not selected: %v", got)
	}
	e.expect(204, "POST", "/api/families/"+first+"/select", token, nil)
	if got := e.firstFamily(token); got != first {
		t.Fatalf("selection not remembered: %v", got)
	}
}

func TestFamilyTypeDefaultsToFamily(t *testing.T) {
	e := newEnv(t)
	token := e.register("p@example.de", "P", "F")
	me := e.expect(200, "GET", "/api/me", token, nil)
	if got := me["families"].([]any)[0].(obj)["type"]; got != "family" {
		t.Fatalf("type: %v", got)
	}
}

func TestRegisterWithFamilyType(t *testing.T) {
	e := newEnv(t)
	id, code := e.startLogin("p@example.de")
	e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
	e.expect(400, "POST", "/api/auth/register", "", obj{
		"request_id": id, "name": "P", "family_name": "F", "family_type": "verein",
	})
	out := e.expect(201, "POST", "/api/auth/register", "", obj{
		"request_id": id, "name": "P", "family_name": "F", "family_type": "friends",
	})
	me := e.expect(200, "GET", "/api/me", out["token"].(string), nil)
	if got := me["families"].([]any)[0].(obj)["type"]; got != "friends" {
		t.Fatalf("type: %v", got)
	}
}

func TestFamilyTypeDecidesWording(t *testing.T) {
	e := newEnv(t)
	token := e.register("p@example.de", "P", "F")
	e.expect(400, "POST", "/api/families", token, obj{"name": "G", "type": "verein"})
	_, missing := e.call("POST", "/api/families", token, obj{"name": "", "type": "friends"})
	if missing["error"] != "Name des Freundeskreises fehlt" {
		t.Errorf("missing name: %v", missing)
	}

	cases := []struct{ familyType, into, to string }{
		{"family", "in die Familie", "zur Familie"},
		{"friends", "in den Freundeskreis", "zum Freundeskreis"},
		{"relatives", "in die Verwandtschaft", "zur Verwandtschaft"},
		{"workgroup", "in die Arbeitsgruppe", "zur Arbeitsgruppe"},
	}
	for _, tc := range cases {
		fid := e.expect(201, "POST", "/api/families", token, obj{"name": "G", "type": tc.familyType})["id"].(string)

		e.expect(201, "POST", "/api/families/"+fid+"/invitations", token, obj{"email": "k@example.de", "role": "restrict_user"})
		if !strings.Contains(e.mailer.last, tc.into+` "G"`) {
			t.Errorf("%s: mail: %s", tc.familyType, e.mailer.last)
		}
		_, dup := e.call("POST", "/api/families/"+fid+"/invitations", token, obj{"email": "p@example.de", "role": "restrict_user"})
		if dup["error"] != "Diese Person gehört bereits "+tc.to+"." {
			t.Errorf("%s: member: %v", tc.familyType, dup)
		}
	}
}

func TestUpdateFamilyType(t *testing.T) {
	e := newEnv(t)
	token := e.register("p@example.de", "P", "F")
	fid := e.firstFamily(token)
	typeOf := func() any {
		return e.expect(200, "GET", "/api/me", token, nil)["families"].([]any)[0].(obj)["type"]
	}

	e.expect(204, "PUT", "/api/families/"+fid, token, obj{"name": "F", "type": "workgroup"})
	if got := typeOf(); got != "workgroup" {
		t.Fatalf("type not changed: %v", got)
	}
	// Without a type the name changes and the type stays.
	e.expect(204, "PUT", "/api/families/"+fid, token, obj{"name": "Neu"})
	if got := typeOf(); got != "workgroup" {
		t.Fatalf("type lost on rename: %v", got)
	}
	e.expect(400, "PUT", "/api/families/"+fid, token, obj{"name": "F", "type": "verein"})

	e.expect(201, "POST", "/api/families/"+fid+"/invitations", token, obj{"email": "k@example.de", "role": "restrict_user"})
	id, code := e.startLogin("k@example.de")
	e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
	child := e.expect(201, "POST", "/api/auth/register", "", obj{"request_id": id, "name": "K"})["token"].(string)
	e.expect(403, "PUT", "/api/families/"+fid, child, obj{"name": "F", "type": "family"})
}

func TestCreatorIsAdminManagerInEveryType(t *testing.T) {
	e := newEnv(t)
	token := e.register("p@example.de", "P", "F")
	for _, familyType := range []string{"friends", "relatives", "workgroup"} {
		e.expect(201, "POST", "/api/families", token, obj{"name": familyType, "type": familyType})
	}
	for _, f := range e.expect(200, "GET", "/api/me", token, nil)["families"].([]any) {
		family := f.(obj)
		if family["role"] != "manager" || family["is_admin"] != true {
			t.Errorf("creator: %v", family)
		}
		if _, stored := family["title"]; stored {
			t.Errorf("title: %v", family)
		}
	}
}

func TestAdminFlagDecidesAdministration(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	join := func(email string, invitation obj) (string, string) {
		invitation["email"] = email
		e.expect(201, "POST", "/api/families/"+fid+"/invitations", admin, invitation)
		id, code := e.startLogin(email)
		e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
		token := e.expect(201, "POST", "/api/auth/register", "", obj{"request_id": id, "name": email})["token"].(string)
		return token, e.expect(200, "GET", "/api/me", token, nil)["id"].(string)
	}

	// A manager without the flag has no admin rights, a restricted admin has them.
	manager, managerID := join("m@example.de", obj{"role": "manager", "title": "ignoriert"})
	e.expect(403, "PUT", "/api/families/"+fid, manager, obj{"name": "X"})
	e.expect(403, "POST", "/api/families/"+fid+"/invitations", manager, obj{"email": "x@example.de", "role": "user"})
	e.expect(403, "PUT", "/api/families/"+fid+"/members/"+managerID, manager, obj{"role": "manager", "is_admin": true})
	restricted, _ := join("r@example.de", obj{"role": "restrict_user", "is_admin": true})
	e.expect(204, "PUT", "/api/families/"+fid, restricted, obj{"name": "F"})
	members := e.expect(200, "GET", "/api/families/"+fid+"/members", admin, nil)["members"].([]any)
	if len(members) != 3 || members[0].(obj)["is_admin"] != true || members[2].(obj)["id"] != managerID {
		t.Errorf("members: %v", members)
	}

	// Guest is reserved for the kiosk mode and old roles are gone.
	for _, role := range []string{"guest", "parent", "child"} {
		e.expect(400, "POST", "/api/families/"+fid+"/invitations", admin, obj{"email": "g@example.de", "role": role})
		e.expect(400, "PUT", "/api/families/"+fid+"/members/"+managerID, admin, obj{"role": role})
	}

	e.expect(204, "PUT", "/api/families/"+fid+"/members/"+managerID, admin, obj{"role": "user", "is_admin": true})
	e.expect(204, "PUT", "/api/families/"+fid, manager, obj{"name": "F"})
	e.expect(404, "PUT", "/api/families/"+fid+"/members/unbekannt", admin, obj{"role": "user"})

	// Revoking the flag of another admin takes the rights away.
	e.expect(204, "PUT", "/api/families/"+fid+"/members/"+managerID, admin, obj{"role": "user"})
	e.expect(403, "PUT", "/api/families/"+fid, manager, obj{"name": "F"})
}

// addMember invites and registers a second user and returns their token and id.
func (e *testEnv) addMember(fid, admin, email string) (string, string) {
	e.t.Helper()
	e.expect(201, "POST", "/api/families/"+fid+"/invitations", admin, obj{"email": email, "role": "user"})
	id, code := e.startLogin(email)
	e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": code})
	token := e.expect(201, "POST", "/api/auth/register", "", obj{"request_id": id, "name": "B"})["token"].(string)
	return token, e.expect(200, "GET", "/api/me", token, nil)["id"].(string)
}

func TestBaseColorsAreUniqueAndOrderedByHue(t *testing.T) {
	seen := map[string]bool{}
	labels := map[string]bool{}
	for _, color := range baseColors {
		if seen[color.Color] || labels[color.Label] || !hexColor.MatchString(color.Color) {
			t.Errorf("%v is a duplicate or invalid", color)
		}
		seen[color.Color], labels[color.Label] = true, true
	}
	if len(baseColors) != 38 {
		t.Fatalf("%d colors", len(baseColors))
	}
	position := func(label string) int {
		return slices.IndexFunc(baseColors, func(c paletteColor) bool { return c.Label == label })
	}
	for _, pair := range [][2]string{{"Rot", "Orange"}, {"Orange", "Gelb"}, {"Gelb", "Grün"}, {"Grün", "Blau"}, {"Blau", "Violett"}, {"Eisblau", "Blau"}} {
		if position(pair[0]) > position(pair[1]) {
			t.Errorf("%s comes after %s", pair[0], pair[1])
		}
	}
	// Nearly gray colors have no real hue and close the list.
	if last := baseColors[len(baseColors)-1].Label; last != "Grau" {
		t.Errorf("last color: %s", last)
	}
}

func TestCustomColors(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	path := "/api/families/" + fid + "/colors"
	member, memberID := e.addMember(fid, admin, "b@example.de")

	got := e.expect(200, "GET", path, member, nil)
	if len(got["base"].([]any)) != len(baseColors) || len(got["custom"].([]any)) != 0 {
		t.Fatalf("start: %v", got)
	}

	id := e.expect(201, "POST", path, admin, obj{"color": "#a1b2c3", "label": "  Nebel  "})["id"].(string)
	blue := e.expect(201, "POST", path, admin, obj{"color": "#0000FF", "label": "Tinte"})["id"].(string)
	red := e.expect(201, "POST", path, admin, obj{"color": "#FF0000", "label": "Signal"})["id"].(string)
	custom := func() []any { return e.expect(200, "GET", path, member, nil)["custom"].([]any) }
	if first := custom()[0].(obj); first["id"] != red {
		t.Errorf("not ordered by color: %v", custom())
	}
	find := func(id string) obj {
		for _, c := range custom() {
			if c.(obj)["id"] == id {
				return c.(obj)
			}
		}
		return nil
	}
	if c := find(id); c["color"] != "#A1B2C3" || c["label"] != "Nebel" || c["used"] != false {
		t.Fatalf("saved: %v", c)
	}

	for name, body := range map[string]obj{
		"no label":  {"color": "#123456", "label": "  "},
		"long":      {"color": "#123456", "label": strings.Repeat("x", 31)},
		"no color":  {"color": "blau", "label": "X"},
		"too short": {"color": "#12345", "label": "X"},
	} {
		if status, out := e.call("POST", path, admin, body); status != 400 {
			t.Errorf("%s: status %d: %v", name, status, out)
		}
	}
	e.expect(409, "POST", path, admin, obj{"color": "#d32f2f", "label": "Stammfarbe"})
	e.expect(409, "POST", path, admin, obj{"color": "#a1b2c3", "label": "Doppelt"})
	e.expect(409, "PUT", path+"/"+blue, admin, obj{"color": "#A1B2C3", "label": "Doppelt"})

	// Only admins manage colors, and members pick them from the table.
	e.expect(403, "POST", path, member, obj{"color": "#123456", "label": "X"})
	e.expect(403, "PUT", path+"/"+id, member, obj{"color": "#123456", "label": "X"})
	e.expect(403, "DELETE", path+"/"+id, member, nil)
	e.expect(204, "PUT", "/api/families/"+fid+"/color", member, obj{"color": "#A1B2C3"})
	if find(id)["used"] != true {
		t.Errorf("not marked as used: %v", find(id))
	}

	// A used color cannot be deleted, and changing it moves its users along.
	e.expect(409, "DELETE", path+"/"+id, admin, nil)
	category := e.expect(201, "POST", "/api/families/"+fid+"/categories", admin, obj{"name": "Nebel", "color": "#A1B2C3"})["id"]
	if _, err := e.server.db.Exec(`UPDATE families SET default_color = '#A1B2C3' WHERE id = ?`, fid); err != nil {
		t.Fatal(err)
	}
	e.expect(204, "PUT", path+"/"+id, admin, obj{"color": "#112233", "label": "Dunkel"})
	for _, m := range e.expect(200, "GET", "/api/families/"+fid+"/members", admin, nil)["members"].([]any) {
		if m.(obj)["id"] == memberID && m.(obj)["color"] != "#112233" {
			t.Errorf("member: %v", m)
		}
	}
	for _, c := range e.expect(200, "GET", "/api/families/"+fid+"/categories", admin, nil)["categories"].([]any) {
		if c.(obj)["id"] == category && c.(obj)["color"] != "#112233" {
			t.Errorf("category: %v", c)
		}
	}
	var familyColor string
	if err := e.server.db.QueryRow(`SELECT default_color FROM families WHERE id = ?`, fid).Scan(&familyColor); err != nil || familyColor != "#112233" {
		t.Errorf("default color: %v %v", familyColor, err)
	}

	// Each use blocks the delete until it is gone. The start color of the calendar does not count.
	e.expect(204, "PUT", "/api/families/"+fid+"/color", member, obj{"color": ""})
	e.expect(409, "DELETE", path+"/"+id, admin, nil)
	e.expect(204, "DELETE", "/api/families/"+fid+"/categories/"+category.(string), admin, nil)
	e.expect(204, "DELETE", path+"/"+id, admin, nil)
	e.expect(404, "DELETE", path+"/"+id, admin, nil)
	e.expect(400, "PUT", "/api/families/"+fid+"/color", member, obj{"color": "#112233"})

	// Families do not share custom colors.
	other := e.register("c@example.de", "C", "Andere")
	otherFid := e.firstFamily(other)
	e.expect(404, "GET", path, other, nil)
	e.expect(404, "PUT", "/api/families/"+otherFid+"/colors/"+blue, other, obj{"color": "#123456", "label": "X"})
	e.expect(404, "DELETE", "/api/families/"+otherFid+"/colors/"+blue, other, nil)
	e.expect(400, "PUT", "/api/families/"+otherFid+"/color", other, obj{"color": "#0000FF"})
	if got := e.expect(200, "GET", "/api/families/"+otherFid+"/colors", other, nil)["custom"].([]any); len(got) != 0 {
		t.Errorf("other family: %v", got)
	}
}

func TestAdminDecidesWhoChangesTheirColor(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	adminID := e.expect(200, "GET", "/api/me", admin, nil)["id"].(string)
	member, memberID := e.addMember(fid, admin, "b@example.de")

	flag := func(token string) any {
		for _, family := range e.expect(200, "GET", "/api/me", token, nil)["families"].([]any) {
			if family.(obj)["id"] == fid {
				return family.(obj)["can_change_color"]
			}
		}
		return nil
	}
	// Members may until an admin says otherwise, and the color can stay the same.
	if flag(member) != true {
		t.Errorf("start: %v", flag(member))
	}
	e.expect(204, "PUT", base+"/color", member, obj{"color": "#D32F2F"})
	e.expect(403, "PUT", base+"/members/"+memberID+"/color", member, obj{"color": "#1565C0", "can_change_color": true})

	e.expect(204, "PUT", base+"/members/"+memberID+"/color", admin, obj{"color": "#1565C0", "can_change_color": false})
	if flag(member) != false {
		t.Errorf("after locking: %v", flag(member))
	}
	e.expect(403, "PUT", base+"/color", member, obj{"color": "#D32F2F"})

	// Without the field the permission stays as it is.
	e.expect(204, "PUT", base+"/members/"+memberID+"/color", admin, obj{"color": ""})
	if flag(member) != false {
		t.Errorf("without field: %v", flag(member))
	}

	// It never holds for admins, who could set the color anyway.
	e.expect(204, "PUT", base+"/members/"+adminID+"/color", admin, obj{"color": "", "can_change_color": false})
	e.expect(204, "PUT", base+"/color", admin, obj{"color": "#D32F2F"})

	e.expect(204, "PUT", base+"/members/"+memberID+"/color", admin, obj{"color": "", "can_change_color": true})
	e.expect(204, "PUT", base+"/color", member, obj{"color": "#D32F2F"})
}

func TestInvitationBringsColorAndPermission(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	colors := base + "/colors"
	id := e.expect(201, "POST", colors, admin, obj{"color": "#A1B2C3", "label": "Nebel"})["id"].(string)

	e.expect(400, "POST", base+"/invitations", admin, obj{"email": "x@example.de", "role": "user", "color": "#010203"})
	e.expect(201, "POST", base+"/invitations", admin, obj{"email": "b@example.de", "role": "user", "color": "#A1B2C3", "can_change_color": false})
	e.expect(201, "POST", base+"/invitations", admin, obj{"email": "c@example.de", "role": "user"})

	people := e.expect(200, "GET", base+"/members", admin, nil)
	invitation := people["invitations"].([]any)[0].(obj)
	if invitation["color"] != "#A1B2C3" || invitation["can_change_color"] != false {
		t.Errorf("invitation: %v", invitation)
	}
	// The color of someone invited is in use and moves along like any other.
	e.expect(409, "DELETE", colors+"/"+id, admin, nil)
	e.expect(204, "PUT", colors+"/"+id, admin, obj{"color": "#112233", "label": "Nebel"})

	join := func(email string) string {
		request, code := e.startLogin(email)
		e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": request, "code": code})
		return e.expect(201, "POST", "/api/auth/register", "", obj{"request_id": request, "name": "N"})["token"].(string)
	}
	family := func(token string) obj {
		for _, family := range e.expect(200, "GET", "/api/me", token, nil)["families"].([]any) {
			if family.(obj)["id"] == fid {
				return family.(obj)
			}
		}
		t.Fatal("not a member")
		return nil
	}
	locked := join("b@example.de")
	if got := family(locked); got["color"] != "#112233" || got["can_change_color"] != false {
		t.Errorf("locked: %v", got)
	}
	e.expect(403, "PUT", base+"/color", locked, obj{"color": ""})
	// Without any wish the old default holds.
	if got := family(join("c@example.de")); got["color"] != "" || got["can_change_color"] != true {
		t.Errorf("default: %v", got)
	}
}

func TestProfilePerFamily(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "Anna", "Eins")
	first := "/api/families/" + e.firstFamily(token)
	second := "/api/families/" + e.expect(201, "POST", "/api/families", token, obj{"name": "Zwei"})["id"].(string)
	me := e.expect(200, "GET", "/api/me", token, nil)["id"]

	// Every family starts with the name of the account.
	if got := e.expect(200, "GET", first+"/profile", token, nil); got["name"] != "Anna" || got["birthday"] != "" || len(got["fields"].([]any)) != 0 {
		t.Fatalf("start: %v", got)
	}

	e.expect(204, "PUT", first+"/profile", token, obj{
		"name": " Mama ", "family_role": " Mutter ", "contact_email": " kein-format ", "birthday": "1980-05-01",
		"fields": []any{
			obj{"kind": "phone", "value": " 1 "}, obj{"kind": "phone", "value": "2"}, obj{"kind": "address", "value": "Weg 1\nOrt"},
			obj{"kind": "mobile", "value": "   "},
		},
	})
	got := e.expect(200, "GET", first+"/profile", token, nil)
	fields := got["fields"].([]any)
	if got["name"] != "Mama" || got["family_role"] != "Mutter" || got["contact_email"] != "kein-format" || got["birthday"] != "1980-05-01" {
		t.Errorf("saved: %v", got)
	}
	// The same kind several times, in order, and nothing for what stayed empty.
	if len(fields) != 3 || fields[0].(obj)["value"] != "1" || fields[1].(obj)["kind"] != "phone" || fields[2].(obj)["kind"] != "address" {
		t.Errorf("fields: %v", fields)
	}

	// The other family is not touched.
	if got := e.expect(200, "GET", second+"/profile", token, nil); got["name"] != "Anna" || got["birthday"] != "" {
		t.Errorf("other family: %v", got)
	}

	// Removing is saving without it.
	e.expect(204, "PUT", first+"/profile", token, obj{"name": "Mama", "fields": []any{obj{"kind": "phone", "value": "2"}}})
	if got := e.expect(200, "GET", first+"/profile", token, nil); len(got["fields"].([]any)) != 1 || got["family_role"] != "" {
		t.Errorf("after removing: %v", got)
	}

	for name, body := range map[string]obj{
		"no name":  {"name": "  "},
		"date":     {"name": "A", "birthday": "morgen"},
		"kind":     {"name": "A", "fields": []any{obj{"kind": "fax", "value": "1"}}},
		"too long": {"name": "A", "fields": []any{obj{"kind": "other", "value": strings.Repeat("x", maxProfileValue+1)}}},
		"role":     {"name": "A", "family_role": strings.Repeat("x", maxProfileText+1)},
	} {
		if status, out := e.call("PUT", first+"/profile", token, body); status != 400 {
			t.Errorf("%s: status %d: %v", name, status, out)
		}
	}

	// Others meet the name of this family, and only that.
	ben, _ := e.addMember(strings.TrimPrefix(first, "/api/families/"), token, "b@example.de")
	for _, member := range e.expect(200, "GET", first+"/members", ben, nil)["members"].([]any) {
		m := member.(obj)
		if m["id"] != me {
			continue
		}
		if m["name"] != "Mama" || m["family_role"] != nil || m["fields"] != nil {
			t.Errorf("seen by others: %v", m)
		}
	}
	e.expect(404, "GET", "/api/families/nix/profile", token, nil)

	// The app greets with the name of the family.
	for _, family := range e.expect(200, "GET", "/api/me", token, nil)["families"].([]any) {
		f := family.(obj)
		want := "Anna"
		if f["name"] == "Eins" {
			want = "Mama"
		}
		if f["member_name"] != want {
			t.Errorf("member name: %v", f)
		}
	}
}

func TestProfileNameAndBirthdayAppearInTheFamily(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "Anna", "Eins")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid
	e.expect(204, "PUT", base+"/profile", token, obj{"name": "Mama", "birthday": "1980-03-14"})

	id := e.expect(201, "POST", base+"/events", token, eventBody(nil))["id"].(string)
	got := e.expect(200, "GET", base+"/events/"+id, token, nil)
	if got["creator_name"] != "Mama" || got["updated_by_name"] != "Mama" {
		t.Errorf("event: %v", got)
	}
	if comment := e.expect(201, "POST", base+"/events/"+id+"/comments", token, obj{"body": "x"}); comment["author_name"] != "Mama" {
		t.Errorf("comment: %v", comment)
	}
	entries := e.entries(token, fid, "2026-03-14T00:00:00Z", "2026-03-15T00:00:00Z")
	if !strings.Contains(titlesOf(entries), "Geburtstag Mama") {
		t.Errorf("birthday: %s", titlesOf(entries))
	}
}

func TestCategories(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	path := "/api/families/" + fid + "/categories"
	member, _ := e.addMember(fid, admin, "b@example.de")

	list := func() []any { return e.expect(200, "GET", path, member, nil)["categories"].([]any) }
	names := func() string {
		out := []string{}
		for _, c := range list() {
			out = append(out, c.(obj)["name"].(string))
		}
		return strings.Join(out, ",")
	}
	start := list()
	if names() != "Allgemein,Wichtig" || start[0].(obj)["color"] != "#A5D6A7" || start[1].(obj)["color"] != "#D32F2F" {
		t.Fatalf("start: %v", start)
	}

	// A new category goes last and may have no color.
	id := e.expect(201, "POST", path, admin, obj{"name": "  Schule  ", "color": ""})["id"].(string)
	if last := list()[2].(obj); last["id"] != id || last["name"] != "Schule" || last["color"] != "" {
		t.Fatalf("created: %v", last)
	}
	e.expect(204, "PUT", path+"/"+id, admin, obj{"name": "Sport", "color": "#1565C0"})
	if last := list()[2].(obj); last["name"] != "Sport" || last["color"] != "#1565C0" {
		t.Fatalf("updated: %v", last)
	}
	e.expect(204, "PUT", path+"/"+id, admin, obj{"name": "Sport", "color": ""})

	e.expect(409, "POST", path, admin, obj{"name": "Wichtig"})
	e.expect(409, "PUT", path+"/"+id, admin, obj{"name": "Wichtig"})
	e.expect(400, "POST", path, admin, obj{"name": "  "})
	e.expect(400, "POST", path, admin, obj{"name": strings.Repeat("x", 51)})
	e.expect(400, "POST", path, admin, obj{"name": "X", "color": "#123456"})
	e.expect(404, "PUT", path+"/unbekannt", admin, obj{"name": "X"})

	general, important := start[0].(obj)["id"], start[1].(obj)["id"]
	e.expect(204, "PUT", path+"/order", admin, obj{"ids": []any{id, general, important}})
	if names() != "Sport,Allgemein,Wichtig" {
		t.Fatalf("order: %s", names())
	}
	for name, ids := range map[string][]any{
		"missing":   {id, general},
		"duplicate": {id, general, general},
		"unknown":   {id, general, "unbekannt"},
	} {
		if status, out := e.call("PUT", path+"/order", admin, obj{"ids": ids}); status != 400 {
			t.Errorf("%s: status %d: %v", name, status, out)
		}
	}
	// A new category still goes last after reordering.
	e.expect(201, "POST", path, admin, obj{"name": "Neu"})
	if names() != "Sport,Allgemein,Wichtig,Neu" {
		t.Fatalf("after create: %s", names())
	}

	e.expect(403, "POST", path, member, obj{"name": "X"})
	e.expect(403, "PUT", path+"/"+id, member, obj{"name": "X"})
	e.expect(403, "PUT", path+"/order", member, obj{"ids": []any{}})
	e.expect(403, "DELETE", path+"/"+id, member, nil)

	other := e.register("c@example.de", "C", "Andere")
	otherPath := "/api/families/" + e.firstFamily(other) + "/categories"
	e.expect(404, "GET", path, other, nil)
	e.expect(404, "DELETE", otherPath+"/"+id, other, nil)
	e.expect(204, "DELETE", path+"/"+id, admin, nil)
	e.expect(404, "DELETE", path+"/"+id, admin, nil)
	if names() != "Allgemein,Wichtig,Neu" {
		t.Fatalf("after delete: %s", names())
	}
}

func TestColorBelongsToTheFamily(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "Erste")
	first := e.firstFamily(token)
	second := e.expect(201, "POST", "/api/families", token, obj{"name": "Zweite"})["id"].(string)
	colors := func() map[any]any {
		out := map[any]any{}
		for _, f := range e.expect(200, "GET", "/api/me", token, nil)["families"].([]any) {
			out[f.(obj)["id"]] = f.(obj)["color"]
		}
		return out
	}
	if got := colors(); got[first] != "" || got[second] != "" {
		t.Fatalf("new memberships have colors: %v", got)
	}

	e.expect(204, "PUT", "/api/families/"+first+"/color", token, obj{"color": "#1565C0"})
	e.expect(204, "PUT", "/api/families/"+second+"/color", token, obj{"color": "#D32F2F"})
	if got := colors(); got[first] != "#1565C0" || got[second] != "#D32F2F" {
		t.Fatalf("colors: %v", got)
	}
	for _, color := range []string{"blau", "#12345", "#12345G", "#1234567", "#123456"} {
		e.expect(400, "PUT", "/api/families/"+first+"/color", token, obj{"color": color})
	}
	if got := colors(); got[first] != "#1565C0" {
		t.Fatalf("invalid color changed it: %v", got)
	}
	// A rename of the user does not touch the colors.
	e.expect(204, "PUT", "/api/families/"+first+"/profile", token, obj{"name": "B"})
	if got := colors(); got[first] != "#1565C0" {
		t.Fatalf("color lost on rename: %v", got)
	}
	// An empty color means none.
	e.expect(204, "PUT", "/api/families/"+first+"/color", token, obj{"color": ""})
	if got := colors(); got[first] != "" || got[second] != "#D32F2F" {
		t.Fatalf("color not cleared: %v", got)
	}

	other := e.register("b@example.de", "B", "Andere")
	e.expect(404, "PUT", "/api/families/"+first+"/color", other, obj{"color": "#546E7A"})
}

func TestAdminChangesMemberColor(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	me := e.expect(200, "GET", "/api/me", admin, nil)
	fid, adminID := me["last_family_id"].(string), me["id"].(string)
	member, memberID := e.addMember(fid, admin, "b@example.de")
	membersPath := "/api/families/" + fid + "/members/"
	colorOf := func(uid string) any {
		for _, m := range e.expect(200, "GET", "/api/families/"+fid+"/members", member, nil)["members"].([]any) {
			if m.(obj)["id"] == uid {
				return m.(obj)["color"]
			}
		}
		return nil
	}

	e.expect(204, "PUT", membersPath+memberID+"/color", admin, obj{"color": "#00897B"})
	if got := colorOf(memberID); got != "#00897B" {
		t.Fatalf("color not saved: %v", got)
	}
	// Role changes keep the color, and invalid colors are rejected.
	e.expect(204, "PUT", membersPath+memberID, admin, obj{"role": "manager"})
	if got := colorOf(memberID); got != "#00897B" {
		t.Fatalf("color lost: %v", got)
	}
	e.expect(400, "PUT", membersPath+memberID+"/color", admin, obj{"color": "blau"})
	e.expect(404, "PUT", membersPath+"unbekannt/color", admin, obj{"color": "#00897B"})

	// Admins can also set their own color here, members only through their own route.
	e.expect(204, "PUT", membersPath+adminID+"/color", admin, obj{"color": "#7B1FA2"})
	if got := colorOf(adminID); got != "#7B1FA2" {
		t.Fatalf("own color: %v", got)
	}
	e.expect(403, "PUT", membersPath+adminID+"/color", member, obj{"color": "#D32F2F"})
	e.expect(204, "PUT", "/api/families/"+fid+"/color", member, obj{"color": "#FFB300"})
	if got, adminColor := colorOf(memberID), colorOf(adminID); got != "#FFB300" || adminColor != "#7B1FA2" {
		t.Fatalf("own route changed the wrong color: %v, %v", got, adminColor)
	}

	e.expect(204, "PUT", membersPath+memberID+"/color", admin, obj{"color": ""})
	if got := colorOf(memberID); got != "" {
		t.Fatalf("color not cleared: %v", got)
	}
}

func uploadBody(t *testing.T, name string, content []byte) (*bytes.Buffer, string) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	part, err := mw.CreateFormFile("file", name)
	if err != nil {
		t.Fatal(err)
	}
	part.Write(content)
	mw.Close()
	return &buf, mw.FormDataContentType()
}

func (e *testEnv) upload(token, fid, kind, name string, content []byte) (int, obj) {
	e.t.Helper()
	body, contentType := uploadBody(e.t, name, content)
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/families/"+fid+"/files?kind="+kind, body)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", contentType)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	out := obj{}
	json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

var pngHeader = []byte("\x89PNG\r\n\x1a\n0000")

// Every family route must refuse other tenants, including direct access by id.
func TestTenantIsolation(t *testing.T) {
	e := newEnv(t)
	alice := e.register("a@example.de", "A", "Alice")
	bob := e.register("b@example.de", "B", "Bob")
	aFam, bFam := e.firstFamily(alice), e.firstFamily(bob)
	base := "/api/families/" + aFam

	listID := e.expect(201, "POST", base+"/lists", alice, obj{"name": "L", "kind": "tasks"})["id"].(string)
	itemID := e.expect(201, "POST", base+"/lists/"+listID+"/items", alice, obj{"title": "I"})["id"].(string)
	eventBody := obj{"title": "E", "start_local": "2026-01-01T10:00", "end_local": "2026-01-01T11:00"}
	eventID := e.expect(201, "POST", base+"/events", alice, eventBody)["id"].(string)
	dayBody := obj{"title": "D", "kind": "memorial", "date": "2026-01-01", "yearly": true}
	dayID := e.expect(201, "POST", base+"/special-days", alice, dayBody)["id"].(string)
	status, out := e.upload(alice, aFam, "photo", "a.png", pngHeader)
	if status != 201 {
		t.Fatalf("upload: %d %v", status, out)
	}
	fileID := out["id"].(string)

	// Bob addressing Alice's family directly.
	for _, r := range [][2]string{
		{"GET", base + "/lists"}, {"GET", base + "/members"}, {"GET", base + "/messages"},
		{"GET", base + "/lists/" + listID + "/items"}, {"GET", base + "/files?kind=photo"},
		{"GET", base + "/files/" + fileID + "/content"}, {"POST", base + "/files/" + fileID + "/link"},
		{"DELETE", base + "/lists/" + listID}, {"POST", base + "/select"},
	} {
		e.expect(404, r[0], r[1], bob, nil)
	}
	e.expect(404, "PUT", base, bob, obj{"name": "X"})

	// Bob using his own family id with Alice's object ids.
	own := "/api/families/" + bFam
	if got := e.expect(200, "GET", own+"/lists/"+listID+"/items", bob, nil); got["raw"] != "[]\n" {
		t.Errorf("foreign items visible: %v", got)
	}
	e.expect(404, "POST", own+"/lists/"+listID+"/items", bob, obj{"title": "X"})
	e.expect(404, "PUT", own+"/items/"+itemID, bob, obj{"title": "X"})
	e.expect(404, "DELETE", own+"/items/"+itemID, bob, nil)
	e.expect(404, "DELETE", own+"/lists/"+listID, bob, nil)
	e.expect(404, "PUT", own+"/events/"+eventID, bob, eventBody)
	e.expect(404, "DELETE", own+"/events/"+eventID, bob, nil)
	e.expect(404, "PUT", own+"/special-days/"+dayID, bob, dayBody)
	e.expect(404, "DELETE", own+"/special-days/"+dayID, bob, nil)
	e.expect(404, "GET", own+"/files/"+fileID+"/content", bob, nil)
	e.expect(404, "POST", own+"/files/"+fileID+"/link", bob, nil)
	e.expect(404, "DELETE", own+"/files/"+fileID, bob, nil)

	// Assigning a task to someone outside the family.
	bobID := e.expect(200, "GET", "/api/me", bob, nil)["id"].(string)
	e.expect(400, "PUT", base+"/items/"+itemID, alice, obj{"title": "I", "assignee_id": bobID})

	// Nothing of Bob's attempts took effect.
	items := e.expect(200, "GET", base+"/lists/"+listID+"/items", alice, nil)
	if !strings.Contains(fmt.Sprint(items["raw"]), `"title":"I"`) {
		t.Errorf("item changed: %v", items)
	}
}

func TestUnauthenticatedIsRejected(t *testing.T) {
	e := newEnv(t)
	e.expect(401, "GET", "/api/me", "", nil)
	e.expect(401, "GET", "/api/me", "falsch", nil)
	token := e.register("a@example.de", "A", "F")
	e.expect(204, "POST", "/api/auth/logout", token, nil)
	e.expect(401, "GET", "/api/me", token, nil)
}

func TestPhotoUploadChecksContent(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	if status, out := e.upload(token, fid, "photo", "evil.png", []byte("<html><script>alert(1)</script>")); status != 400 {
		t.Fatalf("html accepted as photo: %d %v", status, out)
	}
	if status, _ := e.upload(token, fid, "photo", `..\..\evil.png`, pngHeader); status != 201 {
		t.Fatalf("status %d", status)
	}
}

func TestDownloadLink(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	_, out := e.upload(token, fid, "document", "brief.txt", []byte("Hallo Welt"))
	id := out["id"].(string)
	link := e.expect(200, "POST", "/api/families/"+fid+"/files/"+id+"/link", token, nil)["url"].(string)
	res, err := http.Get(e.srv.URL + strings.TrimPrefix(link, "http://test"))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if string(body) != "Hallo Welt" {
		t.Errorf("body %q", body)
	}
	if !strings.HasPrefix(res.Header.Get("Content-Disposition"), "attachment") {
		t.Errorf("disposition %q", res.Header.Get("Content-Disposition"))
	}
	e.expect(204, "DELETE", "/api/families/"+fid+"/files/"+id, token, nil)
	res, err = http.Get(e.srv.URL + strings.TrimPrefix(link, "http://test"))
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusGone {
		t.Errorf("deleted file still downloadable: %d", res.StatusCode)
	}
}

func TestMealUpsertAndClear(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(token) + "/meals"
	e.expect(204, "PUT", base+"/2026-03-01/dinner", token, obj{"title": "Suppe"})
	e.expect(204, "PUT", base+"/2026-03-01/dinner", token, obj{"title": "Pizza"})
	got := e.expect(200, "GET", base+"?from=2026-03-01&to=2026-03-07", token, nil)
	if !strings.Contains(fmt.Sprint(got["raw"]), "Pizza") || strings.Contains(fmt.Sprint(got["raw"]), "Suppe") {
		t.Errorf("got %v", got)
	}
	e.expect(204, "PUT", base+"/2026-03-01/dinner", token, obj{"title": ""})
	got = e.expect(200, "GET", base+"?from=2026-03-01&to=2026-03-07", token, nil)
	if strings.Contains(fmt.Sprint(got["raw"]), "Pizza") {
		t.Errorf("not cleared: %v", got)
	}
}
