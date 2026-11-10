package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
	_ "time/tzdata" // Windows and small containers ship no time zone database.

	"github.com/kinturas/kintura/backend/internal/database"
)

const (
	defaultTimezone    = "Europe/Berlin"
	localTimeFormat    = "2006-01-02T15:04"
	maxReminderMinutes = 366 * 24 * 60
	maxReminders       = 10
	placesURL          = "https://photon.komoot.io/api/" // made for searching while typing, unlike Nominatim
	placesInterval     = 300 * time.Millisecond          // keeps the use of the free service fair
)

// timezones can be chosen for an event. Zones with daylight saving have two names.
var timezones = []struct{ id, standard, summer string }{
	{"Pacific/Honolulu", "Hawaii-Zeit", ""},
	{"America/Anchorage", "Alaska-Normalzeit", "Alaska-Sommerzeit"},
	{"America/Los_Angeles", "Nordamerikanische Westküsten-Normalzeit", "Nordamerikanische Westküsten-Sommerzeit"},
	{"America/Denver", "Rocky-Mountain-Normalzeit", "Rocky-Mountain-Sommerzeit"},
	{"America/Chicago", "Nordamerikanische Inland-Normalzeit", "Nordamerikanische Inland-Sommerzeit"},
	{"America/New_York", "Nordamerikanische Ostküsten-Normalzeit", "Nordamerikanische Ostküsten-Sommerzeit"},
	{"America/Sao_Paulo", "Brasília-Zeit", ""},
	{"Atlantic/Azores", "Azoren-Normalzeit", "Azoren-Sommerzeit"},
	{"UTC", "Koordinierte Weltzeit", ""},
	{"Europe/London", "Britische Normalzeit", "Britische Sommerzeit"},
	{"Europe/Lisbon", "Westeuropäische Normalzeit", "Westeuropäische Sommerzeit"},
	{"Europe/Berlin", "Mitteleuropäische Normalzeit", "Mitteleuropäische Sommerzeit"},
	{"Europe/Athens", "Osteuropäische Normalzeit", "Osteuropäische Sommerzeit"},
	{"Europe/Istanbul", "Türkische Zeit", ""},
	{"Europe/Moscow", "Moskauer Zeit", ""},
	{"Asia/Dubai", "Golf-Zeit", ""},
	{"Asia/Kolkata", "Indische Zeit", ""},
	{"Asia/Bangkok", "Indochina-Zeit", ""},
	{"Asia/Shanghai", "Chinesische Zeit", ""},
	{"Asia/Tokyo", "Japanische Zeit", ""},
	{"Australia/Sydney", "Ostaustralische Normalzeit", "Ostaustralische Sommerzeit"},
	{"Pacific/Auckland", "Neuseeländische Normalzeit", "Neuseeländische Sommerzeit"},
}

func (s *Server) defaultZone() string {
	if s.timezone != "" {
		return s.timezone
	}
	return defaultTimezone
}

// zone resolves the time zone of an event; events from before time zones have none.
func (s *Server) zone(name string) (*time.Location, error) {
	if name == "" {
		name = s.defaultZone()
	}
	return time.LoadLocation(name)
}

func (s *Server) listTimezones(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	now := time.Now()
	zones := []map[string]string{}
	add := func(id, standard, summer string) error {
		loc, err := time.LoadLocation(id)
		if err != nil {
			return err
		}
		label := standard
		if t := now.In(loc); t.IsDST() && summer != "" {
			label = summer
		}
		_, offset := now.In(loc).Zone()
		sign := '+'
		if offset < 0 {
			sign, offset = '-', -offset
		}
		zones = append(zones, map[string]string{
			"id": id, "label": label, "offset": fmt.Sprintf("GMT%c%02d:%02d", sign, offset/3600, offset%3600/60),
		})
		return nil
	}
	listed := false
	for _, tz := range timezones {
		listed = listed || tz.id == s.defaultZone()
		if err := add(tz.id, tz.standard, tz.summer); err != nil {
			return err
		}
	}
	if !listed {
		if err := add(s.defaultZone(), s.defaultZone(), ""); err != nil {
			return err
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"default": s.defaultZone(), "zones": zones})
	return nil
}

