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
	activityPageSize     = 20
	maxActivityPageSize  = 50
	activityKeepDays     = 90
	activityGatherWindow = 2 * time.Hour // articles of one person on one list become one entry
	maxGatheredItemNames = 30
	upcomingDays         = 7
	maxUpcoming          = 10
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

// addActivity notes for each recipient but the actor what happened.
func addActivity(ctx context.Context, tx dbtx, familyID, actorID, kind, refID, title string, recipients []string) error {
	t := activityNow()
	for _, userID := range unique(recipients) {
		if userID == actorID || userID == "" {
			continue
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO activities (id, family_id, user_id, actor_id, kind, ref_id, title, created_at, updated_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			newID(), familyID, userID, nullable(actorID), kind, refID, title, t, t); err != nil {
			return err
		}
	}
	return nil
}

// addGatheredActivity is addActivity for things that come one by one, such as articles
// put on a list: within a while, the entry of the same person on the same list takes
// the name in and moves up instead of a new entry for each.
func addGatheredActivity(ctx context.Context, tx dbtx, familyID, actorID, kind, refID, title, name string, recipients []string) error {
	t := activityNow()
	since := time.Now().UTC().Add(-activityGatherWindow).Format(activityTimeFormat)
	for _, userID := range unique(recipients) {
		if userID == actorID || userID == "" {
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

// listActivities is GET /activities: the newest first, a page at a time. The answer
// carries the cursor for the next page, or none at the end.
func (s *Server) listActivities(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, query := r.Context(), r.URL.Query()
	limit := activityPageSize
	if text := query.Get("limit"); text != "" {
		n, err := strconv.Atoi(text)
		if err != nil || n < 1 {
			return fail(http.StatusBadRequest, "Ungültige Anzahl")
		}
		limit = min(n, maxActivityPageSize)
	}
	where := `a.family_id = ? AND a.user_id = ?`
	args := []any{c.familyID, c.userID}
	// The cursor is the time and id of the last entry of the page before.
	if before := query.Get("before"); before != "" {
		at, id, ok := strings.Cut(before, "|")
		if !ok {
			return fail(http.StatusBadRequest, "Ungültige Seite")
		}
		where += ` AND (a.updated_at < ? OR (a.updated_at = ? AND a.id < ?))`
		args = append(args, at, at, id)
	}
	seenAt, err := s.activitySeenAt(ctx, c)
	if err != nil {
		return err
	}
	rows, err := queryRows(ctx, s.db,
		`SELECT a.id, a.kind, a.ref_id, a.title, a.detail, a.count, a.updated_at,
			COALESCE(a.actor_id, '') AS actor_id, COALESCE(m.name, '') AS actor_name
		 FROM activities a LEFT JOIN memberships m ON m.family_id = a.family_id AND m.user_id = a.actor_id
		 WHERE `+where+` ORDER BY a.updated_at DESC, a.id DESC LIMIT ?`,
		append(args, limit+1)...)
	if err != nil {
		return err
	}
	var next any
	if len(rows) > limit {
		rows = rows[:limit]
		last := rows[limit-1]
		next = last["updated_at"].(string) + "|" + last["id"].(string)
	}
	for _, row := range rows {
		row["new"] = row["updated_at"].(string) > seenAt
		names := []string{}
		if detail := row["detail"].(string); detail != "" {
			names = strings.Split(detail, "\n")
		}
		row["names"] = names
		delete(row, "detail")
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": rows, "next": next})
	return nil
}

func (s *Server) activitySeenAt(ctx context.Context, c reqCtx) (string, error) {
	rows, err := queryRows(ctx, s.db, `SELECT seen_at FROM activity_seen WHERE family_id = ? AND user_id = ?`, c.familyID, c.userID)
	if err != nil || len(rows) == 0 {
		return "", err
	}
	return rows[0]["seen_at"].(string), nil
}

// unreadActivities is GET /activities/unread, for the number on the tile.
func (s *Server) unreadActivities(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	seenAt, err := s.activitySeenAt(ctx, c)
	if err != nil {
		return err
	}
	var count int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM activities WHERE family_id = ? AND user_id = ? AND updated_at > ?`,
		c.familyID, c.userID, seenAt).Scan(&count); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]int{"count": count})
	return nil
}

// markActivitiesSeen is POST /activities/seen: everything up to now counts as read.
func (s *Server) markActivitiesSeen(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO activity_seen (family_id, user_id, seen_at) VALUES (?, ?, ?)
		 ON CONFLICT (family_id, user_id) DO UPDATE SET seen_at = excluded.seen_at`,
		c.familyID, c.userID, activityNow()); err != nil {
		return err
	}
	return noContent(w)
}

// upcomingEvents is GET /activities/upcoming: the next events of the coming days that
// the user takes part in, a series with each occurrence.
func (s *Server) upcomingEvents(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	from := time.Now().UTC().Truncate(time.Minute)
	to := from.AddDate(0, 0, upcomingDays)
	span := entryRange{from: from, to: to, fromText: from.Format(timeFormat), toText: to.Format(timeFormat)}
	events, err := s.eventsInRange(ctx, c, span, false)
	if err != nil {
		return err
	}
	mine, err := queryRows(ctx, s.db,
		`SELECT p.event_id FROM event_participants p JOIN events e ON e.id = p.event_id WHERE e.family_id = ? AND p.user_id = ?`,
		c.familyID, c.userID)
	if err != nil {
		return err
	}
	takesPart := map[any]bool{}
	for _, row := range mine {
		takesPart[row["event_id"]] = true
	}
	out := []map[string]any{}
	for _, event := range events {
		if event["participants_all"] != true && !takesPart[event["id"]] {
			continue
		}
		out = append(out, map[string]any{
			"id": event["id"], "title": event["title"], "start_at": event["start_at"], "end_at": event["end_at"],
			"start_local": event["start_local"], "end_local": event["end_local"], "all_day": event["all_day"],
			"location": event["location"], "color": event["color"],
		})
		if len(out) == maxUpcoming {
			break
		}
	}
	writeJSON(w, http.StatusOK, out)
	return nil
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
	for _, userID := range unique(recipients) {
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
