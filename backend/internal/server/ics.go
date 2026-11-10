package server

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	maxFeedBytes = 5 << 20
	maxFeeds     = 20
	feedMaxAge   = 30 * time.Minute
)

var errFeedUnavailable = errors.New("der Kalender konnte nicht geladen werden")

// --- Reading calendars ---

// icsEvent is a VEVENT as far as the calendar can show it. A rule it cannot express
// leaves only the first date, which is better than wrong dates.
type icsEvent struct {
	uid, title, description, location string
	start, end                        time.Time
	allDay                            bool
	rule                              *recurrence
	until                             time.Time
	count                             int
	excluded                          map[string]bool
	overrides                         string // RECURRENCE-ID of a single changed occurrence
}

func unescapeICS(value string) string {
	return strings.NewReplacer(`\n`, "\n", `\N`, "\n", `\,`, ",", `\;`, ";", `\\`, `\`).Replace(value)
}

// splitICSLine parses NAME;PARAM=VALUE:CONTENT, where quoted parameters may contain colons.
func splitICSLine(line string) (string, map[string]string, string, bool) {
	quoted := false
	for i, ch := range line {
		if ch == '"' {
			quoted = !quoted
		} else if ch == ':' && !quoted {
			head := strings.Split(line[:i], ";")
			params := map[string]string{}
			for _, param := range head[1:] {
				if k, v, ok := strings.Cut(param, "="); ok {
					params[strings.ToUpper(k)] = strings.Trim(v, `"`)
				}
			}
			return strings.ToUpper(head[0]), params, line[i+1:], true
		}
	}
	return "", nil, "", false
}

// parseICSTime reads the date forms of iCalendar. A time zone name that is not an
// IANA name, as from Outlook, falls back to the default zone.
func parseICSTime(value string, params map[string]string, fallback *time.Location) (time.Time, bool, error) {
	if params["VALUE"] == "DATE" || len(value) == 8 {
		t, err := time.ParseInLocation("20060102", value, fallback)
		return t, true, err
	}
	if strings.HasSuffix(value, "Z") {
		t, err := time.Parse("20060102T150405Z", value)
		return t, false, err
	}
	loc := fallback
	if name := params["TZID"]; name != "" {
		if zone, err := time.LoadLocation(name); err == nil {
			loc = zone
		}
	}
	t, err := time.ParseInLocation("20060102T150405", value, loc)
	return t, false, err
}

// parseICSDuration reads the common forms of a DURATION, such as PT1H30M or P1D.
func parseICSDuration(value string) time.Duration {
	value = strings.TrimPrefix(strings.TrimPrefix(value, "+"), "P")
	var out time.Duration
	number := ""
	for _, ch := range value {
		switch {
		case ch >= '0' && ch <= '9':
			number += string(ch)
		case ch == 'T':
		default:
			n, _ := strconv.Atoi(number)
			number = ""
			switch ch {
			case 'W':
				out += time.Duration(n) * 7 * 24 * time.Hour
			case 'D':
				out += time.Duration(n) * 24 * time.Hour
			case 'H':
				out += time.Duration(n) * time.Hour
			case 'M':
				out += time.Duration(n) * time.Minute
			case 'S':
				out += time.Duration(n) * time.Second
			}
		}
	}
	return out
}

