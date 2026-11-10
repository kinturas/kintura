package server

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"
)

func memberOf(e *testEnv, base, token, id string) obj {
	e.t.Helper()
	for _, member := range e.expect(200, "GET", base+"/members", token, nil)["members"].([]any) {
		if member.(obj)["id"] == id {
			return member.(obj)
		}
	}
	return nil
}

func TestManagedMemberHasNoMailAndNoLogin(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	other, _ := e.addMember(fid, admin, "b@example.de")

	e.expect(403, "POST", base+"/members", other, obj{"name": "Kind", "role": "restrict_user"})
	e.expect(400, "POST", base+"/members", admin, obj{"name": "  ", "role": "restrict_user"})
	e.expect(400, "POST", base+"/members", admin, obj{"name": "Kind"})
	e.expect(400, "POST", base+"/members", admin, obj{"name": "Kind", "role": "restrict_user", "color": "#010203"})

	id := e.expect(201, "POST", base+"/members", admin, obj{"name": " Kind ", "role": "restrict_user", "color": "#1565C0", "can_change_color": false})["id"].(string)
	got := memberOf(e, base, admin, id)
	if got["name"] != "Kind" || got["email"] != "" || got["managed"] != true || got["is_admin"] != false ||
		got["color"] != "#1565C0" || got["can_change_color"] != false {
		t.Errorf("member: %v", got)
	}
	// Members with their own address say so.
	if got := memberOf(e, base, admin, e.expect(200, "GET", "/api/me", admin, nil)["id"].(string)); got["managed"] != false || got["email"] != "a@example.de" {
		t.Errorf("admin: %v", got)
	}

	// No way in, whatever the address looks like.
	var internal string
	if err := e.server.db.QueryRow(`SELECT email FROM users WHERE id = ?`, id).Scan(&internal); err != nil {
		t.Fatal(err)
	}
	e.expect(400, "POST", "/api/auth/request", "", obj{"email": internal})
	e.expect(400, "POST", base+"/invitations", admin, obj{"email": internal, "role": "user"})

	// No admin, because nobody could act as one.
	e.expect(400, "PUT", base+"/members/"+id, admin, obj{"role": "manager", "is_admin": true})
	e.expect(204, "PUT", base+"/members/"+id, admin, obj{"role": "user", "is_admin": false})

	// A participant like any other, but no mail goes out.
	e.expect(201, "POST", base+"/events", admin, eventBody(obj{"reminders": []any{30}}))
	at, err := time.Parse(timeFormat, "2026-01-05T08:30:00Z")
	if err != nil {
		t.Fatal(err)
	}
	e.mailer.to = nil
	e.server.sendReminders(context.Background(), at)
	sent := append([]string{}, e.mailer.to...)
	slices.Sort(sent)
	if !slices.Equal(sent, []string{"a@example.de", "b@example.de"}) {
		t.Errorf("reminders: %v", sent)
	}
}

func TestAdminKeepsProfileOfManagedMember(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	other, otherID := e.addMember(fid, admin, "b@example.de")
	id := e.expect(201, "POST", base+"/members", admin, obj{"name": "Kind", "role": "restrict_user"})["id"].(string)
	path := base + "/members/" + id + "/profile"

	e.expect(204, "PUT", path, admin, obj{"name": "Lina", "family_role": "Tochter", "birthday": "2020-02-03",
		"fields": []any{obj{"kind": "other", "value": "Allergie"}}})
	if got := e.expect(200, "GET", path, admin, nil); got["name"] != "Lina" || got["family_role"] != "Tochter" || len(got["fields"].([]any)) != 1 {
		t.Errorf("profile: %v", got)
	}
	if got := memberOf(e, base, admin, id); got["name"] != "Lina" {
		t.Errorf("name in list: %v", got)
	}
	// Her birthday is in the calendar like anyone else's.
	entries := e.entries(admin, fid, "2026-02-03T00:00:00Z", "2026-02-04T00:00:00Z")
	if !strings.Contains(titlesOf(entries), "Geburtstag Lina") {
		t.Errorf("birthday: %s", titlesOf(entries))
	}

	e.expect(403, "GET", path, other, nil)
	e.expect(403, "PUT", path, other, obj{"name": "X"})
	// Only the managed: people with an account keep their profile to themselves.
	e.expect(403, "GET", base+"/members/"+otherID+"/profile", admin, nil)
	e.expect(403, "PUT", base+"/members/"+otherID+"/profile", admin, obj{"name": "X"})
	e.expect(404, "GET", base+"/members/nix/profile", admin, nil)
	foreign := e.register("c@example.de", "C", "G")
	foreignFamily := e.firstFamily(foreign)
	e.expect(404, "GET", "/api/families/"+foreignFamily+"/members/"+id+"/profile", foreign, nil)
}

