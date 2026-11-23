package server

import (
	"context"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Aktuelles: what happened in the family that concerns someone, one row per recipient,
// and what is coming up for them. The app turns kind, actor, title and detail into a
// sentence, so the wording can change without touching what is stored.
const (
	activityEventAdded   = "event_added"   // you were added to an event
	activityEventAll     = "event_all"     // a new event for everyone
	activityEventChanged = "event_changed" // an event of yours was changed
	activityEventRemoved = "event_removed" // you were taken off an event
	activityEventDeleted = "event_deleted" // an event of yours was deleted
	activityListAdded    = "list_added"    // you were added to a shopping list
	activityListAll      = "list_all"      // a new shopping list for everyone
	activityListDeleted  = "list_deleted"  // a shopping list of yours was deleted
	activityListReadable = "list_readable" // a shopping list was made visible to you, read-only
	activityItemsAdded   = "items_added"   // articles were put on a shopping list of yours
	activityItemsDone    = "items_done"    // articles were checked off a shopping list of yours
	activityPageSize     = 20
	maxActivityPageSize  = 100
	activityKeepDays     = 90
	activityGatherWindow = 2 * time.Hour // articles of one person on one list become one entry
	maxGatheredItemNames = 30
	upcomingDays         = 7
	maxUpcoming          = 10
	upcomingPageSize     = 5
	upcomingAllDays      = 366
	maxUpcomingAll       = 200
)

// familyMemberIDs returns the members of the family.
func familyMemberIDs(ctx context.Context, q dbtx, familyID string) ([]string, error) {
	rows, err := queryRows(ctx, q, `SELECT user_id FROM memberships WHERE family_id = ?`, familyID)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row["user_id"].(string))
	}
	return ids, nil
}

