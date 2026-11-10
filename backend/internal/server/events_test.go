package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"
)

func (e *testEnv) events(token, fid, from, to string) []obj {
	e.t.Helper()
	query := url.Values{"from": {from}, "to": {to}}.Encode()
	var out []obj
	if err := e.getJSON("/api/families/"+fid+"/events?"+query, token, &out); err != nil {
		e.t.Fatal(err)
	}
	return out
}

func startsOf(events []obj) string {
	out := []string{}
	for _, event := range events {
		out = append(out, event["start_local"].(string))
	}
	return strings.Join(out, " ")
}

func eventBody(extra obj) obj {
	body := obj{"title": "T", "start_local": "2026-01-05T10:00", "end_local": "2026-01-05T11:00"}
	for k, v := range extra {
		body[k] = v
	}
	return body
}

func TestEventTimezone(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	path := "/api/families/" + fid + "/events"

	// Without a choice, the default applies, with the current offset in summer too.
	id := e.expect(201, "POST", path, token, eventBody(obj{"start_local": "2026-07-01T10:00", "end_local": "2026-07-01T11:00"}))["id"].(string)
	event := e.expect(200, "GET", path+"/"+id, token, nil)
	if event["start_at"] != "2026-07-01T08:00:00Z" || event["start_local"] != "2026-07-01T10:00" || event["timezone"] != "Europe/Berlin" {
		t.Errorf("default zone: %v", event)
	}
	id = e.expect(201, "POST", path, token, eventBody(obj{
		"timezone": "America/New_York", "start_local": "2026-01-05T10:00", "end_local": "2026-01-05T11:00",
	}))["id"].(string)
	event = e.expect(200, "GET", path+"/"+id, token, nil)
	if event["start_at"] != "2026-01-05T15:00:00Z" || event["start_local"] != "2026-01-05T10:00" || event["timezone"] != "America/New_York" {
		t.Errorf("chosen zone: %v", event)
	}

	e.expect(400, "POST", path, token, eventBody(obj{"timezone": "Mars/Olympus"}))
	e.expect(400, "POST", path, token, eventBody(obj{"timezone": "Local"}))
	e.expect(400, "POST", path, token, eventBody(obj{"start_local": "morgen"}))
	e.expect(400, "POST", path, token, eventBody(obj{"end_local": "2026-01-05T09:00"}))

	zones := e.expect(200, "GET", "/api/timezones", token, nil)
	if zones["default"] != "Europe/Berlin" {
		t.Errorf("default: %v", zones["default"])
	}
	found := false
	for _, zone := range zones["zones"].([]any) {
		if z := zone.(obj); z["id"] == "Europe/Berlin" {
			found = strings.HasPrefix(z["label"].(string), "Mitteleuropäische") && strings.HasPrefix(z["offset"].(string), "GMT+0")
		}
	}
	if !found {
		t.Errorf("zones: %v", zones)
	}

	// The default comes from the configuration and may be outside the usual list.
	e.server.timezone = "Asia/Kathmandu"
	zones = e.expect(200, "GET", "/api/timezones", token, nil)
	if zones["default"] != "Asia/Kathmandu" {
		t.Errorf("configured default: %v", zones["default"])
	}
	id = e.expect(201, "POST", path, token, eventBody(nil))["id"].(string)
	if event = e.expect(200, "GET", path+"/"+id, token, nil); event["timezone"] != "Asia/Kathmandu" {
		t.Errorf("configured zone: %v", event)
	}
}