func (s *Server) zoneAllowed(name string) bool {
	return name == s.defaultZone() || slices.ContainsFunc(timezones, func(tz struct{ id, standard, summer string }) bool {
		return tz.id == name
	})
}

const eventColumns = `SELECT e.id, e.title, e.description, e.start_at, e.end_at, e.all_day, e.timezone, e.recurrence,
	e.participants_all, e.visibility, e.category_id, e.location, e.location_lat, e.location_lon,
	e.created_by, COALESCE(cm.name, '') AS creator_name,
	e.updated_at, COALESCE(um.name, '') AS updated_by_name,
	k.name AS category_name, k.color AS category_color,
	COALESCE(NULLIF(k.color, ''), f.default_color) AS color
	FROM events e JOIN families f ON f.id = e.family_id LEFT JOIN categories k ON k.id = e.category_id
	LEFT JOIN memberships cm ON cm.family_id = e.family_id AND cm.user_id = e.created_by
	LEFT JOIN memberships um ON um.family_id = e.family_id AND um.user_id = e.updated_by `

// eventVisible limits a query on events e to what a user may see. It takes the user id twice.
const eventVisible = ` AND (e.visibility = 'all' OR e.participants_all = 1 OR e.created_by = ?
	OR EXISTS (SELECT 1 FROM event_participants p WHERE p.event_id = e.id AND p.user_id = ?)) `

// singleEventVisible is the limit for the routes of a single event. Managers may open any
// event of their family; what they get listed is limited separately, see eventsInRange.
func singleEventVisible(c reqCtx) (string, []any) {
	if c.isManager() {
		return " ", nil
	}
	return eventVisible, []any{c.userID, c.userID}
}

// decorate adds the wall clock and the parsed rule of an event row to what the
// database returns, and reports the first start, its location and the length.
func (s *Server) decorate(row map[string]any) (time.Time, time.Duration, *recurrence, error) {
	loc, err := s.zone(row["timezone"].(string))
	if err != nil {
		return time.Time{}, 0, nil, err
	}
	row["timezone"] = loc.String()
	start, err := time.Parse(timeFormat, row["start_at"].(string))
	if err != nil {
		return time.Time{}, 0, nil, err
	}
	end, err := time.Parse(timeFormat, row["end_at"].(string))
	if err != nil {
		return time.Time{}, 0, nil, err
	}
	start, end = start.In(loc), end.In(loc)
	row["start_local"], row["end_local"] = start.Format(localTimeFormat), end.Format(localTimeFormat)
	var rec *recurrence
	if raw := row["recurrence"].(string); raw != "" {
		rec = &recurrence{}
		if err := json.Unmarshal([]byte(raw), rec); err != nil {
			return time.Time{}, 0, nil, err
		}
	}
	row["recurrence"] = rec
	return start, wallClock(end).Sub(wallClock(start)), rec, nil
}

// listEvents returns everything that happens in the range. A series appears once
// per occurrence, each with the id of the series.
func (s *Server) listEvents(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	fromText, err := normalizeTime(r.URL.Query().Get("from"))
	if err != nil {
		return err
	}
	toText, err := normalizeTime(r.URL.Query().Get("to"))
	if err != nil {
		return err
	}
	from, _ := time.Parse(timeFormat, fromText)
	to, _ := time.Parse(timeFormat, toText)
	out, err := s.eventsInRange(r.Context(), c, entryRange{from: from, to: to, fromText: fromText, toText: toText}, false)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, out)
	return nil
}