var icsWeekdays = map[string]int{"MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6, "SU": 7}

// parseRRule maps a rule to recurrence. It returns nil for anything it cannot
// express, such as BYSETPOS or several days of a month.
func parseRRule(value string, event *icsEvent, loc *time.Location) *recurrence {
	rule := &recurrence{Interval: 1}
	for _, part := range strings.Split(value, ";") {
		key, val, _ := strings.Cut(part, "=")
		switch strings.ToUpper(key) {
		case "FREQ":
			rule.Freq = map[string]string{"DAILY": "day", "WEEKLY": "week", "MONTHLY": "month", "YEARLY": "year"}[val]
		case "INTERVAL":
			rule.Interval, _ = strconv.Atoi(val)
		case "COUNT":
			event.count, _ = strconv.Atoi(val)
		case "UNTIL":
			if until, _, err := parseICSTime(val, nil, loc); err == nil {
				event.until = until
			}
		case "BYDAY":
			for _, day := range strings.Split(val, ",") {
				if len(day) > 2 {
					week, err := strconv.Atoi(day[:len(day)-2])
					if err != nil || rule.MonthWeek != 0 {
						return nil
					}
					rule.MonthWeek, rule.MonthWeekday = week, icsWeekdays[day[len(day)-2:]]
				} else if weekday := icsWeekdays[day]; weekday != 0 {
					rule.Weekdays = append(rule.Weekdays, weekday)
				}
			}
		case "BYMONTHDAY":
			day, err := strconv.Atoi(val)
			if err != nil {
				return nil
			}
			rule.MonthDay = day
		case "WKST", "BYMONTH":
		default:
			return nil
		}
	}
	// Plain weekdays only make sense for weeks, and ordinals only for months.
	if (rule.Freq != "week" && len(rule.Weekdays) > 0) || (rule.Freq == "week" && rule.MonthWeek != 0) {
		return nil
	}
	if rule.Freq == "year" && (rule.MonthWeek != 0 || rule.MonthDay != 0) {
		return nil
	}
	if err := rule.normalize(event.start); err != nil {
		return nil
	}
	return rule
}

func parseICS(body string, fallback *time.Location) []icsEvent {
	body = strings.ReplaceAll(body, "\r\n", "\n")
	body = strings.ReplaceAll(strings.ReplaceAll(body, "\n ", ""), "\n\t", "")
	events := []icsEvent{}
	var current *icsEvent
	var rrule, durationValue string
	var hasEnd, cancelled bool
	nested := 0 // VALARM and the like have properties of the same names
	for _, line := range strings.Split(body, "\n") {
		name, params, value, ok := splitICSLine(line)
		if !ok {
			continue
		}
		switch {
		case name == "BEGIN" && strings.EqualFold(value, "VEVENT"):
			current = &icsEvent{excluded: map[string]bool{}}
			rrule, durationValue, hasEnd, cancelled, nested = "", "", false, false, 0
			continue
		case current == nil:
			continue
		case name == "BEGIN":
			nested++
			continue
		case name == "END" && !strings.EqualFold(value, "VEVENT"):
			nested--
			continue
		case nested > 0:
			continue
		case name == "END":
			event := current
			current = nil
			if event.start.IsZero() || cancelled {
				continue
			}
			if !hasEnd {
				switch {
				case durationValue != "":
					event.end = event.start.Add(parseICSDuration(durationValue))
				case event.allDay:
					event.end = event.start.AddDate(0, 0, 1)
				default:
					event.end = event.start
				}
			}
			// The end of an all-day event is exclusive in iCalendar.
			if event.allDay {
				event.end = event.end.Add(-time.Minute)
				if event.end.Before(event.start) {
					event.end = event.start.Add(24*time.Hour - time.Minute)
				}
			}
			if rrule != "" {
				event.rule = parseRRule(rrule, event, event.start.Location())
			}
			if event.title == "" {
				event.title = "Ohne Titel"
			}
			events = append(events, *event)
			continue
		}
		switch name {
		case "UID":
			current.uid = value
		case "SUMMARY":
			current.title = unescapeICS(value)
		case "DESCRIPTION":
			current.description = unescapeICS(value)
		case "LOCATION":
			current.location = unescapeICS(value)
		case "STATUS":
			cancelled = strings.EqualFold(value, "CANCELLED")
		case "RRULE":
			rrule = value
		case "DURATION":
			durationValue = value
		case "DTSTART":
			if t, allDay, err := parseICSTime(value, params, fallback); err == nil {
				current.start, current.allDay = t, allDay
			}
		case "DTEND":
			if t, _, err := parseICSTime(value, params, fallback); err == nil {
				current.end, hasEnd = t, true
			}
		case "EXDATE":
			for _, date := range strings.Split(value, ",") {
				if t, _, err := parseICSTime(date, params, fallback); err == nil {
					current.excluded[t.UTC().Format(timeFormat)] = true
				}
			}
		case "RECURRENCE-ID":
			if t, _, err := parseICSTime(value, params, fallback); err == nil {
				current.overrides = t.UTC().Format(timeFormat)
			}
		}
	}
	// A changed occurrence replaces its date in the series.
	byUID := map[string]*icsEvent{}
	for i := range events {
		if events[i].overrides == "" {
			byUID[events[i].uid] = &events[i]
		}
	}
	for _, event := range events {
		if master := byUID[event.uid]; event.overrides != "" && master != nil {
			master.excluded[event.overrides] = true
		}
	}
	return events
}

// occurrences returns the beginnings of an event within the range. A series with
// COUNT is counted from its start, whatever the range is.
func (event icsEvent) occurrences(from, to time.Time) []time.Time {
	length := wallClock(event.end).Sub(wallClock(event.start))
	if event.rule == nil {
		if event.start.Before(to) && !event.end.Before(from) {
			return []time.Time{event.start}
		}
		return nil
	}
	counted := from.Add(-length)
	if event.count > 0 {
		counted = event.start
	}
	starts := event.rule.starts(event.start, counted, to)
	out := []time.Time{}
	for i, start := range starts {
		if event.count > 0 && i >= event.count {
			break
		}
		if !event.until.IsZero() && start.After(event.until) {
			break
		}
		if event.excluded[start.UTC().Format(timeFormat)] || occurrenceEnd(start, length).Before(from) {
			continue
		}
		out = append(out, start)
	}
	return out
}

// --- Calendars from a URL ---

// normalizeFeedURL accepts the forms calendar apps hand out, including webcal.
func normalizeFeedURL(raw string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Host == "" || len(raw) > 2000 {
		return "", fail(http.StatusBadRequest, "Das ist keine gültige Adresse.")
	}
	switch strings.ToLower(parsed.Scheme) {
	case "webcal", "webcals":
		parsed.Scheme = "https"
	case "http", "https":
	default:
		return "", fail(http.StatusBadRequest, "Das ist keine gültige Adresse.")
	}
	return parsed.String(), nil
}

func blockedFeedIP(ip net.IP) bool {
	if ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() || ip.IsInterfaceLocalMulticast() || ip.IsMulticast() {
		return true
	}
	// Carrier-grade NAT is as internal as the private ranges.
	_, shared, _ := net.ParseCIDR("100.64.0.0/10")
	return shared.Contains(ip)
}

// fetchFeed loads a calendar for a user-supplied address. The address could point
// into the server's own network, so the check sits at the connection itself, where
// neither a redirect nor a changing DNS answer can get around it.
func (s *Server) fetchFeed(ctx context.Context, address string) (string, error) {
	dialer := &net.Dialer{Timeout: 8 * time.Second, Control: func(network, hostport string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(hostport)
		if err != nil {
			return err
		}
		if !s.allowPrivateFeeds && blockedFeedIP(net.ParseIP(host)) {
			return errors.New("interne Adresse")
		}
		return nil
	}}
	client := &http.Client{
		Timeout:   15 * time.Second,
		Transport: &http.Transport{DialContext: dialer.DialContext, TLSHandshakeTimeout: 8 * time.Second},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 || (req.URL.Scheme != "http" && req.URL.Scheme != "https") {
				return errors.New("zu viele Weiterleitungen")
			}
			return nil
		},
	}
	defer client.CloseIdleConnections()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Kintura/1.0 (+"+s.publicURL+")")
	req.Header.Set("Accept", "text/calendar, */*")
	res, err := client.Do(req)
	if err != nil {
		// A url.Error repeats the address, which can contain a secret.
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			return "", urlErr.Err
		}
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("Status %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, maxFeedBytes+1))
	if err != nil {
		return "", err
	}
	if len(body) > maxFeedBytes {
		return "", errors.New("die Datei ist zu groß")
	}
	if !strings.Contains(string(body[:min(len(body), 4096)]), "BEGIN:VCALENDAR") {
		return "", errors.New("das ist keine Kalenderdatei")
	}
	return string(body), nil
}

func (s *Server) createFeed(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if c.role == restrictedRole {
		return fail(http.StatusForbidden, "In deiner Rolle lassen sich keine Kalender einbinden.")
	}
	var in struct {
		Name string `json:"name"`
		URL  string `json:"url"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	name, err := required(in.Name, "Name", 100)
	if err != nil {
		return err
	}
	address, err := normalizeFeedURL(in.URL)
	if err != nil {
		return err
	}
	ctx := r.Context()
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM calendar_feeds WHERE user_id = ? AND family_id = ?`, c.userID, c.familyID).Scan(&count); err != nil {
		return err
	}
	if count >= maxFeeds {
		return fail(http.StatusBadRequest, "Zu viele Kalender")
	}
	// One message for all failures, so that the check does not reveal what is
	// reachable behind the server.
	body, err := s.fetchFeed(ctx, address)
	if err != nil {
		return fail(http.StatusBadRequest, "Unter dieser Adresse wurde kein Kalender gefunden.")
	}
	id := newID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO calendar_feeds (id, user_id, family_id, name, url, body, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, c.userID, c.familyID, name, address, body, now()); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"key": "feed:" + id})
	return nil
}

