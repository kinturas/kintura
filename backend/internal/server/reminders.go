package server

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// reminderGrace is how late a reminder may still go out, e.g. after a restart.
const reminderGrace = 10 * time.Minute

var germanWeekdays = []string{"Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"}

// sendReminders mails what is due at now to the participants of an event. Each
// reminder is noted before it is sent, so it reaches a person at most once.
func (s *Server) sendReminders(ctx context.Context, now time.Time) {
	if err := s.sendDueReminders(ctx, now); err != nil {
		s.logError(nil, 0, "Erinnerungen: "+err.Error())
	}
}

func (s *Server) sendDueReminders(ctx context.Context, now time.Time) error {
	rows, err := queryRows(ctx, s.db,
		`SELECT e.id, e.family_id, e.title, e.description, e.start_at, e.end_at, e.all_day, e.timezone, e.recurrence, e.location,
			e.participants_all, r.minutes, f.name AS family_name
		 FROM event_reminders r JOIN events e ON e.id = r.event_id JOIN families f ON f.id = e.family_id
		 WHERE e.recurrence <> '' OR e.start_at > ?`, now.UTC().Format(timeFormat))
	if err != nil {
		return err
	}
	for _, row := range rows {
		minutes := row["minutes"].(int64)
		first, _, rec, err := s.decorate(row)
		if err != nil {
			return err
		}
		// A reminder is due if its time lies between now - grace and now.
		lead := time.Duration(minutes) * time.Minute
		from, to := now.Add(lead-reminderGrace), now.Add(lead).Add(time.Second)
		occurrences := []time.Time{}
		if rec != nil {
			occurrences = rec.starts(first, from, to)
		} else if !first.Before(from) && first.Before(to) {
			occurrences = append(occurrences, first)
		}
		for _, occurrence := range occurrences {
			if occurrence.After(now) {
				if err := s.remindOccurrence(ctx, row, minutes, occurrence, now); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func (s *Server) remindOccurrence(ctx context.Context, event map[string]any, minutes int64, occurrence, now time.Time) error {
	id, familyID := event["id"].(string), event["family_id"].(string)
	query := `SELECT u.id, m.name, u.email FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.family_id = ? AND u.notifications = 1`
	args := []any{familyID}
	if event["participants_all"] != true {
		query += ` AND u.id IN (SELECT user_id FROM event_participants WHERE event_id = ?)`
		args = append(args, id)
	}
	recipients, err := queryRows(ctx, s.db, query, args...)
	if err != nil {
		return err
	}
	key := occurrence.UTC().Format(timeFormat)
	for _, recipient := range recipients {
		res, err := s.db.ExecContext(ctx,
			`INSERT INTO reminder_sent (event_id, minutes, occurrence, user_id, sent_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING`,
			id, minutes, key, recipient["id"], now.UTC().Format(timeFormat))
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			continue
		}
		email := recipient["email"].(string)
		subject, body := reminderMail(event, recipient["name"].(string), occurrence)
		if err := s.mailer.Send(email, subject, body); err != nil {
			s.logEntry("Erinnerung", logScope{email: email, familyID: familyID}, http.StatusBadGateway,
				fmt.Sprintf("Erinnerung an „%s“: %v", event["title"], err))
		}
	}
	return nil
}

func reminderMail(event map[string]any, name string, occurrence time.Time) (string, string) {
	// A title may contain anything, but the subject must stay a single header line.
	title := strings.Join(strings.Fields(event["title"].(string)), " ")
	when := fmt.Sprintf("%s, %s", germanWeekdays[occurrence.Weekday()], occurrence.Format("02.01.2006"))
	if event["all_day"] == true {
		when += " (ganztägig)"
	} else {
		when += fmt.Sprintf(", %s Uhr (%s)", occurrence.Format("15:04"), occurrence.Location())
	}
	var body strings.Builder
	fmt.Fprintf(&body, "Hallo %s,\n\ndu hast einen Termin in „%s“:\n\n%s\n%s\n", name, event["family_name"], title, when)
	if location := event["location"].(string); location != "" {
		fmt.Fprintf(&body, "Ort: %s\n", location)
	}
	if description := event["description"].(string); description != "" {
		fmt.Fprintf(&body, "\n%s\n", description)
	}
	return "Erinnerung: " + title, body.String()
}
