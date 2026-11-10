package server

import (
	"strings"
	"testing"
)

func (e *testEnv) rejoin(fid, admin, email, token string) {
	e.t.Helper()
	e.expect(201, "POST", "/api/families/"+fid+"/invitations", admin, obj{"email": email, "role": "user"})
	e.expect(200, "GET", "/api/me", token, nil) // accepts the invitation
}

func TestLeavingKeepsDataForALaterReturn(t *testing.T) {
	for name, leave := range map[string]func(e *testEnv, base, admin, member, memberID string){
		"selbst verlassen": func(e *testEnv, base, _, member, _ string) {
			e.expect(204, "POST", base+"/leave", member, obj{})
		},
		"vom Admin entfernt": func(e *testEnv, base, admin, _, memberID string) {
			e.expect(204, "DELETE", base+"/members/"+memberID, admin, nil)
		},
		"mit dem alten Weg ausgetreten": func(e *testEnv, base, _, member, memberID string) {
			e.expect(204, "DELETE", base+"/members/"+memberID, member, nil)
		},
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t)
			admin := e.register("a@example.de", "A", "F")
			fid := e.firstFamily(admin)
			base := "/api/families/" + fid
			member, memberID := e.addMember(fid, admin, "b@example.de")
			e.expect(204, "PUT", base+"/profile", member, obj{
				"name": "Ben im Kreis", "family_role": "Sohn", "birthday": "2000-01-02",
				"fields": []any{obj{"kind": "phone", "value": "123"}},
			})
			e.expect(204, "PUT", base+"/color", member, obj{"color": "#1565C0"})
			event := e.expect(201, "POST", base+"/events", member, eventBody(obj{
				"visibility": "participants", "participants_all": false, "participant_ids": []any{memberID},
			}))["id"].(string)

			leave(e, base, admin, member, memberID)

			// Gone for now: no access, not listed, the account itself lives on.
			e.expect(404, "GET", base+"/profile", member, nil)
			e.expect(404, "GET", base+"/events/"+event, member, nil)
			for _, m := range e.expect(200, "GET", base+"/members", admin, nil)["members"].([]any) {
				if m.(obj)["id"] == memberID {
					t.Errorf("still listed: %v", m)
				}
			}
			if got := e.expect(200, "GET", "/api/me", member, nil)["id"]; got != memberID {
				t.Errorf("account: %v", got)
			}

			e.rejoin(fid, admin, "b@example.de", member)

			got := e.expect(200, "GET", base+"/profile", member, nil)
			if got["name"] != "Ben im Kreis" || got["family_role"] != "Sohn" || got["birthday"] != "2000-01-02" || len(got["fields"].([]any)) != 1 {
				t.Errorf("profile: %v", got)
			}
			if got := e.expect(200, "GET", base+"/events/"+event, member, nil); got["creator_name"] != "Ben im Kreis" {
				t.Errorf("event: %v", got)
			}
			for _, family := range e.expect(200, "GET", "/api/me", member, nil)["families"].([]any) {
				if f := family.(obj); f["id"] == fid && f["color"] != "#1565C0" {
					t.Errorf("color: %v", f)
				}
			}
			// The invitation decides about the role, not the past.
			var left int
			if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM former_memberships`).Scan(&left); err != nil || left != 0 {
				t.Errorf("archive: %d %v", left, err)
			}
		})
	}
}

func TestFormerMembersStayListedForAdmins(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	member, memberID := e.addMember(fid, admin, "b@example.de")
	viewer, _ := e.addMember(fid, admin, "v@example.de")
	e.expect(204, "PUT", base+"/profile", member, obj{"name": "Ben im Kreis"})
	e.expect(204, "PUT", base+"/color", member, obj{"color": "#1565C0"})
	private := e.expect(201, "POST", base+"/events", member, eventBody(obj{
		"visibility": "participants", "participants_all": false, "participant_ids": []any{memberID},
	}))["id"].(string)
	e.expect(204, "POST", base+"/leave", member, obj{})

	former := func() []any { return e.expect(200, "GET", base+"/members", admin, nil)["former"].([]any) }
	got := former()
	if len(got) != 1 {
		t.Fatalf("former: %v", got)
	}
	if f := got[0].(obj); f["id"] != memberID || f["name"] != "Ben im Kreis" || f["email"] != "b@example.de" || f["color"] != "#1565C0" || f["left_at"] == "" {
		t.Errorf("entry: %v", f)
	}
	// Only admins get to see who left, and only they can act on it.
	if got := e.expect(200, "GET", base+"/members", viewer, nil)["former"].([]any); len(got) != 0 {
		t.Errorf("seen by a member: %v", got)
	}
	e.expect(403, "DELETE", base+"/former/"+memberID, viewer, nil)
	e.expect(404, "DELETE", base+"/former/nix", admin, nil)

	// Invited again it moves over to the invitations, and joining ends the entry.
	e.expect(201, "POST", base+"/invitations", admin, obj{"email": "b@example.de", "role": "user"})
	if got := former(); len(got) != 0 {
		t.Errorf("while invited: %v", got)
	}
	e.expect(200, "GET", "/api/me", member, nil)
	if got := former(); len(got) != 0 {
		t.Errorf("after joining: %v", got)
	}
	if got := e.expect(200, "GET", base+"/profile", member, nil); got["name"] != "Ben im Kreis" {
		t.Errorf("profile: %v", got)
	}

	// Deleting ends it for good, but the account stays for its other families.
	e.expect(204, "POST", base+"/leave", member, obj{})
	e.expect(204, "DELETE", base+"/former/"+memberID, admin, nil)
	if got := former(); len(got) != 0 {
		t.Errorf("after deleting: %v", got)
	}
	e.expect(404, "DELETE", base+"/former/"+memberID, admin, nil)
	e.expect(404, "GET", base+"/events/"+private, admin, nil)
	if got := e.expect(200, "GET", "/api/me", member, nil)["id"]; got != memberID {
		t.Errorf("account: %v", got)
	}
	e.rejoin(fid, admin, "b@example.de", member)
	if got := e.expect(200, "GET", base+"/profile", member, nil); got["name"] != "B" {
		t.Errorf("nothing should come back: %v", got)
	}
	e.expect(404, "GET", base+"/events/"+private, member, nil)
}

func TestLeavingWithAllDataRemovesWhatIsOwn(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	adminID := e.expect(200, "GET", "/api/me", admin, nil)["id"].(string)
	member, memberID := e.addMember(fid, admin, "b@example.de")
	e.expect(204, "PUT", base+"/profile", member, obj{"name": "Ben im Kreis", "birthday": "2000-01-02"})

	private := e.expect(201, "POST", base+"/events", member, eventBody(obj{
		"visibility": "participants", "participants_all": false, "participant_ids": []any{memberID},
	}))["id"].(string)
	shared := e.expect(201, "POST", base+"/events", member, eventBody(obj{"title": "Für alle"}))["id"].(string)
	withAdmin := e.expect(201, "POST", base+"/events", member, eventBody(obj{
		"visibility": "participants", "participants_all": false, "participant_ids": []any{memberID, adminID},
	}))["id"].(string)
	// Made by the admin for this member alone: it must neither vanish nor become public.
	forMember := e.expect(201, "POST", base+"/events", admin, eventBody(obj{
		"visibility": "participants", "participants_all": false, "participant_ids": []any{memberID},
	}))["id"].(string)
	openForMember := e.expect(201, "POST", base+"/events", admin, eventBody(obj{
		"participants_all": false, "participant_ids": []any{memberID},
	}))["id"].(string)
	e.expect(201, "POST", base+"/events/"+shared+"/comments", member, obj{"body": "Mein Kommentar"})
	e.expect(201, "POST", base+"/messages", member, obj{"body": "Meine Nachricht"})
	status, out := e.uploadTo(member, base+"/events/"+shared+"/attachments", "plan.png", pngHeader)
	if status != 201 {
		t.Fatalf("upload: %d %v", status, out)
	}
	file := out["id"].(string)
	if !e.fileStored(file) {
		t.Fatal("file missing")
	}

	e.expect(204, "POST", base+"/leave", member, obj{"delete_data": true})

	if e.fileStored(file) {
		t.Errorf("file still on disk")
	}
	e.expect(404, "GET", base+"/events/"+private, admin, nil)
	got := e.expect(200, "GET", base+"/events/"+shared, admin, nil)
	if got["created_by"] != nil || got["creator_name"] != "" || len(got["comments"].([]any)) != 0 || len(got["attachments"].([]any)) != 0 {
		t.Errorf("shared event: %v", got)
	}
	if got := e.expect(200, "GET", base+"/events/"+withAdmin, admin, nil); len(got["participant_ids"].([]any)) != 1 {
		t.Errorf("event with admin: %v", got)
	}
	if got := e.expect(200, "GET", base+"/events/"+forMember, admin, nil); got["visibility"] != "participants" || got["participants_all"] != false {
		t.Errorf("event for the member: %v", got)
	}
	if got := e.expect(200, "GET", base+"/events/"+openForMember, admin, nil); got["participants_all"] != true {
		t.Errorf("open event for the member: %v", got)
	}
	var messages int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE sender_id = ?`, memberID).Scan(&messages); err != nil || messages != 0 {
		t.Errorf("messages: %d %v", messages, err)
	}

	// A return starts over with the account, and nothing comes back.
	e.rejoin(fid, admin, "b@example.de", member)
	if got := e.expect(200, "GET", base+"/profile", member, nil); got["name"] != "B" || got["birthday"] != "" {
		t.Errorf("after return: %v", got)
	}
	e.expect(404, "GET", base+"/events/"+private, member, nil)
}

