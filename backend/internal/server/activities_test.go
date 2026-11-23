package server

import (
	"bufio"
	"context"
	"net/http"
	"slices"
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

func TestActivitiesOfAllFamilies(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, benID := e.addMember(fid, owner, "b@example.de")
	e.expect(201, "POST", "/api/families", owner, obj{"name": "Zweite"})
	second := e.firstFamily(owner)
	if second == fid {
		t.Fatal("no second family")
	}
	all := func(token, query string) ([]obj, any) {
		t.Helper()
		var out struct {
			Items []obj `json:"items"`
			Next  any   `json:"next"`
		}
		if err := e.getJSON("/api/activities"+query, token, &out); err != nil {
			t.Fatal(err)
		}
		return out.Items, out.Next
	}

	day := func(n int) string { return time.Now().AddDate(0, 0, n).Format("2006-01-02") }
	e.expect(201, "POST", "/api/families/"+fid+"/events", owner, obj{
		"title": "Zahnarzt", "start_local": day(2) + "T10:00", "end_local": day(2) + "T11:00",
		"participants_all": false, "participant_ids": []string{benID},
	})
	list := e.expect(201, "POST", "/api/families/"+second+"/shopping/lists", owner, obj{"name": "Meins"})["id"].(string)
	e.expect(201, "POST", "/api/families/"+second+"/shopping/lists/"+list+"/items", owner, obj{"name": "Milch"})

	// What one did oneself, in every family, never new.
	items, _ := all(owner, "")
	if activityKinds(items) != "items_added,list_all,event_added" {
		t.Fatalf("own: %v", items)
	}
	if items[0]["family_id"] != second || items[0]["own"] != true || items[0]["new"] != false || items[2]["family_id"] != fid {
		t.Fatalf("own entries: %v", items)
	}
	if strings.Join(toStrings(items[2]["names"]), ",") != "B" {
		t.Fatalf("whom it was for: %v", items[2])
	}
	if items, _ := all(owner, "?family="+second); activityKinds(items) != "items_added,list_all" {
		t.Fatalf("one family: %v", items)
	}
	e.expect(404, "GET", "/api/activities?family=nope", owner, nil)
	// The page of one family stays without them, for older apps.
	if items, _ := e.activities(owner, fid, ""); len(items) != 0 {
		t.Fatalf("legacy: %v", items)
	}
	if n := e.expect(200, "GET", "/api/activities/unread", owner, nil)["count"]; n != float64(0) {
		t.Fatalf("own is never unread: %v", n)
	}
	if items, _ := all(ben, ""); activityKinds(items) != "event_added" || items[0]["own"] != false || items[0]["new"] != true {
		t.Fatalf("ben: %v", items)
	}
	if got := e.expect(200, "GET", "/api/activities/unread", ben, nil); got["count"] != float64(1) || got["families"].(obj)[fid] != float64(1) {
		t.Fatalf("ben unread: %v", got)
	}
	// Anna's circles each by themselves, none with news.
	if got := e.expect(200, "GET", "/api/activities/unread", owner, nil)["families"].(obj); len(got) != 2 || got[fid] != float64(0) || got[second] != float64(0) {
		t.Fatalf("anna by circle: %v", got)
	}
	e.expect(204, "POST", "/api/activities/seen", ben, nil)
	if n := e.expect(200, "GET", "/api/families/"+fid+"/activities/unread", ben, nil)["count"]; n != float64(0) {
		t.Fatalf("ben after seen: %v", n)
	}

	// Coming up, over all families, the earliest first.
	e.expect(201, "POST", "/api/families/"+second+"/events", owner, obj{"title": "Sport", "start_local": day(1) + "T18:00", "end_local": day(1) + "T19:00"})
	e.expect(201, "POST", "/api/families/"+fid+"/events", owner, obj{"title": "Grillen", "start_local": day(40) + "T18:00", "end_local": day(40) + "T22:00"})
	var upcoming struct {
		Items []obj `json:"items"`
		More  bool  `json:"more"`
	}
	if err := e.getJSON("/api/activities/upcoming", owner, &upcoming); err != nil {
		t.Fatal(err)
	}
	if len(upcoming.Items) != 2 || upcoming.More || upcoming.Items[0]["title"] != "Sport" || upcoming.Items[0]["family_id"] != second ||
		upcoming.Items[1]["title"] != "Grillen" || upcoming.Items[1]["family_id"] != fid {
		t.Fatalf("upcoming: %v", upcoming)
	}
	if err := e.getJSON("/api/activities/upcoming?limit=1", owner, &upcoming); err != nil || len(upcoming.Items) != 1 || !upcoming.More {
		t.Fatalf("limited: %v %v", upcoming, err)
	}
	if err := e.getJSON("/api/activities/upcoming?family="+fid, owner, &upcoming); err != nil || len(upcoming.Items) != 1 || upcoming.Items[0]["title"] != "Grillen" {
		t.Fatalf("one family: %v %v", upcoming, err)
	}
}

func TestActivitiesOfCheckedOffArticles(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, benID := e.addMember(fid, owner, "b@example.de")
	base := "/api/families/" + fid + "/shopping"
	all := func(token string) []obj {
		t.Helper()
		var out struct {
			Items []obj `json:"items"`
		}
		if err := e.getJSON("/api/activities", token, &out); err != nil {
			t.Fatal(err)
		}
		return out.Items
	}

	list := e.expect(201, "POST", base+"/lists", owner, obj{"name": "Wocheneinkauf", "assignees_all": false, "assignee_ids": []string{benID}})["id"].(string)
	milk := e.expect(201, "POST", base+"/lists/"+list+"/items", owner, obj{"name": "Milch"})["id"].(string)
	brot := e.expect(201, "POST", base+"/lists/"+list+"/items", owner, obj{"name": "Brot"})["id"].(string)

	// Ben checks off two, one by name and one by its id; again changes nothing.
	e.expect(204, "POST", base+"/lists/"+list+"/items/check", ben, obj{"name": "Brot"})
	e.expect(204, "POST", base+"/lists/"+list+"/items/check", ben, obj{"name": "Brot"})
	e.expect(200, "PUT", base+"/items/"+milk, ben, obj{"urgency": "", "done": true})
	items := all(owner)
	if items[0]["kind"] != "items_done" || items[0]["actor_name"] != "B" || items[0]["count"] != float64(2) ||
		strings.Join(toStrings(items[0]["names"]), ",") != "Milch,Brot" {
		t.Fatalf("anna: %v", items)
	}
	if own := all(ben); own[0]["kind"] != "items_done" || own[0]["own"] != true {
		t.Fatalf("ben: %v", own)
	}
	// Older apps do not know it.
	if legacy, _ := e.activities(owner, fid, ""); slices.ContainsFunc(legacy, func(a obj) bool { return a["kind"] == "items_done" }) {
		t.Fatalf("legacy: %v", legacy)
	}

	// Taken back: out of the news again, and gone with the last one.
	e.expect(200, "PUT", base+"/items/"+milk, ben, obj{"urgency": "", "done": false})
	if items := all(owner); items[0]["count"] != float64(1) || strings.Join(toStrings(items[0]["names"]), ",") != "Brot" {
		t.Fatalf("taken back: %v", items[0])
	}
	e.expect(200, "PUT", base+"/items/"+brot, ben, obj{"urgency": "", "done": false})
	if items := all(owner); slices.ContainsFunc(items, func(a obj) bool { return a["kind"] == "items_done" }) {
		t.Fatalf("all taken back: %v", items)
	}
}

func TestActivitiesOfComments(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, benID := e.addMember(fid, owner, "b@example.de")
	carl, carlID := e.addMember(fid, owner, "c@example.de")
	dora, _ := e.addMember(fid, owner, "d@example.de")
	base := "/api/families/" + fid
	all := func(token string) []obj {
		t.Helper()
		var out struct {
			Items []obj `json:"items"`
		}
		if err := e.getJSON("/api/activities", token, &out); err != nil {
			t.Fatal(err)
		}
		return out.Items
	}
	day := time.Now().AddDate(0, 0, 2).Format("2006-01-02")
	id := e.expect(201, "POST", base+"/events", owner, obj{
		"title": "Zahnarzt", "start_local": day + "T10:00", "end_local": day + "T11:00",
		"participants_all": false, "participant_ids": []string{benID},
	})["id"].(string)

	// Carl sees it, though he takes no part, and comments: Anna made it, Ben takes part.
	long := strings.Repeat("sehr ", 40) + "\n wichtig"
	e.expect(201, "POST", base+"/events/"+id+"/comments", carl, obj{"body": long})
	for _, token := range []string{owner, ben} {
		got := all(token)[0]
		names := toStrings(got["names"])
		if got["kind"] != "event_comment" || got["ref_id"] != id || got["title"] != "Zahnarzt" || got["actor_id"] != carlID ||
			len(names) != 1 || !strings.HasSuffix(names[0], " …") || strings.Contains(names[0], "\n") {
			t.Fatalf("comment: %v", got)
		}
	}
	if got := all(carl)[0]; got["kind"] != "event_comment" || got["own"] != true {
		t.Fatalf("carl's own: %v", got)
	}
	if got := all(dora); len(got) != 0 {
		t.Fatalf("dora has nothing to do with it: %v", got)
	}

	// Ben answers: Carl hears of it, having commented before.
	e.expect(201, "POST", base+"/events/"+id+"/comments", ben, obj{"body": "Danke"})
	if got := all(carl)[0]; got["kind"] != "event_comment" || strings.Join(toStrings(got["names"]), "") != "Danke" || got["own"] != false {
		t.Fatalf("carl: %v", got)
	}
	// Older apps do not know it.
	if legacy, _ := e.activities(owner, fid, ""); slices.ContainsFunc(legacy, func(a obj) bool { return a["kind"] == "event_comment" }) {
		t.Fatalf("legacy: %v", legacy)
	}
	if n := e.expect(200, "GET", base+"/activities/unread", owner, nil)["count"]; n != float64(0) {
		t.Fatalf("legacy unread: %v", n)
	}
}

func TestShoppingListComments(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(owner)
	ben, benID := e.addMember(fid, owner, "b@example.de")
	carl, carlID := e.addMember(fid, owner, "c@example.de")
	stranger := e.register("x@example.de", "X", "Fremde")
	base := "/api/families/" + fid + "/shopping/lists"
	all := func(token string) []obj {
		t.Helper()
		var out struct {
			Items []obj `json:"items"`
		}
		if err := e.getJSON("/api/activities", token, &out); err != nil {
			t.Fatal(err)
		}
		return out.Items
	}
	comments := func(token, list string) []obj {
		t.Helper()
		var out []obj
		if err := e.getJSON(base+"/"+list+"/comments", token, &out); err != nil {
			t.Fatal(err)
		}
		return out
	}

	// For Ben, visible to everyone: Carl may only look, and comment.
	list := e.expect(201, "POST", base, owner, obj{"name": "Grillfest", "assignees_all": false, "assignee_ids": []string{benID}, "visibility": "all"})["id"].(string)
	if got := comments(ben, list); len(got) != 0 {
		t.Fatalf("empty: %v", got)
	}
	e.expect(400, "POST", base+"/"+list+"/comments", carl, obj{"body": "  "})
	got := e.expect(201, "POST", base+"/"+list+"/comments", carl, obj{"body": " Bringe Salat mit "})
	if got["body"] != "Bringe Salat mit" || got["author_id"] != carlID {
		t.Fatalf("comment: %v", got)
	}
	e.expect(201, "POST", base+"/"+list+"/comments", ben, obj{"body": "Super"})
	if got := comments(owner, list); len(got) != 2 || got[0]["body"] != "Bringe Salat mit" || got[1]["body"] != "Super" {
		t.Fatalf("in order: %v", got)
	}

	// Anna made it, Ben is on it; Carl hears of Ben's answer, having commented.
	if got := all(owner)[0]; got["kind"] != "list_comment" || got["ref_id"] != list || got["title"] != "Grillfest" ||
		strings.Join(toStrings(got["names"]), "") != "Super" {
		t.Fatalf("anna: %v", got)
	}
	if got := all(carl)[0]; got["kind"] != "list_comment" || got["own"] != false || got["actor_id"] != benID {
		t.Fatalf("carl: %v", got)
	}
	if got := all(ben)[0]; got["kind"] != "list_comment" || got["own"] != true {
		t.Fatalf("ben's own: %v", got)
	}
	// Counted on the overview, hidden from older apps, closed to others.
	var lists []obj
	if err := e.getJSON("/api/families/"+fid+"/shopping/lists", ben, &lists); err != nil || len(lists) != 1 || lists[0]["comment_count"] != float64(2) {
		t.Fatalf("overview: %v %v", lists, err)
	}
	if legacy, _ := e.activities(owner, fid, ""); slices.ContainsFunc(legacy, func(a obj) bool { return a["kind"] == "list_comment" }) {
		t.Fatalf("legacy: %v", legacy)
	}
	e.expect(404, "GET", base+"/"+list+"/comments", stranger, nil)
	e.expect(404, "POST", base+"/"+list+"/comments", stranger, obj{"body": "Hallo"})
}