// eventsInRange keeps to what the user may see, unless everything is asked for,
// which only a manager may do and the caller has to check.
func (s *Server) eventsInRange(ctx context.Context, c reqCtx, span entryRange, everything bool) ([]map[string]any, error) {
	from, to := span.from, span.to
	query := eventColumns + `WHERE e.family_id = ? AND e.start_at < ? AND (e.recurrence <> '' OR e.end_at >= ?)`
	args := []any{c.familyID, span.toText, span.fromText}
	if !everything {
		query += eventVisible
		args = append(args, c.userID, c.userID)
	}
	rows, err := queryRows(ctx, s.db, query+` ORDER BY e.start_at`, args...)
	if err != nil {
		return nil, err
	}
	out := []map[string]any{}
	for _, row := range rows {
		first, length, rec, err := s.decorate(row)
		if err != nil {
			return nil, err
		}
		if rec == nil {
			out = append(out, row)
			continue
		}
		// An occurrence that began before the range can still reach into it.
		for _, start := range rec.starts(first, from.Add(-length), to) {
			end := occurrenceEnd(start, length)
			if end.Before(from) {
				continue
			}
			occurrence := make(map[string]any, len(row))
			for k, v := range row {
				occurrence[k] = v
			}
			occurrence["start_at"] = start.UTC().Format(timeFormat)
			occurrence["end_at"] = end.UTC().Format(timeFormat)
			occurrence["start_local"] = start.Format(localTimeFormat)
			occurrence["end_local"] = end.Format(localTimeFormat)
			out = append(out, occurrence)
		}
	}
	slices.SortStableFunc(out, func(a, b map[string]any) int {
		return strings.Compare(a["start_at"].(string), b["start_at"].(string))
	})
	return out, nil
}

// eventAccess reports errNotFound for an event the user may not see, just as for
// one of another family.
func (s *Server) eventAccess(ctx context.Context, c reqCtx, id string) error {
	var found int
	limit, limitArgs := singleEventVisible(c)
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM events e WHERE e.id = ? AND e.family_id = ?`+limit,
		append([]any{id, c.familyID}, limitArgs...)...).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	return err
}

// eventChangeAccess is for what changes an event or its attachments. Whoever sees an
// event may comment on it and copy it, but changing it is up to its creator and the
// managers. An event whose creator is gone is left to the managers.
func (s *Server) eventChangeAccess(ctx context.Context, c reqCtx, id string) error {
	if err := s.eventAccess(ctx, c, id); err != nil {
		return err
	}
	if c.isManager() {
		return nil
	}
	var creator sql.NullString
	if err := s.db.QueryRowContext(ctx, `SELECT created_by FROM events WHERE id = ? AND family_id = ?`, id, c.familyID).Scan(&creator); err != nil {
		return err
	}
	if creator.String != c.userID {
		return fail(http.StatusForbidden, "Termine anderer Mitglieder können nur Manager ändern.")
	}
	return nil
}

// getEvent returns an event or series as it was saved, with everything the form shows.
func (s *Server) getEvent(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	limit, limitArgs := singleEventVisible(c)
	rows, err := queryRows(ctx, s.db, eventColumns+`WHERE e.id = ? AND e.family_id = ?`+limit, append([]any{id, c.familyID}, limitArgs...)...)
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return errNotFound
	}
	event := rows[0]
	if _, _, _, err := s.decorate(event); err != nil {
		return err
	}
	participants, err := queryRows(ctx, s.db,
		`SELECT p.user_id FROM event_participants p JOIN memberships m ON m.user_id = p.user_id AND m.family_id = ? WHERE p.event_id = ?`, c.familyID, id)
	if err != nil {
		return err
	}
	ids := []any{}
	for _, participant := range participants {
		ids = append(ids, participant["user_id"])
	}
	event["participant_ids"] = ids
	reminders, err := queryRows(ctx, s.db, `SELECT minutes FROM event_reminders WHERE event_id = ? ORDER BY minutes`, id)
	if err != nil {
		return err
	}
	minutes := []any{}
	for _, reminder := range reminders {
		minutes = append(minutes, reminder["minutes"])
	}
	event["reminders"] = minutes
	attachments, err := queryRows(ctx, s.db, `SELECT id, name, size FROM files WHERE event_id = ? ORDER BY created_at, name`, id)
	if err != nil {
		return err
	}
	event["attachments"] = attachments
	comments, err := queryRows(ctx, s.db, eventCommentColumns+`WHERE c.event_id = ? ORDER BY c.created_at, c.seq`, c.familyID, id)
	if err != nil {
		return err
	}
	event["comments"] = comments
	writeJSON(w, http.StatusOK, event)
	return nil
}

// eventCommentColumns takes the family id first. Whoever left it has no name any more.
const eventCommentColumns = `SELECT c.id, c.body, c.created_at, COALESCE(m.name, '') AS author_name FROM event_comments c
	LEFT JOIN memberships m ON m.user_id = c.user_id AND m.family_id = ? `

func (s *Server) addEventComment(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, eventID := r.Context(), r.PathValue("id")
	if err := s.eventAccess(ctx, c, eventID); err != nil {
		return err
	}
	var in struct {
		Body string `json:"body"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	body, err := required(in.Body, "Kommentar", 2000)
	if err != nil {
		return err
	}
	id := newID()
	if _, err := s.db.ExecContext(ctx, `INSERT INTO event_comments (id, event_id, user_id, body, created_at, seq)
		 VALUES (?1, ?2, ?3, ?4, ?5, (SELECT COALESCE(MAX(seq), 0) + 1 FROM event_comments WHERE event_id = ?2))`,
		id, eventID, c.userID, body, now()); err != nil {
		return err
	}
	rows, err := queryRows(ctx, s.db, eventCommentColumns+`WHERE c.id = ?`, c.familyID, id)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, rows[0])
	return nil
}