func TestRecurrenceStarts(t *testing.T) {
	berlin, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		t.Fatal(err)
	}
	date := func(s string) time.Time {
		parsed, err := time.ParseInLocation(localTimeFormat, s, berlin)
		if err != nil {
			t.Fatal(err)
		}
		return parsed
	}
	for _, tc := range []struct {
		name, first, from, to string
		rec                   recurrence
		want                  string
	}{
		{"täglich", "2026-01-05T10:00", "2026-01-01T00:00", "2026-01-08T00:00",
			recurrence{Freq: "day", Interval: 1}, "01-05 01-06 01-07"},
		{"alle 3 Tage ab später", "2026-01-01T10:00", "2026-03-01T00:00", "2026-03-08T00:00",
			recurrence{Freq: "day", Interval: 3}, "03-02 03-05"},
		{"Wochentage", "2026-01-07T10:00", "2026-01-05T00:00", "2026-01-13T00:00",
			recurrence{Freq: "week", Interval: 1, Weekdays: []int{1, 2, 3, 4, 5}}, "01-07 01-08 01-09 01-12"},
		{"alle 2 Wochen Mo und Do", "2026-01-05T10:00", "2026-01-05T00:00", "2026-02-03T00:00",
			recurrence{Freq: "week", Interval: 2, Weekdays: []int{1, 4}}, "01-05 01-08 01-19 01-22 02-02"},
		{"alle 2 Wochen springt richtig", "2026-01-05T10:00", "2027-01-11T00:00", "2027-01-20T00:00",
			recurrence{Freq: "week", Interval: 2, Weekdays: []int{1}}, "01-18"},
		{"Monat, Tag 31 fällt auf den letzten", "2026-01-31T10:00", "2026-01-01T00:00", "2026-05-01T00:00",
			recurrence{Freq: "month", Interval: 1, MonthDay: 31}, "01-31 02-28 03-31 04-30"},
		{"erster Montag", "2026-01-05T10:00", "2026-01-01T00:00", "2026-04-01T00:00",
			recurrence{Freq: "month", Interval: 1, MonthWeek: 1, MonthWeekday: 1}, "01-05 02-02 03-02"},
		{"letzter Freitag", "2026-01-30T10:00", "2026-01-01T00:00", "2026-04-01T00:00",
			recurrence{Freq: "month", Interval: 1, MonthWeek: -1, MonthWeekday: 5}, "01-30 02-27 03-27"},
		{"nicht vor dem ersten Termin", "2026-01-20T10:00", "2026-01-01T00:00", "2026-03-01T00:00",
			recurrence{Freq: "month", Interval: 1, MonthWeek: 1, MonthWeekday: 1}, "02-02"},
		{"jährlich, 29. Februar", "2028-02-29T10:00", "2028-01-01T00:00", "2030-03-01T00:00",
			recurrence{Freq: "year", Interval: 1}, "02-29 02-28 02-28"},
		{"Ende vor Beginn des Bereichs", "2026-01-05T10:00", "2025-01-01T00:00", "2025-06-01T00:00",
			recurrence{Freq: "day", Interval: 1}, ""},
	} {
		got := []string{}
		for _, start := range tc.rec.starts(date(tc.first), date(tc.from), date(tc.to)) {
			got = append(got, start.Format("01-02"))
			if start.Format("15:04") != "10:00" {
				t.Errorf("%s: time of day %s", tc.name, start)
			}
		}
		if strings.Join(got, " ") != tc.want {
			t.Errorf("%s: %v, want %s", tc.name, got, tc.want)
		}
	}

	// Daylight saving moves the UTC time, not the wall clock.
	rec := recurrence{Freq: "week", Interval: 1, Weekdays: []int{7}}
	starts := rec.starts(date("2026-03-22T10:00"), date("2026-03-22T00:00"), date("2026-03-30T00:00"))
	if len(starts) != 2 || starts[0].UTC().Hour() != 9 || starts[1].UTC().Hour() != 8 {
		t.Errorf("daylight saving: %v", starts)
	}

	// The limit also ends a loop whose range is far too wide.
	rec = recurrence{Freq: "day", Interval: 1}
	if n := len(rec.starts(date("2026-01-01T10:00"), date("2026-01-01T00:00"), date("9000-01-01T00:00"))); n != maxOccurrences {
		t.Errorf("limit: %d", n)
	}
}

