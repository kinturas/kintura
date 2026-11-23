package server

import (
	"strings"
	"testing"
	"time"
)

func TestCommentChanges(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, benID := e.addMember(fid, owner, "b@example.de")
	carl, carlID := e.addMember(fid, owner, "c@example.de")
	base := "/api/families/" + fid
	// A manager, but no admin: that is not enough for the comments of others.
	e.expect(204, "PUT", base+"/members/"+carlID, owner, obj{"role": "manager", "is_admin": false})

	day := time.Now().AddDate(0, 0, 2).Format("2006-01-02")
	event := e.expect(201, "POST", base+"/events", owner, obj{
		"title": "Zahnarzt", "start_local": day + "T10:00", "end_local": day + "T11:00",
		"participants_all": false, "participant_ids": []string{benID},
	})["id"].(string)
	list := e.expect(201, "POST", base+"/shopping/lists", owner, obj{"name": "Grillfest", "visibility": "all"})["id"].(string)

	entry := func(token, kind string) obj {
		t.Helper()
		var out struct {
			Items []obj `json:"items"`
		}
		if err := e.getJSON("/api/activities", token, &out); err != nil {
			t.Fatal(err)
		}
		for _, item := range out.Items {
			if item["kind"] == kind {
				return item
			}
		}
		t.Fatalf("no %s: %v", kind, out.Items)
		return nil
	}
	quoted := func(token, kind string) string {
		t.Helper()
		return strings.Join(toStrings(entry(token, kind)["names"]), "")
	}

	for _, thing := range []struct{ path, kind string }{
		{base + "/events/" + event + "/comments", "event_comment"},
		{base + "/shopping/lists/" + list + "/comments", "list_comment"},
	} {
		t.Run(thing.kind, func(t *testing.T) {
			comments := func(token string) []obj {
				t.Helper()
				if strings.Contains(thing.path, "/events/") {
					var got obj
					if err := e.getJSON(strings.TrimSuffix(thing.path, "/comments"), token, &got); err != nil {
						t.Fatal(err)
					}
					var out []obj
					for _, c := range got["comments"].([]any) {
						out = append(out, c.(obj))
					}
					return out
				}
				var out []obj
				if err := e.getJSON(thing.path, token, &out); err != nil {
					t.Fatal(err)
				}
				return out
			}

			own := e.expect(201, "POST", thing.path, ben, obj{"body": "Ich komme mit"})
			if own["can_edit"] != true || own["can_delete"] != true || own["deleted"] != false {
				t.Fatalf("own: %v", own)
			}
			id := own["id"].(string)
			// What others may do with it: Anna as admin may delete it, nobody else
			// may change it, Carl as manager may do neither.
			if got := comments(owner)[0]; got["can_edit"] != false || got["can_delete"] != true {
				t.Fatalf("admin: %v", got)
			}
			if got := comments(carl)[0]; got["can_edit"] != false || got["can_delete"] != false {
				t.Fatalf("manager: %v", got)
			}
			e.expect(403, "PUT", thing.path+"/"+id, owner, obj{"body": "Anders"})
			e.expect(403, "PUT", thing.path+"/"+id, carl, obj{"body": "Anders"})
			e.expect(403, "DELETE", thing.path+"/"+id, carl, nil)
			e.expect(404, "PUT", thing.path+"/nope", ben, obj{"body": "Anders"})
			e.expect(400, "PUT", thing.path+"/"+id, ben, obj{"body": " "})

			// Ben changes his words, and Aktuelles quotes the new ones.
			if got := e.expect(200, "PUT", thing.path+"/"+id, ben, obj{"body": " Ich komme später "}); got["body"] != "Ich komme später" || got["edited_at"] == nil {
				t.Fatalf("edited: %v", got)
			}
			if got := quoted(owner, thing.kind); got != "Ich komme später" {
				t.Fatalf("quoted after edit: %q", got)
			}
			// And tells of the change, to the others and himself.
			if got := entry(owner, thing.kind+"_edited"); got["actor_id"] != benID || got["own"] != false ||
				strings.Join(toStrings(got["names"]), "") != "Ich komme später" {
				t.Fatalf("edited entry: %v", got)
			}
			if got := entry(ben, thing.kind+"_edited"); got["own"] != true {
				t.Fatalf("own edited entry: %v", got)
			}

			// Anna deletes it: it stays as a note, without words, also in Aktuelles.
			got := e.expect(200, "DELETE", thing.path+"/"+id, owner, nil)
			if got["deleted"] != true || got["body"] != "" || got["deleted_by_name"] != "Anna" || got["can_edit"] != false || got["can_delete"] != false {
				t.Fatalf("deleted: %v", got)
			}
			if list := comments(ben); len(list) != 1 || list[0]["deleted"] != true || list[0]["body"] != "" || list[0]["author_name"] == "" {
				t.Fatalf("note: %v", list)
			}
			if got := quoted(owner, thing.kind); got != "" {
				t.Fatalf("quoted after delete: %q", got)
			}
			// Ben hears that Anna deleted his; the entry names him as its author.
			if got := entry(ben, thing.kind+"_deleted"); got["own"] != false || len(toStrings(got["names"])) != 1 {
				t.Fatalf("deleted entry: %v", got)
			}
			if got := entry(owner, thing.kind+"_deleted"); got["own"] != true {
				t.Fatalf("own deleted entry: %v", got)
			}
			e.expect(409, "PUT", thing.path+"/"+id, ben, obj{"body": "Doch"})
			e.expect(200, "DELETE", thing.path+"/"+id, ben, nil)

			// One's own one may delete without being admin.
			mine := e.expect(201, "POST", thing.path, carl, obj{"body": "Gut"})["id"].(string)
			if got := e.expect(200, "DELETE", thing.path+"/"+mine, carl, nil); got["deleted_by_name"] == "" {
				t.Fatalf("own delete: %v", got)
			}
		})
	}

	// Deleted ones are not counted on the list.
	var lists []obj
	if err := e.getJSON(base+"/shopping/lists", ben, &lists); err != nil || lists[0]["comment_count"] != float64(0) {
		t.Fatalf("count: %v %v", lists, err)
	}
}
