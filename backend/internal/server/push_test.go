package server

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakePusher struct {
	mu   sync.Mutex
	sent []PushMessage
	gone map[string]bool
}

func (f *fakePusher) Push(_ context.Context, msg PushMessage) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.gone[msg.Token] {
		return errPushGone
	}
	f.sent = append(f.sent, msg)
	return nil
}

func TestPushDevices(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, benID := e.addMember(fid, owner, "b@example.de")
	base := "/api/families/" + fid + "/shopping/lists"
	devices := func() int {
		t.Helper()
		var n int
		if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM push_devices`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	// Without Firebase the server says so, and the app keeps to itself.
	e.expect(501, "PUT", "/api/me/push-device", owner, obj{"token": "tok-a", "platform": "android"})
	push := &fakePusher{gone: map[string]bool{}}
	e.server.push = push
	e.expect(400, "PUT", "/api/me/push-device", owner, obj{"token": "", "platform": "android"})
	e.expect(400, "PUT", "/api/me/push-device", owner, obj{"token": "tok-a", "platform": "ios"})

	// What came before the device is not sent.
	list := e.expect(201, "POST", base, owner, obj{"name": "Grillfest", "assignees_all": false, "assignee_ids": []string{benID}, "visibility": "all"})["id"].(string)
	e.expect(201, "POST", base+"/"+list+"/comments", ben, obj{"body": "Vorher"})
	e.expect(204, "PUT", "/api/me/push-device", owner, obj{"token": "tok-a", "platform": "android"})
	// Again, as at every start of the app: still one.
	e.expect(204, "PUT", "/api/me/push-device", owner, obj{"token": "tok-a", "platform": "android"})
	if n := devices(); n != 1 {
		t.Fatalf("devices: %d", n)
	}
	e.server.sendPushes(context.Background(), time.Now())
	if len(push.sent) != 0 {
		t.Fatalf("old ones sent: %v", push.sent)
	}

	// Ben comments: Anna's phone hears of it, once; Ben's own entry goes nowhere.
	e.expect(201, "POST", base+"/"+list+"/comments", ben, obj{"body": "Bringe Salat mit"})
	e.server.sendPushes(context.Background(), time.Now())
	e.server.sendPushes(context.Background(), time.Now())
	if len(push.sent) != 1 {
		t.Fatalf("sent: %v", push.sent)
	}
	msg := push.sent[0]
	if msg.Token != "tok-a" || msg.Title != "Kintura" || !strings.HasSuffix(msg.Body, " hat die Einkaufsliste „Grillfest“ kommentiert: „Bringe Salat mit“.") ||
		msg.Data["family_id"] != fid || msg.Data["kintura"] != "activity" || msg.Tag == "" {
		t.Fatalf("message: %+v", msg)
	}

	// Entries older than the window are left, as after a break of the server.
	e.expect(201, "POST", base+"/"+list+"/comments", ben, obj{"body": "Noch was"})
	e.server.sendPushes(context.Background(), time.Now().Add(2*pushWindow))
	if len(push.sent) != 1 {
		t.Fatalf("too old, still sent: %v", push.sent)
	}

	// A device that is gone is forgotten.
	push.gone["tok-a"] = true
	e.expect(201, "POST", base+"/"+list+"/comments", ben, obj{"body": "Hallo?"})
	e.server.sendPushes(context.Background(), time.Now())
	if n := devices(); n != 0 {
		t.Fatalf("gone device kept: %d", n)
	}

	// Signing out takes the device along; turning off as well.
	e.expect(204, "PUT", "/api/me/push-device", ben, obj{"token": "tok-b", "platform": "android"})
	e.expect(204, "DELETE", "/api/me/push-device", ben, nil)
	if n := devices(); n != 0 {
		t.Fatalf("after turning off: %d", n)
	}
	e.expect(204, "PUT", "/api/me/push-device", ben, obj{"token": "tok-b", "platform": "android"})
	e.expect(204, "POST", "/api/auth/logout", ben, nil)
	if n := devices(); n != 0 {
		t.Fatalf("after signing out: %d", n)
	}
}

func TestPushText(t *testing.T) {
	for _, c := range []struct {
		kind, actor string
		names       []string
		count       int
		want        string
	}{
		{activityItemsAdded, "Ben", []string{"Milch"}, 1, "Ben hat Milch auf „X“ gesetzt."},
		{activityItemsDone, "Ben", []string{"A", "B", "C", "D", "E"}, 6, "Ben hat 6 Artikel auf „X“ abgehakt: A, B, C, D und 2 weitere."},
		{activityEventAdded, "", nil, 1, "Jemand hat dich zum Termin „X“ hinzugefügt."},
		{activityEventComment, "Ben", nil, 1, "Ben hat den Termin „X“ kommentiert."},
		{activityListCommentDeleted, "Anna", []string{"Ben"}, 1, "Anna hat den Kommentar von Ben zur Einkaufsliste „X“ gelöscht."},
		{activityEventCommentEdited, "Ben", []string{"Neu"}, 1, "Ben hat einen Kommentar zum Termin „X“ bearbeitet: „Neu“."},
		{"neu", "Ben", nil, 1, "Ben hat etwas geändert."},
	} {
		if got := pushText(c.kind, c.actor, "X", c.names, c.count); got != c.want {
			t.Errorf("%s: %q, want %q", c.kind, got, c.want)
		}
	}
}

func TestFCM(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	var tokens, sends int
	var sent map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			tokens++
			if err := r.ParseForm(); err != nil || r.Form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" ||
				strings.Count(r.Form.Get("assertion"), ".") != 2 {
				t.Errorf("token request: %v %v", r.Form, err)
			}
			_, _ = io.WriteString(w, `{"access_token":"at-1","expires_in":3600}`)
		case "/send":
			sends++
			if r.Header.Get("Authorization") != "Bearer at-1" {
				t.Errorf("auth: %q", r.Header.Get("Authorization"))
			}
			if err := json.NewDecoder(r.Body).Decode(&sent); err != nil {
				t.Error(err)
			}
			if strings.Contains(sent["message"].(map[string]any)["token"].(string), "gone") {
				w.WriteHeader(http.StatusNotFound)
				_, _ = io.WriteString(w, `{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`)
				return
			}
			_, _ = io.WriteString(w, `{"name":"projects/p/messages/1"}`)
		}
	}))
	defer srv.Close()
	credentials, _ := json.Marshal(map[string]string{
		"type": "service_account", "project_id": "p", "client_email": "push@p.iam.gserviceaccount.com",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
		"token_uri":   srv.URL + "/token",
	})
	fcm, err := NewFCM(credentials)
	if err != nil {
		t.Fatal(err)
	}
	fcm.sendURL = srv.URL + "/send"
	ctx := context.Background()
	if err := fcm.Push(ctx, PushMessage{Token: "d1", Title: "Kintura", Body: "Ben hat …", Tag: "a1", Data: map[string]string{"kintura": "activity"}}); err != nil {
		t.Fatal(err)
	}
	message := sent["message"].(map[string]any)
	if message["notification"].(map[string]any)["title"] != "Kintura" || message["data"].(map[string]any)["kintura"] != "activity" ||
		message["android"].(map[string]any)["notification"].(map[string]any)["channel_id"] != "activities" {
		t.Fatalf("message: %v", message)
	}
	// The token holds for the next one; a device that is gone says so.
	if err := fcm.Push(ctx, PushMessage{Token: "gone"}); err != errPushGone {
		t.Fatalf("gone: %v", err)
	}
	if tokens != 1 || sends != 2 {
		t.Fatalf("tokens %d, sends %d", tokens, sends)
	}
	if _, err := NewFCM([]byte(`{"type":"authorized_user"}`)); err == nil {
		t.Fatal("no service account accepted")
	}
}