func TestLastAdminCannotLeaveOthersBehind(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	second, secondID := e.addMember(fid, admin, "b@example.de")

	for _, body := range []obj{{}, {"delete_data": true}} {
		if status, out := e.call("POST", base+"/leave", admin, body); status != 409 || !strings.Contains(out["error"].(string), "letzte Admin") {
			t.Errorf("%v: %d %v", body, status, out)
		}
	}
	// With another admin the way is free.
	e.expect(204, "PUT", base+"/members/"+secondID, admin, obj{"role": "manager", "is_admin": true})
	e.expect(204, "POST", base+"/leave", admin, obj{})
	if got := e.expect(200, "GET", base+"/members", second, nil)["members"].([]any); len(got) != 1 {
		t.Errorf("members: %v", got)
	}
}

func TestLastAdminWaitsForFormerMembersToBeDeleted(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	member, memberID := e.addMember(fid, admin, "b@example.de")
	e.expect(204, "POST", base+"/leave", member, obj{})

	for _, body := range []obj{{}, {"delete_data": true}} {
		status, out := e.call("POST", base+"/leave", admin, body)
		if status != 409 || !strings.Contains(out["error"].(string), "verlassen haben") {
			t.Errorf("%v: %d %v", body, status, out)
		}
	}
	// Also while they are invited again and so not in the list of those who left.
	e.expect(201, "POST", base+"/invitations", admin, obj{"email": "b@example.de", "role": "user"})
	if status, _ := e.call("POST", base+"/leave", admin, obj{}); status != 409 {
		t.Errorf("while invited: %d", status)
	}
	invitations := e.expect(200, "GET", base+"/members", admin, nil)["invitations"].([]any)
	e.expect(204, "DELETE", base+"/invitations/"+invitations[0].(obj)["id"].(string), admin, nil)

	e.expect(204, "DELETE", base+"/former/"+memberID, admin, nil)
	e.expect(204, "POST", base+"/leave", admin, obj{})
}