func TestManagedMemberGetsNewAccountWithCode(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	other, _ := e.addMember(fid, admin, "b@example.de")
	id := e.expect(201, "POST", base+"/members", admin, obj{"name": "Lina", "role": "restrict_user"})["id"].(string)
	path := base + "/members/" + id + "/email"

	e.expect(403, "POST", path, other, obj{"email": "lina@example.de"})
	e.expect(400, "POST", path, admin, obj{"email": "kaputt"})
	// Already in this family: no mail at all.
	e.mailer.to = nil
	e.expect(409, "POST", path, admin, obj{"email": "b@example.de"})
	if len(e.mailer.to) != 0 {
		t.Errorf("mail: %v", e.mailer.to)
	}
	e.expect(410, "POST", path+"/confirm", admin, obj{"code": "1"})

	e.expect(204, "POST", path, admin, obj{"email": "Lina@example.de"})
	if !slices.Equal(e.mailer.to, []string{"lina@example.de"}) {
		t.Fatalf("code went to: %v", e.mailer.to)
	}
	code := codePattern.FindStringSubmatch(e.mailer.last)[1]
	wrong := "000000"
	if code == wrong {
		wrong = "000001"
	}
	e.expect(400, "POST", path+"/confirm", admin, obj{"code": wrong})
	if got := memberOf(e, base, admin, id); got["managed"] != true {
		t.Errorf("too early: %v", got)
	}

	e.expect(204, "POST", path+"/confirm", admin, obj{"code": code})
	got := memberOf(e, base, admin, id)
	if got["managed"] != false || got["email"] != "lina@example.de" || got["name"] != "Lina" {
		t.Errorf("after: %v", got)
	}
	// From now on it is a person: the admin is out, and the login works.
	e.expect(403, "GET", base+"/members/"+id+"/profile", admin, nil)
	e.expect(403, "POST", path, admin, obj{"email": "x@example.de"})
	login, loginCode := e.startLogin("lina@example.de")
	out := e.expect(200, "POST", "/api/auth/verify", "", obj{"request_id": login, "code": loginCode})
	if out["status"] != "authenticated" {
		t.Fatalf("login: %v", out)
	}
	me := e.expect(200, "GET", "/api/me", out["token"].(string), nil)
	if me["id"] != id || len(me["families"].([]any)) != 1 || me["notifications"] != true {
		t.Errorf("me: %v", me)
	}
}

