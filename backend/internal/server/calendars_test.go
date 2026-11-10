package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func (e *testEnv) entries(token, fid, from, to string) []obj {
	e.t.Helper()
	query := url.Values{"from": {from}, "to": {to}}.Encode()
	var out []obj
	if err := e.getJSON("/api/families/"+fid+"/calendar-entries?"+query, token, &out); err != nil {
		e.t.Fatal(err)
	}
	return out
}

func titlesOf(entries []obj) string {
	out := []string{}
	for _, entry := range entries {
		out = append(out, entry["title"].(string))
	}
	return strings.Join(out, ",")
}

func TestEventComments(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	base := "/api/families/" + fid
	ben, benID := e.addMember(fid, owner, "b@example.de")
	cara, _ := e.addMember(fid, owner, "c@example.de")
	id := e.expect(201, "POST", base+"/events", ben, eventBody(obj{
		"visibility": "participants", "participants_all": false, "participant_ids": []any{benID},
	}))["id"].(string)
	path := base + "/events/" + id

	e.expect(404, "POST", path+"/comments", cara, obj{"body": "Hallo"})
	e.expect(400, "POST", path+"/comments", ben, obj{"body": "   "})
	if got := e.expect(201, "POST", path+"/comments", ben, obj{"body": " Hallo "}); got["body"] != "Hallo" || got["author_name"] != "B" {
		t.Errorf("comment: %v", got)
	}
	comments := e.expect(200, "GET", path, ben, nil)["comments"].([]any)
	if len(comments) != 1 || comments[0].(obj)["body"] != "Hallo" {
		t.Errorf("comments: %v", comments)
	}
	e.expect(204, "DELETE", path, ben, nil)
}

func TestEventRemembersLastChange(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	base := "/api/families/" + fid
	ben, _ := e.addMember(fid, owner, "b@example.de")
	id := e.expect(201, "POST", base+"/events", ben, eventBody(nil))["id"].(string)
	path := base + "/events/" + id
	if got := e.expect(200, "GET", path, owner, nil); got["updated_at"] == nil || got["updated_by_name"] != "B" {
		t.Errorf("after creating: %v", got)
	}
	e.expect(204, "PUT", path, owner, eventBody(nil))
	if got := e.expect(200, "GET", path, owner, nil); got["updated_by_name"] != "A" {
		t.Errorf("after editing: %v", got)
	}
}

