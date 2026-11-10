package server

import (
	"slices"
	"strings"
	"testing"
)

// invited creates an invitation and returns its id and the code from its mail.
func invited(e *testEnv, base, admin, email string, extra obj) (string, string) {
	e.t.Helper()
	body := obj{"email": email, "role": "user"}
	for key, value := range extra {
		body[key] = value
	}
	id := e.expect(201, "POST", base+"/invitations", admin, body)["id"].(string)
	return id, codePattern.FindStringSubmatch(e.mailer.last)[1]
}

func TestInvitationMailExplainsItsCode(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(admin)
	invited(e, base, admin, "n@example.de", nil)
	for _, want := range []string{`"F"`, "melde dich", "Wer ihn eingibt", "7 Tage"} {
		if !strings.Contains(e.mailer.last, want) {
			t.Errorf("%q missing: %s", want, e.mailer.last)
		}
	}
	// What comes back never includes the code.
	people := e.expect(200, "GET", base+"/members", admin, nil)["invitations"].([]any)
	if _, leaked := people[0].(obj)["code_hash"]; leaked {
		t.Errorf("invitation: %v", people[0])
	}
}

func TestConfirmingInvitationCreatesTheMissingAccount(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(admin)
	id, code := invited(e, base, admin, "n@example.de", obj{"color": "#1565C0", "can_change_color": false})
	path := base + "/invitations/" + id + "/confirm"

	// A wrong code says nothing about the address, and none of it counts as joining.
	e.expect(400, "POST", path, admin, obj{"code": "x", "name": "Neu"})

	// Only the right code gets as far as asking for the name, and that costs no attempts.
	for range maxCodeAttempts + 1 {
		if got := e.expect(200, "POST", path, admin, obj{"code": " " + code + " ", "name": "  "}); got["status"] != "name_required" {
			t.Fatalf("without a name: %v", got)
		}
	}
	if got := e.expect(200, "POST", path, admin, obj{"code": code, "name": " Neu "}); got["status"] != "joined" {
		t.Fatalf("with a name: %v", got)
	}
	if !strings.Contains(e.mailer.last, "aufgenommen") {
		t.Errorf("the person has to hear about it: %s", e.mailer.last)
	}

	people := e.expect(200, "GET", base+"/members", admin, nil)
	if len(people["invitations"].([]any)) != 0 {
		t.Errorf("invitations: %v", people["invitations"])
	}
	var found obj
	for _, member := range people["members"].([]any) {
		if member.(obj)["email"] == "n@example.de" {
			found = member.(obj)
		}
	}
	if found == nil || found["name"] != "Neu" || found["role"] != "user" || found["color"] != "#1565C0" || found["can_change_color"] != false {
		t.Fatalf("member: %v", people["members"])
	}

	// The account is a normal one and logs in without registering, with no family of its own.
	request, loginCode := e.startLogin("n@example.de")
	login := e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": request, "code": loginCode})
	if login["status"] != "authenticated" {
		t.Fatalf("login: %v", login)
	}
	me := e.expect(200, "GET", "/api/me", login["token"].(string), nil)
	if me["name"] != "Neu" || me["is_sysadmin"] == true || len(me["families"].([]any)) != 1 {
		t.Errorf("me: %v", me)
	}
	// Used up.
	e.expect(404, "POST", path, admin, obj{"code": code})
}

