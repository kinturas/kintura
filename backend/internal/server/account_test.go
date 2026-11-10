package server

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestEmailChangeNeedsCodeFromNewAddress(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	e.register("taken@example.de", "B", "G")
	email := func() any { return e.expect(200, "GET", "/api/me", token, nil)["email"] }

	e.expect(400, "POST", "/api/me/email", token, obj{"email": "kein-format"})
	e.expect(400, "POST", "/api/me/email", token, obj{"email": "a@example.de"})
	// Taken in any spelling, and not even a mail goes out.
	e.mailer.to = nil
	e.expect(409, "POST", "/api/me/email", token, obj{"email": " TAKEN@example.de "})
	if len(e.mailer.to) != 0 {
		t.Errorf("mail for a taken address: %v", e.mailer.to)
	}
	e.expect(410, "POST", "/api/me/email/confirm", token, obj{"code": "000000"})

	e.expect(204, "POST", "/api/me/email", token, obj{"email": "Neu@example.de"})
	if !slices.Equal(e.mailer.to, []string{"neu@example.de"}) {
		t.Fatalf("code went to: %v", e.mailer.to)
	}
	code := codePattern.FindStringSubmatch(e.mailer.last)[1]
	if got := email(); got != "a@example.de" {
		t.Errorf("changed too early: %v", got)
	}
	wrong := "000000"
	if code == wrong {
		wrong = "000001"
	}
	e.expect(400, "POST", "/api/me/email/confirm", token, obj{"code": wrong})

	e.mailer.to = nil
	e.expect(204, "POST", "/api/me/email/confirm", token, obj{"code": code})
	if got := email(); got != "neu@example.de" {
		t.Errorf("after confirming: %v", got)
	}
	// The old address hears about it.
	if !slices.Equal(e.mailer.to, []string{"a@example.de"}) || !strings.Contains(e.mailer.last, "neu@example.de") {
		t.Errorf("notice: %v %s", e.mailer.to, e.mailer.last)
	}
	// A code works once, and the login follows the new address.
	e.expect(410, "POST", "/api/me/email/confirm", token, obj{"code": code})
	id, loginCode := e.startLogin("neu@example.de")
	if out := e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": id, "code": loginCode}); out["status"] != "authenticated" {
		t.Errorf("login: %v", out)
	}
}

func TestEmailChangeIsLimited(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	e.expect(204, "POST", "/api/me/email", token, obj{"email": "n@example.de"})
	for i := 0; i < maxCodeAttempts; i++ {
		e.call("POST", "/api/me/email/confirm", token, obj{"code": "x"})
	}
	code := codePattern.FindStringSubmatch(e.mailer.last)[1]
	e.expect(429, "POST", "/api/me/email/confirm", token, obj{"code": code})

	for i := 1; i < maxOpenRequests; i++ {
		e.expect(204, "POST", "/api/me/email", token, obj{"email": "n@example.de"})
	}
	e.expect(429, "POST", "/api/me/email", token, obj{"email": "n@example.de"})
}

func TestEmailChangeLosesAgainstRegistrationInBetween(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	e.expect(204, "POST", "/api/me/email", token, obj{"email": "n@example.de"})
	code := codePattern.FindStringSubmatch(e.mailer.last)[1]
	e.register("n@example.de", "B", "G")
	e.expect(409, "POST", "/api/me/email/confirm", token, obj{"code": code})
	if got := e.expect(200, "GET", "/api/me", token, nil)["email"]; got != "a@example.de" {
		t.Errorf("email: %v", got)
	}
}

func TestEmailChangeNotForTokenAccount(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	if _, err := e.server.db.Exec(`UPDATE users SET email = ? WHERE email = 'a@example.de' `, "x@example.de"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.server.db.Exec(`DELETE FROM users WHERE email = ?`, adminEmail); err != nil {
		t.Fatal(err)
	}
	if _, err := e.server.db.Exec(`UPDATE users SET email = ? WHERE email = 'x@example.de'`, adminEmail); err != nil {
		t.Fatal(err)
	}
	e.expect(409, "POST", "/api/me/email", token, obj{"email": "n@example.de"})
}

func TestNotificationsDecideAboutReminders(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	guest, _ := e.addMember(fid, owner, "b@example.de")
	if got := e.expect(200, "GET", "/api/me", guest, nil)["notifications"]; got != true {
		t.Errorf("start: %v", got)
	}
	e.expect(204, "PUT", "/api/me/notifications", guest, obj{"enabled": false})
	if got := e.expect(200, "GET", "/api/me", guest, nil)["notifications"]; got != false {
		t.Errorf("after switching off: %v", got)
	}

	e.expect(201, "POST", "/api/families/"+fid+"/events", owner, eventBody(obj{"reminders": []any{30}}))
	at, err := time.Parse(timeFormat, "2026-01-05T08:30:00Z")
	if err != nil {
		t.Fatal(err)
	}
	e.mailer.to = nil
	e.server.sendReminders(context.Background(), at)
	if !slices.Equal(e.mailer.to, []string{"a@example.de"}) {
		t.Errorf("reminder went to: %v", e.mailer.to)
	}

	// Switching on again brings back later ones, and the login code never stopped.
	e.startLogin("b@example.de")
	e.expect(204, "PUT", "/api/me/notifications", guest, obj{"enabled": true})
	e.mailer.to = nil
	e.server.sendReminders(context.Background(), at)
	if !slices.Equal(e.mailer.to, []string{"b@example.de"}) {
		t.Errorf("after switching on: %v", e.mailer.to)
	}
}

func TestFeedbackGoesToSysadmins(t *testing.T) {
	e := newEnv(t)
	admin := e.register("admin@example.de", "Chefin", "F")
	second := e.register("second@example.de", "Zweite", "G")
	if _, err := e.server.db.Exec(`UPDATE users SET is_sysadmin = 1 WHERE email = 'second@example.de'`); err != nil {
		t.Fatal(err)
	}
	user := e.register("u@example.de", "Nutzer", "H")
	_, _ = admin, second

	e.expect(400, "POST", "/api/feedback", user, obj{"text": "  "})
	e.expect(400, "POST", "/api/feedback", user, obj{"text": strings.Repeat("x", maxFeedbackLength+1)})

	e.mailer.to = nil
	e.expect(204, "POST", "/api/feedback", user, obj{"text": " Tolle App "})
	sent := append([]string{}, e.mailer.to...)
	slices.Sort(sent)
	// Neither the sender nor the token account without a mailbox.
	if !slices.Equal(sent, []string{"admin@example.de", "second@example.de"}) {
		t.Errorf("sent to: %v", sent)
	}
	for _, want := range []string{"Tolle App", "Nutzer", "u@example.de"} {
		if !strings.Contains(e.mailer.last, want) {
			t.Errorf("no %q in: %s", want, e.mailer.last)
		}
	}

	e.mailer.err = errors.New("kaputt")
	e.expect(502, "POST", "/api/feedback", user, obj{"text": "Noch mal"})
	e.mailer.err = nil
	status, _ := e.call("POST", "/api/feedback", "", obj{"text": "Anonym"})
	if status != 401 {
		t.Errorf("without login: %d", status)
	}
}