func TestOnlyCreatorAndManagersChangeEvents(t *testing.T) {
	e := newEnv(t)
	manager := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(manager)
	base := "/api/families/" + fid
	ben, _ := e.addMember(fid, manager, "b@example.de")
	cara, caraID := e.addMember(fid, manager, "c@example.de")
	// An admin who is not a manager is no exception: it goes by the role.
	dora, doraID := e.addMember(fid, manager, "d@example.de")
	e.setRole(fid, manager, doraID, "user", true)

	event := func(extra obj) string {
		return e.expect(201, "POST", base+"/events", ben, eventBody(extra))["id"].(string)
	}
	id := event(obj{"participants_all": false, "participant_ids": []any{caraID}})
	path := base + "/events/" + id

	// Not for others, even if they take part or are admins.
	for _, other := range []string{cara, dora} {
		e.expect(403, "PUT", path, other, eventBody(nil))
		e.expect(403, "DELETE", path, other, nil)
		status, _ := e.uploadTo(other, base+"/events/"+id+"/attachments", "plan.png", pngHeader)
		if status != 403 {
			t.Errorf("upload: %d", status)
		}
	}

	// What they could do with it before still works.
	e.expect(200, "GET", path, cara, nil)
	e.expect(201, "POST", path+"/comments", cara, obj{"body": "Danke"})
	e.expect(201, "POST", path+"/copy", cara, obj{})
	e.expect(200, "GET", path+"/ics", cara, nil)

	// Their own copy is theirs.
	var copied string
	if err := e.server.db.QueryRow(`SELECT id FROM events WHERE family_id = ? AND created_by = ?`, fid, caraID).Scan(&copied); err != nil {
		t.Fatal(err)
	}
	e.expect(204, "PUT", base+"/events/"+copied, cara, eventBody(nil))
	e.expect(204, "DELETE", base+"/events/"+copied, cara, nil)

	// The creator and the manager can.
	e.expect(204, "PUT", path, ben, eventBody(obj{"participants_all": false, "participant_ids": []any{caraID}}))
	e.expect(204, "PUT", path, manager, eventBody(obj{"participants_all": false, "participant_ids": []any{caraID}}))
	status, file := e.uploadTo(ben, base+"/events/"+id+"/attachments", "plan.png", pngHeader)
	if status != 201 {
		t.Fatalf("upload: %d %v", status, file)
	}
	attachment := base + "/events/" + id + "/attachments/" + file["id"].(string)
	e.expect(403, "DELETE", attachment, cara, nil)
	e.expect(200, "POST", attachment+"/link", cara, nil)
	e.expect(204, "DELETE", attachment, manager, nil)

	// The calendar says so, per person.
	editable := func(token string) any {
		for _, entry := range e.entries(token, fid, "2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z") {
			if entry["id"] == id {
				return entry["editable"]
			}
		}
		return nil
	}
	if editable(ben) != true || editable(manager) != true || editable(cara) != false || editable(dora) != false {
		t.Errorf("editable: ben %v, manager %v, cara %v, dora %v", editable(ben), editable(manager), editable(cara), editable(dora))
	}

	// Handing it over hands over the right as well.
	e.expect(204, "PUT", path+"/creator", manager, obj{"user_id": caraID})
	e.expect(403, "PUT", path, ben, eventBody(nil))
	e.expect(204, "PUT", path, cara, eventBody(obj{"participants_all": false, "participant_ids": []any{caraID}}))

	// Without a creator it is up to the managers.
	if _, err := e.server.db.Exec(`UPDATE events SET created_by = NULL WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	e.expect(403, "DELETE", path, cara, nil)
	e.expect(204, "DELETE", path, manager, nil)
}

func TestEventCopies(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	base := "/api/families/" + fid
	ben, benID := e.addMember(fid, owner, "b@example.de")
	cara, _ := e.addMember(fid, owner, "c@example.de")
	id := e.expect(201, "POST", base+"/events", ben, eventBody(obj{
		"title": "Geheim", "start_local": "2026-03-10T10:00", "end_local": "2026-03-10T11:30", "timezone": "Europe/Berlin",
		"visibility": "participants", "participants_all": false, "participant_ids": []any{benID}, "reminders": []any{15},
	}))["id"].(string)
	copyPath := base + "/events/" + id + "/copy"

	e.expect(404, "POST", copyPath, cara, obj{})
	e.expect(400, "POST", copyPath, ben, obj{"days": []any{"gestern"}})
	tooMany := []any{}
	for i := 1; i <= 11; i++ {
		tooMany = append(tooMany, fmt.Sprintf("2026-04-%02d", i))
	}
	e.expect(400, "POST", copyPath, ben, obj{"days": tooMany})

	// Same time of day, across the change to summer time.
	ids := e.expect(201, "POST", copyPath, ben, obj{"days": []any{"2026-04-01", "2026-04-03"}})["ids"].([]any)
	if len(ids) != 2 {
		t.Fatalf("ids: %v", ids)
	}
	got := e.expect(200, "GET", base+"/events/"+ids[0].(string), ben, nil)
	if got["start_local"] != "2026-04-01T10:00" || got["end_local"] != "2026-04-01T11:30" || got["created_by"] != benID ||
		got["visibility"] != "participants" || len(got["participant_ids"].([]any)) != 1 || len(got["reminders"].([]any)) != 1 {
		t.Errorf("copy: %v", got)
	}

	// A duplicate stays as it is.
	duplicate := e.expect(201, "POST", copyPath, ben, obj{})["ids"].([]any)[0].(string)
	if got := e.expect(200, "GET", base+"/events/"+duplicate, ben, nil); got["start_local"] != "2026-03-10T10:00" {
		t.Errorf("duplicate: %v", got)
	}

	// Into another family only as a member, and without anyone who is not there.
	other := e.register("d@example.de", "D", "G")
	otherFamily := e.firstFamily(other)
	e.expect(404, "POST", copyPath, ben, obj{"family_id": otherFamily})
	e.expect(201, "POST", "/api/families/"+otherFamily+"/invitations", other, obj{"email": "b@example.de", "role": "user"})
	e.expect(200, "GET", "/api/me", ben, nil) // accepts the invitation
	moved := e.expect(201, "POST", copyPath, ben, obj{"family_id": otherFamily})["ids"].([]any)[0].(string)
	if got := e.expect(200, "GET", "/api/families/"+otherFamily+"/events/"+moved, ben, nil); got["category_id"] != nil ||
		got["visibility"] != "participants" || len(got["participant_ids"].([]any)) != 1 {
		t.Errorf("in other family: %v", got)
	}
	// Whoever could not see it there still cannot.
	eve, _ := e.addMember(otherFamily, other, "e@example.de")
	e.expect(404, "GET", "/api/families/"+otherFamily+"/events/"+moved, eve, nil)
}

func TestEventICS(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	base := "/api/families/" + fid
	ben, benID := e.addMember(fid, owner, "b@example.de")
	cara, _ := e.addMember(fid, owner, "c@example.de")
	id := e.expect(201, "POST", base+"/events", ben, eventBody(obj{
		"title": "Zahnarzt", "visibility": "participants", "participants_all": false, "participant_ids": []any{benID},
	}))["id"].(string)
	path := base + "/events/" + id + "/ics"
	e.expect(404, "GET", path, cara, nil)
	got := e.expect(200, "GET", path, ben, nil)
	content := got["content"].(string)
	if got["filename"] != "termin.ics" || !strings.Contains(content, "BEGIN:VEVENT") || !strings.Contains(content, "SUMMARY:Zahnarzt") {
		t.Errorf("ics: %v", got)
	}
}

func TestEntryICS(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	path := "/api/families/" + e.firstFamily(token) + "/calendar-entries/ics"

	// Whole days end the next day in iCalendar, as for everything else shared.
	day := e.expect(200, "POST", path, token, obj{
		"title": "Buß- und Bettag (Sachsen)", "all_day": true, "start_local": "2026-11-18T00:00", "end_local": "2026-11-18T23:59",
	})["content"].(string)
	for _, want := range []string{"SUMMARY:Buß- und Bettag (Sachsen)", "DTSTART;VALUE=DATE:20261118", "DTEND;VALUE=DATE:20261119"} {
		if !strings.Contains(day, want) {
			t.Errorf("no %q in:\n%s", want, day)
		}
	}
	timed := e.expect(200, "POST", path, token, obj{
		"title": "Probe", "location": "Halle", "start_at": "2026-11-18T09:00:00Z", "end_at": "2026-11-18T10:00:00Z",
	})["content"].(string)
	for _, want := range []string{"DTSTART;TZID=UTC:20261118T090000", "DTEND;TZID=UTC:20261118T100000", "LOCATION:Halle"} {
		if !strings.Contains(timed, want) {
			t.Errorf("no %q in:\n%s", want, timed)
		}
	}
	e.expect(400, "POST", path, token, obj{"title": " ", "start_at": "2026-11-18T09:00:00Z", "end_at": "2026-11-18T10:00:00Z"})
	e.expect(400, "POST", path, token, obj{"title": "Kaputt", "start_at": "gestern", "end_at": "heute"})
	e.expect(404, "POST", "/api/families/nix/calendar-entries/ics", token, obj{"title": "T"})
}

func TestCalendarPrefsNameTheColorOfTheCalendar(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(token)

	got := e.expect(200, "GET", base+"/calendar-prefs", token, nil)
	if got["calendar_color"] != "#BBDEFB" || got["view"] != "agenda" {
		t.Errorf("start: %v", got)
	}
	e.expect(204, "PUT", base+"/calendars/family", token, obj{"enabled": true, "color": "#D32F2F"})
	if got := e.expect(200, "GET", base+"/calendar-prefs", token, nil); got["calendar_color"] != "#D32F2F" {
		t.Errorf("own color: %v", got)
	}
	// The app sends back what it got, which must not get in the way.
	got["view"] = "week"
	e.expect(204, "PUT", base+"/calendar-prefs", token, got)
}

// setRole gives an invited member the role and admin flag these tests are about.
func (e *testEnv) setRole(fid, admin, id, role string, isAdmin bool) {
	e.t.Helper()
	e.expect(204, "PUT", "/api/families/"+fid+"/members/"+id, admin, obj{"role": role, "is_admin": isAdmin})
}

func TestManagerGetsAllEventsOnlyWhenAsked(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	base := "/api/families/" + fid
	ben, benID := e.addMember(fid, owner, "b@example.de")
	manager, managerID := e.addMember(fid, owner, "m@example.de")
	e.setRole(fid, owner, managerID, "manager", false)
	admin, adminID := e.addMember(fid, owner, "n@example.de")
	e.setRole(fid, owner, adminID, "user", true)

	secret := e.expect(201, "POST", base+"/events", ben, eventBody(obj{
		"title": "Geheim", "visibility": "participants", "participants_all": false, "participant_ids": []any{benID},
	}))["id"].(string)
	e.expect(201, "POST", base+"/events", ben, eventBody(obj{
		"title": "Offen", "participants_all": false, "participant_ids": []any{benID},
	}))
	from, to := "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z"
	query := url.Values{"from": {from}, "to": {to}, "all": {"1"}}.Encode()

	// The role alone lists nothing more.
	if got := titlesOf(e.entries(manager, fid, from, to)); got != "Offen" {
		t.Errorf("manager without asking: %s", got)
	}

	var all []obj
	if err := e.getJSON(base+"/calendar-entries?"+query, manager, &all); err != nil {
		t.Fatal(err)
	}
	editable := map[string]any{}
	for _, entry := range all {
		editable[entry["title"].(string)] = entry["editable"]
	}
	if len(all) != 2 || editable["Geheim"] != true || editable["Offen"] != true {
		t.Errorf("manager asking: %v", editable)
	}
	// The event behind the entry is open as well, attachments included.
	path := base + "/events/" + secret
	e.expect(200, "GET", path, manager, nil)
	e.expect(204, "PUT", path, manager, eventBody(obj{
		"title": "Geheim 2", "visibility": "participants", "participants_all": false, "participant_ids": []any{benID},
	}))
	if status, out := e.uploadTo(manager, path+"/attachments", "plan.png", pngHeader); status != 201 {
		t.Errorf("upload: %d %v", status, out)
	}

	// The admin flag does not give any of that, and neither does being a member.
	for name, token := range map[string]string{"admin": admin, "member": ben} {
		e.expect(403, "GET", base+"/calendar-entries?"+query, token, nil)
		if name == "admin" {
			e.expect(404, "GET", path, token, nil)
			e.expect(404, "PUT", path, token, eventBody(nil))
		}
	}
	if got := titlesOf(e.entries(ben, fid, from, to)); !strings.Contains(got, "Geheim 2") {
		t.Errorf("participant: %s", got)
	}
	e.expect(204, "DELETE", path, manager, nil)
}

func TestManagersHandOverEvents(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	base := "/api/families/" + fid
	ownerID := e.expect(200, "GET", "/api/me", owner, nil)["id"]
	ben, benID := e.addMember(fid, owner, "b@example.de")
	cara, caraID := e.addMember(fid, owner, "c@example.de")
	manager, managerID := e.addMember(fid, owner, "m@example.de")
	e.setRole(fid, owner, managerID, "manager", false)
	admin, adminID := e.addMember(fid, owner, "n@example.de")
	e.setRole(fid, owner, adminID, "user", true)
	outsider := e.register("d@example.de", "D", "G")
	outsiderID := e.expect(200, "GET", "/api/me", outsider, nil)["id"]

	id := e.expect(201, "POST", base+"/events", ben, eventBody(obj{
		"title": "Geheim", "visibility": "participants", "participants_all": false, "participant_ids": []any{caraID},
	}))["id"].(string)
	path := base + "/events/" + id
	creator := path + "/creator"
	if got := e.expect(200, "GET", path, ben, nil); got["created_by"] != benID || got["creator_name"] == "" {
		t.Errorf("creator: %v", got)
	}

	e.expect(403, "PUT", creator, ben, obj{"user_id": benID})
	e.expect(400, "PUT", creator, owner, obj{"user_id": outsiderID})
	e.expect(400, "PUT", creator, owner, obj{"user_id": ""})
	e.expect(404, "PUT", base+"/events/nix/creator", owner, obj{"user_id": ownerID})
	// The admin flag alone is not enough.
	e.expect(403, "PUT", creator, admin, obj{"user_id": adminID})

	e.expect(204, "PUT", creator, manager, obj{"user_id": adminID})
	if got := e.expect(200, "GET", path, admin, nil); got["created_by"] != adminID {
		t.Errorf("after handing over: %v", got)
	}
	// Whoever had it is neither creator nor participant any more.
	e.expect(404, "GET", path, ben, nil)
	e.expect(200, "GET", path, cara, nil)
	// Not even as the creator of the event.
	e.expect(403, "PUT", creator, admin, obj{"user_id": benID})
	e.expect(204, "PUT", creator, manager, obj{"user_id": benID})

	// A creator who left has no name any more.
	e.expect(204, "DELETE", base+"/members/"+benID, owner, nil)
	if got := e.expect(200, "GET", path, cara, nil); got["creator_name"] != "" {
		t.Errorf("after leaving: %v", got)
	}
}

func calendarNamed(t *testing.T, data obj, key string) obj {
	t.Helper()
	for _, cal := range data["calendars"].([]any) {
		if cal.(obj)["key"] == key {
			return cal.(obj)
		}
	}
	t.Fatalf("no calendar %s in %v", key, data["calendars"])
	return nil
}

func TestCalendarListAndDefaults(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "Müller")
	base := "/api/families/" + e.firstFamily(token)
	data := e.expect(200, "GET", base+"/calendars", token, nil)

	keys := []string{}
	for _, cal := range data["calendars"].([]any) {
		keys = append(keys, cal.(obj)["key"].(string))
		if cal.(obj)["enabled"] != true {
			t.Errorf("not enabled: %v", cal)
		}
	}
	if strings.Join(keys, ",") != "family,tasks,school,holidays,birthdays,special" {
		t.Errorf("keys: %v", keys)
	}
	if family := calendarNamed(t, data, "family"); family["name"] != "Müller" || family["subtitle"] != "Standardkalender" || family["shareable"] != true {
		t.Errorf("family: %v", family)
	}
	if school := calendarNamed(t, data, "school"); school["shareable"] != true {
		t.Errorf("school: %v", school)
	}
	prefs := data["prefs"].(obj)
	if prefs["week_start"] != "monday" || prefs["week_numbers"] != false || prefs["default_reminder"] != float64(0) || prefs["view"] != "agenda" {
		t.Errorf("prefs: %v", prefs)
	}
	if data["cleanup_months"] != float64(12) {
		t.Errorf("cleanup: %v", data["cleanup_months"])
	}
	for kind, color := range calendarColors {
		if !isBaseColor(color) {
			t.Errorf("%s: %s is no base color", kind, color)
		}
	}
	if len(data["states"].([]any)) != 16 {
		t.Errorf("states: %v", data["states"])
	}

	// A calendar remembers its choice per user and family.
	e.expect(204, "PUT", base+"/calendars/tasks", token, obj{"enabled": false, "color": "#D32F2F"})
	tasks := calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), "tasks")
	if tasks["enabled"] != false || tasks["color"] != "#D32F2F" {
		t.Errorf("tasks: %v", tasks)
	}
	// Only colors of the family's table, base or custom, and never none.
	e.expect(400, "PUT", base+"/calendars/tasks", token, obj{"enabled": true, "color": "#010203"})
	e.expect(400, "PUT", base+"/calendars/tasks", token, obj{"enabled": true, "color": ""})
	e.expect(201, "POST", base+"/colors", token, obj{"color": "#5C7CFA", "label": "Eigen"})
	e.expect(204, "PUT", base+"/calendars/tasks", token, obj{"enabled": true, "color": "#5C7CFA"})
	if got := calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), "tasks"); got["color"] != "#5C7CFA" {
		t.Errorf("custom color: %v", got)
	}
	e.expect(204, "PUT", base+"/calendars/tasks", token, obj{"enabled": true, "color": "#D32F2F"})
	// A family may start with a color that is not in the table, which can stay when only toggling.
	if _, err := e.server.db.Exec(`UPDATE families SET default_color = '#010203' WHERE id = ?`, e.firstFamily(token)); err != nil {
		t.Fatal(err)
	}
	e.expect(204, "PUT", base+"/calendars/family", token, obj{"enabled": true, "color": "#010203"})

	e.expect(404, "PUT", base+"/calendars/unbekannt", token, obj{"enabled": true, "color": "#D32F2F"})
	e.expect(400, "PUT", base+"/calendars/school", token, obj{"enabled": true, "color": "#F57C00", "regions": []any{"DE-XX"}})
	e.expect(204, "PUT", base+"/calendars/school", token, obj{"enabled": true, "color": "#F57C00", "regions": []any{"DE-BY", "DE-HE"}})
	school := calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), "school")
	if school["subtitle"] != "Bayern, Hessen" {
		t.Errorf("school subtitle: %v", school)
	}
}

func TestCalendarColorsAreSharedAndForManagers(t *testing.T) {
	e := newEnv(t)
	manager := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(manager)
	base := "/api/families/" + fid
	ben, _ := e.addMember(fid, manager, "b@example.de")
	// An admin who is not a manager is no exception: it goes by the role.
	dora, doraID := e.addMember(fid, manager, "d@example.de")
	e.setRole(fid, manager, doraID, "user", true)
	const red = "#D32F2F"
	colorOf := func(token, key string) any {
		return calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), key)["color"]
	}

	for _, key := range []string{"family", "tasks", "school", "holidays", "birthdays", "special"} {
		path := base + "/calendars/" + key
		if got := calendarNamed(t, e.expect(200, "GET", base+"/calendars", ben, nil), key); got["color_shared"] != true {
			t.Errorf("%s: %v", key, got)
		}
		before := colorOf(ben, key)
		e.expect(403, "PUT", path, ben, obj{"enabled": true, "color": red})
		e.expect(403, "PUT", path, dora, obj{"enabled": true, "color": red})
		if got := colorOf(manager, key); got != before {
			t.Errorf("%s changed by others: %v", key, got)
		}
		e.expect(204, "PUT", path, manager, obj{"enabled": true, "color": red})
		for _, token := range []string{manager, ben, dora} {
			if got := colorOf(token, key); got != red {
				t.Errorf("%s: %v", key, got)
			}
		}
	}
	if got := e.expect(200, "GET", base+"/calendar-prefs", ben, nil)["calendar_color"]; got != red {
		t.Errorf("calendar color for the form: %v", got)
	}
	e.expect(201, "POST", base+"/events", manager, eventBody(nil))
	for _, entry := range e.entries(ben, fid, "2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z") {
		if entry["source"] == "family" && entry["color"] != red {
			t.Errorf("entry: %v", entry)
		}
	}

	// Showing or hiding stays personal and needs no right, with or without the color.
	e.expect(204, "PUT", base+"/calendars/tasks", ben, obj{"enabled": false})
	e.expect(204, "PUT", base+"/calendars/school", ben, obj{"enabled": true, "color": red, "regions": []any{"DE-BY"}})
	if got := calendarNamed(t, e.expect(200, "GET", base+"/calendars", ben, nil), "tasks"); got["enabled"] != false || got["color"] != red {
		t.Errorf("ben: %v", got)
	}
	if got := calendarNamed(t, e.expect(200, "GET", base+"/calendars", manager, nil), "tasks"); got["enabled"] != true {
		t.Errorf("manager: %v", got)
	}
	if got := calendarNamed(t, e.expect(200, "GET", base+"/calendars", manager, nil), "school"); fmt.Sprint(got["regions"]) != "[DE-BW]" {
		t.Errorf("regions are personal: %v", got)
	}

	// A stale list of the app cannot bring back the old color.
	e.expect(204, "PUT", base+"/calendars/tasks", manager, obj{"enabled": true, "color": "#1565C0"})
	e.expect(204, "PUT", base+"/calendars/tasks", ben, obj{"enabled": true})
	if got := colorOf(ben, "tasks"); got != "#1565C0" {
		t.Errorf("after toggling: %v", got)
	}

	// Another family has its own.
	other := e.register("o@example.de", "O", "Anders")
	otherBase := "/api/families/" + e.firstFamily(other)
	if got := calendarNamed(t, e.expect(200, "GET", otherBase+"/calendars", other, nil), "tasks")["color"]; got != calendarColors["tasks"] {
		t.Errorf("other family: %v", got)
	}
}

func TestCalendarsStartWithGermanyAndBadenWuerttemberg(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(token)
	school := func() obj { return calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), "school") }

	data := e.expect(200, "GET", base+"/calendars", token, nil)
	if got := fmt.Sprint(data["prefs"].(obj)["holiday_countries"]); got != "[DE]" {
		t.Errorf("countries: %s", got)
	}
	if got := school(); fmt.Sprint(got["regions"]) != "[DE-BW]" || got["subtitle"] != "Baden-Württemberg" {
		t.Errorf("school: %v", got)
	}

	// Only switching keeps it, with or without saying so.
	e.expect(204, "PUT", base+"/calendars/school", token, obj{"enabled": false})
	if got := school(); got["enabled"] != false || fmt.Sprint(got["regions"]) != "[DE-BW]" {
		t.Errorf("after switching: %v", got)
	}
	// Taking everything out stays that way, also for the countries.
	e.expect(204, "PUT", base+"/calendars/school", token, obj{"enabled": true, "regions": []any{}})
	if got := school(); got["regions"] != nil || got["subtitle"] != "Kein Bundesland ausgewählt" {
		t.Errorf("no state: %v", got)
	}
	prefs := e.expect(200, "GET", base+"/calendar-prefs", token, nil)
	prefs["holiday_countries"] = []any{}
	e.expect(204, "PUT", base+"/calendar-prefs", token, prefs)
	if got := calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), "holidays"); got["subtitle"] != "Kein Land ausgewählt" {
		t.Errorf("no country: %v", got)
	}

	// Per family: in another one the same person starts anew.
	e.expect(201, "POST", "/api/families", token, obj{"name": "Zweite"})
	other := "/api/families/" + e.firstFamily(token)
	if other == base {
		t.Fatal("no new family selected")
	}
	if got := calendarNamed(t, e.expect(200, "GET", other+"/calendars", token, nil), "school"); fmt.Sprint(got["regions"]) != "[DE-BW]" {
		t.Errorf("other family: %v", got)
	}
}

func TestCustomColorsInCalendars(t *testing.T) {
	e := newEnv(t)
	manager := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(manager)
	base := "/api/families/" + fid
	ben, _ := e.addMember(fid, manager, "b@example.de")
	foreign := e.register("o@example.de", "O", "Anders")
	foreignID := e.firstFamily(foreign)
	e.expect(201, "POST", "/api/families/"+foreignID+"/invitations", foreign, obj{"email": "b@example.de", "role": "user"})
	e.expect(200, "GET", "/api/me", ben, nil) // accepts the invitation
	key := "family:" + foreignID
	color := func(token, name string) any {
		return calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), name)["color"]
	}

	shared := e.expect(201, "POST", base+"/colors", manager, obj{"color": "#5C7CFA", "label": "Gemeinsam"})["id"].(string)
	personal := e.expect(201, "POST", base+"/colors", manager, obj{"color": "#112233", "label": "Eigen"})["id"].(string)
	e.expect(204, "PUT", base+"/calendars/tasks", manager, obj{"enabled": true, "color": "#5C7CFA"})
	e.expect(204, "PUT", base+"/calendars/"+key, ben, obj{"enabled": true, "color": "#112233"})

	// A color of another family is none of this one's.
	e.expect(201, "POST", "/api/families/"+foreignID+"/colors", foreign, obj{"color": "#445566", "label": "Fremd"})
	e.expect(400, "PUT", base+"/calendars/"+key, ben, obj{"enabled": true, "color": "#445566"})

	// Changing a color moves both along.
	e.expect(204, "PUT", base+"/colors/"+shared, manager, obj{"color": "#5C7CFB", "label": "Gemeinsam"})
	e.expect(204, "PUT", base+"/colors/"+personal, manager, obj{"color": "#112234", "label": "Eigen"})
	if got := color(ben, "tasks"); got != "#5C7CFB" {
		t.Errorf("shared after moving: %v", got)
	}
	if got := color(ben, key); got != "#112234" {
		t.Errorf("personal after moving: %v", got)
	}

	// A shared calendar keeps its color from being deleted, and the list says so.
	e.expect(409, "DELETE", base+"/colors/"+shared, manager, nil)
	for _, entry := range e.expect(200, "GET", base+"/colors", manager, nil)["custom"].([]any) {
		if want := entry.(obj)["id"] == shared; entry.(obj)["used"] != want {
			t.Errorf("used: %v", entry)
		}
	}
	e.expect(204, "PUT", base+"/calendars/tasks", manager, obj{"enabled": true, "color": "#D32F2F"})
	e.expect(204, "DELETE", base+"/colors/"+shared, manager, nil)

	// Someone's own choice does not, and falls back to the default.
	e.expect(204, "DELETE", base+"/colors/"+personal, manager, nil)
	if got := color(ben, key); got != calendarColors["other_family"] {
		t.Errorf("personal after deleting: %v", got)
	}
	e.expect(404, "DELETE", base+"/colors/"+personal, manager, nil)
}

func TestPersonalCalendarsKeepTheirOwnColor(t *testing.T) {
	e := newEnv(t)
	manager := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(manager)
	base := "/api/families/" + fid
	ben, _ := e.addMember(fid, manager, "b@example.de")
	foreign := e.register("o@example.de", "O", "Anders")
	foreignID := e.firstFamily(foreign)
	e.expect(201, "POST", "/api/families/"+foreignID+"/invitations", foreign, obj{"email": "b@example.de", "role": "user"})
	e.expect(200, "GET", "/api/me", ben, nil) // accepts the invitation
	key := "family:" + foreignID

	got := calendarNamed(t, e.expect(200, "GET", base+"/calendars", ben, nil), key)
	if got["color_shared"] != false {
		t.Errorf("calendar: %v", got)
	}
	// In the other family Ben is no manager, and here not one either.
	e.expect(204, "PUT", base+"/calendars/"+key, ben, obj{"enabled": true, "color": "#D32F2F"})
	if got := calendarNamed(t, e.expect(200, "GET", base+"/calendars", ben, nil), key); got["color"] != "#D32F2F" {
		t.Errorf("own color: %v", got)
	}
}

func TestCalendarPrefs(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(token)
	good := func(extra obj) obj {
		body := obj{"week_numbers": true, "week_start": "sunday", "default_reminder": 30, "holiday_countries": []any{"AT", "DE", "AT"}, "view": "week"}
		for k, v := range extra {
			body[k] = v
		}
		return body
	}
	e.expect(204, "PUT", base+"/calendar-prefs", token, good(nil))
	prefs := e.expect(200, "GET", base+"/calendar-prefs", token, nil)
	if prefs["week_numbers"] != true || prefs["week_start"] != "sunday" || prefs["default_reminder"] != float64(30) || prefs["view"] != "week" {
		t.Errorf("prefs: %v", prefs)
	}
	if fmt.Sprint(prefs["holiday_countries"]) != "[AT DE]" {
		t.Errorf("countries: %v", prefs["holiday_countries"])
	}
	// One holiday calendar for all countries.
	data := e.expect(200, "GET", base+"/calendars", token, nil)
	if got := calendarNamed(t, data, "holidays"); !strings.Contains(got["subtitle"].(string), ",") {
		t.Errorf("holidays: %v", got)
	}

	for _, bad := range []obj{
		{"week_start": "tuesday"}, {"view": "year"}, {"default_reminder": -1}, {"default_reminder": maxReminderMinutes + 1},
		{"holiday_countries": []any{"germany"}},
	} {
		e.expect(400, "PUT", base+"/calendar-prefs", token, good(bad))
	}
}

func TestCalendarEntriesFromAllSources(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid
	from, to := "2026-03-01T00:00:00Z", "2026-04-01T00:00:00Z"

	e.expect(201, "POST", base+"/events", token, eventBody(obj{"title": "Termin", "start_local": "2026-03-10T10:00", "end_local": "2026-03-10T11:00"}))
	listID := e.expect(201, "POST", base+"/lists", token, obj{"name": "L", "kind": "tasks"})["id"].(string)
	e.expect(201, "POST", base+"/lists/"+listID+"/items", token, obj{"title": "Aufgabe", "due_date": "2026-03-11"})
	e.expect(201, "POST", base+"/lists/"+listID+"/items", token, obj{"title": "Ohne Datum"})
	shopping := e.expect(201, "POST", base+"/lists", token, obj{"name": "S", "kind": "shopping"})["id"].(string)
	e.expect(201, "POST", base+"/lists/"+shopping+"/items", token, obj{"title": "Milch", "due_date": "2026-03-11"})
	e.expect(201, "POST", base+"/special-days", token, obj{"title": "Oma", "kind": "birthday", "date": "1950-03-12", "yearly": true})
	e.expect(201, "POST", base+"/special-days", token, obj{"title": "Jahrestag", "kind": "memorial", "date": "2000-03-13", "yearly": true})
	e.expect(204, "PUT", base+"/profile", token, obj{"name": "Anna", "birthday": "1990-03-14"})

	got := e.entries(token, fid, from, to)
	if titlesOf(got) != "Termin,Aufgabe,Oma,Jahrestag,Geburtstag Anna" {
		t.Fatalf("entries: %s", titlesOf(got))
	}
	for _, entry := range got {
		if editable := entry["source"] == "family"; entry["editable"] != editable {
			t.Errorf("editable: %v", entry)
		}
	}
	if task := got[1]; task["all_day"] != true || task["start_local"] != "2026-03-11T00:00" || task["color"] != calendarColors["tasks"] {
		t.Errorf("task: %v", task)
	}

	// Disabling a calendar removes its entries, for this user only.
	e.expect(204, "PUT", base+"/calendars/special", token, obj{"enabled": false, "color": calendarColors["special"]})
	e.expect(204, "PUT", base+"/calendars/birthdays", token, obj{"enabled": false, "color": calendarColors["birthdays"]})
	if got := titlesOf(e.entries(token, fid, from, to)); got != "Termin,Aufgabe" {
		t.Errorf("after disabling: %s", got)
	}
	other, _ := e.addMember(fid, token, "b@example.de")
	if got := titlesOf(e.entries(other, fid, from, to)); !strings.Contains(got, "Jahrestag") {
		t.Errorf("other user: %s", got)
	}

	// The calendar color applies unless a category has its own.
	categories := e.expect(200, "GET", base+"/categories", token, nil)["categories"].([]any)
	important := categories[1].(obj)
	e.expect(201, "POST", base+"/events", token, eventBody(obj{
		"title": "Dringend", "category_id": important["id"], "start_local": "2026-03-20T10:00", "end_local": "2026-03-20T11:00",
	}))
	e.expect(204, "PUT", base+"/calendars/family", token, obj{"enabled": true, "color": "#1565C0"})
	for _, entry := range e.entries(token, fid, from, to) {
		want := "#1565C0"
		if entry["title"] == "Dringend" {
			want = important["color"].(string)
		}
		if entry["source"] == "family" && entry["color"] != want {
			t.Errorf("%s: %v", entry["title"], entry["color"])
		}
	}

	e.expect(400, "PUT", base+"/profile", token, obj{"name": "Anna", "birthday": "morgen"})
	e.expect(204, "PUT", base+"/profile", token, obj{"name": "Anna", "birthday": ""})
	if me := e.expect(200, "GET", base+"/profile", token, nil); me["birthday"] != "" {
		t.Errorf("birthday: %v", me)
	}
}

func TestYearlyDate(t *testing.T) {
	if got := yearlyDate("2000-02-29", 2027); got != "2027-02-28" {
		t.Errorf("not a leap year: %s", got)
	}
	if got := yearlyDate("2000-02-29", 2028); got != "2028-02-29" {
		t.Errorf("leap year: %s", got)
	}
}

// Other families appear read-only and only with what the user may see there.
func TestOtherFamiliesInCalendar(t *testing.T) {
	e := newEnv(t)
	anna := e.register("a@example.de", "A", "Eigene")
	own := e.firstFamily(anna)
	ben := e.register("b@example.de", "B", "Fremd")
	foreign := e.firstFamily(ben)
	cara := e.register("c@example.de", "C", "Dritte")
	third := e.firstFamily(cara)
	path := "/api/families/" + foreign

	body := func(title string, extra obj) obj {
		out := eventBody(obj{"title": title})
		for k, v := range extra {
			out[k] = v
		}
		return out
	}
	e.expect(201, "POST", "/api/families/"+third+"/events", cara, body("Nicht meiner", nil))
	e.expect(201, "POST", path+"/events", ben, body("Offen", nil))
	e.expect(201, "POST", path+"/events", ben, body("Geheim", obj{"visibility": "participants", "participants_all": false,
		"participant_ids": []any{e.expect(200, "GET", "/api/me", ben, nil)["id"]}}))
	from, to := "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z"

	if got := titlesOf(e.entries(anna, own, from, to)); got != "" {
		t.Errorf("before joining: %s", got)
	}
	e.expect(404, "PUT", "/api/families/"+own+"/calendars/family:"+foreign, anna, obj{"enabled": true, "color": "#D32F2F"})

	e.expect(201, "POST", path+"/invitations", ben, obj{"email": "a@example.de", "role": "user"})
	e.expect(200, "GET", "/api/me", anna, nil) // accepts the invitation

	got := e.entries(anna, own, from, to)
	if titlesOf(got) != "Offen" {
		t.Fatalf("after joining: %s", titlesOf(got))
	}
	if got[0]["editable"] != false || got[0]["source"] != "family:"+foreign || got[0]["source_name"] != "Fremd" {
		t.Errorf("entry: %v", got[0])
	}
	// The key of a family the user does not belong to stays out of reach.
	e.expect(404, "PUT", "/api/families/"+own+"/calendars/family:"+third, anna, obj{"enabled": true, "color": "#D32F2F"})
	e.expect(204, "PUT", "/api/families/"+own+"/calendars/family:"+foreign, anna, obj{"enabled": false, "color": calendarColors["other_family"]})
	if got := e.entries(anna, own, from, to); len(got) != 0 {
		t.Errorf("after disabling: %s", titlesOf(got))
	}
}

func TestHolidayCalendars(t *testing.T) {
	e := newEnv(t)
	var calls atomic.Int32
	down := atomic.Bool{}
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if down.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		name := func(text string) []obj {
			return []obj{{"language": "EN", "text": "x"}, {"language": "DE", "text": text}}
		}
		switch r.URL.Path {
		case "/Countries":
			json.NewEncoder(w).Encode([]obj{{"isoCode": "DE", "name": name("Deutschland")}, {"isoCode": "AT", "name": name("Österreich")}})
		case "/PublicHolidays":
			json.NewEncoder(w).Encode([]obj{
				{"id": "h1", "startDate": "2026-12-25", "endDate": "2026-12-25", "name": name("Weihnachten"), "nationwide": true},
				{"id": "h2", "startDate": "2026-12-26", "endDate": "2026-12-26", "name": name("Regional"), "nationwide": false,
					"subdivisions": []obj{{"code": "DE-SN", "shortName": "SN"}}},
			})
		case "/Subdivisions":
			json.NewEncoder(w).Encode([]obj{{"code": "DE-SN", "name": name("Sachsen")}})
		case "/SchoolHolidays":
			// The service repeats holidays that cross the new year in both years.
			json.NewEncoder(w).Encode([]obj{{"id": "s-" + r.URL.Query().Get("subdivisionCode"), "startDate": "2026-12-23", "endDate": "2027-01-09", "name": name("Weihnachtsferien")}})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer service.Close()
	e.server.holidaysURL = service.URL
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid
	from, to := "2026-12-20T00:00:00Z", "2027-01-05T00:00:00Z"

	// Someone new starts with Germany and Baden-Württemberg.
	if got := titlesOf(e.entries(token, fid, from, to)); got != "Weihnachtsferien (Baden-Württemberg),Weihnachten,Regional (Sachsen)" {
		t.Fatalf("to start with: %s", got)
	}
	// Choosing nothing is a choice, which stays.
	e.expect(204, "PUT", base+"/calendars/school", token, obj{"enabled": true, "regions": []any{}})
	if got := titlesOf(e.entries(token, fid, from, to)); got != "Weihnachten,Regional (Sachsen)" {
		t.Fatalf("no state chosen: %s", got)
	}
	names := e.expect(200, "GET", base+"/calendars", token, nil)["countries"].([]any)
	if names[0].(obj)["name"] != "Deutschland" {
		t.Errorf("countries: %v", names)
	}

	e.expect(204, "PUT", base+"/calendars/school", token, obj{"enabled": true, "color": calendarColors["school"], "regions": []any{"DE-BY"}})
	got := e.entries(token, fid, from, to)
	if titlesOf(got) != "Weihnachtsferien (Bayern),Weihnachten,Regional (Sachsen)" {
		t.Fatalf("school: %s", titlesOf(got))
	}
	if got[0]["start_local"] != "2026-12-23T00:00" || got[0]["end_local"] != "2027-01-09T23:59" || got[0]["all_day"] != true {
		t.Errorf("multi-day: %v", got[0])
	}
	// Two states are told apart.
	e.expect(204, "PUT", base+"/calendars/school", token, obj{"enabled": true, "color": calendarColors["school"], "regions": []any{"DE-BY", "DE-HE"}})
	if got := titlesOf(e.entries(token, fid, from, to)); !strings.Contains(got, "Weihnachtsferien (Bayern)") || !strings.Contains(got, "Weihnachtsferien (Hessen)") {
		t.Errorf("two states: %s", got)
	}

	// The answers are cached.
	before := calls.Load()
	e.entries(token, fid, from, to)
	if calls.Load() != before {
		t.Errorf("not cached: %d calls", calls.Load()-before)
	}

	// Old data survives an outage of the service, which ends up in the log.
	stale := time.Now().UTC().Add(-holidayCacheTTL - time.Hour).Format(timeFormat)
	if _, err := e.server.db.Exec(`UPDATE holiday_cache SET fetched_at = ?`, stale); err != nil {
		t.Fatal(err)
	}
	down.Store(true)
	if got := titlesOf(e.entries(token, fid, from, to)); !strings.Contains(got, "Weihnachten") {
		t.Errorf("during an outage: %s", got)
	}
	var logged int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM error_log WHERE message LIKE 'Feiertagsdienst%'`).Scan(&logged); err != nil || logged == 0 {
		t.Errorf("logged: %d %v", logged, err)
	}
}

