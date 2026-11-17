package server

import (
	"bytes"
	"fmt"
	"image"
	"image/png"
	"net/url"
	"testing"
)

func (e *testEnv) shoppingLists(token, fid string) []obj {
	e.t.Helper()
	var out []obj
	if err := e.getJSON("/api/families/"+fid+"/shopping/lists", token, &out); err != nil {
		e.t.Fatal(err)
	}
	return out
}

func (e *testEnv) shoppingItems(token, fid, listID string) []obj {
	e.t.Helper()
	var out []obj
	if err := e.getJSON("/api/families/"+fid+"/shopping/lists/"+listID+"/items", token, &out); err != nil {
		e.t.Fatal(err)
	}
	return out
}

func itemNames(items []obj) string {
	out := ""
	for i, item := range items {
		if i > 0 {
			out += ","
		}
		out += item["name"].(string)
		if item["done"] == true {
			out += "✓"
		}
	}
	return out
}

func TestShoppingItems(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid + "/shopping"

	e.expect(400, "POST", base+"/lists", token, obj{"name": " "})
	e.expect(400, "POST", base+"/lists", token, obj{"name": "W", "color": "rot"})
	list := e.expect(201, "POST", base+"/lists", token, obj{"name": "Wocheneinkauf", "color": "#3567b5"})["id"].(string)
	other := e.expect(201, "POST", base+"/lists", token, obj{"name": "Baumarkt"})["id"].(string)
	lists := e.shoppingLists(token, fid)
	if len(lists) != 2 || lists[1]["color"] != "#3567B5" || lists[1]["assignees_all"] != true || lists[1]["can_edit"] != true {
		t.Fatalf("lists: %v", lists)
	}

	milk := e.expect(201, "POST", base+"/lists/"+list+"/items", token, obj{"name": "Milch"})["id"].(string)
	e.expect(201, "POST", base+"/lists/"+list+"/items", token, obj{"name": "Brot"})
	// Adding it again keeps the one entry.
	if again := e.expect(200, "POST", base+"/lists/"+list+"/items", token, obj{"name": "Milch"})["id"]; again != milk {
		t.Fatalf("again: %v", again)
	}
	e.expect(400, "PUT", base+"/items/"+milk, token, obj{"urgency": "sofort"})
	e.expect(200, "PUT", base+"/items/"+milk, token, obj{"amount": "2 l", "note": "laktosefrei", "urgency": "urgent"})
	if got := itemNames(e.shoppingItems(token, fid, list)); got != "Brot,Milch" {
		t.Fatalf("open: %s", got)
	}

	// Done, it goes to the recent ones and keeps its notes; added again, it is open again.
	e.expect(200, "PUT", base+"/items/"+milk, token, obj{"amount": "2 l", "note": "laktosefrei", "urgency": "urgent", "done": true})
	items := e.shoppingItems(token, fid, list)
	if itemNames(items) != "Brot,Milch✓" || items[1]["amount"] != "2 l" || items[1]["done_at"] == "" {
		t.Fatalf("done: %v", items)
	}
	if n := e.shoppingLists(token, fid)[1]["open_items"]; fmt.Sprint(n) != "1" {
		t.Fatalf("open_items: %v", n)
	}
	e.expect(200, "POST", base+"/lists/"+list+"/items", token, obj{"name": "Milch"})
	items = e.shoppingItems(token, fid, list)
	if itemNames(items) != "Brot,Milch" || items[1]["note"] != "laktosefrei" {
		t.Fatalf("again open: %v", items)
	}

	// Moving takes the photos along and merges into an entry the other list has.
	var buf bytes.Buffer
	png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 2, 2)))
	status, photo := e.uploadTo(token, base+"/items/"+milk+"/photos", "p.png", buf.Bytes())
	if status != 201 {
		t.Fatalf("upload: %d %v", status, photo)
	}
	if status, _ := e.uploadTo(token, base+"/items/"+milk+"/photos", "p.txt", []byte("hallo")); status != 400 {
		t.Fatalf("text as photo: %d", status)
	}
	target := e.expect(201, "POST", base+"/lists/"+other+"/items", token, obj{"name": "Milch"})["id"].(string)
	moved := e.expect(200, "PUT", base+"/items/"+milk, token, obj{"amount": "3 l", "list_id": other})["id"]
	if moved != target {
		t.Fatalf("moved into %v, want %v", moved, target)
	}
	items = e.shoppingItems(token, fid, other)
	if len(items) != 1 || items[0]["amount"] != "3 l" || fmt.Sprint(items[0]["photo_ids"]) != fmt.Sprintf("[%s]", photo["id"]) {
		t.Fatalf("other: %v", items)
	}
	if got := itemNames(e.shoppingItems(token, fid, list)); got != "Brot" {
		t.Fatalf("left behind: %s", got)
	}
	if status, body := e.getRaw(base+"/photos/"+photo["id"].(string), token); status != 200 || body != buf.String() {
		t.Fatalf("photo: %d", status)
	}
	e.expect(204, "DELETE", base+"/photos/"+photo["id"].(string), token, nil)

	e.expect(204, "DELETE", base+"/items/"+target, token, nil)
	e.expect(204, "DELETE", base+"/lists/"+other, token, nil)
	e.expect(404, "GET", base+"/lists/"+other+"/items", token, nil)
}