func TestAnotherAdminCanLeaveDespiteFormerMembers(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	member, _ := e.addMember(fid, admin, "b@example.de")
	_, secondID := e.addMember(fid, admin, "c@example.de")
	e.expect(204, "PUT", base+"/members/"+secondID, admin, obj{"role": "manager", "is_admin": true})
	e.expect(204, "POST", base+"/leave", member, obj{})
	e.expect(204, "POST", base+"/leave", admin, obj{})
}

func TestLastMemberLeavesFamilyBehindOrDeletesIt(t *testing.T) {
	count := func(e *testEnv, table, fid string) int {
		t.Helper()
		var n int
		column := "family_id"
		if table == "families" {
			column = "id"
		}
		if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM `+table+` WHERE `+column+` = ?`, fid).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	t.Run("nur verlassen", func(t *testing.T) {
		e := newEnv(t)
		admin := e.register("a@example.de", "A", "F")
		fid := e.firstFamily(admin)
		base := "/api/families/" + fid
		e.expect(201, "POST", base+"/events", admin, eventBody(nil))
		e.expect(201, "POST", base+"/invitations", admin, obj{"email": "n@example.de", "role": "user"})

		e.expect(204, "POST", base+"/leave", admin, obj{})
		e.expect(404, "GET", base+"/members", admin, nil)

		// It stays for the support, but nobody can join a family without an admin.
		if count(e, "families", fid) != 1 || count(e, "events", fid) != 1 || count(e, "former_memberships", fid) != 1 {
			t.Errorf("should stay")
		}
		if count(e, "invitations", fid) != 0 {
			t.Errorf("invitation still open")
		}
	})

	t.Run("mit allen Daten", func(t *testing.T) {
		e := newEnv(t)
		admin := e.register("a@example.de", "A", "F")
		fid := e.firstFamily(admin)
		base := "/api/families/" + fid
		event := e.expect(201, "POST", base+"/events", admin, eventBody(nil))["id"].(string)
		status, out := e.uploadTo(admin, base+"/events/"+event+"/attachments", "plan.png", pngHeader)
		if status != 201 {
			t.Fatalf("upload: %d %v", status, out)
		}
		file := out["id"].(string)

		e.expect(204, "POST", base+"/leave", admin, obj{"delete_data": true})
		if count(e, "families", fid) != 0 || count(e, "events", fid) != 0 || count(e, "former_memberships", fid) != 0 {
			t.Errorf("should be gone")
		}
		if e.fileStored(file) {
			t.Errorf("file still on disk")
		}
		// The account lives on without a family.
		if got := e.expect(200, "GET", "/api/me", admin, nil)["families"].([]any); len(got) != 0 {
			t.Errorf("families: %v", got)
		}
	})
}