func TestManagedMemberMergesIntoAccountFromOtherFamily(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	elsewhere := e.register("lina@example.de", "Lina Konto", "Eigener Kreis")
	accountID := e.expect(200, "GET", "/api/me", elsewhere, nil)["id"].(string)

	id := e.expect(201, "POST", base+"/members", admin, obj{"name": "Lina im Kreis", "role": "restrict_user", "color": "#1565C0"})["id"].(string)
	e.expect(204, "PUT", base+"/members/"+id+"/profile", admin, obj{"name": "Lina im Kreis", "family_role": "Tochter"})
	event := e.expect(201, "POST", base+"/events", admin, eventBody(obj{
		"visibility": "participants", "participants_all": false, "participant_ids": []any{id},
	}))["id"].(string)
	e.expect(201, "POST", base+"/invitations", admin, obj{"email": "lina@example.de", "role": "user"})

	path := base + "/members/" + id + "/email"
	e.expect(204, "POST", path, admin, obj{"email": "lina@example.de"})
	code := codePattern.FindStringSubmatch(e.mailer.last)[1]
	if !strings.Contains(e.mailer.last, `Kreis "F"`) {
		t.Errorf("the mail has to say what the code does: %s", e.mailer.last)
	}
	e.expect(204, "POST", path+"/confirm", admin, obj{"code": code})

	// The stand-in is gone, the account is in the family with what was kept for it.
	if got := memberOf(e, base, admin, id); got != nil {
		t.Errorf("stand-in: %v", got)
	}
	got := memberOf(e, base, admin, accountID)
	if got == nil || got["name"] != "Lina im Kreis" || got["role"] != "restrict_user" || got["color"] != "#1565C0" {
		t.Errorf("account: %v", got)
	}
	var users int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM users WHERE id = ?`, id).Scan(&users); err != nil || users != 0 {
		t.Errorf("users: %d %v", users, err)
	}
	if got := e.expect(200, "GET", base+"/profile", elsewhere, nil); got["family_role"] != "Tochter" {
		t.Errorf("profile: %v", got)
	}
	ids := e.expect(200, "GET", base+"/events/"+event, elsewhere, nil)["participant_ids"].([]any)
	if !slices.Equal(ids, []any{accountID}) {
		t.Errorf("participants: %v", ids)
	}
	// The other family is untouched, and so is the name there.
	if families := e.expect(200, "GET", "/api/me", elsewhere, nil)["families"].([]any); len(families) != 2 {
		t.Errorf("families: %v", families)
	}
	// The open invitation is used up.
	people := e.expect(200, "GET", base+"/members", admin, nil)["invitations"].([]any)
	if len(people) != 0 {
		t.Errorf("invitations: %v", people)
	}
}

func TestRemovingManagedMemberDeletesThemForGood(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	other, _ := e.addMember(fid, admin, "b@example.de")
	id := e.expect(201, "POST", base+"/members", admin, obj{"name": "Lina", "role": "restrict_user"})["id"].(string)
	e.expect(204, "PUT", base+"/members/"+id+"/profile", admin, obj{"name": "Lina", "birthday": "2020-02-03"})
	// Made for her by the admin: it stays, private as it was, with the admin alone.
	private := e.expect(201, "POST", base+"/events", admin, eventBody(obj{
		"visibility": "participants", "participants_all": false, "participant_ids": []any{id},
	}))["id"].(string)
	open := e.expect(201, "POST", base+"/events", admin, eventBody(obj{
		"participants_all": false, "participant_ids": []any{id},
	}))["id"].(string)

	e.expect(403, "DELETE", base+"/members/"+id, other, nil)
	e.expect(204, "DELETE", base+"/members/"+id, admin, nil)

	if got := memberOf(e, base, admin, id); got != nil {
		t.Errorf("still listed: %v", got)
	}
	var left int
	if err := e.server.db.QueryRow(`SELECT (SELECT COUNT(*) FROM users WHERE id = ?1) + (SELECT COUNT(*) FROM former_memberships WHERE user_id = ?1)`, id).Scan(&left); err != nil || left != 0 {
		t.Errorf("kept: %d %v", left, err)
	}
	if got := e.expect(200, "GET", base+"/events/"+private, admin, nil); got["visibility"] != "participants" || got["participants_all"] != false {
		t.Errorf("private event: %v", got)
	}
	e.expect(404, "GET", base+"/events/"+private, other, nil)
	if got := e.expect(200, "GET", base+"/events/"+open, admin, nil); got["participants_all"] != true {
		t.Errorf("open event: %v", got)
	}
	entries := e.entries(admin, fid, "2026-02-03T00:00:00Z", "2026-02-04T00:00:00Z")
	if strings.Contains(titlesOf(entries), "Lina") {
		t.Errorf("birthday: %s", titlesOf(entries))
	}
	e.expect(404, "DELETE", base+"/members/"+id, admin, nil)
}

func TestLastAdminWithOnlyManagedMembersIsToldWhatToDo(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	id := e.expect(201, "POST", base+"/members", admin, obj{"name": "Lina", "role": "restrict_user"})["id"].(string)

	status, out := e.call("POST", base+"/leave", admin, obj{})
	if status != 409 || !strings.Contains(out["error"].(string), "E-Mail-Adresse") {
		t.Errorf("only managed: %d %v", status, out)
	}
	// With someone who could take over, the usual advice holds.
	e.addMember(fid, admin, "b@example.de")
	status, out = e.call("POST", base+"/leave", admin, obj{})
	if status != 409 || strings.Contains(out["error"].(string), "E-Mail-Adresse") {
		t.Errorf("with a candidate: %d %v", status, out)
	}

	// Deleting them clears the way, as the message says.
	e2 := newEnv(t)
	alone := e2.register("a@example.de", "A", "F")
	aloneBase := "/api/families/" + e2.firstFamily(alone)
	kid := e2.expect(201, "POST", aloneBase+"/members", alone, obj{"name": "Lina", "role": "restrict_user"})["id"].(string)
	e2.expect(204, "DELETE", aloneBase+"/members/"+kid, alone, nil)
	e2.expect(204, "POST", aloneBase+"/leave", alone, obj{})
	_ = id
}

func TestManagedMemberMergeFailsIfAddressJoinedMeanwhile(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	id := e.expect(201, "POST", base+"/members", admin, obj{"name": "Lina", "role": "restrict_user"})["id"].(string)
	path := base + "/members/" + id + "/email"
	e.expect(204, "POST", path, admin, obj{"email": "lina@example.de"})
	code := codePattern.FindStringSubmatch(e.mailer.last)[1]
	e.addMember(fid, admin, "lina@example.de")
	e.expect(409, "POST", path+"/confirm", admin, obj{"code": code})
	if got := memberOf(e, base, admin, id); got == nil || got["managed"] != true {
		t.Errorf("stand-in: %v", got)
	}
}