func TestShoppingListVisibility(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	base := "/api/families/" + fid + "/shopping"
	guest, guestID := e.addMember(fid, owner, "b@example.de")
	outsider, outsiderID := e.addMember(fid, owner, "c@example.de")
	_ = outsiderID

	e.expect(400, "POST", base+"/lists", owner, obj{"name": "P", "assignees_all": false})
	private := e.expect(201, "POST", base+"/lists", owner, obj{
		"name": "Geschenke", "assignees_all": false, "assignee_ids": []any{guestID}, "visibility": "participants",
	})["id"].(string)
	open := e.expect(201, "POST", base+"/lists", owner, obj{
		"name": "Offen", "assignees_all": false, "assignee_ids": []any{guestID},
	})["id"].(string)

	if lists := e.shoppingLists(guest, fid); len(lists) != 2 || lists[0]["can_edit"] != false ||
		fmt.Sprint(lists[0]["assignee_ids"]) != "["+guestID+"]" {
		t.Fatalf("guest: %v", lists)
	}
	if lists := e.shoppingLists(outsider, fid); len(lists) != 1 || lists[0]["id"] != open {
		t.Fatalf("outsider: %v", lists)
	}
	e.expect(404, "GET", base+"/lists/"+private+"/items", outsider, nil)
	e.expect(404, "POST", base+"/lists/"+private+"/items", outsider, obj{"name": "Milch"})
	item := e.expect(201, "POST", base+"/lists/"+private+"/items", guest, obj{"name": "Milch"})["id"].(string)
	e.expect(404, "PUT", base+"/items/"+item, outsider, obj{"done": true})

	// An article cannot be moved into a list one cannot see.
	mine := e.expect(201, "POST", base+"/lists/"+open+"/items", outsider, obj{"name": "Brot"})["id"].(string)
	e.expect(400, "PUT", base+"/items/"+mine, outsider, obj{"list_id": private})

	// Seeing a list allows to shop with it, not to change it.
	e.expect(403, "PUT", base+"/lists/"+private, guest, obj{"name": "X"})
	e.expect(403, "DELETE", base+"/lists/"+private, guest, nil)
	e.expect(204, "PUT", base+"/lists/"+private, owner, obj{"name": "Geschenke", "visibility": "participants",
		"assignees_all": false, "assignee_ids": []any{guestID, outsiderID}})
	if lists := e.shoppingLists(outsider, fid); len(lists) != 2 {
		t.Fatalf("outsider after adding: %v", lists)
	}

	// Once a guest is deleted for good, a private list stays with its creator and an
	// open one is for everyone again.
	e.expect(204, "PUT", base+"/lists/"+private, owner, obj{"name": "Geschenke", "visibility": "participants",
		"assignees_all": false, "assignee_ids": []any{guestID}})
	e.expect(204, "DELETE", "/api/families/"+fid+"/members/"+guestID, owner, nil)
	e.expect(204, "DELETE", "/api/families/"+fid+"/former/"+guestID, owner, nil)
	ownerID := e.expect(200, "GET", "/api/me", owner, nil)["id"].(string)
	for _, list := range e.shoppingLists(owner, fid) {
		want := map[string]string{private: "false [" + ownerID + "]", open: "true []"}[list["id"].(string)]
		if got := fmt.Sprint(list["assignees_all"], " ", list["assignee_ids"]); got != want {
			t.Errorf("%v after deleting: %s, want %s", list["name"], got, want)
		}
	}
	if lists := e.shoppingLists(outsider, fid); len(lists) != 1 || lists[0]["id"] != open {
		t.Fatalf("outsider after deleting: %v", lists)
	}
}

func TestShoppingArticles(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid + "/shopping/articles"

	if got := e.expect(201, "POST", base, token, obj{"name": "  übertopf "})["name"]; got != "Übertopf" {
		t.Fatalf("name: %v", got)
	}
	e.expect(409, "POST", base, token, obj{"name": "Übertopf"})
	e.expect(400, "POST", base, token, obj{"name": "X", "category": "elektro"})
	e.expect(400, "PUT", base, token, obj{"name": "Milch", "icon": "<svg>"})
	e.expect(204, "PUT", base, token, obj{"name": "Milch", "icon": "bottle", "category": "getraenke"})
	e.expect(204, "PUT", base, token, obj{"name": "Übertopf", "icon": "pot", "category": "baumarkt_garten"})

	var articles []obj
	if err := e.getJSON(base, token, &articles); err != nil {
		t.Fatal(err)
	}
	if len(articles) != 2 || articles[0]["name"] != "Milch" || articles[0]["custom"] != false ||
		articles[1]["custom"] != true || articles[1]["category"] != "baumarkt_garten" || articles[1]["icon"] != "pot" {
		t.Fatalf("articles: %v", articles)
	}
	// Only own articles can be deleted.
	e.expect(404, "DELETE", base+"?name=Milch", token, nil)
	e.expect(204, "DELETE", base+"?name="+url.QueryEscape("Übertopf"), token, nil)
}