func TestRegionalHolidayNamesWhereItHolds(t *testing.T) {
	names := map[string]string{"DE-SN": "Sachsen", "DE-BY": "Bayern", "DE-HE": "Hessen", "DE-BY-AU": "Augsburg"}
	sub := func(codes ...string) []holidaySubdivision {
		out := []holidaySubdivision{}
		for _, code := range codes {
			out = append(out, holidaySubdivision{Code: code, ShortName: code + "?"})
		}
		return out
	}
	for _, test := range []struct {
		codes              []string
		title, description string
	}{
		{[]string{"DE-SN"}, "Tag (Sachsen)", ""},
		{[]string{"DE-SN", "DE-BY", "DE-HE"}, "Tag (Bayern, Hessen, Sachsen)", ""},
		{[]string{"DE-SN", "DE-BY", "DE-HE", "DE-BY-AU"}, "Tag (4 Regionen)", "Gilt in: Augsburg, Bayern, Hessen, Sachsen"},
		// Without the service there is at least the short name.
		{[]string{"XX"}, "Tag (XX?)", ""},
		{nil, "Tag", ""},
	} {
		title, description := regionalHoliday("Tag", sub(test.codes...), names)
		if title != test.title || description != test.description {
			t.Errorf("%v: %q %q", test.codes, title, description)
		}
	}
}