// eventICS returns the event as a file for other apps, with all of a series.
func (s *Server) eventICS(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.eventAccess(ctx, c, id); err != nil {
		return err
	}
	rows, err := queryRows(ctx, s.db, eventColumns+`WHERE e.id = ? AND e.family_id = ?`, id, c.familyID)
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return errNotFound
	}
	start, length, rec, err := s.decorate(rows[0])
	if err != nil {
		return err
	}
	content := renderICS(rows[0]["title"].(string), []icsEntry{icsEntryOf(rows[0], start, length, rec)})
	writeJSON(w, http.StatusOK, map[string]string{"filename": "termin.ics", "content": content})
	return nil
}

const maxCopyDays = 10

// copyEvent copies an event, as it is or to other days at the same time of day, into
// this family or another one of the user. The copy belongs to the user, and attachments
// and comments stay with the original. A series copied to days becomes single events.
func (s *Server) copyEvent(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.eventAccess(ctx, c, id); err != nil {
		return err
	}
	var in struct {
		Days     []string `json:"days"`
		FamilyID string   `json:"family_id"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if len(in.Days) > maxCopyDays {
		return fail(http.StatusBadRequest, fmt.Sprintf("Höchstens %d Tage auf einmal", maxCopyDays))
	}
	target := c.familyID
	if in.FamilyID != "" && in.FamilyID != c.familyID {
		var found int
		err := s.db.QueryRowContext(ctx, `SELECT 1 FROM memberships WHERE family_id = ? AND user_id = ?`, in.FamilyID, c.userID).Scan(&found)
		if errors.Is(err, sql.ErrNoRows) {
			return errNotFound
		}
		if err != nil {
			return err
		}
		target = in.FamilyID
	}

	var title, description, startAt, endAt, timezone, visibility, rule, location string
	var allDay, everyone bool
	var category sql.NullString
	var lat, lon sql.NullFloat64
	if err := s.db.QueryRowContext(ctx,
		`SELECT title, description, start_at, end_at, all_day, timezone, participants_all, visibility, category_id, recurrence, location, location_lat, location_lon
		 FROM events WHERE id = ? AND family_id = ?`, id, c.familyID).
		Scan(&title, &description, &startAt, &endAt, &allDay, &timezone, &everyone, &visibility, &category, &rule, &location, &lat, &lon); err != nil {
		return err
	}
	// Categories belong to a family.
	if target != c.familyID {
		category = sql.NullString{}
	}

	type span struct{ start, end string }
	spans := []span{{startAt, endAt}}
	if len(in.Days) > 0 {
		loc, err := s.zone(timezone)
		if err != nil {
			return err
		}
		start, err := time.Parse(timeFormat, startAt)
		if err != nil {
			return err
		}
		end, err := time.Parse(timeFormat, endAt)
		if err != nil {
			return err
		}
		start, end = start.In(loc), end.In(loc)
		length := wallClock(end).Sub(wallClock(start))
		hour, minute, sec := start.Clock()
		spans = nil
		rule = ""
		for _, text := range in.Days {
			day, err := time.Parse("2006-01-02", text)
			if err != nil {
				return fail(http.StatusBadRequest, "Ungültiges Datum")
			}
			y, m, d := day.Date()
			moved := time.Date(y, m, d, hour, minute, sec, 0, loc)
			spans = append(spans, span{moved.UTC().Format(timeFormat), occurrenceEnd(moved, length).UTC().Format(timeFormat)})
		}
	}

	// Only members of the target can take part. If nobody is left, the event stays with the user.
	participants := []string{}
	if !everyone {
		rows, err := queryRows(ctx, s.db,
			`SELECT p.user_id FROM event_participants p JOIN memberships m ON m.user_id = p.user_id AND m.family_id = ? WHERE p.event_id = ?`, target, id)
		if err != nil {
			return err
		}
		for _, row := range rows {
			participants = append(participants, row["user_id"].(string))
		}
		if len(participants) == 0 {
			participants = []string{c.userID}
		}
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	ids := []string{}
	for _, copied := range spans {
		copyID := newID()
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO events (id, family_id, title, description, start_at, end_at, all_day, timezone, created_by,
				participants_all, visibility, category_id, recurrence, location, location_lat, location_lon, updated_at, updated_by)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			copyID, target, title, description, copied.start, copied.end, allDay, timezone, c.userID,
			everyone, visibility, category, rule, location, lat, lon, now(), c.userID); err != nil {
			return err
		}
		for _, userID := range participants {
			if _, err := tx.ExecContext(ctx, `INSERT INTO event_participants (event_id, user_id) VALUES (?, ?)`, copyID, userID); err != nil {
				return err
			}
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO event_reminders (event_id, minutes) SELECT ?, minutes FROM event_reminders WHERE event_id = ?`, copyID, id); err != nil {
			return err
		}
		ids = append(ids, copyID)
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]any{"ids": ids})
	return nil
}

