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
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

const (
	holidaysURL     = "https://openholidaysapi.org"
	holidayCacheTTL = 7 * 24 * time.Hour
	maxCountries    = 20

	maxRegionsInTitle = 3
)

// Colors of the calendars until someone picks another one. A calendar of the
// current family has none: it starts with the default color of its family.
var calendarColors = map[string]string{
	"tasks": "#1565C0", "school": "#F57C00", "holidays": "#2E7D32", "birthdays": "#D81B60",
	"special": "#7B1FA2", "other_family": "#546E7A", "feed": "#00897B",
}

// sharedColorKinds look the same for everyone in a family, and only managers change
// them. Other families and feeds are a user's own choice to show, and so is their color.
var sharedColorKinds = map[string]bool{
	"family": true, "tasks": true, "school": true, "holidays": true, "birthdays": true, "special": true,
}

// germanStates are the regions of the school holiday calendar.
var germanStates = []struct{ Code, Name string }{
	{"DE-BW", "Baden-Württemberg"}, {"DE-BY", "Bayern"}, {"DE-BE", "Berlin"}, {"DE-BB", "Brandenburg"},
	{"DE-HB", "Bremen"}, {"DE-HH", "Hamburg"}, {"DE-HE", "Hessen"}, {"DE-MV", "Mecklenburg-Vorpommern"},
	{"DE-NI", "Niedersachsen"}, {"DE-NW", "Nordrhein-Westfalen"}, {"DE-RP", "Rheinland-Pfalz"}, {"DE-SL", "Saarland"},
	{"DE-SN", "Sachsen"}, {"DE-ST", "Sachsen-Anhalt"}, {"DE-SH", "Schleswig-Holstein"}, {"DE-TH", "Thüringen"},
}

// What someone starts with until they choose for themselves. Choosing nothing counts
// as a choice and stays.
var (
	defaultHolidayCountries = []string{"DE"}
	defaultSchoolRegions    = []string{"DE-BW"}
)

// shareableKinds can be subscribed to from other calendar apps.
var shareableKinds = map[string]bool{
	"family": true, "tasks": true, "birthdays": true, "special": true, "school": true, "holidays": true,
}

// mayShareCalendar keeps restricted members, in families the children, from handing out
// a link to anything about the people in their family. School holidays and public
// holidays say nothing about them.
func mayShareCalendar(role, key string) bool {
	return role != restrictedRole || key == "school" || key == "holidays"
}

// notSharedByRestricted selects the links restricted members may not have.
const notSharedByRestricted = `key NOT IN ('school', 'holidays')`

var cleanupChoices = []int{1, 3, 6, 9, 12, 24, 36}

var countryCode = regexp.MustCompile(`^[A-Z]{2}$`)

type calendar struct {
	Key       string   `json:"key"`
	Kind      string   `json:"kind"`
	Name      string   `json:"name"`
	Subtitle  string   `json:"subtitle"`
	Enabled   bool     `json:"enabled"`
	Color     string   `json:"color"`
	Regions   []string `json:"regions,omitempty"`
	Shareable bool     `json:"shareable"`
	// ColorShared says that the color is the family's, see sharedColorKinds.
	ColorShared bool   `json:"color_shared"`
	ShareURL    string `json:"share_url,omitempty"`
	URL         string `json:"url,omitempty"`
	LastError   string `json:"last_error,omitempty"`

	familyID  string   // of other_family
	countries []string // of holidays
	feedID    string
}

type calendarPrefs struct {
	WeekNumbers      bool     `json:"week_numbers"`
	WeekStart        string   `json:"week_start"`
	DefaultReminder  int      `json:"default_reminder"`
	HolidayCountries []string `json:"holiday_countries"`
	View             string   `json:"view"`
}

func (s *Server) calendarPrefs(ctx context.Context, c reqCtx) (calendarPrefs, error) {
	prefs := calendarPrefs{WeekStart: "monday", HolidayCountries: slices.Clone(defaultHolidayCountries), View: "agenda"}
	var countries string
	err := s.db.QueryRowContext(ctx,
		`SELECT week_numbers, week_start, default_reminder, holiday_countries, view FROM calendar_prefs WHERE user_id = ? AND family_id = ?`,
		c.userID, c.familyID).Scan(&prefs.WeekNumbers, &prefs.WeekStart, &prefs.DefaultReminder, &countries, &prefs.View)
	if errors.Is(err, sql.ErrNoRows) {
		return prefs, nil
	}
	if err != nil {
		return prefs, err
	}
	return prefs, json.Unmarshal([]byte(countries), &prefs.HolidayCountries)
}