const sampleICS = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" +
	"BEGIN:VTIMEZONE\r\nTZID:Europe/Berlin\r\nBEGIN:STANDARD\r\nDTSTART:19701025T030000\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n" +
	// Folded summary with escapes and an alarm with properties of the same names.
	"BEGIN:VEVENT\r\nUID:single\r\nSUMMARY:Lang\\, mit\r\n  Faltung\r\nDTSTART;TZID=Europe/Berlin:20260310T100000\r\nDTEND;TZID=Europe/Berlin:20260310T110000\r\n" +
	"LOCATION:Ort\\;1\r\nBEGIN:VALARM\r\nSUMMARY:Alarm\r\nDTSTART:19990101T000000Z\r\nEND:VALARM\r\nEND:VEVENT\r\n" +
	// All-day: the end is exclusive.
	"BEGIN:VEVENT\r\nUID:allday\r\nSUMMARY:Ganztag\r\nDTSTART;VALUE=DATE:20260311\r\nDTEND;VALUE=DATE:20260313\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:noend\r\nSUMMARY:Ohne Ende\r\nDTSTART;VALUE=DATE:20260314\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:duration\r\nSUMMARY:Dauer\r\nDTSTART:20260315T090000Z\r\nDURATION:PT1H30M\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:gone\r\nSUMMARY:Abgesagt\r\nSTATUS:CANCELLED\r\nDTSTART:20260316T090000Z\r\nEND:VEVENT\r\n" +
	// A weekly series with an exception, a moved date and a limit.
	"BEGIN:VEVENT\r\nUID:series\r\nSUMMARY:Serie\r\nDTSTART;TZID=Europe/Berlin:20260302T180000\r\nDTEND;TZID=Europe/Berlin:20260302T190000\r\n" +
	"RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=5\r\nEXDATE;TZID=Europe/Berlin:20260309T180000\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:series\r\nRECURRENCE-ID;TZID=Europe/Berlin:20260316T180000\r\nSUMMARY:Verschoben\r\nDTSTART;TZID=Europe/Berlin:20260317T180000\r\nDTEND;TZID=Europe/Berlin:20260317T190000\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:until\r\nSUMMARY:Bis\r\nDTSTART:20260601T090000Z\r\nRRULE:FREQ=DAILY;UNTIL=20260602T090000Z\r\nEND:VEVENT\r\n" +
	// What cannot be expressed keeps only its first date.
	"BEGIN:VEVENT\r\nUID:odd\r\nSUMMARY:Komplex\r\nDTSTART:20260701T090000Z\r\nRRULE:FREQ=MONTHLY;BYSETPOS=2;BYDAY=MO,TU\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:month\r\nSUMMARY:Monat\r\nDTSTART:20260805T090000Z\r\nRRULE:FREQ=MONTHLY;BYDAY=1WE\r\nEND:VEVENT\r\n" +
	"END:VCALENDAR\r\n"