type eventInput struct {
	Title           string      `json:"title"`
	Description     string      `json:"description"`
	StartLocal      string      `json:"start_local"`
	EndLocal        string      `json:"end_local"`
	AllDay          bool        `json:"all_day"`
	Timezone        string      `json:"timezone"`
	ParticipantsAll *bool       `json:"participants_all"`
	ParticipantIDs  []string    `json:"participant_ids"`
	Visibility      string      `json:"visibility"`
	CategoryID      string      `json:"category_id"`
	Recurrence      *recurrence `json:"recurrence"`
	Reminders       []int       `json:"reminders"`
	Location        string      `json:"location"`
	LocationLat     *float64    `json:"location_lat"`
	LocationLon     *float64    `json:"location_lon"`

	startAt, endAt, rule string
	everyone             bool
}

func (s *Server) readEvent(w http.ResponseWriter, r *http.Request, c reqCtx) (eventInput, error) {
	var in eventInput
	if err := readJSON(w, r, &in); err != nil {
		return in, err
	}
	var err error
	if in.Title, err = required(in.Title, "Titel", 200); err != nil {
		return in, err
	}
	if in.Timezone == "" {
		in.Timezone = s.defaultZone()
	}
	if !s.zoneAllowed(in.Timezone) {
		return in, fail(http.StatusBadRequest, "Unbekannte Zeitzone")
	}
	loc, err := time.LoadLocation(in.Timezone)
	if err != nil {
		return in, err
	}
	start, err := time.ParseInLocation(localTimeFormat, in.StartLocal, loc)
	if err != nil {
		return in, fail(http.StatusBadRequest, "Ungültiger Zeitpunkt")
	}
	end, err := time.ParseInLocation(localTimeFormat, in.EndLocal, loc)
	if err != nil {
		return in, fail(http.StatusBadRequest, "Ungültiger Zeitpunkt")
	}
	if end.Before(start) {
		return in, fail(http.StatusBadRequest, "Das Ende liegt vor dem Beginn.")
	}
	in.startAt, in.endAt = start.UTC().Format(timeFormat), end.UTC().Format(timeFormat)

	if in.Visibility == "" {
		in.Visibility = "all"
	}
	if in.Visibility != "all" && in.Visibility != "participants" {
		return in, fail(http.StatusBadRequest, "Ungültige Sichtbarkeit")
	}
	if in.Location = strings.TrimSpace(in.Location); len([]rune(in.Location)) > 300 {
		return in, fail(http.StatusBadRequest, "Der Ort ist zu lang")
	}
	// Coordinates only exist for a place from the search, and only as a pair.
	if (in.LocationLat == nil) != (in.LocationLon == nil) || (in.LocationLat != nil &&
		(in.Location == "" || *in.LocationLat < -90 || *in.LocationLat > 90 || *in.LocationLon < -180 || *in.LocationLon > 180)) {
		return in, fail(http.StatusBadRequest, "Ungültige Koordinaten")
	}
	if in.Recurrence != nil {
		if err := in.Recurrence.normalize(start); err != nil {
			return in, err
		}
		raw, err := json.Marshal(in.Recurrence)
		if err != nil {
			return in, err
		}
		in.rule = string(raw)
	}

	if len(in.Reminders) > maxReminders {
		return in, fail(http.StatusBadRequest, "Zu viele Erinnerungen")
	}
	for _, minutes := range in.Reminders {
		if minutes < 1 || minutes > maxReminderMinutes {
			return in, fail(http.StatusBadRequest, "Ungültige Erinnerung")
		}
	}
	slices.Sort(in.Reminders)
	in.Reminders = slices.Compact(in.Reminders)

	// Participants and category come from the client, so they must belong to this family.
	ctx := r.Context()
	in.everyone = in.ParticipantsAll == nil || *in.ParticipantsAll
	if in.everyone {
		in.ParticipantIDs = nil
	} else if len(in.ParticipantIDs) == 0 {
		return in, fail(http.StatusBadRequest, "Bitte mindestens eine beteiligte Person auswählen.")
	}
	slices.Sort(in.ParticipantIDs)
	in.ParticipantIDs = slices.Compact(in.ParticipantIDs)
	for _, id := range in.ParticipantIDs {
		var found int
		err := s.db.QueryRowContext(ctx, `SELECT 1 FROM memberships WHERE family_id = ? AND user_id = ?`, c.familyID, id).Scan(&found)
		if errors.Is(err, sql.ErrNoRows) {
			return in, fail(http.StatusBadRequest, "Unbekannte beteiligte Person")
		}
		if err != nil {
			return in, err
		}
	}
	if in.CategoryID != "" {
		var found int
		err := s.db.QueryRowContext(ctx, `SELECT 1 FROM categories WHERE id = ? AND family_id = ?`, in.CategoryID, c.familyID).Scan(&found)
		if errors.Is(err, sql.ErrNoRows) {
			return in, fail(http.StatusBadRequest, "Unbekannte Kategorie")
		}
		if err != nil {
			return in, err
		}
	}
	return in, nil
}