func (s *Server) deleteFeed(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	id := r.PathValue("id")
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM calendar_feeds WHERE id = ? AND user_id = ? AND family_id = ?`, id, c.userID, c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(r.Context(), `DELETE FROM calendar_settings WHERE user_id = ? AND family_id = ? AND key = ?`,
		c.userID, c.familyID, "feed:"+id); err != nil {
		return err
	}
	return noContent(w)
}

// renewFeed loads a calendar again and stores it. If that fails, it returns
// errFeedUnavailable: the old dates stay and it shows up in the calendar management.
func (s *Server) renewFeed(r *http.Request, id, name, address string) (string, error) {
	ctx := r.Context()
	body, err := s.fetchFeed(ctx, address)
	if err != nil {
		s.logError(r, http.StatusBadGateway, fmt.Sprintf("Kalender „%s“: %v", name, err))
		if _, err := s.db.ExecContext(ctx, `UPDATE calendar_feeds SET fetched_at = ?, last_error = ? WHERE id = ?`, now(), errFeedUnavailable.Error(), id); err != nil {
			return "", err
		}
		return "", errFeedUnavailable
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE calendar_feeds SET body = ?, fetched_at = ?, last_error = '' WHERE id = ?`, body, now(), id); err != nil {
		return "", err
	}
	return body, nil
}