func TestParseICS(t *testing.T) {
	berlin, _ := time.LoadLocation("Europe/Berlin")
	events := parseICS(sampleICS, berlin)
	find := func(title string) icsEvent {
		for _, event := range events {
			if event.title == title {
				return event
			}
		}
		t.Fatalf("no %s in %v", title, events)
		return icsEvent{}
	}
	if len(events) != 9 {
		t.Errorf("%d events", len(events))
	}
	single := find("Lang, mit Faltung")
	if single.location != "Ort;1" || single.start.UTC().Hour() != 9 || single.end.Sub(single.start) != time.Hour || single.start.Year() != 2026 {
		t.Errorf("single: %+v", single)
	}
	if all := find("Ganztag"); !all.allDay || all.end.Format("2006-01-02T15:04") != "2026-03-12T23:59" {
		t.Errorf("all-day end: %s", all.end)
	}
	if noEnd := find("Ohne Ende"); noEnd.end.Format("2006-01-02T15:04") != "2026-03-14T23:59" {
		t.Errorf("no end: %s", noEnd.end)
	}
	if duration := find("Dauer"); duration.end.Sub(duration.start) != 90*time.Minute {
		t.Errorf("duration: %s", duration.end)
	}

	dates := func(title, from, to string) string {
		out := []string{}
		for _, start := range find(title).occurrences(mustTime(t, from), mustTime(t, to)) {
			out = append(out, start.Format("01-02"))
		}
		return strings.Join(out, " ")
	}
	// Five from the start, minus the exception and the moved date.
	if got := dates("Serie", "2026-03-01T00:00:00Z", "2026-05-01T00:00:00Z"); got != "03-02 03-23 03-30" {
		t.Errorf("series: %s", got)
	}
	// Counting must not depend on the range.
	if got := dates("Serie", "2026-03-25T00:00:00Z", "2026-05-01T00:00:00Z"); got != "03-30" {
		t.Errorf("series later: %s", got)
	}
	if got := dates("Bis", "2026-06-01T00:00:00Z", "2026-06-10T00:00:00Z"); got != "06-01 06-02" {
		t.Errorf("until: %s", got)
	}
	if got := dates("Komplex", "2026-07-01T00:00:00Z", "2026-12-01T00:00:00Z"); got != "07-01" {
		t.Errorf("unsupported rule: %s", got)
	}
	if got := dates("Monat", "2026-08-01T00:00:00Z", "2026-10-31T00:00:00Z"); got != "08-05 09-02 10-07" {
		t.Errorf("first Wednesday: %s", got)
	}
}

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	parsed, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func TestCalendarFeeds(t *testing.T) {
	e := newEnv(t)
	body := sampleICS
	status := http.StatusOK
	var seenAgent string
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenAgent = r.Header.Get("User-Agent")
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
	defer service.Close()
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid
	secretURL := service.URL + "/geheimer-pfad.ics"
	feedBody := obj{"name": "Schule", "url": secretURL}

	// The server must not be usable to look into its own network.
	message := e.expect(400, "POST", base+"/calendar-feeds", token, feedBody)["error"]
	e.expect(400, "POST", base+"/calendar-feeds", token, obj{"name": "X", "url": "http://169.254.169.254/latest/meta-data"})
	e.expect(400, "POST", base+"/calendar-feeds", token, obj{"name": "X", "url": "file:///etc/passwd"})
	e.expect(400, "POST", base+"/calendar-feeds", token, obj{"name": "X", "url": "kein link"})
	e.expect(400, "POST", base+"/calendar-feeds", token, obj{"name": "", "url": "https://example.de/a.ics"})
	if message != "Unter dieser Adresse wurde kein Kalender gefunden." {
		t.Errorf("message: %v", message)
	}

	e.server.allowPrivateFeeds = true
	body = "kein Kalender"
	e.expect(400, "POST", base+"/calendar-feeds", token, feedBody)
	body = sampleICS
	key := e.expect(201, "POST", base+"/calendar-feeds", token, feedBody)["key"].(string)
	if !strings.HasPrefix(seenAgent, "Kintura/") {
		t.Errorf("agent: %s", seenAgent)
	}

	got := e.entries(token, fid, "2026-03-10T00:00:00Z", "2026-03-10T20:00:00Z")
	if titlesOf(got) != "Lang, mit Faltung" || got[0]["editable"] != false || got[0]["source"] != key || got[0]["color"] != calendarColors["feed"] {
		t.Fatalf("entries: %v", got)
	}

	// Feeds belong to the one who added them.
	other, _ := e.addMember(fid, token, "b@example.de")
	if got := e.entries(other, fid, "2026-03-10T00:00:00Z", "2026-03-10T20:00:00Z"); len(got) != 0 {
		t.Errorf("other user sees %s", titlesOf(got))
	}
	id := strings.TrimPrefix(key, "feed:")
	e.expect(404, "DELETE", base+"/calendar-feeds/"+id, other, nil)
	e.expect(404, "PUT", base+"/calendars/"+key, other, obj{"enabled": true, "color": "#D32F2F"})

	// Renewing at once does not wait for the stored copy to age.
	refresh := base + "/calendar-feeds/" + id + "/refresh"
	e.expect(404, "POST", refresh, other, nil)
	body = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
	if got := e.expect(200, "POST", refresh, token, nil)["events"]; got != float64(0) {
		t.Errorf("empty calendar: %v", got)
	}
	if got := e.entries(token, fid, "2026-03-10T00:00:00Z", "2026-03-10T20:00:00Z"); len(got) != 0 {
		t.Errorf("not renewed: %s", titlesOf(got))
	}
	// A failure keeps the dates until the next success.
	body = sampleICS
	if got := e.expect(200, "POST", refresh, token, nil)["events"]; got == float64(0) {
		t.Errorf("full calendar: %v", got)
	}
	body = "kein Kalender"
	e.expect(400, "POST", refresh, token, nil)
	if got := titlesOf(e.entries(token, fid, "2026-03-10T00:00:00Z", "2026-03-10T20:00:00Z")); got != "Lang, mit Faltung" {
		t.Errorf("after failed refresh: %s", got)
	}
	if cal := calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), key); cal["last_error"] == nil {
		t.Errorf("no error shown: %v", cal)
	}
	body = sampleICS
	e.expect(200, "POST", refresh, token, nil)
	if cal := calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), key); cal["last_error"] != nil {
		t.Errorf("error stays: %v", cal)
	}

	// A failed renewal keeps the dates and reports without the secret address.
	old := time.Now().UTC().Add(-feedMaxAge - time.Minute).Format(timeFormat)
	if _, err := e.server.db.Exec(`UPDATE calendar_feeds SET fetched_at = ?`, old); err != nil {
		t.Fatal(err)
	}
	service.Close()
	got = e.entries(token, fid, "2026-03-10T00:00:00Z", "2026-03-10T20:00:00Z")
	if titlesOf(got) != "Lang, mit Faltung" {
		t.Errorf("after failure: %s", titlesOf(got))
	}
	cal := calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), key)
	if cal["last_error"] == "" || cal["url"] != secretURL {
		t.Errorf("calendar: %v", cal)
	}
	logged, err := queryRows(t.Context(), e.server.db, `SELECT message FROM error_log`)
	if err != nil {
		t.Fatal(err)
	}
	messages := fmt.Sprint(logged)
	if !strings.Contains(messages, "Schule") || strings.Contains(messages, "geheimer-pfad") {
		t.Errorf("log: %s", messages)
	}

	e.expect(204, "DELETE", base+"/calendar-feeds/"+id, token, nil)
	if got := e.entries(token, fid, "2026-03-10T00:00:00Z", "2026-03-10T20:00:00Z"); len(got) != 0 {
		t.Errorf("after delete: %s", titlesOf(got))
	}
}