func TestRecurringEvents(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	path := "/api/families/" + fid + "/events"

	id := e.expect(201, "POST", path, token, eventBody(obj{"recurrence": obj{"freq": "week", "interval": 1}}))["id"].(string)
	// The weekday follows from the start, and the series shows up where it never started.
	series := e.expect(200, "GET", path+"/"+id, token, nil)
	if rec := series["recurrence"].(obj); !slices.Equal(rec["weekdays"].([]any), []any{float64(1)}) {
		t.Errorf("saved rule: %v", rec)
	}
	got := e.events(token, fid, "2026-02-01T00:00:00Z", "2026-02-16T00:00:00Z")
	if startsOf(got) != "2026-02-02T10:00 2026-02-09T10:00" {
		t.Errorf("occurrences: %s", startsOf(got))
	}
	if got[0]["id"] != id || got[0]["start_at"] != "2026-02-02T09:00:00Z" || got[0]["end_local"] != "2026-02-02T11:00" {
		t.Errorf("occurrence: %v", got[0])
	}
	// Editing starts from the series, not from an occurrence.
	if series["start_local"] != "2026-01-05T10:00" {
		t.Errorf("series: %v", series)
	}

	// An occurrence that started before the range but reaches into it counts.
	e.expect(204, "DELETE", path+"/"+id, token, nil)
	e.expect(201, "POST", path, token, eventBody(obj{
		"end_local": "2026-01-06T11:00", "recurrence": obj{"freq": "week", "interval": 2},
	}))
	got = e.events(token, fid, "2026-01-20T00:00:00Z", "2026-01-21T00:00:00Z")
	if startsOf(got) != "2026-01-19T10:00" || got[0]["end_local"] != "2026-01-20T11:00" {
		t.Errorf("reaching into the range: %v", got)
	}

	for _, rule := range []obj{
		{"freq": "stündlich", "interval": 1},
		{"freq": "day", "interval": 0},
		{"freq": "day", "interval": 1000},
		{"freq": "week", "interval": 1, "weekdays": []any{0}},
		{"freq": "week", "interval": 1, "weekdays": []any{8}},
		{"freq": "month", "interval": 1, "month_day": 32},
		{"freq": "month", "interval": 1, "month_week": 5, "month_weekday": 1},
		{"freq": "month", "interval": 1, "month_week": 1, "month_weekday": 8},
		{"freq": "month", "interval": 1, "month_week": 1},
	} {
		e.expect(400, "POST", path, token, eventBody(obj{"recurrence": rule}))
	}

	// Removing the rule ends the series.
	id = e.events(token, fid, "2026-01-20T00:00:00Z", "2026-01-21T00:00:00Z")[0]["id"].(string)
	e.expect(204, "PUT", path+"/"+id, token, eventBody(nil))
	if got := e.events(token, fid, "2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z"); len(got) != 0 {
		t.Errorf("rule not removed: %s", startsOf(got))
	}
}