// refreshFeed renews a calendar at once and reports how many events it now has.
func (s *Server) refreshFeed(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	id := r.PathValue("id")
	var name, address string
	err := s.db.QueryRowContext(r.Context(), `SELECT name, url FROM calendar_feeds WHERE id = ? AND user_id = ? AND family_id = ?`, id, c.userID, c.familyID).
		Scan(&name, &address)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	body, err := s.renewFeed(r, id, name, address)
	if errors.Is(err, errFeedUnavailable) {
		return fail(http.StatusBadRequest, "Der Kalender konnte nicht geladen werden.")
	}
	if err != nil {
		return err
	}
	loc, err := s.zone("")
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]int{"events": len(parseICS(body, loc))})
	return nil
}

// feedEntries reads a stored calendar and renews it when it is old.
func (s *Server) feedEntries(r *http.Request, c reqCtx, cal calendar, span entryRange) ([]map[string]any, error) {
	ctx := r.Context()
	var address, body, fetchedAt string
	if err := s.db.QueryRowContext(ctx, `SELECT url, body, fetched_at FROM calendar_feeds WHERE id = ? AND user_id = ?`, cal.feedID, c.userID).
		Scan(&address, &body, &fetchedAt); err != nil {
		return nil, err
	}
	if at, err := time.Parse(timeFormat, fetchedAt); err != nil || time.Since(at) > feedMaxAge {
		fresh, err := s.renewFeed(r, cal.feedID, cal.Name, address)
		if err == nil {
			body = fresh
		} else if !errors.Is(err, errFeedUnavailable) {
			return nil, err
		}
	}
	loc, err := s.zone("")
	if err != nil {
		return nil, err
	}
	out := []map[string]any{}
	for _, event := range parseICS(body, loc) {
		length := wallClock(event.end).Sub(wallClock(event.start))
		// A copy of a timed entry has to be saved in a zone of ours, while whole days keep their dates.
		wall := func(t time.Time) time.Time {
			if event.allDay {
				return t
			}
			return t.In(loc)
		}
		for _, start := range event.occurrences(span.from, span.to) {
			end := occurrenceEnd(start, length)
			out = append(out, map[string]any{
				"id": cal.Key + ":" + event.uid + ":" + start.UTC().Format(timeFormat), "title": event.title,
				"description": event.description, "location": event.location,
				"start_at": start.UTC().Format(timeFormat), "end_at": end.UTC().Format(timeFormat),
				"start_local": wall(start).Format(localTimeFormat), "end_local": wall(end).Format(localTimeFormat),
				"timezone": loc.String(), "all_day": event.allDay, "recurrence": nil, "color": cal.Color,
			})
		}
	}
	return out, nil
}