func TestEntryColors(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid
	me := e.expect(200, "GET", "/api/me", token, nil)["id"]
	ben, benID := e.addMember(fid, token, "b@example.de")
	_, caraID := e.addMember(fid, token, "c@example.de")
	const calendarColor, benColor = "#1565C0", "#2E7D32"
	e.expect(204, "PUT", base+"/calendars/family", token, obj{"enabled": true, "color": calendarColor})
	e.expect(204, "PUT", base+"/color", ben, obj{"color": benColor})

	categories := e.expect(200, "GET", base+"/categories", token, nil)["categories"].([]any)
	withColor := categories[1].(obj)
	withoutColor := e.expect(201, "POST", base+"/categories", token, obj{"name": "Blass", "color": ""})["id"]
	only := func(ids ...any) obj { return obj{"participants_all": false, "participant_ids": ids} }
	merge := func(a, b obj) obj {
		for k, v := range b {
			a[k] = v
		}
		return a
	}
	for title, body := range map[string]obj{
		"Alle":              {},
		"Nur Ben":           only(benID),
		"Nur Cara":          only(caraID), // has no color
		"Ben und Cara":      only(benID, caraID),
		"Ben mit Kategorie": merge(only(benID), obj{"category_id": withColor["id"]}),
		"Ben, blass":        merge(only(benID), obj{"category_id": withoutColor}),
		"Nur ich":           only(me),
	} {
		e.expect(201, "POST", base+"/events", token, eventBody(merge(body, obj{"title": title, "start_local": "2026-03-10T10:00", "end_local": "2026-03-10T11:00"})))
	}
	want := map[string]string{
		"Alle": calendarColor, "Nur Ben": benColor, "Nur Cara": calendarColor, "Ben und Cara": calendarColor,
		"Ben mit Kategorie": withColor["color"].(string), "Ben, blass": benColor, "Nur ich": calendarColor,
	}
	seen := 0
	for _, entry := range e.entries(token, fid, "2026-03-10T00:00:00Z", "2026-03-11T00:00:00Z") {
		if color, ok := want[entry["title"].(string)]; ok {
			seen++
			if entry["color"] != color {
				t.Errorf("%v: %v, want %s", entry["title"], entry["color"], color)
			}
		}
	}
	if seen != len(want) {
		t.Errorf("seen %d of %d", seen, len(want))
	}

	// The standard calendar of another family follows the same rule with its colors.
	other := e.register("d@example.de", "D", "G")
	otherBase := "/api/families/" + e.firstFamily(other)
	e.expect(201, "POST", otherBase+"/invitations", other, obj{"email": "a@example.de", "role": "user"})
	e.expect(200, "GET", "/api/me", token, nil) // accepts the invitation
	const otherColor = "#D32F2F"
	e.expect(204, "PUT", otherBase+"/color", other, obj{"color": otherColor})
	e.expect(201, "POST", otherBase+"/events", other, eventBody(merge(only(e.expect(200, "GET", "/api/me", other, nil)["id"]),
		obj{"title": "Bei D", "start_local": "2026-03-10T12:00", "end_local": "2026-03-10T13:00"})))
	found := false
	for _, entry := range e.entries(token, fid, "2026-03-10T00:00:00Z", "2026-03-11T00:00:00Z") {
		if entry["title"] == "Bei D" {
			found = true
			if entry["color"] != otherColor {
				t.Errorf("other family: %v", entry["color"])
			}
			if entry["participant_ids"] != nil {
				t.Errorf("other family names participants: %v", entry)
			}
		}
	}
	if !found {
		t.Error("event of the other family is missing")
	}
}

func TestEntriesNameTheirParticipants(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid
	_, ben := e.addMember(fid, token, "b@example.de")
	e.expect(201, "POST", base+"/events", token, eventBody(obj{"title": "Alle", "start_local": "2026-03-10T10:00", "end_local": "2026-03-10T11:00"}))
	e.expect(201, "POST", base+"/events", token, eventBody(obj{"title": "Nur Ben", "start_local": "2026-03-10T12:00", "end_local": "2026-03-10T13:00",
		"participants_all": false, "participant_ids": []any{ben}}))
	// A series names them at every date.
	e.expect(201, "POST", base+"/events", token, eventBody(obj{"title": "Serie", "start_local": "2026-03-10T14:00", "end_local": "2026-03-10T15:00",
		"participants_all": false, "participant_ids": []any{ben}, "recurrence": obj{"freq": "day", "interval": 1}}))

	got := e.entries(token, fid, "2026-03-10T00:00:00Z", "2026-03-11T23:00:00Z")
	series := 0
	for _, entry := range got {
		ids, _ := entry["participant_ids"].([]any)
		if entry["source"] != "family" {
			if entry["participant_ids"] != nil {
				t.Errorf("%v names participants: %v", entry["source"], entry)
			}
			continue
		}
		switch entry["title"] {
		case "Alle":
			if len(ids) != 0 || entry["participants_all"] != true {
				t.Errorf("everyone: %v", entry)
			}
		case "Serie":
			series++
			fallthrough
		case "Nur Ben":
			if len(ids) != 1 || ids[0] != ben || entry["participants_all"] != false {
				t.Errorf("%v: %v", entry["title"], entry)
			}
		}
	}
	if series != 2 {
		t.Errorf("series dates: %d", series)
	}
}

func TestBlockedFeedAddresses(t *testing.T) {
	for address, blocked := range map[string]bool{
		"127.0.0.1": true, "::1": true, "10.1.2.3": true, "192.168.1.1": true, "172.16.0.1": true,
		"169.254.169.254": true, "fe80::1": true, "fc00::1": true, "0.0.0.0": true, "100.64.0.1": true, "224.0.0.1": true,
		"::ffff:127.0.0.1": true, "8.8.8.8": false, "2606:4700:4700::1111": false,
	} {
		if got := blockedFeedIP(net.ParseIP(address)); got != blocked {
			t.Errorf("%s: %v", address, got)
		}
	}
	for raw, want := range map[string]string{
		"webcal://example.de/a.ics":  "https://example.de/a.ics",
		" https://example.de/a.ics ": "https://example.de/a.ics",
	} {
		if got, err := normalizeFeedURL(raw); err != nil || got != want {
			t.Errorf("%s: %s %v", raw, got, err)
		}
	}
}