func TestPrivateEvents(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	path := "/api/families/" + fid + "/events"
	guest, guestID := e.addMember(fid, owner, "b@example.de")
	other, _ := e.addMember(fid, owner, "c@example.de")
	outsider := e.register("d@example.de", "D", "G")
	outsiderID := e.expect(200, "GET", "/api/me", outsider, nil)["id"].(string)

	id := e.expect(201, "POST", path, owner, eventBody(obj{
		"visibility": "participants", "participants_all": false, "participant_ids": []any{guestID},
	}))["id"].(string)
	public := e.expect(201, "POST", path, owner, eventBody(obj{
		"title": "Offen", "participants_all": false, "participant_ids": []any{guestID},
	}))["id"].(string)
	from, to := "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z"

	ids := func(events []obj) []any {
		out := []any{}
		for _, event := range events {
			out = append(out, event["id"])
		}
		slices.SortFunc(out, func(a, b any) int { return strings.Compare(a.(string), b.(string)) })
		return out
	}
	both := []any{id, public}
	slices.SortFunc(both, func(a, b any) int { return strings.Compare(a.(string), b.(string)) })
	if got := ids(e.events(owner, fid, from, to)); !slices.Equal(got, both) {
		t.Errorf("creator: %v", got)
	}
	if got := ids(e.events(guest, fid, from, to)); !slices.Equal(got, both) {
		t.Errorf("participant: %v", got)
	}
	if got := ids(e.events(other, fid, from, to)); !slices.Equal(got, []any{public}) {
		t.Errorf("not participating: %v", got)
	}
	if got := e.expect(200, "GET", path+"/"+id, guest, nil)["participant_ids"].([]any); !slices.Equal(got, []any{guestID}) {
		t.Errorf("participants: %v", got)
	}

	// Attachments share the fate of their event.
	status, out := e.uploadTo(owner, path+"/"+id+"/attachments", "plan.png", pngHeader)
	if status != 201 {
		t.Fatalf("upload: %d %v", status, out)
	}
	fileID := out["id"].(string)
	attachment := path + "/" + id + "/attachments/" + fileID
	for _, r := range [][2]string{
		{"GET", path + "/" + id}, {"PUT", path + "/" + id}, {"DELETE", path + "/" + id},
		{"POST", attachment + "/link"}, {"DELETE", attachment},
	} {
		e.expect(404, r[0], r[1], other, eventBody(nil))
	}
	if status, _ := e.uploadTo(other, path+"/"+id+"/attachments", "x.png", pngHeader); status != 404 {
		t.Errorf("upload to a private event: %d", status)
	}
	// Neither the general file routes nor the lists offer a way around that.
	files := "/api/families/" + fid + "/files"
	e.expect(404, "GET", files+"/"+fileID+"/content", owner, nil)
	e.expect(404, "POST", files+"/"+fileID+"/link", owner, nil)
	e.expect(404, "DELETE", files+"/"+fileID, owner, nil)
	if status, raw := e.getRaw(files+"?kind=document", owner); status != 200 || strings.Contains(raw, fileID) {
		t.Errorf("attachment listed: %d %s", status, raw)
	}
	e.expect(200, "POST", attachment+"/link", guest, nil)
	// A file of the event must not be reachable through another event.
	e.expect(404, "POST", path+"/"+public+"/attachments/"+fileID+"/link", other, nil)

	got := e.expect(200, "GET", path+"/"+id, owner, nil)["attachments"].([]any)
	if len(got) != 1 || got[0].(obj)["name"] != "plan.png" {
		t.Errorf("attachments: %v", got)
	}

	e.expect(400, "POST", path, owner, eventBody(obj{"participants_all": false}))
	e.expect(400, "POST", path, owner, eventBody(obj{"participants_all": false, "participant_ids": []any{outsiderID}}))
	e.expect(400, "POST", path, owner, eventBody(obj{"visibility": "geheim"}))

	// Deleting the event also removes the file on disk.
	if !e.fileStored(fileID) {
		t.Fatal("file missing")
	}
	e.expect(204, "DELETE", path+"/"+id, owner, nil)
	if e.fileStored(fileID) {
		t.Errorf("file kept")
	}
}

func TestDeleteAttachment(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	path := "/api/families/" + e.firstFamily(token) + "/events"
	id := e.expect(201, "POST", path, token, eventBody(nil))["id"].(string)
	status, out := e.uploadTo(token, path+"/"+id+"/attachments", "plan.png", pngHeader)
	if status != 201 {
		t.Fatalf("upload: %d", status)
	}
	e.expect(204, "DELETE", path+"/"+id+"/attachments/"+out["id"].(string), token, nil)
	if got := e.expect(200, "GET", path+"/"+id, token, nil)["attachments"].([]any); len(got) != 0 {
		t.Errorf("attachments: %v", got)
	}
}