// --- Sharing calendars ---

func escapeICS(value string) string {
	return strings.NewReplacer(`\`, `\\`, ";", `\;`, ",", `\,`, "\r\n", `\n`, "\n", `\n`, "\r", "").Replace(value)
}

// writeICSLine folds lines at 75 bytes without cutting a UTF-8 character.
func writeICSLine(out *strings.Builder, line string) {
	for len(line) > 75 {
		cut := 75
		for cut > 0 && line[cut]&0xC0 == 0x80 {
			cut--
		}
		out.WriteString(line[:cut] + "\r\n")
		line = " " + line[cut:]
	}
	out.WriteString(line + "\r\n")
}

func rruleOf(rec *recurrence) string {
	freq := map[string]string{"day": "DAILY", "week": "WEEKLY", "month": "MONTHLY", "year": "YEARLY"}[rec.Freq]
	days := []string{"", "MO", "TU", "WE", "TH", "FR", "SA", "SU"}
	rule := fmt.Sprintf("FREQ=%s;INTERVAL=%d", freq, rec.Interval)
	switch {
	case len(rec.Weekdays) > 0:
		names := []string{}
		for _, day := range rec.Weekdays {
			names = append(names, days[day])
		}
		rule += ";BYDAY=" + strings.Join(names, ",")
	case rec.MonthWeek != 0:
		rule += fmt.Sprintf(";BYDAY=%d%s", rec.MonthWeek, days[rec.MonthWeekday])
	case rec.MonthDay != 0:
		rule += fmt.Sprintf(";BYMONTHDAY=%d", rec.MonthDay)
	}
	return rule
}

type icsEntry struct {
	uid, title, description, location, rule string
	start, end                              time.Time
	allDay                                  bool
}

// shareCalendar serves a calendar to other apps. The token stands in for the user,
// who sees exactly what they may see, as long as they belong to the family.
func (s *Server) shareCalendar(w http.ResponseWriter, r *http.Request) {
	entries, name, err := s.sharedEntries(r)
	if errors.Is(err, sql.ErrNoRows) || errors.Is(err, errNotFound) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		s.logError(r, http.StatusInternalServerError, "Kalenderfreigabe: "+err.Error())
		http.Error(w, "Interner Fehler", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/calendar; charset=utf-8")
	w.Header().Set("Content-Disposition", `inline; filename="kintura.ics"`)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Cache-Control", "private, max-age=300")
	io.WriteString(w, renderICS(name, entries))
}

func renderICS(name string, entries []icsEntry) string {
	var out strings.Builder
	writeICSLine(&out, "BEGIN:VCALENDAR")
	writeICSLine(&out, "VERSION:2.0")
	writeICSLine(&out, "PRODID:-//Kintura//Kalender//DE")
	writeICSLine(&out, "X-WR-CALNAME:"+escapeICS(name))
	stamp := time.Now().UTC().Format("20060102T150405Z")
	for _, entry := range entries {
		writeICSLine(&out, "BEGIN:VEVENT")
		writeICSLine(&out, "UID:"+entry.uid+"@kintura")
		writeICSLine(&out, "DTSTAMP:"+stamp)
		if entry.allDay {
			writeICSLine(&out, "DTSTART;VALUE=DATE:"+entry.start.Format("20060102"))
			// Exclusive in iCalendar, see parseICS.
			writeICSLine(&out, "DTEND;VALUE=DATE:"+entry.end.AddDate(0, 0, 1).Format("20060102"))
		} else {
			zone := entry.start.Location().String()
			writeICSLine(&out, "DTSTART;TZID="+zone+":"+entry.start.Format("20060102T150405"))
			writeICSLine(&out, "DTEND;TZID="+zone+":"+entry.end.Format("20060102T150405"))
		}
		if entry.rule != "" {
			writeICSLine(&out, "RRULE:"+entry.rule)
		}
		writeICSLine(&out, "SUMMARY:"+escapeICS(entry.title))
		if entry.description != "" {
			writeICSLine(&out, "DESCRIPTION:"+escapeICS(entry.description))
		}
		if entry.location != "" {
			writeICSLine(&out, "LOCATION:"+escapeICS(entry.location))
		}
		writeICSLine(&out, "END:VEVENT")
	}
	writeICSLine(&out, "END:VCALENDAR")
	return out.String()
}

// entryICS turns an entry of any calendar into a file for other apps. The app sends
// what it was given, because many calendars keep their entries nowhere to look them up.
func (s *Server) entryICS(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Title       string `json:"title"`
		Description string `json:"description"`
		Location    string `json:"location"`
		AllDay      bool   `json:"all_day"`
		StartAt     string `json:"start_at"`
		EndAt       string `json:"end_at"`
		StartLocal  string `json:"start_local"`
		EndLocal    string `json:"end_local"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	title, err := required(in.Title, "Titel", 1000)
	if err != nil {
		return err
	}
	first, last, layout := in.StartAt, in.EndAt, timeFormat
	if in.AllDay {
		first, last, layout = in.StartLocal, in.EndLocal, localTimeFormat
	}
	start, err := time.Parse(layout, first)
	if err != nil {
		return fail(http.StatusBadRequest, "Ungültiger Zeitpunkt")
	}
	end, err := time.Parse(layout, last)
	if err != nil {
		return fail(http.StatusBadRequest, "Ungültiger Zeitpunkt")
	}
	content := renderICS(title, []icsEntry{{
		uid: newID(), title: title, description: in.Description, location: in.Location, start: start, end: end, allDay: in.AllDay,
	}})
	writeJSON(w, http.StatusOK, map[string]string{"filename": "termin.ics", "content": content})
	return nil
}

// icsEntryOf describes a decorated event row for other apps.
func icsEntryOf(row map[string]any, start time.Time, length time.Duration, rec *recurrence) icsEntry {
	entry := icsEntry{
		uid: row["id"].(string), title: row["title"].(string), description: row["description"].(string), location: row["location"].(string),
		start: start, end: occurrenceEnd(start, length), allDay: row["all_day"] == true,
	}
	if rec != nil {
		entry.rule = rruleOf(rec)
	}
	return entry
}

func (s *Server) sharedEntries(r *http.Request) ([]icsEntry, string, error) {
	ctx := r.Context()
	token := strings.TrimSuffix(r.PathValue("token"), ".ics")
	var c reqCtx
	var key, familyName string
	if err := s.db.QueryRowContext(ctx,
		`SELECT s.user_id, s.family_id, s.key, f.name, m.role FROM calendar_shares s
		 JOIN memberships m ON m.user_id = s.user_id AND m.family_id = s.family_id
		 JOIN families f ON f.id = s.family_id WHERE s.token = ?`, token).
		Scan(&c.userID, &c.familyID, &key, &familyName, &c.role); err != nil {
		return nil, "", err
	}
	if !mayShareCalendar(c.role, key) {
		return nil, "", errNotFound
	}
	if key == "school" || key == "holidays" {
		return s.sharedHolidays(r, c, key)
	}
	day := func(date string) time.Time {
		parsed, _ := time.Parse("2006-01-02", date)
		return parsed
	}
	out := []icsEntry{}
	specialDays := func(kind string) error {
		days, err := queryRows(ctx, s.db, `SELECT id, title, date, yearly, note FROM special_days WHERE family_id = ? AND `+kind, c.familyID)
		if err != nil {
			return err
		}
		for _, row := range days {
			entry := icsEntry{uid: row["id"].(string), title: row["title"].(string), description: row["note"].(string), start: day(row["date"].(string)), allDay: true}
			entry.end = entry.start
			if row["yearly"] == true {
				entry.rule = "FREQ=YEARLY"
			}
			out = append(out, entry)
		}
		return nil
	}
	switch key {
	case "family":
		rows, err := queryRows(ctx, s.db, eventColumns+`WHERE e.family_id = ?`+eventVisible, c.familyID, c.userID, c.userID)
		if err != nil {
			return nil, "", err
		}
		for _, row := range rows {
			start, length, rec, err := s.decorate(row)
			if err != nil {
				return nil, "", err
			}
			out = append(out, icsEntryOf(row, start, length, rec))
		}
		return out, familyName, nil
	case "tasks":
		rows, err := queryRows(ctx, s.db,
			`SELECT i.id, i.title, i.note, i.due_date FROM list_items i JOIN lists l ON l.id = i.list_id
			 WHERE i.family_id = ? AND l.kind = 'tasks' AND i.done = 0 AND i.due_date IS NOT NULL AND i.due_date <> ''`, c.familyID)
		if err != nil {
			return nil, "", err
		}
		for _, row := range rows {
			date := day(row["due_date"].(string))
			out = append(out, icsEntry{uid: row["id"].(string), title: row["title"].(string), description: row["note"].(string), start: date, end: date, allDay: true})
		}
		return out, familyName + " Aufgaben", nil
	case "birthdays":
		members, err := queryRows(ctx, s.db,
			`SELECT user_id AS id, name, birthday FROM memberships WHERE family_id = ? AND birthday <> ''`, c.familyID)
		if err != nil {
			return nil, "", err
		}
		for _, member := range members {
			date := day(member["birthday"].(string))
			out = append(out, icsEntry{uid: member["id"].(string), title: "Geburtstag " + member["name"].(string), start: date, end: date, allDay: true, rule: "FREQ=YEARLY"})
		}
		if err := specialDays(`kind = 'birthday'`); err != nil {
			return nil, "", err
		}
		return out, familyName + " Geburtstage", nil
	case "special":
		if err := specialDays(`kind <> 'birthday'`); err != nil {
			return nil, "", err
		}
		return out, familyName + " Besondere Tage", nil
	}
	return nil, "", errNotFound
}

// sharedHolidays serves holidays from last year to the end of next year, the most an
// app needs and about what the holiday service knows. The states and countries are those
// of the link's owner right now. Its name stays out of it, since nothing here is about
// that family.
func (s *Server) sharedHolidays(r *http.Request, c reqCtx, key string) ([]icsEntry, string, error) {
	prefs, err := s.calendarPrefs(r.Context(), c)
	if err != nil {
		return nil, "", err
	}
	calendars, err := s.calendarsOf(r, c, prefs, nil)
	if err != nil {
		return nil, "", err
	}
	i := slices.IndexFunc(calendars, func(cal calendar) bool { return cal.Key == key })
	if i < 0 {
		return nil, "", errNotFound
	}
	cal := calendars[i]
	year := time.Now().UTC().Year()
	from := time.Date(year-1, time.January, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(year+1, time.December, 31, 0, 0, 0, 0, time.UTC)
	span := entryRange{from: from, to: to, firstDay: from.Format("2006-01-02"), lastDay: to.Format("2006-01-02")}
	out := []icsEntry{}
	for _, entry := range s.holidayCalendarEntries(r, cal, span) {
		start, err := time.Parse(localTimeFormat, entry["start_local"].(string))
		if err != nil {
			return nil, "", err
		}
		end, err := time.Parse(localTimeFormat, entry["end_local"].(string))
		if err != nil {
			return nil, "", err
		}
		out = append(out, icsEntry{
			uid: entry["id"].(string), title: entry["title"].(string), description: entry["description"].(string),
			start: start, end: wallDay(end), allDay: true,
		})
	}
	if cal.Kind == "school" {
		return out, "Schulferien", nil
	}
	return out, "Feiertage", nil
}

// wallDay drops the time of day, since an all-day entry ends on a date.
func wallDay(at time.Time) time.Time {
	return time.Date(at.Year(), at.Month(), at.Day(), 0, 0, 0, 0, time.UTC)
}