func TestCalendarShare(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid
	me := e.expect(200, "GET", "/api/me", token, nil)["id"]
	other, otherID := e.addMember(fid, token, "b@example.de")

	e.expect(201, "POST", base+"/events", token, eventBody(obj{
		"title": "Offen, mit; Zeichen", "description": "Zeile\nzwei", "recurrence": obj{"freq": "week", "interval": 2, "weekdays": []any{1, 3}},
	}))
	e.expect(201, "POST", base+"/events", token, eventBody(obj{
		"title": "Ganztag", "all_day": true, "start_local": "2026-03-01T00:00", "end_local": "2026-03-01T23:59",
	}))
	e.expect(201, "POST", base+"/events", token, eventBody(obj{
		"title": "Nur Anna", "visibility": "participants", "participants_all": false, "participant_ids": []any{me},
	}))
	e.expect(201, "POST", base+"/events", other, eventBody(obj{
		"title": "Nur Ben", "visibility": "participants", "participants_all": false, "participant_ids": []any{otherID},
	}))

	e.expect(404, "POST", base+"/calendars/unbekannt/share", token, nil)
	link := e.expect(201, "POST", base+"/calendars/family/share", token, nil)["url"].(string)
	if again := e.expect(200, "POST", base+"/calendars/family/share", token, nil)["url"]; again != link {
		t.Errorf("second link: %v", again)
	}
	if shown := calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), "family"); shown["share_url"] != link {
		t.Errorf("share url: %v", shown)
	}
	if !strings.HasPrefix(link, "http://test/cal/") || !strings.HasSuffix(link, ".ics") {
		t.Fatalf("link: %s", link)
	}
	path := strings.TrimPrefix(link, "http://test")
	read := func(p string) (int, string, http.Header) {
		res, err := http.Get(e.srv.URL + p)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var out strings.Builder
		buf := make([]byte, 1<<16)
		for {
			n, err := res.Body.Read(buf)
			out.Write(buf[:n])
			if err != nil {
				break
			}
		}
		return res.StatusCode, out.String(), res.Header
	}

	status, ics, header := read(path)
	if status != 200 || !strings.HasPrefix(header.Get("Content-Type"), "text/calendar") {
		t.Fatalf("%d %v", status, header)
	}
	for _, want := range []string{
		"BEGIN:VCALENDAR\r\n", "SUMMARY:Offen\\, mit\\; Zeichen\r\n", "DESCRIPTION:Zeile\\nzwei\r\n",
		"RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE\r\n", "DTSTART;TZID=Europe/Berlin:20260105T100000\r\n",
		"DTSTART;VALUE=DATE:20260301\r\n", "DTEND;VALUE=DATE:20260302\r\n", "SUMMARY:Nur Anna\r\n", "END:VCALENDAR\r\n",
	} {
		if !strings.Contains(ics, want) {
			t.Errorf("missing %q in\n%s", want, ics)
		}
	}
	// The link shows what its owner may see, and nothing of what they may not.
	if strings.Contains(ics, "Nur Ben") {
		t.Errorf("private event of another member:\n%s", ics)
	}
	// What the backend writes, it can read again.
	berlin, _ := time.LoadLocation("Europe/Berlin")
	if parsed := parseICS(ics, berlin); len(parsed) != 3 || parsed[0].rule == nil && parsed[1].rule == nil && parsed[2].rule == nil {
		t.Errorf("reading back: %+v", parsed)
	}

	// Birthdays and tasks can be shared as well.
	e.expect(204, "PUT", base+"/profile", token, obj{"name": "Anna", "birthday": "1990-03-14"})
	birthdays := e.expect(201, "POST", base+"/calendars/birthdays/share", token, nil)["url"].(string)
	if _, got, _ := read(strings.TrimPrefix(birthdays, "http://test")); !strings.Contains(got, "SUMMARY:Geburtstag Anna") || !strings.Contains(got, "RRULE:FREQ=YEARLY") {
		t.Errorf("birthdays:\n%s", got)
	}
	listID := e.expect(201, "POST", base+"/lists", token, obj{"name": "L", "kind": "tasks"})["id"].(string)
	e.expect(201, "POST", base+"/lists/"+listID+"/items", token, obj{"title": "Steuer", "due_date": "2026-05-31"})
	tasks := e.expect(201, "POST", base+"/calendars/tasks/share", token, nil)["url"].(string)
	if _, got, _ := read(strings.TrimPrefix(tasks, "http://test")); !strings.Contains(got, "SUMMARY:Steuer") {
		t.Errorf("tasks:\n%s", got)
	}

	if status, _, _ := read("/cal/falsch.ics"); status != 404 {
		t.Errorf("unknown token: %d", status)
	}
	// Leaving the family ends the link of the one who left.
	otherLink := e.expect(201, "POST", base+"/calendars/family/share", other, nil)["url"].(string)
	otherPath := strings.TrimPrefix(otherLink, "http://test")
	if status, _, _ := read(otherPath); status != 200 {
		t.Errorf("other link: %d", status)
	}
	e.expect(204, "DELETE", base+"/members/"+otherID, token, nil)
	if status, _, _ := read(otherPath); status != 404 {
		t.Errorf("after leaving: %d", status)
	}

	e.expect(404, "DELETE", base+"/calendars/special/share", token, nil)
	e.expect(204, "DELETE", base+"/calendars/family/share", token, nil)
	if status, _, _ := read(path); status != 404 {
		t.Errorf("after delete: %d", status)
	}
	// A new link is a new secret.
	if fresh := e.expect(201, "POST", base+"/calendars/family/share", token, nil)["url"]; fresh == link {
		t.Errorf("link reused: %v", fresh)
	}
}

// holidayShareEnv has a holiday service that answers with days of this year.
func holidayShareEnv(t *testing.T) (*testEnv, func(link string) (int, string)) {
	t.Helper()
	e := newEnv(t)
	year := time.Now().UTC().Year()
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := func(text string) []obj { return []obj{{"language": "DE", "text": text}} }
		switch r.URL.Path {
		case "/PublicHolidays":
			json.NewEncoder(w).Encode([]obj{{"id": "h-" + r.URL.Query().Get("countryIsoCode"), "startDate": fmt.Sprintf("%d-12-25", year), "endDate": fmt.Sprintf("%d-12-25", year), "name": name("Weihnachten"), "nationwide": true}})
		case "/SchoolHolidays":
			json.NewEncoder(w).Encode([]obj{{"id": "s-" + r.URL.Query().Get("subdivisionCode"), "startDate": fmt.Sprintf("%d-07-01", year), "endDate": fmt.Sprintf("%d-07-03", year), "name": name("Sommerferien")}})
		default:
			io.WriteString(w, "[]")
		}
	}))
	t.Cleanup(service.Close)
	e.server.holidaysURL = service.URL
	read := func(link string) (int, string) {
		res, err := http.Get(e.srv.URL + strings.TrimPrefix(link, "http://test"))
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, err := io.ReadAll(res.Body)
		if err != nil {
			t.Fatal(err)
		}
		return res.StatusCode, string(body)
	}
	return e, read
}

func TestSharingHolidaysAndSpecialDays(t *testing.T) {
	e, read := holidayShareEnv(t)
	year := time.Now().UTC().Year()
	token := e.register("a@example.de", "A", "Geheimer Name")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid

	// What is someone's own choice to show stays out of it.
	foreign := e.register("o@example.de", "O", "Anders")
	foreignID := e.firstFamily(foreign)
	e.expect(201, "POST", "/api/families/"+foreignID+"/invitations", foreign, obj{"email": "a@example.de", "role": "user"})
	e.expect(200, "GET", "/api/me", token, nil) // accepts the invitation
	e.expect(400, "POST", base+"/calendars/family:"+foreignID+"/share", token, nil)

	// Public holidays, of the chosen country.
	data := e.expect(200, "GET", base+"/calendars", token, nil)
	for _, key := range []string{"school", "holidays", "special"} {
		if got := calendarNamed(t, data, key); got["shareable"] != true {
			t.Errorf("%s: %v", key, got)
		}
	}
	holidays := e.expect(201, "POST", base+"/calendars/holidays/share", token, nil)["url"].(string)
	status, ics := read(holidays)
	if status != 200 || !strings.Contains(ics, "SUMMARY:Weihnachten\r\n") ||
		!strings.Contains(ics, fmt.Sprintf("DTSTART;VALUE=DATE:%d1225\r\n", year)) || !strings.Contains(ics, fmt.Sprintf("DTEND;VALUE=DATE:%d1226\r\n", year)) {
		t.Errorf("holidays: %d\n%s", status, ics)
	}
	// Nothing here is about the family, so its name stays out of it.
	if strings.Contains(ics, "Geheimer Name") {
		t.Errorf("family name:\n%s", ics)
	}

	// School holidays of the states the owner has chosen, as they are now.
	school := e.expect(201, "POST", base+"/calendars/school/share", token, nil)["url"].(string)
	if status, ics := read(school); status != 200 || !strings.Contains(ics, "SUMMARY:Sommerferien (Baden-Württemberg)\r\n") {
		t.Errorf("to start with: %d\n%s", status, ics)
	}
	e.expect(204, "PUT", base+"/calendars/school", token, obj{"enabled": true, "regions": []any{}})
	if status, ics := read(school); status != 200 || strings.Contains(ics, "Sommerferien") {
		t.Errorf("no state: %d\n%s", status, ics)
	}
	e.expect(204, "PUT", base+"/calendars/school", token, obj{"enabled": true, "regions": []any{"DE-BY"}})
	if status, ics := read(school); status != 200 || !strings.Contains(ics, "SUMMARY:Sommerferien (Bayern)\r\n") ||
		!strings.Contains(ics, fmt.Sprintf("DTEND;VALUE=DATE:%d0704\r\n", year)) {
		t.Errorf("one state: %d\n%s", status, ics)
	}

	// Special days, without the birthdays that have a calendar of their own.
	e.expect(201, "POST", base+"/special-days", token, obj{"title": "Hochzeitstag", "kind": "feast", "date": "2020-06-01", "yearly": true})
	e.expect(201, "POST", base+"/special-days", token, obj{"title": "Oma", "kind": "birthday", "date": "1950-02-03", "yearly": true})
	special := e.expect(201, "POST", base+"/calendars/special/share", token, nil)["url"].(string)
	if status, ics := read(special); status != 200 || !strings.Contains(ics, "SUMMARY:Hochzeitstag\r\n") || !strings.Contains(ics, "RRULE:FREQ=YEARLY") || strings.Contains(ics, "Oma") {
		t.Errorf("special: %d\n%s", status, ics)
	}

	// The calendar and its link outlast every country, and follow the choice.
	prefs := e.expect(200, "GET", base+"/calendar-prefs", token, nil)
	set := func(countries ...any) {
		prefs["holiday_countries"] = countries
		e.expect(204, "PUT", base+"/calendar-prefs", token, prefs)
	}
	set()
	shown := calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), "holidays")
	if shown["subtitle"] != "Kein Land ausgewählt" || shown["share_url"] != holidays {
		t.Errorf("without a country: %v", shown)
	}
	if status, ics := read(holidays); status != 200 || strings.Contains(ics, "Weihnachten") {
		t.Errorf("link without a country: %d\n%s", status, ics)
	}
	set("AT", "DE")
	shown = calendarNamed(t, e.expect(200, "GET", base+"/calendars", token, nil), "holidays")
	if shown["share_url"] != holidays || !strings.Contains(shown["subtitle"].(string), ",") {
		t.Errorf("two countries: %v", shown)
	}
	// Several countries say which is which.
	if status, ics := read(holidays); status != 200 || !strings.Contains(ics, "SUMMARY:Weihnachten (AT)\r\n") || !strings.Contains(ics, "SUMMARY:Weihnachten (DE)\r\n") {
		t.Errorf("link with two countries: %d\n%s", status, ics)
	}
	set("DE")
	if status, ics := read(holidays); status != 200 || !strings.Contains(ics, "SUMMARY:Weihnachten\r\n") {
		t.Errorf("link with one country again: %d\n%s", status, ics)
	}
}