// saveEventLists replaces the participants and reminders of an event.
func saveEventLists(ctx context.Context, tx *database.Tx, id string, in eventInput) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM event_participants WHERE event_id = ?`, id); err != nil {
		return err
	}
	for _, userID := range in.ParticipantIDs {
		if _, err := tx.ExecContext(ctx, `INSERT INTO event_participants (event_id, user_id) VALUES (?, ?)`, id, userID); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM event_reminders WHERE event_id = ?`, id); err != nil {
		return err
	}
	for _, minutes := range in.Reminders {
		if _, err := tx.ExecContext(ctx, `INSERT INTO event_reminders (event_id, minutes) VALUES (?, ?)`, id, minutes); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) createEvent(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := s.readEvent(w, r, c)
	if err != nil {
		return err
	}
	ctx := r.Context()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	id := newID()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO events (id, family_id, title, description, start_at, end_at, all_day, timezone, created_by,
			participants_all, visibility, category_id, recurrence, location, location_lat, location_lon, updated_at, updated_by)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, c.familyID, in.Title, in.Description, in.startAt, in.endAt, in.AllDay, in.Timezone, c.userID,
		in.everyone, in.Visibility, nullable(in.CategoryID), in.rule, in.Location, in.LocationLat, in.LocationLon, now(), c.userID); err != nil {
		return err
	}
	if err := saveEventLists(ctx, tx, id, in); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