// addActivity notes for each recipient but the actor what happened, and for the actor
// what they did. Where it is about people, the actor's entry names them, and there is
// none if it concerns nobody else.
func addActivity(ctx context.Context, tx dbtx, familyID, actorID, kind, refID, title string, recipients []string) error {
	t := activityNow()
	var others []string
	for _, userID := range unique(recipients) {
		if userID == actorID || userID == "" {
			continue
		}
		others = append(others, userID)
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO activities (id, family_id, user_id, actor_id, kind, ref_id, title, created_at, updated_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			newID(), familyID, userID, nullable(actorID), kind, refID, title, t, t); err != nil {
			return err
		}
	}
	if actorID == "" {
		return nil
	}
	detail, count := "", 1
	if activityAboutPeople[kind] {
		if len(others) == 0 {
			return nil
		}
		names, err := memberNames(ctx, tx, familyID, others)
		if err != nil {
			return err
		}
		if len(names) > maxGatheredItemNames {
			names = names[:maxGatheredItemNames]
		}
		detail, count = strings.Join(names, "\n"), len(others)
	}
	_, err := tx.ExecContext(ctx,
		`INSERT INTO activities (id, family_id, user_id, actor_id, kind, ref_id, title, detail, count, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		newID(), familyID, actorID, actorID, kind, refID, title, detail, count, t, t)
	return err
}

// activityAboutPeople are the kinds that tell someone what was done for them; the
// actor's own entry names them instead.
var activityAboutPeople = map[string]bool{
	activityEventAdded: true, activityEventRemoved: true, activityListAdded: true, activityListReadable: true,
}

// memberNames returns the names of the given members of the family, sorted.
func memberNames(ctx context.Context, q dbtx, familyID string, ids []string) ([]string, error) {
	rows, err := queryRows(ctx, q, `SELECT user_id, name FROM memberships WHERE family_id = ?`, familyID)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, row := range rows {
		if slices.Contains(ids, row["user_id"].(string)) {
			names = append(names, row["name"].(string))
		}
	}
	slices.Sort(names)
	return names, nil
}

// addGatheredActivity is addActivity for things that come one by one, such as articles
// put on a list: within a while, the entry of the same person on the same list takes
// the name in and moves up instead of a new entry for each. The actor gets one too.
func addGatheredActivity(ctx context.Context, tx dbtx, familyID, actorID, kind, refID, title, name string, recipients []string) error {
	t := activityNow()
	since := time.Now().UTC().Add(-activityGatherWindow).Format(activityTimeFormat)
	for _, userID := range unique(append(slices.Clone(recipients), actorID)) {
		if userID == "" {
			continue
		}
		rows, err := queryRows(ctx, tx,
			`SELECT id, detail, count FROM activities
			 WHERE family_id = ? AND user_id = ? AND actor_id = ? AND kind = ? AND ref_id = ? AND updated_at >= ?
			 ORDER BY updated_at DESC LIMIT 1`,
			familyID, userID, actorID, kind, refID, since)
		if err != nil {
			return err
		}
		if len(rows) == 0 {
			if _, err := tx.ExecContext(ctx,
				`INSERT INTO activities (id, family_id, user_id, actor_id, kind, ref_id, title, detail, created_at, updated_at)
				 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				newID(), familyID, userID, actorID, kind, refID, title, name, t, t); err != nil {
				return err
			}
			continue
		}
		row := rows[0]
		names := strings.Split(row["detail"].(string), "\n")
		count := int(row["count"].(int64))
		if slices.Contains(names, name) {
			// Taken off and put back on: it is news again, but no more articles.
			names = slices.DeleteFunc(names, func(n string) bool { return n == name })
		} else {
			count++
		}
		// The newest first; the oldest drop out of the names, not out of the count.
		names = append([]string{name}, names...)
		if len(names) > maxGatheredItemNames {
			names = names[:maxGatheredItemNames]
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE activities SET detail = ?, count = ?, title = ?, updated_at = ? WHERE id = ?`,
			strings.Join(names, "\n"), count, title, t, row["id"]); err != nil {
			return err
		}
	}
	return nil
}

// ungatherActivity takes a name out of the gathered entries of the actor again, for an
// article checked off by mistake and taken back soon after. An entry left without
// any goes; the others keep their time, since nothing new happened.
func ungatherActivity(ctx context.Context, tx dbtx, familyID, actorID, kind, refID, name string) error {
	since := time.Now().UTC().Add(-activityGatherWindow).Format(activityTimeFormat)
	rows, err := queryRows(ctx, tx,
		`SELECT id, detail, count FROM activities
		 WHERE family_id = ? AND actor_id = ? AND kind = ? AND ref_id = ? AND updated_at >= ?`,
		familyID, actorID, kind, refID, since)
	if err != nil {
		return err
	}
	for _, row := range rows {
		names := strings.Split(row["detail"].(string), "\n")
		if !slices.Contains(names, name) {
			continue
		}
		names = slices.DeleteFunc(names, func(n string) bool { return n == name })
		count := int(row["count"].(int64)) - 1
		if count <= 0 || len(names) == 0 {
			if _, err := tx.ExecContext(ctx, `DELETE FROM activities WHERE id = ?`, row["id"]); err != nil {
				return err
			}
			continue
		}
		if _, err := tx.ExecContext(ctx, `UPDATE activities SET detail = ?, count = ? WHERE id = ?`,
			strings.Join(names, "\n"), count, row["id"]); err != nil {
			return err
		}
	}
	return nil
}

func unique(ids []string) []string {
	out := slices.Clone(ids)
	slices.Sort(out)
	return slices.Compact(out)
}

// minus returns what is in a but not in b.
func minus(a, b []string) []string {
	var out []string
	for _, id := range a {
		if !slices.Contains(b, id) {
			out = append(out, id)
		}
	}
	return out
}

func both(a, b []string) []string {
	var out []string
	for _, id := range a {
		if slices.Contains(b, id) {
			out = append(out, id)
		}
	}
	return out
}

// eventPeople is who takes part in an event: everyone in the family, or the participants.
func eventPeople(ctx context.Context, q dbtx, familyID, eventID string, everyone bool) ([]string, error) {
	if everyone {
		return familyMemberIDs(ctx, q, familyID)
	}
	rows, err := queryRows(ctx, q, `SELECT user_id FROM event_participants WHERE event_id = ?`, eventID)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row["user_id"].(string))
	}
	return ids, nil
}

// shoppingListPeople is whom a shopping list concerns: its creator and the people it is
// for, or everyone in the family if it is for everyone.
func shoppingListPeople(ctx context.Context, q dbtx, familyID, listID string) ([]string, error) {
	rows, err := queryRows(ctx, q,
		`SELECT COALESCE(created_by, '') AS created_by, assignees_all FROM shopping_lists WHERE id = ? AND family_id = ?`, listID, familyID)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	if rows[0]["assignees_all"] == true {
		return familyMemberIDs(ctx, q, familyID)
	}
	ids := []string{rows[0]["created_by"].(string)}
	assignees, err := queryRows(ctx, q, `SELECT user_id FROM shopping_list_assignees WHERE list_id = ?`, listID)
	if err != nil {
		return nil, err
	}
	for _, row := range assignees {
		ids = append(ids, row["user_id"].(string))
	}
	return ids, nil
}

// listActivities is GET /families/{fid}/activities: the newest first, a page at a time.
// Without the user's own entries, which older apps would word as someone else's, and
// without checked-off articles, which they do not know.
func (s *Server) listActivities(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	page, err := s.activityPage(r, c.userID, []string{c.familyID}, false)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, page)
	return nil
}

// listAllActivities is GET /activities: what happened in all families of the user, or
// in the one given as family, and what the user did themselves.
func (s *Server) listAllActivities(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	families, err := s.activityFamilies(r, c)
	if err != nil {
		return err
	}
	page, err := s.activityPage(r, c.userID, families, true)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, page)
	return nil
}

// activityFamilies are the families the user belongs to, or only the one asked for
// with ?family=, which must be one of them.
func (s *Server) activityFamilies(r *http.Request, c reqCtx) ([]string, error) {
	rows, err := queryRows(r.Context(), s.db, `SELECT family_id FROM memberships WHERE user_id = ?`, c.userID)
	if err != nil {
		return nil, err
	}
	only := r.URL.Query().Get("family")
	var ids []string
	for _, row := range rows {
		if id := row["family_id"].(string); only == "" || id == only {
			ids = append(ids, id)
		}
	}
	if only != "" && len(ids) == 0 {
		return nil, errNotFound
	}
	return ids, nil
}

// activityPage is a page of the entries of the user in the families, the newest first.
// The answer carries the cursor for the next page, or none at the end.
func (s *Server) activityPage(r *http.Request, userID string, families []string, withOwn bool) (map[string]any, error) {
	ctx, query := r.Context(), r.URL.Query()
	limit := activityPageSize
	if text := query.Get("limit"); text != "" {
		n, err := strconv.Atoi(text)
		if err != nil || n < 1 {
			return nil, fail(http.StatusBadRequest, "Ungültige Anzahl")
		}
		limit = min(n, maxActivityPageSize)
	}
	if len(families) == 0 {
		return map[string]any{"items": []map[string]any{}, "next": nil}, nil
	}
	where := `a.user_id = ? AND a.family_id IN (?` + strings.Repeat(", ?", len(families)-1) + `)`
	args := []any{userID}
	for _, id := range families {
		args = append(args, id)
	}
	if !withOwn {
		where += ` AND COALESCE(a.actor_id, '') <> a.user_id AND a.kind <> '` + activityItemsDone + `'`
	}
	// The cursor is the time and id of the last entry of the page before.
	if before := query.Get("before"); before != "" {
		at, id, ok := strings.Cut(before, "|")
		if !ok {
			return nil, fail(http.StatusBadRequest, "Ungültige Seite")
		}
		where += ` AND (a.updated_at < ? OR (a.updated_at = ? AND a.id < ?))`
		args = append(args, at, at, id)
	}
	rows, err := queryRows(ctx, s.db,
		`SELECT a.id, a.family_id, a.kind, a.ref_id, a.title, a.detail, a.count, a.updated_at,
			COALESCE(a.actor_id, '') AS actor_id, COALESCE(m.name, '') AS actor_name, COALESCE(seen.seen_at, '') AS seen_at
		 FROM activities a
		 LEFT JOIN memberships m ON m.family_id = a.family_id AND m.user_id = a.actor_id
		 LEFT JOIN activity_seen seen ON seen.family_id = a.family_id AND seen.user_id = a.user_id
		 WHERE `+where+` ORDER BY a.updated_at DESC, a.id DESC LIMIT ?`,
		append(args, limit+1)...)
	if err != nil {
		return nil, err
	}
	var next any
	if len(rows) > limit {
		rows = rows[:limit]
		last := rows[limit-1]
		next = last["updated_at"].(string) + "|" + last["id"].(string)
	}
	for _, row := range rows {
		own := row["actor_id"] == userID
		row["own"] = own
		row["new"] = !own && row["updated_at"].(string) > row["seen_at"].(string)
		names := []string{}
		if detail := row["detail"].(string); detail != "" {
			names = strings.Split(detail, "\n")
		}
		row["names"] = names
		delete(row, "detail")
		delete(row, "seen_at")
	}
	return map[string]any{"items": rows, "next": next}, nil
}

// unreadActivities is GET /families/{fid}/activities/unread, for the number on the tile.
func (s *Server) unreadActivities(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	return s.writeUnread(w, r, c.userID, []string{c.familyID})
}

// unreadAllActivities is GET /activities/unread: the same over all families, or the
// one given as family.
func (s *Server) unreadAllActivities(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	families, err := s.activityFamilies(r, c)
	if err != nil {
		return err
	}
	return s.writeUnread(w, r, c.userID, families)
}

// writeUnread counts what others did since the user last looked, family by family.
func (s *Server) writeUnread(w http.ResponseWriter, r *http.Request, userID string, families []string) error {
	total := 0
	for _, familyID := range families {
		var count int
		if err := s.db.QueryRowContext(r.Context(),
			`SELECT COUNT(*) FROM activities a
			 LEFT JOIN activity_seen seen ON seen.family_id = a.family_id AND seen.user_id = a.user_id
			 WHERE a.family_id = ? AND a.user_id = ? AND a.updated_at > COALESCE(seen.seen_at, '')
			   AND COALESCE(a.actor_id, '') <> a.user_id`,
			familyID, userID).Scan(&count); err != nil {
			return err
		}
		total += count
	}
	writeJSON(w, http.StatusOK, map[string]int{"count": total})
	return nil
}

// markActivitiesSeen is POST /families/{fid}/activities/seen: everything up to now counts as read.
func (s *Server) markActivitiesSeen(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if err := s.markSeen(r.Context(), c.userID, []string{c.familyID}); err != nil {
		return err
	}
	return noContent(w)
}

// markAllActivitiesSeen is POST /activities/seen, for all families or the one given as family.
func (s *Server) markAllActivitiesSeen(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	families, err := s.activityFamilies(r, c)
	if err != nil {
		return err
	}
	if err := s.markSeen(r.Context(), c.userID, families); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) markSeen(ctx context.Context, userID string, families []string) error {
	t := activityNow()
	for _, familyID := range families {
		if _, err := s.db.ExecContext(ctx,
			`INSERT INTO activity_seen (family_id, user_id, seen_at) VALUES (?, ?, ?)
			 ON CONFLICT (family_id, user_id) DO UPDATE SET seen_at = excluded.seen_at`,
			familyID, userID, t); err != nil {
			return err
		}
	}
	return nil
}

// upcomingEvents is GET /families/{fid}/activities/upcoming: the next events of the
// coming days that the user takes part in, a series with each occurrence.
func (s *Server) upcomingEvents(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	events, err := s.upcomingIn(r.Context(), c.userID, []string{c.familyID}, upcomingDays, maxUpcoming)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, events)
	return nil
}

// upcomingAllEvents is GET /activities/upcoming: the next events of the user in all
// families, or the one given as family, as many as limit asks for. more tells whether
// others come after them.
func (s *Server) upcomingAllEvents(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	limit := upcomingPageSize
	if text := r.URL.Query().Get("limit"); text != "" {
		n, err := strconv.Atoi(text)
		if err != nil || n < 1 {
			return fail(http.StatusBadRequest, "Ungültige Anzahl")
		}
		limit = min(n, maxUpcomingAll)
	}
	families, err := s.activityFamilies(r, c)
	if err != nil {
		return err
	}
	events, err := s.upcomingIn(r.Context(), c.userID, families, upcomingAllDays, limit+1)
	if err != nil {
		return err
	}
	more := len(events) > limit
	if more {
		events = events[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": events, "more": more})
	return nil
}

// upcomingIn returns the first events of the next days in the families that the user
// takes part in, at most limit, the earliest first, a series with each occurrence.
func (s *Server) upcomingIn(ctx context.Context, userID string, families []string, days, limit int) ([]map[string]any, error) {
	from := time.Now().UTC().Truncate(time.Minute)
	to := from.AddDate(0, 0, days)
	span := entryRange{from: from, to: to, fromText: from.Format(timeFormat), toText: to.Format(timeFormat)}
	out := []map[string]any{}
	for _, familyID := range families {
		events, err := s.eventsInRange(ctx, reqCtx{userID: userID, familyID: familyID}, span, false)
		if err != nil {
			return nil, err
		}
		mine, err := queryRows(ctx, s.db,
			`SELECT p.event_id FROM event_participants p JOIN events e ON e.id = p.event_id WHERE e.family_id = ? AND p.user_id = ?`,
			familyID, userID)
		if err != nil {
			return nil, err
		}
		takesPart := map[any]bool{}
		for _, row := range mine {
			takesPart[row["event_id"]] = true
		}
		for _, event := range events {
			if event["participants_all"] != true && !takesPart[event["id"]] {
				continue
			}
			out = append(out, map[string]any{
				"id": event["id"], "family_id": familyID, "title": event["title"], "start_at": event["start_at"], "end_at": event["end_at"],
				"start_local": event["start_local"], "end_local": event["end_local"], "all_day": event["all_day"],
				"location": event["location"], "color": event["color"],
			})
		}
	}
	slices.SortStableFunc(out, func(a, b map[string]any) int {
		return strings.Compare(a["start_at"].(string), b["start_at"].(string))
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// cleanupActivities drops what is older than anyone scrolls back to.
func (s *Server) cleanupActivities(ctx context.Context) {
	cutoff := time.Now().UTC().AddDate(0, 0, -activityKeepDays).Format(activityTimeFormat)
	if _, err := s.db.ExecContext(ctx, `DELETE FROM activities WHERE updated_at < ?`, cutoff); err != nil {
		s.logError(nil, 0, "Aktuelles bereinigen: "+err.Error())
	}
}

// addReplacingActivity is addActivity for news that a newer one makes old, such as an
// event changed again: the entry of the same person about the same thing goes first.
func addReplacingActivity(ctx context.Context, tx dbtx, familyID, actorID, kind, refID, title string, recipients []string) error {
	since := time.Now().UTC().Add(-activityGatherWindow).Format(activityTimeFormat)
	for _, userID := range unique(append(slices.Clone(recipients), actorID)) {
		if _, err := tx.ExecContext(ctx,
			`DELETE FROM activities WHERE family_id = ? AND user_id = ? AND actor_id = ? AND kind = ? AND ref_id = ? AND updated_at >= ?`,
			familyID, userID, actorID, kind, refID, since); err != nil {
			return err
		}
	}
	return addActivity(ctx, tx, familyID, actorID, kind, refID, title, recipients)
}

// activityTimeFormat orders entries of the same second; the cursor of the pages and
// what counts as read depend on it. Only activities and activity_seen use it.
const activityTimeFormat = "2006-01-02T15:04:05.000000Z"

var (
	activityClockMu sync.Mutex
	activityClock   time.Time
)

// activityNow is the time for an entry, always after the one before, even where the
// clock of the system stands still between two of them.
func activityNow() string {
	activityClockMu.Lock()
	defer activityClockMu.Unlock()
	t := time.Now().UTC().Truncate(time.Microsecond)
	if !t.After(activityClock) {
		t = activityClock.Add(time.Microsecond)
	}
	activityClock = t
	return t.Format(activityTimeFormat)
}

// shoppingListReaders is who may only look at a shopping list: everyone else in the
// family if it is visible to everyone, nobody otherwise.
func shoppingListReaders(ctx context.Context, q dbtx, familyID, listID string, people []string) ([]string, error) {
	var visibility string
	if err := q.QueryRowContext(ctx, `SELECT visibility FROM shopping_lists WHERE id = ?`, listID).Scan(&visibility); err != nil {
		return nil, err
	}
	if visibility != "all" {
		return nil, nil
	}
	members, err := familyMemberIDs(ctx, q, familyID)
	if err != nil {
		return nil, err
	}
	return minus(members, people), nil
}