func TestConfirmingInvitationJoinsOnlyThisFamily(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(admin)
	other := e.register("o@example.de", "O", "Anderer")
	otherBase := "/api/families/" + e.firstFamily(other)
	person := e.register("p@example.de", "Person", "Eigener")

	// Nobody can answer this one by entering the code of the other family.
	otherID, otherCode := invited(e, otherBase, other, "p@example.de", nil)
	id, code := invited(e, base, admin, "p@example.de", nil)
	if code == otherCode {
		t.Skip("the two random codes happen to match")
	}
	e.expect(400, "POST", base+"/invitations/"+id+"/confirm", admin, obj{"code": otherCode})
	e.expect(404, "POST", base+"/invitations/"+otherID+"/confirm", admin, obj{"code": otherCode})

	// An account is enough, no name needed.
	if got := e.expect(200, "POST", base+"/invitations/"+id+"/confirm", admin, obj{"code": code}); got["status"] != "joined" {
		t.Fatalf("status: %v", got)
	}
	var names []string
	var memberships int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM memberships m JOIN users u ON u.id = m.user_id WHERE u.email = 'p@example.de'`).Scan(&memberships); err != nil {
		t.Fatal(err)
	}
	if memberships != 2 {
		t.Errorf("memberships: %d", memberships)
	}
	if got := e.expect(200, "GET", otherBase+"/members", other, nil)["invitations"].([]any); len(got) != 1 {
		t.Errorf("the other invitation is still open: %v", got)
	}
	// The next login of the person herself answers that one.
	for _, family := range e.expect(200, "GET", "/api/me", person, nil)["families"].([]any) {
		names = append(names, family.(obj)["name"].(string))
	}
	slices.Sort(names)
	if !slices.Equal(names, []string{"Anderer", "Eigener", "F"}) {
		t.Errorf("families: %v", names)
	}
}

func TestConfirmingInvitationBringsBackWhatWasKept(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	token, uid := e.addMember(fid, admin, "b@example.de")
	e.expect(204, "PUT", base+"/profile", token, obj{"name": "Bea im Kreis", "family_role": "Tante"})
	e.expect(204, "POST", base+"/leave", token, obj{"delete_data": false})

	id, code := invited(e, base, admin, "b@example.de", nil)
	e.expect(200, "POST", base+"/invitations/"+id+"/confirm", admin, obj{"code": code})

	got := memberOf(e, base, admin, uid)
	if got == nil || got["name"] != "Bea im Kreis" {
		t.Errorf("member: %v", got)
	}
	if former := e.expect(200, "GET", base+"/members", admin, nil)["former"].([]any); len(former) != 0 {
		t.Errorf("former: %v", former)
	}
}

func TestInvitationCodeHasItsLimits(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	member, _ := e.addMember(fid, admin, "b@example.de")
	id, code := invited(e, base, admin, "n@example.de", nil)
	path := base + "/invitations/" + id

	// Only for admins, and only of this family.
	e.expect(403, "POST", path+"/confirm", member, obj{"code": code})
	e.expect(403, "POST", path+"/resend", member, nil)
	stranger := e.register("s@example.de", "S", "Fremd")
	strangerBase := "/api/families/" + e.firstFamily(stranger)
	e.expect(404, "POST", strangerBase+"/invitations/"+id+"/confirm", stranger, obj{"code": code})
	e.expect(404, "POST", strangerBase+"/invitations/"+id+"/resend", stranger, nil)

	// Too many wrong guesses end the code, and only a new mail helps.
	for range maxCodeAttempts {
		e.expect(400, "POST", path+"/confirm", admin, obj{"code": "x"})
	}
	e.expect(429, "POST", path+"/confirm", admin, obj{"code": code})

	e.expect(204, "POST", path+"/resend", admin, nil)
	if !strings.Contains(e.mailer.last, "eingeladen") {
		t.Errorf("mail: %s", e.mailer.last)
	}
	fresh := codePattern.FindStringSubmatch(e.mailer.last)[1]
	if fresh != code {
		e.expect(400, "POST", path+"/confirm", admin, obj{"code": code})
	}

	// An expired code does not work, even if it is the right one.
	if _, err := e.server.db.Exec(`UPDATE invitations SET code_expires_at = '2000-01-01T00:00:00Z' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	e.expect(410, "POST", path+"/confirm", admin, obj{"code": fresh})
}

func TestInvitationMailsAreLimitedPerAddress(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(admin)
	id, _ := invited(e, base, admin, "n@example.de", nil)
	for range maxOpenRequests - 2 {
		e.expect(204, "POST", base+"/invitations/"+id+"/resend", admin, nil)
	}

	// Withdrawing and inviting anew does not start over, or it could go on forever.
	e.expect(204, "DELETE", base+"/invitations/"+id, admin, nil)
	id, _ = invited(e, base, admin, "n@example.de", nil)
	e.expect(429, "POST", base+"/invitations/"+id+"/resend", admin, nil)
	e.expect(204, "DELETE", base+"/invitations/"+id, admin, nil)
	e.expect(429, "POST", base+"/invitations", admin, obj{"email": "n@example.de", "role": "user"})

	// Others are not affected, and the limit is over after a day.
	invited(e, base, admin, "m@example.de", nil)
	if _, err := e.server.db.Exec(`UPDATE invitation_mails SET expires_at = '2000-01-01T00:00:00Z'`); err != nil {
		t.Fatal(err)
	}
	id, code := invited(e, base, admin, "n@example.de", nil)
	e.expect(200, "POST", base+"/invitations/"+id+"/confirm", admin, obj{"code": code, "name": "Neu"})
}

func TestInvitationFromBeforeCodesAsksToSendAgain(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(admin)
	id, _ := invited(e, base, admin, "n@example.de", nil)
	if _, err := e.server.db.Exec(`UPDATE invitations SET code_hash = '', code_expires_at = '' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	e.expect(410, "POST", base+"/invitations/"+id+"/confirm", admin, obj{"code": ""})
	e.expect(204, "POST", base+"/invitations/"+id+"/resend", admin, nil)
	code := codePattern.FindStringSubmatch(e.mailer.last)[1]
	e.expect(200, "POST", base+"/invitations/"+id+"/confirm", admin, obj{"code": code, "name": "Neu"})
}