func TestEventCategory(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	base := "/api/families/" + fid
	categories := e.expect(200, "GET", base+"/categories", token, nil)["categories"].([]any)
	general := categories[0].(obj)["id"].(string)
	if categories[0].(obj)["used"] != false {
		t.Errorf("unused category: %v", categories[0])
	}
	foreign := e.register("b@example.de", "B", "G")
	foreignCategory := e.expect(200, "GET", "/api/families/"+e.firstFamily(foreign)+"/categories", foreign, nil)["categories"].([]any)[0].(obj)["id"]

	// Without a category, an event takes the default color of the family.
	id := e.expect(201, "POST", base+"/events", token, eventBody(nil))["id"].(string)
	if event := e.expect(200, "GET", base+"/events/"+id, token, nil); event["color"] != "#BBDEFB" || event["category_id"] != nil {
		t.Errorf("no category: %v", event)
	}
	e.expect(204, "PUT", base+"/events/"+id, token, eventBody(obj{"category_id": general}))
	if event := e.expect(200, "GET", base+"/events/"+id, token, nil); event["color"] != "#A5D6A7" || event["category_name"] != "Allgemein" {
		t.Errorf("category: %v", event)
	}
	e.expect(400, "POST", base+"/events", token, eventBody(obj{"category_id": foreignCategory}))
	e.expect(400, "POST", base+"/events", token, eventBody(obj{"category_id": "unbekannt"}))

	// A category without its own color also falls back.
	e.expect(204, "PUT", base+"/categories/"+general, token, obj{"name": "Allgemein", "color": ""})
	if event := e.expect(200, "GET", base+"/events/"+id, token, nil); event["color"] != "#BBDEFB" {
		t.Errorf("colorless category: %v", event)
	}

	// Used categories stay until the last event lets go of them.
	e.expect(409, "DELETE", base+"/categories/"+general, token, nil)
	if first := e.expect(200, "GET", base+"/categories", token, nil)["categories"].([]any)[0].(obj); first["used"] != true {
		t.Errorf("used category: %v", first)
	}
	e.expect(204, "PUT", base+"/events/"+id, token, eventBody(nil))
	e.expect(204, "DELETE", base+"/categories/"+general, token, nil)
}

