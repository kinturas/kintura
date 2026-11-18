package server

import (
	"bufio"
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

func (e *testEnv) activities(token, fid, query string) ([]obj, any) {
	e.t.Helper()
	var out struct {
		Items []obj `json:"items"`
		Next  any   `json:"next"`
	}
	if err := e.getJSON("/api/families/"+fid+"/activities"+query, token, &out); err != nil {
		e.t.Fatal(err)
	}
	return out.Items, out.Next
}

func activityKinds(items []obj) string {
	kinds := make([]string, len(items))
	for i, item := range items {
		kinds[i] = item["kind"].(string)
	}
	return strings.Join(kinds, ",")
}

func TestActivitiesOfEvents(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, benID := e.addMember(fid, owner, "b@example.de")
	carl, _ := e.addMember(fid, owner, "c@example.de")
	base := "/api/families/" + fid

	day := time.Now().AddDate(0, 0, 2).Format("2006-01-02")
	event := obj{
		"title": "Zahnarzt", "start_local": day + "T10:00", "end_local": day + "T11:00",
		"participants_all": false, "participant_ids": []string{benID},
	}
	id := e.expect(201, "POST", base+"/events", owner, event)["id"].(string)
	items, next := e.activities(ben, fid, "")
	if activityKinds(items) != "event_added" || next != nil {
		t.Fatalf("ben: %v %v", items, next)
	}
	if items[0]["actor_name"] != "Anna" || items[0]["title"] != "Zahnarzt" || items[0]["ref_id"] != id || items[0]["new"] != true {
		t.Fatalf("entry: %v", items[0])
	}
	if items, _ := e.activities(owner, fid, ""); len(items) != 0 {
		t.Fatalf("the actor hears nothing of their own doing: %v", items)
	}
	if items, _ := e.activities(carl, fid, ""); len(items) != 0 {
		t.Fatalf("carl takes no part: %v", items)
	}

	// Changed twice: one entry, with the newer title.
	event["title"] = "Zahnarzt Dr. Weiß"
	e.expect(204, "PUT", base+"/events/"+id, owner, event)
	event["start_local"], event["end_local"] = day+"T14:00", day+"T15:00"
	e.expect(204, "PUT", base+"/events/"+id, owner, event)
	items, _ = e.activities(ben, fid, "")
	if activityKinds(items) != "event_changed,event_added" || items[0]["title"] != "Zahnarzt Dr. Weiß" {
		t.Fatalf("changed: %v", items)
	}
	// Saving what is there tells nobody anything.
	e.expect(204, "PUT", base+"/events/"+id, owner, event)
	if items, _ := e.activities(ben, fid, ""); len(items) != 2 {
		t.Fatalf("unchanged: %v", items)
	}

	var upcoming []obj
	if err := e.getJSON(base+"/activities/upcoming", ben, &upcoming); err != nil {
		t.Fatal(err)
	}
	if len(upcoming) != 1 || upcoming[0]["title"] != "Zahnarzt Dr. Weiß" || upcoming[0]["start_local"] != day+"T14:00" {
		t.Fatalf("upcoming: %v", upcoming)
	}
	if err := e.getJSON(base+"/activities/upcoming", carl, &upcoming); err != nil || len(upcoming) != 0 {
		t.Fatalf("carl's upcoming: %v %v", upcoming, err)
	}

	// Ben off, everyone on: Ben is told he is out, Carl that he is in.
	event["participant_ids"] = []string{}
	event["participants_all"] = true
	e.expect(204, "PUT", base+"/events/"+id, owner, event)
	if items, _ := e.activities(carl, fid, ""); activityKinds(items) != "event_added" {
		t.Fatalf("carl: %v", items)
	}
	if items, _ := e.activities(ben, fid, ""); activityKinds(items) != "event_changed,event_added" {
		t.Fatalf("ben stays in with everyone: %v", items)
	}
	e.expect(204, "DELETE", base+"/events/"+id, owner, nil)
	if items, _ := e.activities(carl, fid, ""); activityKinds(items) != "event_deleted,event_added" || items[0]["title"] != "Zahnarzt Dr. Weiß" {
		t.Fatalf("deleted: %v", items)
	}

	// For everyone from the start.
	e.expect(201, "POST", base+"/events", owner, obj{"title": "Grillen", "start_local": day + "T18:00", "end_local": day + "T22:00"})
	if items, _ := e.activities(carl, fid, ""); items[0]["kind"] != "event_all" {
		t.Fatalf("for everyone: %v", items)
	}

	// Taken off a private event.
	private := obj{
		"title": "Geheim", "start_local": day + "T10:00", "end_local": day + "T11:00", "visibility": "participants",
		"participants_all": false, "participant_ids": []string{benID},
	}
	id = e.expect(201, "POST", base+"/events", owner, private)["id"].(string)
	private["participant_ids"] = []string{e.expect(200, "GET", "/api/me", owner, nil)["id"].(string)}
	e.expect(204, "PUT", base+"/events/"+id, owner, private)
	if items, _ := e.activities(ben, fid, ""); items[0]["kind"] != "event_removed" || items[1]["kind"] != "event_added" {
		t.Fatalf("removed: %v", items)
	}
}

func TestActivitiesOfShoppingAndPaging(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, benID := e.addMember(fid, owner, "b@example.de")
	carl, carlID := e.addMember(fid, owner, "c@example.de")
	base := "/api/families/" + fid

	list := e.expect(201, "POST", base+"/shopping/lists", owner, obj{
		"name": "Wocheneinkauf", "assignees_all": false, "assignee_ids": []string{benID},
	})["id"].(string)
	if items, _ := e.activities(ben, fid, ""); activityKinds(items) != "list_added" || items[0]["title"] != "Wocheneinkauf" {
		t.Fatalf("ben: %v", items)
	}
	if items, _ := e.activities(carl, fid, ""); len(items) != 0 {
		t.Fatalf("carl: %v", items)
	}

	// Articles of one person become one entry; one already on the list counts once.
	for _, name := range []string{"Milch", "Brot", "Milch"} {
		e.call("POST", base+"/shopping/lists/"+list+"/items", owner, obj{"name": name})
	}
	items, _ := e.activities(ben, fid, "")
	if activityKinds(items) != "items_added,list_added" || items[0]["count"] != float64(2) ||
		strings.Join(toStrings(items[0]["names"]), ",") != "Brot,Milch" {
		t.Fatalf("items: %v", items)
	}
	// Ben's own articles go to Anna, the creator, not back to Ben.
	e.expect(201, "POST", base+"/shopping/lists/"+list+"/items", ben, obj{"name": "Eier"})
	if items, _ := e.activities(owner, fid, ""); activityKinds(items) != "items_added" || items[0]["actor_name"] != "B" {
		t.Fatalf("anna: %v", items)
	}
	if items, _ := e.activities(ben, fid, ""); len(items) != 2 {
		t.Fatalf("ben hears nothing of his own: %v", items)
	}

	// Carl joins the list.
	e.expect(204, "PUT", base+"/shopping/lists/"+list, owner, obj{
		"name": "Wocheneinkauf", "assignees_all": false, "assignee_ids": []string{benID, carlID},
	})
	if items, _ := e.activities(carl, fid, ""); activityKinds(items) != "list_added" {
		t.Fatalf("carl added: %v", items)
	}
	if items, _ := e.activities(ben, fid, ""); len(items) != 2 {
		t.Fatalf("ben was on it before: %v", items)
	}

	// Unread until seen.
	if n := e.expect(200, "GET", base+"/activities/unread", ben, nil)["count"]; n != float64(2) {
		t.Fatalf("unread: %v", n)
	}
	e.expect(204, "POST", base+"/activities/seen", ben, nil)
	if n := e.expect(200, "GET", base+"/activities/unread", ben, nil)["count"]; n != float64(0) {
		t.Fatalf("unread after seen: %v", n)
	}
	if items, _ := e.activities(ben, fid, ""); items[0]["new"] != false {
		t.Fatalf("seen: %v", items)
	}

	// Pages.
	e.expect(204, "DELETE", base+"/shopping/lists/"+list, owner, nil)
	first, next := e.activities(ben, fid, "?limit=2")
	if activityKinds(first) != "list_deleted,items_added" || next == nil {
		t.Fatalf("first page: %v %v", first, next)
	}
	second, next := e.activities(ben, fid, "?limit=2&before="+urlQuery(next.(string)))
	if activityKinds(second) != "list_added" || next != nil {
		t.Fatalf("second page: %v %v", second, next)
	}
	e.expect(400, "GET", base+"/activities?before=kaputt", ben, nil)
	e.expect(400, "GET", base+"/activities?limit=0", ben, nil)

	// Gone with the member.
	e.expect(204, "DELETE", base+"/members/"+benID, owner, nil)
	e.expect(204, "DELETE", base+"/former/"+benID, owner, nil)
	var rows int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM activities WHERE user_id = ?`, benID).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("left behind: %d %v", rows, err)
	}
}

func toStrings(v any) []string {
	var out []string
	for _, s := range v.([]any) {
		out = append(out, s.(string))
	}
	return out
}

func urlQuery(s string) string {
	return strings.NewReplacer("|", "%7C", ":", "%3A").Replace(s)
}

func TestLiveStream(t *testing.T) {
	e := newEnv(t)
	e.server.liveHeartbeat = 50 * time.Millisecond
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, _ := e.addMember(fid, owner, "b@example.de")
	other := e.register("x@example.de", "X", "Fremde")

	open := func(token string) (*bufio.Scanner, context.CancelFunc) {
		ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
		req, _ := http.NewRequestWithContext(ctx, "GET", e.srv.URL+"/api/live", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if res.StatusCode != 200 || res.Header.Get("Content-Type") != "text/event-stream" {
			t.Fatalf("status %d, type %q", res.StatusCode, res.Header.Get("Content-Type"))
		}
		t.Cleanup(func() { res.Body.Close() })
		return bufio.NewScanner(res.Body), cancel
	}
	next := func(s *bufio.Scanner) string {
		for s.Scan() {
			if data, ok := strings.CutPrefix(s.Text(), "data: "); ok {
				return data
			}
		}
		return ""
	}

	if status, _ := e.call("GET", "/api/live", "", nil); status != 401 {
		t.Fatalf("without login: %d", status)
	}
	stream, cancel := open(ben)
	defer cancel()
	strange, cancelStrange := open(other)
	defer cancelStrange()

	// Reading for oneself is no news; a change is, after the heartbeats.
	e.expect(204, "POST", "/api/families/"+fid+"/activities/seen", owner, nil)
	e.expect(400, "POST", "/api/families/"+fid+"/shopping/lists", owner, obj{"name": ""})
	time.Sleep(120 * time.Millisecond)
	e.expect(201, "POST", "/api/families/"+fid+"/shopping/lists", owner, obj{"name": "W"})
	if got := next(stream); got != `{"family":"`+fid+`","topic":"shopping"}` {
		t.Fatalf("got %q", got)
	}
	e.expect(204, "PUT", "/api/families/"+fid+"/profile", owner, obj{"name": "Anna", "birthday": ""})
	if got := next(stream); got != `{"family":"`+fid+`","topic":"family"}` {
		t.Fatalf("got %q", got)
	}

	// Someone of another family hears nothing; the stream ends on logout.
	cancelStrange()
	if strange.Scan() && strings.HasPrefix(strange.Text(), "data:") {
		t.Fatalf("other family: %q", strange.Text())
	}
	e.expect(204, "POST", "/api/auth/logout", ben, nil)
	done := make(chan bool)
	go func() {
		for stream.Scan() {
		}
		done <- true
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("the stream outlived the session")
	}
}

func TestActivitiesOfReadableLists(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, benID := e.addMember(fid, owner, "b@example.de")
	carl, _ := e.addMember(fid, owner, "c@example.de")
	base := "/api/families/" + fid + "/shopping/lists"

	list := e.expect(201, "POST", base, owner, obj{"name": "Geschenke", "assignees_all": false, "assignee_ids": []string{benID}})["id"].(string)
	if items, _ := e.activities(carl, fid, ""); len(items) != 0 {
		t.Fatalf("private: %v", items)
	}
	// Made visible to everyone: Carl may look, Ben was on it before.
	e.expect(204, "PUT", base+"/"+list, owner, obj{"name": "Geschenke", "assignees_all": false, "assignee_ids": []string{benID}, "visibility": "all"})
	if items, _ := e.activities(carl, fid, ""); activityKinds(items) != "list_readable" {
		t.Fatalf("carl: %v", items)
	}
	if items, _ := e.activities(ben, fid, ""); activityKinds(items) != "list_added" {
		t.Fatalf("ben: %v", items)
	}
	// Saved again as it is: nothing new.
	e.expect(204, "PUT", base+"/"+list, owner, obj{"name": "Geschenke", "assignees_all": false, "assignee_ids": []string{benID}, "visibility": "all"})
	if items, _ := e.activities(carl, fid, ""); len(items) != 1 {
		t.Fatalf("again: %v", items)
	}
	// Visible to everyone from the start.
	e.expect(201, "POST", base, owner, obj{"name": "Baumarkt", "assignees_all": false, "assignee_ids": []string{benID}, "visibility": "all"})
	if items, _ := e.activities(carl, fid, ""); activityKinds(items) != "list_readable,list_readable" || items[0]["title"] != "Baumarkt" {
		t.Fatalf("new: %v", items)
	}
}
