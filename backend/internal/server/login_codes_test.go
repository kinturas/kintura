package server

import (
	"regexp"
	"strings"
	"testing"
)

// loginCodeOf makes a managed member with a login code, and returns both ids and the code.
func loginCodeOf(e *testEnv, base, admin string) (string, string) {
	e.t.Helper()
	id := e.expect(201, "POST", base+"/members", admin, obj{"name": "Kind", "role": "restrict_user"})["id"].(string)
	return id, e.expect(201, "POST", base+"/members/"+id+"/login-code", admin, nil)["code"].(string)
}

func TestLoginCodeWorksExactlyOnce(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(admin)
	id, code := loginCodeOf(e, base, admin)

	if !regexp.MustCompile(`^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$`).MatchString(code) {
		t.Errorf("code: %s", code)
	}
	e.expect(400, "POST", "/api/auth/code", "", obj{"code": ""})
	e.expect(400, "POST", "/api/auth/code", "", obj{"code": "AAAA-AAAA-AAAA"})

	// However it was typed.
	typed := strings.ToLower(strings.ReplaceAll(code, "-", " "))
	login := e.expect(200, "POST", "/api/auth/code", "", obj{"code": " " + typed + " "})
	me := e.expect(200, "GET", "/api/me", login["token"].(string), nil)
	if me["id"] != id || me["managed"] != true || me["email"] != "" || me["name"] != "Kind" || len(me["families"].([]any)) != 1 {
		t.Errorf("me: %v", me)
	}

	// Once only.
	e.expect(400, "POST", "/api/auth/code", "", obj{"code": code})
}

func TestOnlyLatestLoginCodeWorksAndNotForever(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(admin)
	id, first := loginCodeOf(e, base, admin)
	second := e.expect(201, "POST", base+"/members/"+id+"/login-code", admin, nil)["code"].(string)
	e.expect(400, "POST", "/api/auth/code", "", obj{"code": first})

	if _, err := e.server.db.Exec(`UPDATE login_codes SET expires_at = '2000-01-01T00:00:00Z'`); err != nil {
		t.Fatal(err)
	}
	e.expect(400, "POST", "/api/auth/code", "", obj{"code": second})
}

func TestLoginCodeIsForManagedMembersAndAdmins(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	member, memberID := e.addMember(fid, admin, "b@example.de")
	id, _ := loginCodeOf(e, base, admin)

	e.expect(403, "POST", base+"/members/"+id+"/login-code", member, nil)
	// A code for an account would be a way around its mailbox.
	e.expect(403, "POST", base+"/members/"+memberID+"/login-code", admin, nil)
	stranger := e.register("s@example.de", "S", "Fremd")
	strangerBase := "/api/families/" + e.firstFamily(stranger)
	e.expect(404, "POST", strangerBase+"/members/"+id+"/login-code", stranger, nil)
}

func TestLoginCodeEndsWithItsMember(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(admin)

	t.Run("deleted", func(t *testing.T) {
		id, code := loginCodeOf(e, base, admin)
		e.expect(204, "DELETE", base+"/members/"+id, admin, nil)
		e.expect(400, "POST", "/api/auth/code", "", obj{"code": code})
	})

	t.Run("given an address", func(t *testing.T) {
		id, code := loginCodeOf(e, base, admin)
		e.expect(204, "POST", base+"/members/"+id+"/email", admin, obj{"email": "kind@example.de"})
		mailed := codePattern.FindStringSubmatch(e.mailer.last)[1]
		e.expect(204, "POST", base+"/members/"+id+"/email/confirm", admin, obj{"code": mailed})
		e.expect(400, "POST", "/api/auth/code", "", obj{"code": code})
	})
}

func TestLoggedInManagedMemberStaysManaged(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	id, code := loginCodeOf(e, base, admin)
	token := e.expect(200, "POST", "/api/auth/code", "", obj{"code": code})["token"].(string)

	// Taking part works, within the role.
	e.expect(200, "GET", base+"/members", token, nil)
	e.expect(204, "PUT", base+"/profile", token, obj{"name": "Lina", "family_role": "Tochter"})
	if got := memberOf(e, base, admin, id); got["name"] != "Lina" || got["email"] != "" {
		t.Errorf("member: %v", got)
	}
	e.expect(403, "POST", base+"/invitations", token, obj{"email": "x@example.de", "role": "user"})

	// What needs an address of their own does not.
	e.expect(403, "POST", "/api/families", token, obj{"name": "Eigener"})
	e.expect(403, "POST", "/api/me/email", token, obj{"email": "x@example.de"})
	e.expect(403, "PUT", "/api/me/notifications", token, obj{"enabled": true})
	e.expect(403, "POST", base+"/leave", token, obj{"delete_data": false})
	e.expect(403, "POST", base+"/leave", token, obj{"delete_data": true})
	e.expect(403, "DELETE", base+"/members/"+id, token, nil)
	if got := memberOf(e, base, admin, id); got == nil {
		t.Fatalf("still a member")
	}

	// Still in the hands of the admin, which also ends the session.
	e.expect(204, "PUT", base+"/members/"+id+"/profile", admin, obj{"name": "Lina"})
	e.expect(204, "DELETE", base+"/members/"+id, admin, nil)
	e.expect(401, "GET", "/api/me", token, nil)
}

func TestFeedbackDoesNotShowInternalAddress(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(admin)
	_, code := loginCodeOf(e, base, admin)
	token := e.expect(200, "POST", "/api/auth/code", "", obj{"code": code})["token"].(string)
	e.expect(204, "POST", "/api/feedback", token, obj{"text": "Hallo"})
	if strings.Contains(e.mailer.last, internalEmailDomain) || !strings.Contains(e.mailer.last, "ohne E-Mail-Adresse") {
		t.Errorf("mail: %s", e.mailer.last)
	}
}

func TestMergingLoggedInManagedMemberKeepsTheirCalendarSetup(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	elsewhere := e.register("lina@example.de", "Lina", "Eigener")
	accountID := e.expect(200, "GET", "/api/me", elsewhere, nil)["id"].(string)
	id, code := loginCodeOf(e, base, admin)
	token := e.expect(200, "POST", "/api/auth/code", "", obj{"code": code})["token"].(string)
	if _, err := e.server.db.Exec(`INSERT INTO calendar_prefs (user_id, family_id, view) VALUES (?, ?, 'month')`, id, fid); err != nil {
		t.Fatal(err)
	}

	path := base + "/members/" + id + "/email"
	e.expect(204, "POST", path, admin, obj{"email": "lina@example.de"})
	mailed := codePattern.FindStringSubmatch(e.mailer.last)[1]
	e.expect(204, "POST", path+"/confirm", admin, obj{"code": mailed})

	var owner string
	if err := e.server.db.QueryRow(`SELECT user_id FROM calendar_prefs WHERE family_id = ? AND view = 'month'`, fid).Scan(&owner); err != nil || owner != accountID {
		t.Errorf("prefs: %q %v", owner, err)
	}
	// Their session stood for the row that is gone; from now on the account logs in.
	e.expect(401, "GET", "/api/me", token, nil)
}