// fetchHolidayData asks the holiday service and caches its answer, because it
// changes rarely. An old answer is better than none while the service is down.
func (s *Server) fetchHolidayData(r *http.Request, kind, scope string, year int, query url.Values, path string) []byte {
	ctx := r.Context()
	var payload []byte
	var fetchedAt string
	err := s.db.QueryRowContext(ctx, `SELECT payload, fetched_at FROM holiday_cache WHERE kind = ? AND scope = ? AND year = ?`,
		kind, scope, year).Scan(&payload, &fetchedAt)
	if err == nil {
		if at, err := time.Parse(timeFormat, fetchedAt); err == nil && time.Since(at) < holidayCacheTTL {
			return payload
		}
	}
	base := s.holidaysURL
	if base == "" {
		base = holidaysURL
	}
	timeout, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(timeout, http.MethodGet, base+path+"?"+query.Encode(), nil)
	if err != nil {
		return payload
	}
	req.Header.Set("Accept", "application/json")
	fresh, err := readHolidayResponse(req)
	if err != nil {
		s.logError(r, http.StatusBadGateway, fmt.Sprintf("Feiertagsdienst (%s %s %d): %v", kind, scope, year, err))
		return payload
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO holiday_cache (kind, scope, year, payload, fetched_at) VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT (kind, scope, year) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at`,
		kind, scope, year, fresh, now()); err != nil {
		s.logError(r, http.StatusInternalServerError, "Feiertagsdienst: "+err.Error())
	}
	return fresh
}

func readHolidayResponse(req *http.Request) ([]byte, error) {
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Status %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	if err != nil {
		return nil, err
	}
	if !json.Valid(body) {
		return nil, errors.New("keine gültige Antwort")
	}
	return body, nil
}

type localizedName []struct {
	Language string `json:"language"`
	Text     string `json:"text"`
}

func (names localizedName) german() string {
	for _, name := range names {
		if name.Language == "DE" {
			return name.Text
		}
	}
	if len(names) > 0 {
		return names[0].Text
	}
	return ""
}

type country struct {
	Code string `json:"code"`
	Name string `json:"name"`
}

// listCountries returns what the holiday service knows, and at least Germany.
func (s *Server) listCountries(r *http.Request) []country {
	out := []country{}
	var found []struct {
		IsoCode string        `json:"isoCode"`
		Name    localizedName `json:"name"`
	}
	payload := s.fetchHolidayData(r, "countries", "", 0, url.Values{"languageIsoCode": {"DE"}}, "/Countries")
	if payload != nil && json.Unmarshal(payload, &found) == nil {
		for _, entry := range found {
			out = append(out, country{entry.IsoCode, entry.Name.german()})
		}
	}
	if len(out) == 0 {
		return []country{{"DE", "Deutschland"}}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// calendarsOf lists everything a user can show in a family. Other families and
// feeds are limited to the user's own, so that this list also guards every key.
func (s *Server) calendarsOf(r *http.Request, c reqCtx, prefs calendarPrefs, countries []country) ([]calendar, error) {
	ctx := r.Context()
	rows, err := queryRows(ctx, s.db, `SELECT key, enabled, color, regions FROM calendar_settings WHERE user_id = ? AND family_id = ?`, c.userID, c.familyID)
	if err != nil {
		return nil, err
	}
	settings := map[string]map[string]any{}
	for _, row := range rows {
		settings[row["key"].(string)] = row
	}
	shares, err := queryRows(ctx, s.db, `SELECT key, token FROM calendar_shares WHERE user_id = ? AND family_id = ?`, c.userID, c.familyID)
	if err != nil {
		return nil, err
	}
	shareTokens := map[string]string{}
	for _, row := range shares {
		shareTokens[row["key"].(string)] = row["token"].(string)
	}
	colors, err := queryRows(ctx, s.db, `SELECT key, color FROM calendar_colors WHERE family_id = ?`, c.familyID)
	if err != nil {
		return nil, err
	}
	familyColors := map[string]string{}
	for _, row := range colors {
		familyColors[row["key"].(string)] = row["color"].(string)
	}

	out := []calendar{}
	add := func(cal calendar) {
		// Other families' calendars start hidden, so that joining one does not fill the own calendar.
		cal.Enabled = cal.Kind != "other_family"
		cal.ColorShared = sharedColorKinds[cal.Kind]
		if cal.Color == "" {
			cal.Color = calendarColors[cal.Kind]
		}
		if saved := settings[cal.Key]; saved != nil {
			cal.Enabled = saved["enabled"] == int64(1)
			if color := saved["color"].(string); color != "" && !cal.ColorShared {
				cal.Color = color
			}
			if raw := saved["regions"].(string); raw != "" {
				json.Unmarshal([]byte(raw), &cal.Regions)
			}
		}
		if color := familyColors[cal.Key]; color != "" && cal.ColorShared {
			cal.Color = color
		}
		cal.Shareable = shareableKinds[cal.Kind] && mayShareCalendar(c.role, cal.Key)
		if token := shareTokens[cal.Key]; token != "" && cal.Shareable {
			cal.ShareURL = s.publicURL + "/cal/" + token + ".ics"
		}
		out = append(out, cal)
	}

	var familyName, defaultColor string
	if err := s.db.QueryRowContext(ctx, `SELECT name, default_color FROM families WHERE id = ?`, c.familyID).Scan(&familyName, &defaultColor); err != nil {
		return nil, err
	}
	add(calendar{Key: "family", Kind: "family", Name: familyName, Subtitle: "Standardkalender", Color: defaultColor})
	add(calendar{Key: "tasks", Kind: "tasks", Name: "Geplante Aufgaben", Subtitle: "Aufgaben mit Datum"})
	add(calendar{Key: "school", Kind: "school", Name: "Schulferien", Regions: slices.Clone(defaultSchoolRegions)})
	school := &out[len(out)-1]
	names := []string{}
	for _, state := range germanStates {
		if slices.Contains(school.Regions, state.Code) {
			names = append(names, state.Name)
		}
	}
	school.Subtitle = strings.Join(names, ", ")
	if school.Subtitle == "" {
		school.Subtitle = "Kein Bundesland ausgewählt"
	}
	// One calendar whatever is chosen, so that its link and color outlast any country.
	holidayNames := []string{}
	for _, code := range prefs.HolidayCountries {
		name := code
		if i := slices.IndexFunc(countries, func(c country) bool { return c.Code == code }); i >= 0 {
			name = countries[i].Name
		}
		holidayNames = append(holidayNames, name)
	}
	holidaySubtitle := strings.Join(holidayNames, ", ")
	if holidaySubtitle == "" {
		holidaySubtitle = "Kein Land ausgewählt"
	}
	add(calendar{Key: "holidays", Kind: "holidays", Name: "Feiertage", Subtitle: holidaySubtitle, countries: prefs.HolidayCountries})
	add(calendar{Key: "birthdays", Kind: "birthdays", Name: "Geburtstage", Subtitle: "Aus Profilen und besonderen Tagen"})
	add(calendar{Key: "special", Kind: "special", Name: "Besondere Tage", Subtitle: "Ohne Geburtstage"})

	others, err := queryRows(ctx, s.db,
		`SELECT f.id, f.name FROM memberships m JOIN families f ON f.id = m.family_id
		 WHERE m.user_id = ? AND f.id <> ? ORDER BY LOWER(f.name)`, c.userID, c.familyID)
	if err != nil {
		return nil, err
	}
	for _, other := range others {
		id := other["id"].(string)
		add(calendar{Key: "family:" + id, Kind: "other_family", Name: other["name"].(string), Subtitle: "Standardkalender", familyID: id})
	}
	feeds, err := queryRows(ctx, s.db,
		`SELECT id, name, url, last_error FROM calendar_feeds WHERE user_id = ? AND family_id = ? ORDER BY LOWER(name)`, c.userID, c.familyID)
	if err != nil {
		return nil, err
	}
	for _, feed := range feeds {
		id := feed["id"].(string)
		add(calendar{
			Key: "feed:" + id, Kind: "feed", Name: feed["name"].(string), Subtitle: "Kalender-URL", feedID: id,
			URL: feed["url"].(string), LastError: feed["last_error"].(string),
		})
	}
	return out, nil
}

func (s *Server) getCalendars(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	prefs, err := s.calendarPrefs(r.Context(), c)
	if err != nil {
		return err
	}
	countries := s.listCountries(r)
	calendars, err := s.calendarsOf(r, c, prefs, countries)
	if err != nil {
		return err
	}
	var cleanup int
	if err := s.db.QueryRowContext(r.Context(), `SELECT cleanup_months FROM families WHERE id = ?`, c.familyID).Scan(&cleanup); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"calendars": calendars, "prefs": prefs, "countries": countries, "states": germanStates, "cleanup_months": cleanup,
	})
	return nil
}

// getCalendarPrefs is the cheap part of getCalendars, for screens that only show events.
func (s *Server) getCalendarPrefs(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	prefs, err := s.calendarPrefs(ctx, c)
	if err != nil {
		return err
	}
	// The form colors its header like the event will be, which starts from this.
	var color string
	if err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE((SELECT color FROM calendar_colors WHERE family_id = ?1 AND key = 'family'), default_color)
		 FROM families WHERE id = ?1`, c.familyID).Scan(&color); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, struct {
		calendarPrefs
		CalendarColor string `json:"calendar_color"`
	}{prefs, color})
	return nil
}