func TestReminderMails(t *testing.T) {
	e := newEnv(t)
	owner := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(owner)
	path := "/api/families/" + fid + "/events"
	_, guestID := e.addMember(fid, owner, "b@example.de")
	e.addMember(fid, owner, "c@example.de")
	start := func(s string) time.Time {
		parsed, err := time.Parse(timeFormat, s)
		if err != nil {
			t.Fatal(err)
		}
		return parsed
	}
	e.mailer.to = nil
	run := func(at string) []string {
		e.mailer.to = nil
		e.server.sendReminders(context.Background(), start(at))
		sent := append([]string{}, e.mailer.to...)
		slices.Sort(sent)
		return sent
	}
	want := func(at string, recipients ...string) {
		t.Helper()
		if got := run(at); !slices.Equal(got, recipients) {
			t.Errorf("%s: %v, want %v", at, got, recipients)
		}
	}

	// 10:00 in Berlin is 09:00 UTC. Only participants hear about it.
	id := e.expect(201, "POST", path, owner, eventBody(obj{
		"title": "Zahnarzt\r\nBcc: x@example.de", "location": "Praxis", "reminders": []any{30, 1440},
		"participants_all": false, "participant_ids": []any{guestID},
	}))["id"].(string)
	want("2026-01-05T08:29:00Z")
	want("2026-01-05T08:30:00Z", "b@example.de")
	if !strings.Contains(e.mailer.last, "Montag, 05.01.2026, 10:00 Uhr (Europe/Berlin)") || !strings.Contains(e.mailer.last, "Ort: Praxis") {
		t.Errorf("mail: %s", e.mailer.last)
	}
	want("2026-01-05T08:31:00Z") // only once
	want("2026-01-04T09:00:00Z", "b@example.de")
	// A reminder whose time has long passed stays silent, and so does a past event.
	want("2026-01-05T08:50:00Z")
	want("2026-01-05T10:00:00Z")

	// The subject stays one header line whatever the title contains.
	event := e.expect(200, "GET", path+"/"+id, owner, nil)
	subject, _ := reminderMail(obj{
		"title": event["title"], "family_name": "F", "all_day": false, "location": "", "description": "",
	}, "B", start("2026-01-05T09:00:00Z"))
	if strings.ContainsAny(subject, "\r\n") || subject != "Erinnerung: Zahnarzt Bcc: x@example.de" {
		t.Errorf("subject: %q", subject)
	}
	e.expect(204, "DELETE", path+"/"+id, owner, nil)

	// A series reminds of each occurrence, for everyone by default.
	id = e.expect(201, "POST", path, owner, eventBody(obj{
		"reminders": []any{5}, "recurrence": obj{"freq": "day", "interval": 1},
	}))["id"].(string)
	everyone := []string{"a@example.de", "b@example.de", "c@example.de"}
	want("2026-01-06T08:55:00Z", everyone...)
	want("2026-01-06T08:55:00Z")
	want("2026-01-07T08:55:00Z", everyone...)
	e.expect(204, "DELETE", path+"/"+id, owner, nil)

	// A failing mail is logged and does not stop the next recipient.
	id = e.expect(201, "POST", path, owner, eventBody(obj{"reminders": []any{5}}))["id"].(string)
	e.mailer.err = errors.New("kaputt")
	run("2026-01-05T08:55:00Z")
	e.mailer.err = nil
	var n int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM error_log WHERE endpoint = 'Erinnerung' AND family_name = 'F' AND email <> ''`).Scan(&n); err != nil || n != 3 {
		t.Errorf("logged: %d %v", n, err)
	}
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM reminder_sent WHERE event_id = ?`, id).Scan(&n); err != nil || n != 3 {
		t.Errorf("noted: %d %v", n, err)
	}

	e.expect(400, "POST", path, owner, eventBody(obj{"reminders": []any{0}}))
	e.expect(400, "POST", path, owner, eventBody(obj{"reminders": []any{maxReminderMinutes + 1}}))
	// Doubles collapse.
	id = e.expect(201, "POST", path, owner, eventBody(obj{"reminders": []any{30, 30, 5}}))["id"].(string)
	if got := e.expect(200, "GET", path+"/"+id, owner, nil)["reminders"].([]any); fmt.Sprint(got) != "[5 30]" {
		t.Errorf("reminders: %v", got)
	}
}