func TestRestrictedMembersShareOnlyHolidays(t *testing.T) {
	e, read := holidayShareEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	kid, kidID := e.addMember(fid, admin, "k@example.de")
	e.setRole(fid, admin, kidID, "restrict_user", false)

	data := e.expect(200, "GET", base+"/calendars", kid, nil)
	for key, want := range map[string]bool{"family": false, "tasks": false, "birthdays": false, "special": false, "school": true, "holidays": true} {
		if got := calendarNamed(t, data, key); got["shareable"] != want {
			t.Errorf("%s: %v", key, got)
		}
		if !want {
			e.expect(403, "POST", base+"/calendars/"+key+"/share", kid, nil)
		}
	}
	school := e.expect(201, "POST", base+"/calendars/school/share", kid, nil)["url"].(string)
	holidays := e.expect(201, "POST", base+"/calendars/holidays/share", kid, nil)["url"].(string)
	for _, link := range []string{school, holidays} {
		if status, _ := read(link); status != 200 {
			t.Errorf("%s: %d", link, status)
		}
	}
	if got := calendarNamed(t, e.expect(200, "GET", base+"/calendars", kid, nil), "school"); got["share_url"] != school {
		t.Errorf("school: %v", got)
	}

	// Another role and back keeps these, and a link for more ends for good.
	e.setRole(fid, admin, kidID, "user", false)
	special := e.expect(201, "POST", base+"/calendars/special/share", kid, nil)["url"].(string)
	if status, _ := read(special); status != 200 {
		t.Errorf("special as a user: %d", status)
	}
	e.setRole(fid, admin, kidID, "restrict_user", false)
	if status, _ := read(special); status != 404 {
		t.Errorf("special as a child: %d", status)
	}
	if status, _ := read(school); status != 200 {
		t.Errorf("school after the changes: %d", status)
	}
	e.setRole(fid, admin, kidID, "user", false)
	if status, _ := read(special); status != 404 {
		t.Errorf("special back as a user: %d", status)
	}
}

func TestRestrictedMembersShareNoCalendars(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	kid, kidID := e.addMember(fid, admin, "k@example.de")
	status := func(link string) int {
		res, err := http.Get(e.srv.URL + strings.TrimPrefix(link, "http://test"))
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}

	// As a user the link works, and the page says so.
	link := e.expect(201, "POST", base+"/calendars/family/share", kid, nil)["url"].(string)
	if got := status(link); got != 200 {
		t.Fatalf("link: %d", got)
	}

	// With the role it goes, and the calendar no longer offers it.
	e.setRole(fid, admin, kidID, "restrict_user", false)
	if got := status(link); got != 404 {
		t.Errorf("after the change of role: %d", got)
	}
	data := e.expect(200, "GET", base+"/calendars", kid, nil)
	for _, key := range []string{"family", "tasks", "birthdays"} {
		if got := calendarNamed(t, data, key); got["shareable"] != false || got["share_url"] != nil {
			t.Errorf("%s: %v", key, got)
		}
	}
	e.expect(403, "POST", base+"/calendars/family/share", kid, nil)
	e.expect(403, "POST", base+"/calendars/tasks/share", kid, nil)

	// Everything else about the calendars stays.
	e.expect(204, "PUT", base+"/calendars/tasks", kid, obj{"enabled": false})

	// Another role does not bring the old link back, only a new one works.
	e.setRole(fid, admin, kidID, "user", false)
	if got := status(link); got != 404 {
		t.Errorf("old link after going back: %d", got)
	}
	fresh := e.expect(201, "POST", base+"/calendars/family/share", kid, nil)["url"].(string)
	if got := status(fresh); got != 200 {
		t.Errorf("new link: %d", got)
	}

	// Even if a link was left behind, it does not answer for a restricted member.
	if _, err := e.server.db.Exec(`UPDATE memberships SET role = 'restrict_user' WHERE family_id = ? AND user_id = ?`, fid, kidID); err != nil {
		t.Fatal(err)
	}
	if got := status(fresh); got != 404 {
		t.Errorf("left behind: %d", got)
	}

	// Others in the family are not affected.
	own := e.expect(201, "POST", base+"/calendars/family/share", admin, nil)["url"].(string)
	if got := status(own); got != 200 {
		t.Errorf("admin: %d", got)
	}
}

func TestRestrictedMembersOnlySwitchCalendarsAndChooseStates(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	kid, kidID := e.addMember(fid, admin, "k@example.de")
	foreign := e.register("o@example.de", "O", "Anders")
	foreignID := e.firstFamily(foreign)
	e.expect(201, "POST", "/api/families/"+foreignID+"/invitations", foreign, obj{"email": "k@example.de", "role": "user"})
	e.expect(200, "GET", "/api/me", kid, nil) // accepts the invitation
	e.setRole(fid, admin, kidID, "restrict_user", false)

	// Switching and the states work.
	e.expect(204, "PUT", base+"/calendars/tasks", kid, obj{"enabled": false})
	e.expect(204, "PUT", base+"/calendars/school", kid, obj{"enabled": true, "regions": []any{"DE-BY"}})
	data := e.expect(200, "GET", base+"/calendars", kid, nil)
	if got := calendarNamed(t, data, "tasks"); got["enabled"] != false {
		t.Errorf("tasks: %v", got)
	}
	if got := calendarNamed(t, data, "school"); fmt.Sprint(got["regions"]) != "[DE-BY]" {
		t.Errorf("school: %v", got)
	}

	// Not even the color of what is otherwise their own, nor a calendar by address.
	key := "family:" + foreignID
	e.expect(403, "PUT", base+"/calendars/"+key, kid, obj{"enabled": true, "color": "#D32F2F"})
	e.expect(204, "PUT", base+"/calendars/"+key, kid, obj{"enabled": false})
	e.expect(403, "POST", base+"/calendar-feeds", kid, obj{"name": "X", "url": "https://example.de/a.ics"})

	// It goes by the role in this family: in the other one the same person is a user.
	e.expect(204, "PUT", "/api/families/"+foreignID+"/calendars/family:"+fid, kid, obj{"enabled": true, "color": "#D32F2F"})
}

func TestCalendarCleanup(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid
	member, _ := e.addMember(fid, token, "b@example.de")

	e.expect(403, "PUT", base+"/calendar-cleanup", member, obj{"months": 1})
	for _, months := range []int{0, 2, 48} {
		e.expect(400, "PUT", base+"/calendar-cleanup", token, obj{"months": months})
	}

	at := func(ago time.Duration) string { return time.Now().Add(-ago).Format(localTimeFormat) }
	day := 24 * time.Hour
	add := func(title string, ago time.Duration, extra obj) string {
		body := eventBody(obj{"title": title, "start_local": at(ago), "end_local": at(ago)})
		for k, v := range extra {
			body[k] = v
		}
		return e.expect(201, "POST", base+"/events", token, body)["id"].(string)
	}
	old := add("Alt", 400*day, nil)
	add("Alte Serie", 400*day, obj{"recurrence": obj{"freq": "year", "interval": 1}})
	add("Mittel", 100*day, nil)
	add("Neu", day, nil)
	status, out := e.uploadTo(token, base+"/events/"+old+"/attachments", "a.png", pngHeader)
	if status != 201 {
		t.Fatalf("upload: %d", status)
	}
	stored := out["id"].(string)

	foreign := e.register("c@example.de", "C", "G")
	foreignFamily := e.firstFamily(foreign)
	e.expect(201, "POST", "/api/families/"+foreignFamily+"/events", foreign, eventBody(obj{"title": "Fremd", "start_local": at(100 * day), "end_local": at(100 * day)}))
	e.expect(204, "PUT", "/api/families/"+foreignFamily+"/calendar-cleanup", foreign, obj{"months": 36})

	titles := func(db string) []string {
		rows, err := queryRows(context.Background(), e.server.db, `SELECT title FROM events WHERE family_id = ? ORDER BY title`, db)
		if err != nil {
			t.Fatal(err)
		}
		out := []string{}
		for _, row := range rows {
			out = append(out, row["title"].(string))
		}
		return out
	}

	// By default a year: old single events go with their files, a series stays.
	e.server.cleanup(context.Background())
	if got := titles(fid); !slices.Equal(got, []string{"Alte Serie", "Mittel", "Neu"}) {
		t.Errorf("after a year: %v", got)
	}
	if e.fileStored(stored) {
		t.Errorf("attachment kept")
	}

	e.expect(204, "PUT", base+"/calendar-cleanup", token, obj{"months": 1})
	e.server.cleanup(context.Background())
	if got := titles(fid); !slices.Equal(got, []string{"Alte Serie", "Neu"}) {
		t.Errorf("after a month: %v", got)
	}
	// Each family has its own limit.
	if got := titles(foreignFamily); !slices.Equal(got, []string{"Fremd"}) {
		t.Errorf("other family: %v", got)
	}
}
