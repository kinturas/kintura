package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAppTooOld(t *testing.T) {
	for _, c := range []struct {
		sent, min string
		want      bool
	}{
		{"0.0.12+30", "0.0.13", true},
		{"0.0.13+30", "0.0.13", false},
		{"0.1.0", "0.0.13", false},
		{"1.2.3", "1.10.0", true},
		// Unknown: let through, it may be a development build or an older app.
		{"", "9.9.9", false},
		{"dev", "9.9.9", false},
		{"1.2", "9.9.9", false},
	} {
		if got := appTooOld(c.sent, c.min); got != c.want {
			t.Errorf("appTooOld(%q, %q) = %v, want %v", c.sent, c.min, got, c.want)
		}
	}
}

func TestAppVersionHeader(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")

	if v := e.expect(200, "GET", "/api/version", "", nil); v["min_app_version"] != minAppVersion {
		t.Errorf("version: %v", v)
	}
	// The web app may call from another origin and send the header.
	req := httptest.NewRequest(http.MethodOptions, "/api/me", nil)
	rec := httptest.NewRecorder()
	e.server.Handler().ServeHTTP(rec, req)
	if got := rec.Header().Get("Access-Control-Allow-Headers"); got != "Authorization, Content-Type, X-App-Version, X-App-Platform" {
		t.Errorf("CORS: %q", got)
	}

	call := func(version string) int {
		req := httptest.NewRequest(http.MethodGet, "/api/me", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		if version != "" {
			req.Header.Set(appVersionHeader, version)
		}
		rec := httptest.NewRecorder()
		e.server.Handler().ServeHTTP(rec, req)
		return rec.Code
	}
	if code := call(""); code != 200 {
		t.Errorf("without version: %d", code)
	}
	if code := call("99.0.0+1"); code != 200 {
		t.Errorf("new app: %d", code)
	}
}

func TestAppTooOldIsTurnedAway(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	e.server.minAppVersion = "1.0.0"

	req := httptest.NewRequest(http.MethodGet, "/api/me", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set(appVersionHeader, "0.9.9+3")
	rec := httptest.NewRecorder()
	e.server.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUpgradeRequired {
		t.Fatalf("old app: %d %s", rec.Code, rec.Body)
	}

	// What to do it still learns.
	req = httptest.NewRequest(http.MethodGet, "/api/version", nil)
	req.Header.Set(appVersionHeader, "0.9.9+3")
	rec = httptest.NewRecorder()
	e.server.Handler().ServeHTTP(rec, req)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"min_app_version":"1.0.0"`) {
		t.Fatalf("version: %d %s", rec.Code, rec.Body)
	}
}

func TestAPIIsNeverCached(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")

	get := func(path, token string) string {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		e.server.Handler().ServeHTTP(rec, req)
		return rec.Header().Get("Cache-Control")
	}
	fid := e.firstFamily(token)
	for _, path := range []string{"/api/me", "/api/families/" + fid + "/members"} {
		if got := get(path, token); got != "no-store" {
			t.Errorf("%s: Cache-Control %q", path, got)
		}
	}
	// Errors too, and the version the apps compare against.
	if got := get("/api/me", ""); got != "no-store" {
		t.Errorf("401: Cache-Control %q", got)
	}
	if got := get("/api/version", ""); got != "no-store" {
		t.Errorf("version: Cache-Control %q", got)
	}
}