func TestSearchPlaces(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	var query url.Values
	var agent string
	fail := false
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if fail {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		query, agent = r.URL.Query(), r.Header.Get("User-Agent")
		feature := func(properties obj) obj {
			return obj{"properties": properties, "geometry": obj{"coordinates": []float64{9.25, 47.92}}}
		}
		town := obj{"name": "Pfullendorf", "county": "Landkreis Sigmaringen", "state": "Baden-Württemberg", "postcode": "88630", "country": "Deutschland"}
		json.NewEncoder(w).Encode(obj{"features": []obj{
			feature(town),
			// The same address again, as from a second piece of a street.
			feature(town),
			feature(obj{"name": "Flugplatz", "street": "Hauptstraße", "housenumber": "5", "city": "Flugplatz", "country": "Deutschland"}),
			{"properties": obj{"name": "Ohne Koordinaten"}, "geometry": obj{}},
		}})
	}))
	defer service.Close()
	e.server.placesURL = service.URL

	e.expect(401, "GET", "/api/places?q=x", "", nil)
	e.expect(400, "GET", "/api/places?q=", token, nil)
	got := e.expect(200, "GET", "/api/places?q="+url.QueryEscape("Marienplatz & Co"), token, nil)["places"].([]any)
	if len(got) != 2 {
		t.Fatalf("places: %v", got)
	}
	first := got[0].(obj)
	if first["label"] != "Pfullendorf, Landkreis Sigmaringen, Baden-Württemberg, 88630, Deutschland" || first["lat"] != 47.92 || first["lon"] != 9.25 {
		t.Errorf("place: %v", first)
	}
	if second := got[1].(obj); second["label"] != "Flugplatz, Hauptstraße 5, Deutschland" {
		t.Errorf("repeated parts: %v", second)
	}
	if query.Get("q") != "Marienplatz & Co" || query.Get("lang") != "de" || !strings.HasPrefix(agent, "Kintura/") {
		t.Errorf("request: %v %s", query, agent)
	}

	// Calls keep a distance, even while someone is typing.
	began := time.Now()
	e.expect(200, "GET", "/api/places?q=b", token, nil)
	if time.Since(began) < placesInterval/2 {
		t.Errorf("no pause: %s", time.Since(began))
	}

	fail = true
	e.expect(502, "GET", "/api/places?q=c", token, nil)
	var n int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM error_log WHERE endpoint = 'GET /api/places'`).Scan(&n); err != nil || n != 1 {
		t.Errorf("logged: %d %v", n, err)
	}
}

func TestEventCoordinates(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	base := "/api/families/" + e.firstFamily(token) + "/events"
	place := obj{"location": "Pfullendorf", "location_lat": 47.92, "location_lon": 9.25}

	id := e.expect(201, "POST", base, token, eventBody(place))["id"].(string)
	if got := e.expect(200, "GET", base+"/"+id, token, nil); got["location_lat"] != 47.92 || got["location_lon"] != 9.25 {
		t.Errorf("saved: %v", got)
	}
	// Free text has none, and saving it removes the old ones.
	e.expect(204, "PUT", base+"/"+id, token, eventBody(obj{"location": "bei Oma"}))
	if got := e.expect(200, "GET", base+"/"+id, token, nil); got["location_lat"] != nil || got["location_lon"] != nil {
		t.Errorf("free text: %v", got)
	}
	for name, body := range map[string]obj{
		"half":     {"location": "X", "location_lat": 47.92},
		"no place": {"location": "", "location_lat": 47.92, "location_lon": 9.25},
		"lat":      {"location": "X", "location_lat": 91.0, "location_lon": 9.25},
		"lon":      {"location": "X", "location_lat": 47.92, "location_lon": -181.0},
	} {
		if status, out := e.call("POST", base, token, eventBody(body)); status != 400 {
			t.Errorf("%s: status %d: %v", name, status, out)
		}
	}
}

func TestExistingEventsStayVisible(t *testing.T) {
	e := newEnv(t)
	token := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(token)
	// As left by the migration: no time zone and no creator.
	if _, err := e.server.db.Exec(`INSERT INTO events (id, family_id, title, start_at, end_at) VALUES ('old', ?, 'Alt', '2026-01-05T09:00:00Z', '2026-01-05T10:00:00Z')`, fid); err != nil {
		t.Fatal(err)
	}
	got := e.events(token, fid, "2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z")
	if len(got) != 1 || got[0]["start_local"] != "2026-01-05T10:00" || got[0]["timezone"] != "Europe/Berlin" {
		t.Errorf("old event: %v", got)
	}
}

func (e *testEnv) uploadTo(token, path, name string, content []byte) (int, obj) {
	e.t.Helper()
	body, contentType := uploadBody(e.t, name, content)
	req, _ := http.NewRequest("POST", e.srv.URL+path, body)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", contentType)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	out := obj{}
	json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func (e *testEnv) getRaw(path, token string) (int, string) {
	e.t.Helper()
	req, _ := http.NewRequest("GET", e.srv.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(raw)
}