func (s *Server) putCalendarPrefs(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in calendarPrefs
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if in.WeekStart != "monday" && in.WeekStart != "sunday" {
		return fail(http.StatusBadRequest, "Ungültiger Wochenbeginn")
	}
	if !slices.Contains([]string{"agenda", "day", "three", "week", "month"}, in.View) {
		return fail(http.StatusBadRequest, "Ungültige Ansicht")
	}
	if in.DefaultReminder < 0 || in.DefaultReminder > maxReminderMinutes {
		return fail(http.StatusBadRequest, "Ungültige Erinnerung")
	}
	if len(in.HolidayCountries) > maxCountries {
		return fail(http.StatusBadRequest, "Zu viele Länder")
	}
	if in.HolidayCountries == nil {
		in.HolidayCountries = []string{}
	}
	slices.Sort(in.HolidayCountries)
	in.HolidayCountries = slices.Compact(in.HolidayCountries)
	for _, code := range in.HolidayCountries {
		if !countryCode.MatchString(code) {
			return fail(http.StatusBadRequest, "Unbekanntes Land")
		}
	}
	countries, err := json.Marshal(in.HolidayCountries)
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO calendar_prefs (user_id, family_id, week_numbers, week_start, default_reminder, holiday_countries, view)
		 VALUES (?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT (user_id, family_id) DO UPDATE SET week_numbers = excluded.week_numbers, week_start = excluded.week_start,
			default_reminder = excluded.default_reminder, holiday_countries = excluded.holiday_countries, view = excluded.view`,
		c.userID, c.familyID, in.WeekNumbers, in.WeekStart, in.DefaultReminder, string(countries), in.View); err != nil {
		return err
	}
	return noContent(w)
}

// calendarByKey resolves a key from the URL against what the user may use.
func (s *Server) calendarByKey(r *http.Request, c reqCtx) (calendar, error) {
	prefs, err := s.calendarPrefs(r.Context(), c)
	if err != nil {
		return calendar{}, err
	}
	calendars, err := s.calendarsOf(r, c, prefs, nil)
	if err != nil {
		return calendar{}, err
	}
	key := r.PathValue("key")
	if i := slices.IndexFunc(calendars, func(cal calendar) bool { return cal.Key == key }); i >= 0 {
		return calendars[i], nil
	}
	return calendar{}, errNotFound
}

func (s *Server) putCalendar(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	cal, err := s.calendarByKey(r, c)
	if err != nil {
		return err
	}
	var in struct {
		Enabled bool `json:"enabled"`
		// Left out, it stays. Showing or hiding a calendar is everyone's own choice,
		// and must not bring back a color a manager has changed in the meantime.
		Color   *string  `json:"color"`
		Regions []string `json:"regions"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	color := cal.Color
	if in.Color != nil {
		color = *in.Color
	}
	changed := color != cal.Color
	if changed && cal.ColorShared && !c.isManager() {
		return fail(http.StatusForbidden, "Die Farbe dieses Kalenders können nur Manager ändern.")
	}
	// Restricted members only show or hide calendars, and choose their school holidays.
	if changed && c.role == restrictedRole {
		return fail(http.StatusForbidden, "In deiner Rolle lässt sich die Farbe nicht ändern.")
	}
	if changed {
		if err := s.checkFamilyColor(r.Context(), c.familyID, color); err != nil {
			return err
		}
	}
	regions := ""
	if cal.Kind == "school" {
		// Left out, they stay, so that switching the calendar keeps what it starts with.
		if in.Regions == nil {
			in.Regions = cal.Regions
		}
		if in.Regions == nil {
			in.Regions = []string{}
		}
		for _, code := range in.Regions {
			if !slices.ContainsFunc(germanStates, func(state struct{ Code, Name string }) bool { return state.Code == code }) {
				return fail(http.StatusBadRequest, "Unbekanntes Bundesland")
			}
		}
		raw, err := json.Marshal(in.Regions)
		if err != nil {
			return err
		}
		regions = string(raw)
	}
	ctx := r.Context()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	personal := color
	if cal.ColorShared {
		personal = ""
		if changed {
			if _, err := tx.ExecContext(ctx, `INSERT INTO calendar_colors (family_id, key, color) VALUES (?, ?, ?)
				 ON CONFLICT (family_id, key) DO UPDATE SET color = excluded.color`,
				c.familyID, cal.Key, color); err != nil {
				return err
			}
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO calendar_settings (user_id, family_id, key, enabled, color, regions) VALUES (?, ?, ?, ?, ?, ?)
		 ON CONFLICT (user_id, family_id, key) DO UPDATE SET enabled = excluded.enabled, color = excluded.color, regions = excluded.regions`,
		c.userID, c.familyID, cal.Key, in.Enabled, personal, regions); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

// putCleanup sets how long past events stay. It deletes for the whole family, so
// it is up to its admins.
func (s *Server) putCleanup(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Months int `json:"months"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if !slices.Contains(cleanupChoices, in.Months) {
		return fail(http.StatusBadRequest, "Ungültiger Zeitraum")
	}
	if _, err := s.db.ExecContext(r.Context(), `UPDATE families SET cleanup_months = ? WHERE id = ?`, in.Months, c.familyID); err != nil {
		return err
	}
	return noContent(w)
}

// cleanupEvents deletes single events that ended before the limit of their family.
// A series goes on and stays, since it has no end.
func (s *Server) cleanupEvents(ctx context.Context) {
	families, err := queryRows(ctx, s.db, `SELECT id, cleanup_months FROM families`)
	if err != nil {
		s.logError(nil, 0, "Kalenderbereinigung: "+err.Error())
		return
	}
	for _, family := range families {
		id := family["id"].(string)
		cutoff := time.Now().UTC().AddDate(0, -int(family["cleanup_months"].(int64)), 0).Format(timeFormat)
		files, err := queryRows(ctx, s.db,
			`SELECT f.id FROM files f JOIN events e ON e.id = f.event_id WHERE e.family_id = ? AND e.recurrence = '' AND e.end_at < ?`, id, cutoff)
		if err != nil {
			s.logError(nil, 0, "Kalenderbereinigung: "+err.Error())
			continue
		}
		if _, err := s.db.ExecContext(ctx, `DELETE FROM events WHERE family_id = ? AND recurrence = '' AND end_at < ?`, id, cutoff); err != nil {
			s.logError(nil, 0, "Kalenderbereinigung: "+err.Error())
			continue
		}
		for _, file := range files {
			s.removeStoredFile(nil, file["id"].(string))
		}
	}
}

// entryRange is what calendarEntries works on: the range as times and as dates.
type entryRange struct {
	from, to          time.Time
	fromText, toText  string
	firstDay, lastDay string
}

func allDayEntry(cal calendar, id, title, description, first, last string) map[string]any {
	return map[string]any{
		"id": cal.Key + ":" + id, "title": title, "description": description, "location": "",
		"start_at": first + "T00:00:00Z", "end_at": last + "T23:59:00Z",
		"start_local": first + "T00:00", "end_local": last + "T23:59",
		"all_day": true, "recurrence": nil, "color": cal.Color,
	}
}

// yearlyDate returns a date of the given year, on the last day of February for a
// birthday on the 29th.
func yearlyDate(date string, year int) string {
	parsed, err := time.Parse("2006-01-02", date)
	if err != nil {
		return date
	}
	day := min(parsed.Day(), daysInMonth(year, parsed.Month()))
	return time.Date(year, parsed.Month(), day, 0, 0, 0, 0, time.UTC).Format("2006-01-02")
}

func (s *Server) specialDayEntries(ctx context.Context, cal calendar, familyID string, span entryRange, birthdays bool) ([]map[string]any, error) {
	days, err := queryRows(ctx, s.db, `SELECT id, title, kind, date, yearly, note FROM special_days WHERE family_id = ?`, familyID)
	if err != nil {
		return nil, err
	}
	out := []map[string]any{}
	for _, day := range days {
		if (day["kind"] == "birthday") != birthdays {
			continue
		}
		id, date := day["id"].(string), day["date"].(string)
		if day["yearly"] != true {
			if date >= span.firstDay && date <= span.lastDay {
				out = append(out, allDayEntry(cal, id, day["title"].(string), day["note"].(string), date, date))
			}
			continue
		}
		for year := span.from.Year() - 1; year <= span.to.Year(); year++ {
			if on := yearlyDate(date, year); on >= span.firstDay && on <= span.lastDay {
				out = append(out, allDayEntry(cal, fmt.Sprint(id, ":", year), day["title"].(string), day["note"].(string), on, on))
			}
		}
	}
	return out, nil
}

type holidaySubdivision struct {
	Code      string `json:"code"`
	ShortName string `json:"shortName"`
}

type subdivisionNode struct {
	Code     string            `json:"code"`
	Name     localizedName     `json:"name"`
	Children []subdivisionNode `json:"children"`
}

// subdivisionNames returns the regions of a country by code, down to single towns. The
// German states are known without the service.
func (s *Server) subdivisionNames(r *http.Request, country string) map[string]string {
	names := map[string]string{}
	for _, state := range germanStates {
		names[state.Code] = state.Name
	}
	var collect func(nodes []subdivisionNode)
	collect = func(nodes []subdivisionNode) {
		for _, node := range nodes {
			names[node.Code] = node.Name.german()
			collect(node.Children)
		}
	}
	var nodes []subdivisionNode
	payload := s.fetchHolidayData(r, "subdivisions", country, 0,
		url.Values{"countryIsoCode": {country}, "languageIsoCode": {"DE"}}, "/Subdivisions")
	if payload != nil && json.Unmarshal(payload, &nodes) == nil {
		collect(nodes)
	}
	return names
}

// regionalHoliday names where a holiday holds. A longer list does not fit a calendar,
// so it moves to the description.
func regionalHoliday(name string, subdivisions []holidaySubdivision, names map[string]string) (title, description string) {
	regions := []string{}
	for _, subdivision := range subdivisions {
		region, known := names[subdivision.Code]
		if !known {
			region = subdivision.ShortName
		}
		if !slices.Contains(regions, region) {
			regions = append(regions, region)
		}
	}
	slices.Sort(regions)
	switch {
	case len(regions) == 0:
		return name, ""
	case len(regions) <= maxRegionsInTitle:
		return name + " (" + strings.Join(regions, ", ") + ")", ""
	}
	return fmt.Sprintf("%s (%d Regionen)", name, len(regions)), "Gilt in: " + strings.Join(regions, ", ")
}

func (s *Server) holidayEntries(r *http.Request, cal calendar, kind, scope string, query url.Values, path string, span entryRange, suffix string) []map[string]any {
	out := []map[string]any{}
	seen := map[string]bool{}
	var names map[string]string
	for year := span.from.Year() - 1; year <= span.to.Year(); year++ {
		q := url.Values{}
		for k, v := range query {
			q[k] = v
		}
		q.Set("languageIsoCode", "DE")
		q.Set("validFrom", fmt.Sprintf("%d-01-01", year))
		q.Set("validTo", fmt.Sprintf("%d-12-31", year))
		var found []struct {
			ID           string               `json:"id"`
			StartDate    string               `json:"startDate"`
			EndDate      string               `json:"endDate"`
			Name         localizedName        `json:"name"`
			Nationwide   bool                 `json:"nationwide"`
			Subdivisions []holidaySubdivision `json:"subdivisions"`
		}
		payload := s.fetchHolidayData(r, kind, scope, year, q, path)
		if payload == nil || json.Unmarshal(payload, &found) != nil {
			continue
		}
		for _, holiday := range found {
			// The Christmas holidays are part of the answers of both years.
			if seen[holiday.ID] || holiday.StartDate > span.lastDay || holiday.EndDate < span.firstDay {
				continue
			}
			seen[holiday.ID] = true
			title, description := holiday.Name.german()+suffix, ""
			// Holidays of a single region do not hold for the whole country, so they say where.
			if kind == "public" && !holiday.Nationwide {
				if names == nil {
					names = s.subdivisionNames(r, scope)
				}
				title, description = regionalHoliday(title, holiday.Subdivisions, names)
			}
			out = append(out, allDayEntry(cal, holiday.ID, title, description, holiday.StartDate, holiday.EndDate))
		}
	}
	return out
}

// holidayCalendarEntries lists the school holidays of the chosen states or the public
// holidays of the chosen countries, which say where they hold once there are several.
func (s *Server) holidayCalendarEntries(r *http.Request, cal calendar, span entryRange) []map[string]any {
	entries := []map[string]any{}
	if cal.Kind == "holidays" {
		for _, code := range cal.countries {
			suffix := ""
			if len(cal.countries) > 1 {
				suffix = " (" + code + ")"
			}
			entries = append(entries, s.holidayEntries(r, cal, "public", code,
				url.Values{"countryIsoCode": {code}}, "/PublicHolidays", span, suffix)...)
		}
		return entries
	}
	for _, state := range germanStates {
		if slices.Contains(cal.Regions, state.Code) {
			entries = append(entries, s.holidayEntries(r, cal, "school", state.Code,
				url.Values{"countryIsoCode": {"DE"}, "subdivisionCode": {state.Code}}, "/SchoolHolidays", span, " ("+state.Name+")")...)
		}
	}
	return entries
}

// calendarEntries merges everything the enabled calendars show in a range. Only
// events of the current family can be edited from here.
func (s *Server) calendarEntries(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
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
	everything := r.URL.Query().Get("all") == "1"
	if everything && !c.isManager() {
		return fail(http.StatusForbidden, "Nur für Manager erlaubt")
	}
	// A day that begins in another time zone can lie just outside the range in UTC.
	span := entryRange{from, to, fromText, toText, from.AddDate(0, 0, -1).Format("2006-01-02"), to.AddDate(0, 0, 1).Format("2006-01-02")}
	prefs, err := s.calendarPrefs(ctx, c)
	if err != nil {
		return err
	}
	calendars, err := s.calendarsOf(r, c, prefs, nil)
	if err != nil {
		return err
	}

	out := []map[string]any{}
	for _, cal := range calendars {
		if !cal.Enabled {
			continue
		}
		var entries []map[string]any
		switch cal.Kind {
		case "family", "other_family":
			scope := reqCtx{userID: c.userID, familyID: c.familyID}
			if cal.Kind == "other_family" {
				scope.familyID = cal.familyID
			}
			// Being a manager of this family says nothing about another one.
			if entries, err = s.eventsInRange(ctx, scope, span, everything && cal.Kind == "family"); err != nil {
				return err
			}
			rows, err := queryRows(ctx, s.db,
				`SELECT p.event_id, p.user_id, m.color FROM event_participants p JOIN events e ON e.id = p.event_id
				 JOIN memberships m ON m.user_id = p.user_id AND m.family_id = e.family_id WHERE e.family_id = ?`, scope.familyID)
			if err != nil {
				return err
			}
			participants := map[any][]any{}
			memberColors := map[any]string{}
			for _, row := range rows {
				participants[row["event_id"]] = append(participants[row["event_id"]], row["user_id"])
				memberColors[row["event_id"]] = row["color"].(string)
			}
			for _, entry := range entries {
				// A category with a color goes first, then the one person the event is for.
				if color, _ := entry["category_color"].(string); color == "" {
					entry["color"] = cal.Color
					if color := memberColors[entry["id"]]; color != "" && entry["participants_all"] == false && len(participants[entry["id"]]) == 1 {
						entry["color"] = color
					}
				}
				// The same rule as eventChangeAccess, for the app to offer only what works.
				entry["editable"] = cal.Kind == "family" && (c.isManager() || entry["created_by"] == c.userID)
				// The app filters the calendar by member without asking again.
				if cal.Kind == "family" {
					ids := participants[entry["id"]]
					if ids == nil {
						ids = []any{}
					}
					entry["participant_ids"] = ids
				} else {
					delete(entry, "created_by")
					delete(entry, "creator_name")
					delete(entry, "updated_at")
					delete(entry, "updated_by_name")
				}
			}
		case "tasks":
			items, err := queryRows(ctx, s.db,
				`SELECT i.id, i.title, i.note, i.due_date FROM list_items i JOIN lists l ON l.id = i.list_id
				 WHERE i.family_id = ? AND l.kind = 'tasks' AND i.done = 0 AND i.due_date >= ? AND i.due_date <= ?`,
				c.familyID, span.firstDay, span.lastDay)
			if err != nil {
				return err
			}
			for _, item := range items {
				date := item["due_date"].(string)
				entries = append(entries, allDayEntry(cal, item["id"].(string), item["title"].(string), item["note"].(string), date, date))
			}
		case "birthdays":
			members, err := queryRows(ctx, s.db,
				`SELECT user_id AS id, name, birthday FROM memberships WHERE family_id = ? AND birthday <> ''`, c.familyID)
			if err != nil {
				return err
			}
			for _, member := range members {
				for year := span.from.Year() - 1; year <= span.to.Year(); year++ {
					if on := yearlyDate(member["birthday"].(string), year); on >= span.firstDay && on <= span.lastDay {
						entries = append(entries, allDayEntry(cal, fmt.Sprint(member["id"], ":", year), "Geburtstag "+member["name"].(string), "", on, on))
					}
				}
			}
			days, err := s.specialDayEntries(ctx, cal, c.familyID, span, true)
			if err != nil {
				return err
			}
			entries = append(entries, days...)
		case "special":
			if entries, err = s.specialDayEntries(ctx, cal, c.familyID, span, false); err != nil {
				return err
			}
		case "school", "holidays":
			entries = s.holidayCalendarEntries(r, cal, span)
		case "feed":
			if entries, err = s.feedEntries(r, c, cal, span); err != nil {
				return err
			}
		}
		for _, entry := range entries {
			entry["source"] = cal.Key
			entry["source_name"] = cal.Name
			if _, ok := entry["editable"]; !ok {
				entry["editable"] = false
			}
			out = append(out, entry)
		}
	}
	slices.SortStableFunc(out, func(a, b map[string]any) int {
		return strings.Compare(a["start_at"].(string), b["start_at"].(string))
	})
	writeJSON(w, http.StatusOK, out)
	return nil
}

func (s *Server) createShare(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	cal, err := s.calendarByKey(r, c)
	if err != nil {
		return err
	}
	if !shareableKinds[cal.Kind] {
		return fail(http.StatusBadRequest, "Dieser Kalender lässt sich nicht freigeben.")
	}
	if !cal.Shareable {
		return fail(http.StatusForbidden, "In deiner Rolle lässt sich dieser Kalender nicht freigeben.")
	}
	if cal.ShareURL != "" {
		writeJSON(w, http.StatusOK, map[string]string{"url": cal.ShareURL})
		return nil
	}
	token := randomHex(32)
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO calendar_shares (token, user_id, family_id, key, created_at) VALUES (?, ?, ?, ?, ?)`,
		token, c.userID, c.familyID, cal.Key, now()); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"url": s.publicURL + "/cal/" + token + ".ics"})
	return nil
}

func (s *Server) deleteShare(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM calendar_shares WHERE user_id = ? AND family_id = ? AND key = ?`,
		c.userID, c.familyID, r.PathValue("key"))
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}