func (s *Server) updateEvent(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.eventChangeAccess(ctx, c, id); err != nil {
		return err
	}
	in, err := s.readEvent(w, r, c)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx,
		`UPDATE events SET title = ?, description = ?, start_at = ?, end_at = ?, all_day = ?, timezone = ?,
			participants_all = ?, visibility = ?, category_id = ?, recurrence = ?, location = ?, location_lat = ?, location_lon = ?,
			updated_at = ?, updated_by = ?
		 WHERE id = ? AND family_id = ?`,
		in.Title, in.Description, in.startAt, in.endAt, in.AllDay, in.Timezone,
		in.everyone, in.Visibility, nullable(in.CategoryID), in.rule, in.Location, in.LocationLat, in.LocationLon, now(), c.userID, id, c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	if err := saveEventLists(ctx, tx, id, in); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

// setEventCreator hands an event over to another member. Only for managers.
func (s *Server) setEventCreator(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if !c.isManager() {
		return fail(http.StatusForbidden, "Nur für Manager erlaubt")
	}
	ctx := r.Context()
	if err := s.eventAccess(ctx, c, r.PathValue("id")); err != nil {
		return err
	}
	var in struct {
		UserID string `json:"user_id"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	var found int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM memberships WHERE family_id = ? AND user_id = ?`, c.familyID, in.UserID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return fail(http.StatusBadRequest, "Ersteller muss Mitglied sein")
	}
	if err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, `UPDATE events SET created_by = ?, updated_at = ?, updated_by = ? WHERE id = ? AND family_id = ?`,
		in.UserID, now(), c.userID, r.PathValue("id"), c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) deleteEvent(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.eventChangeAccess(ctx, c, id); err != nil {
		return err
	}
	attachments, err := queryRows(ctx, s.db, `SELECT id FROM files WHERE event_id = ?`, id)
	if err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, `DELETE FROM events WHERE id = ? AND family_id = ?`, id, c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	for _, attachment := range attachments {
		s.removeStoredFile(r, attachment["id"].(string))
	}
	return noContent(w)
}

// removeStoredFile removes the file of a row that is already gone. r may be nil.
func (s *Server) removeStoredFile(r *http.Request, id string) {
	if err := s.files.Delete(context.Background(), id); err != nil {
		s.logError(r, http.StatusInternalServerError, "Anhang löschen: "+err.Error())
	}
}

func (s *Server) uploadAttachment(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	id := r.PathValue("id")
	if err := s.eventChangeAccess(r.Context(), c, id); err != nil {
		return err
	}
	return s.storeUpload(w, r, c, "document", id)
}

// attachmentAccess checks both the event and that the file belongs to it.
func (s *Server) attachmentAccess(r *http.Request, c reqCtx) (string, error) {
	ctx, eventID, id := r.Context(), r.PathValue("id"), r.PathValue("fileId")
	if err := s.eventAccess(ctx, c, eventID); err != nil {
		return "", err
	}
	var found int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM files WHERE id = ? AND event_id = ?`, id, eventID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return "", errNotFound
	}
	return id, err
}

func (s *Server) attachmentLink(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	id, err := s.attachmentAccess(r, c)
	if err != nil {
		return err
	}
	return s.writeDownloadLink(w, r, id)
}

func (s *Server) deleteAttachment(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	id, err := s.attachmentAccess(r, c)
	if err != nil {
		return err
	}
	if err := s.eventChangeAccess(r.Context(), c, r.PathValue("id")); err != nil {
		return err
	}
	return s.removeFile(w, r, id)
}

// placeLabel joins the parts of an address, without what repeats itself.
func placeLabel(name, street, number, city, county, state, postcode, country string) string {
	parts := []string{}
	for _, part := range []string{name, strings.TrimSpace(street + " " + number), city, county, state, postcode, country} {
		if part != "" && !slices.Contains(parts, part) {
			parts = append(parts, part)
		}
	}
	return strings.Join(parts, ", ")
}

// searchPlaces looks up addresses for the location of an event. Going through the
// backend keeps the service replaceable and its usage limit in one place.
func (s *Server) searchPlaces(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	query, err := required(r.URL.Query().Get("q"), "Suchbegriff", 200)
	if err != nil {
		return err
	}
	s.placesMu.Lock()
	if wait := placesInterval - time.Since(s.placesLast); wait > 0 {
		time.Sleep(wait)
	}
	s.placesLast = time.Now()
	s.placesMu.Unlock()

	base := s.placesURL
	if base == "" {
		base = placesURL
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		base+"?"+url.Values{"limit": {"8"}, "lang": {"de"}, "q": {query}}.Encode(), nil)
	if err != nil {
		return err
	}
	// The service asks every application to identify itself.
	req.Header.Set("User-Agent", "Kintura/1.0 (+"+s.publicURL+")")
	unavailable := func(cause error) error {
		return &apiError{http.StatusBadGateway, "Die Ortssuche ist gerade nicht erreichbar.", fmt.Errorf("Ortssuche: %w", cause)}
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return unavailable(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return unavailable(fmt.Errorf("Status %d", res.StatusCode))
	}
	var found struct {
		Features []struct {
			Properties struct {
				Name, Street, City, County, State, Postcode, Country string
				HouseNumber                                          string `json:"housenumber"`
			} `json:"properties"`
			Geometry struct {
				Coordinates []float64 `json:"coordinates"`
			} `json:"geometry"`
		} `json:"features"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&found); err != nil {
		return unavailable(err)
	}
	places := []map[string]any{}
	seen := map[string]bool{}
	for _, feature := range found.Features {
		p := feature.Properties
		label := placeLabel(p.Name, p.Street, p.HouseNumber, p.City, p.County, p.State, p.Postcode, p.Country)
		// A long street consists of many pieces with the same address.
		if label == "" || seen[label] || len(feature.Geometry.Coordinates) != 2 {
			continue
		}
		seen[label] = true
		places = append(places, map[string]any{"label": label, "lat": feature.Geometry.Coordinates[1], "lon": feature.Geometry.Coordinates[0]})
	}
	writeJSON(w, http.StatusOK, map[string]any{"places": places})
	return nil
}
