package server

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

// pushWindow is how old an entry of Aktuelles may be to still be sent: after a break
// of the server, nobody wants yesterday's news on their phone.
const pushWindow = time.Hour

// pushInterval is how often the server looks for entries to send.
const pushInterval = 5 * time.Second

// registerPushDevice is PUT /api/me/push-device: this sign-in of the app gets what is
// new in Aktuelles as push messages. With signing out the device is gone.
func (s *Server) registerPushDevice(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if s.push == nil {
		return fail(http.StatusNotImplemented, "Push-Nachrichten sind auf diesem Server nicht eingerichtet.")
	}
	var in struct {
		Token    string `json:"token"`
		Platform string `json:"platform"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	token := strings.TrimSpace(in.Token)
	if token == "" || len(token) > 4096 {
		return fail(http.StatusBadRequest, "Ungültiges Gerät")
	}
	if in.Platform != "android" {
		return fail(http.StatusBadRequest, "Unbekannte Plattform")
	}
	ctx, t := r.Context(), now()
	session := hashToken(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// One token is one device; whoever signs in there now has it.
	if _, err := tx.ExecContext(ctx, `DELETE FROM push_devices WHERE token = ? OR session_hash = ?`, token, session); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO push_devices (token, user_id, session_hash, platform, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)`, token, c.userID, session, in.Platform, t, t); err != nil {
		return err
	}
	// What came before is not sent afterwards.
	if _, err := tx.ExecContext(ctx, `UPDATE activities SET pushed_at = updated_at WHERE user_id = ?`, c.userID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

// unregisterPushDevice is DELETE /api/me/push-device: no more push messages for this
// sign-in of the app.
func (s *Server) unregisterPushDevice(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	session := hashToken(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if _, err := s.db.ExecContext(r.Context(), `DELETE FROM push_devices WHERE session_hash = ? AND user_id = ?`, session, c.userID); err != nil {
		return err
	}
	return noContent(w)
}

// sendPushes sends what others did, entry by entry, to the devices of whom it concerns.
// An entry that grows, as with more articles on a list, is sent again and replaces
// the one before on the device.
func (s *Server) sendPushes(ctx context.Context, at time.Time) {
	if s.push == nil {
		return
	}
	if err := s.sendDuePushes(ctx, at); err != nil {
		log.Printf("Push-Nachrichten: %v", err)
	}
	if err := s.sendDueChatPushes(ctx, at); err != nil {
		log.Printf("Push-Nachrichten zu Nachrichten: %v", err)
	}
}

// sendDueChatPushes sends each new message once to the devices of the people of its
// chat, but not to the sender nor to who has read it already.
func (s *Server) sendDueChatPushes(ctx context.Context, at time.Time) error {
	rows, err := queryRows(ctx, s.db,
		`SELECT m.id, m.chat_id, m.family_id, m.body, m.created_at, COALESCE(m.sender_id, '') AS sender_id,
			ch.kind, ch.name AS chat_name, COALESCE(f.name, '') AS family_name, COALESCE(ms.name, '') AS sender_name,
			COALESCE((SELECT MIN(x.name) FROM files x WHERE x.chat_message_id = m.id), '') AS file_name,
			(SELECT COUNT(*) FROM files x WHERE x.chat_message_id = m.id AND x.kind = 'photo') AS photos
		 FROM chat_messages m JOIN chats ch ON ch.id = m.chat_id
		 LEFT JOIN families f ON f.id = m.family_id
		 LEFT JOIN memberships ms ON ms.family_id = m.family_id AND ms.user_id = m.sender_id
		 WHERE m.pushed_at IS NULL AND m.deleted_at IS NULL AND m.created_at > ?
		 ORDER BY m.created_at LIMIT 200`,
		at.Add(-pushWindow).UTC().Format(chatTimeFormat))
	if err != nil {
		return err
	}
	for _, row := range rows {
		people, err := chatPeople(ctx, s.db, row["chat_id"].(string))
		if err != nil {
			return err
		}
		text := row["body"].(string)
		switch {
		case anyInt(row["photos"]) > 0:
			text = "📷 Bild"
		case row["file_name"] != "":
			text = "📎 " + row["file_name"].(string)
		}
		sender := row["sender_name"].(string)
		if sender == "" {
			sender = "Jemand"
		}
		title, body := sender, text
		if row["kind"] == "group" {
			title, body = row["chat_name"].(string), sender+": "+text
		}
		for _, person := range people {
			if person == row["sender_id"] {
				continue
			}
			var read string
			err := s.db.QueryRowContext(ctx, `SELECT read_at FROM chat_reads WHERE chat_id = ? AND user_id = ?`, row["chat_id"], person).Scan(&read)
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return err
			}
			if read >= row["created_at"].(string) {
				continue
			}
			devices, err := queryRows(ctx, s.db,
				`SELECT d.token, (SELECT COUNT(*) FROM memberships o WHERE o.user_id = d.user_id) AS families
				 FROM push_devices d WHERE d.user_id = ?`, person)
			if err != nil {
				return err
			}
			for _, device := range devices {
				shown := title
				if anyInt(device["families"]) > 1 && row["family_name"] != "" {
					shown += " · " + row["family_name"].(string)
				}
				token := device["token"].(string)
				err := s.push.Push(ctx, PushMessage{
					Token: token, Title: shown, Body: body, Tag: "chat-" + row["chat_id"].(string),
					Data: map[string]string{"kintura": "message", "family_id": row["family_id"].(string), "chat_id": row["chat_id"].(string)},
				})
				if errors.Is(err, errPushGone) {
					if _, err := s.db.ExecContext(ctx, `DELETE FROM push_devices WHERE token = ?`, token); err != nil {
						return err
					}
				} else if err != nil {
					log.Printf("Push-Nachricht: %v", err)
				}
			}
		}
		if _, err := s.db.ExecContext(ctx, `UPDATE chat_messages SET pushed_at = ? WHERE id = ?`, chatNow(), row["id"]); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) sendDuePushes(ctx context.Context, at time.Time) error {
	rows, err := queryRows(ctx, s.db,
		`SELECT a.id, a.family_id, a.user_id, a.kind, a.title, a.detail, a.count, a.updated_at,
			COALESCE(m.name, '') AS actor_name, COALESCE(f.name, '') AS family_name,
			(SELECT COUNT(*) FROM memberships o WHERE o.user_id = a.user_id) AS families
		 FROM activities a
		 LEFT JOIN memberships m ON m.family_id = a.family_id AND m.user_id = a.actor_id
		 LEFT JOIN families f ON f.id = a.family_id
		 LEFT JOIN activity_seen seen ON seen.family_id = a.family_id AND seen.user_id = a.user_id
		 WHERE (a.pushed_at IS NULL OR a.pushed_at < a.updated_at) AND a.updated_at > ?
			AND COALESCE(a.actor_id, '') <> a.user_id AND a.updated_at > COALESCE(seen.seen_at, '')
			AND EXISTS (SELECT 1 FROM push_devices d WHERE d.user_id = a.user_id)
		 ORDER BY a.updated_at LIMIT 200`,
		at.Add(-pushWindow).UTC().Format(time.RFC3339Nano))
	if err != nil {
		return err
	}
	for _, row := range rows {
		devices, err := queryRows(ctx, s.db, `SELECT token FROM push_devices WHERE user_id = ?`, row["user_id"])
		if err != nil {
			return err
		}
		title := "Kintura"
		if anyInt(row["families"]) > 1 && row["family_name"] != "" {
			title += " · " + row["family_name"].(string)
		}
		names := []string{}
		if detail := row["detail"].(string); detail != "" {
			names = strings.Split(detail, "\n")
		}
		body := pushText(row["kind"].(string), row["actor_name"].(string), row["title"].(string), names, anyInt(row["count"]))
		for _, device := range devices {
			token := device["token"].(string)
			err := s.push.Push(ctx, PushMessage{
				Token: token, Title: title, Body: body, Tag: row["id"].(string),
				Data: map[string]string{"kintura": "activity", "family_id": row["family_id"].(string)},
			})
			if errors.Is(err, errPushGone) {
				if _, err := s.db.ExecContext(ctx, `DELETE FROM push_devices WHERE token = ?`, token); err != nil {
					return err
				}
			} else if err != nil {
				// Not sent again: a message too late is worse than one missing.
				log.Printf("Push-Nachricht: %v", err)
			}
		}
		if _, err := s.db.ExecContext(ctx, `UPDATE activities SET pushed_at = ? WHERE id = ?`, row["updated_at"], row["id"]); err != nil {
			return err
		}
	}
	return nil
}

// pushText is the sentence of an entry of Aktuelles, as the app shows it for what
// others did (activityText in activity_screen.dart).
func pushText(kind, actor, title string, names []string, count int) string {
	who := actor
	if who == "" {
		who = "Jemand"
	}
	title = "„" + title + "“"
	first := ""
	if len(names) > 0 {
		first = names[0]
	}
	quote := ""
	if first != "" {
		quote = ": „" + first + "“"
	}
	whose := "einen Kommentar"
	if first != "" {
		whose = "den Kommentar von " + first
	}
	switch kind {
	case activityEventAdded:
		return who + " hat dich zum Termin " + title + " hinzugefügt."
	case activityEventAll:
		return who + " hat den Termin " + title + " für alle angelegt."
	case activityEventChanged:
		return who + " hat den Termin " + title + " geändert."
	case activityEventRemoved:
		return who + " hat dich aus dem Termin " + title + " herausgenommen."
	case activityEventDeleted:
		return who + " hat den Termin " + title + " gelöscht."
	case activityEventComment:
		return who + " hat den Termin " + title + " kommentiert" + quote + "."
	case activityEventCommentEdited:
		return who + " hat einen Kommentar zum Termin " + title + " bearbeitet" + quote + "."
	case activityEventCommentDeleted:
		return who + " hat " + whose + " zum Termin " + title + " gelöscht."
	case activityListAdded:
		return who + " hat dich zur Einkaufsliste " + title + " hinzugefügt."
	case activityListAll:
		return who + " hat die Einkaufsliste " + title + " für alle angelegt."
	case activityListDeleted:
		return who + " hat die Einkaufsliste " + title + " gelöscht."
	case activityListComment:
		return who + " hat die Einkaufsliste " + title + " kommentiert" + quote + "."
	case activityListCommentEdited:
		return who + " hat einen Kommentar zur Einkaufsliste " + title + " bearbeitet" + quote + "."
	case activityListCommentDeleted:
		return who + " hat " + whose + " zur Einkaufsliste " + title + " gelöscht."
	case activityListReadable:
		return who + " hat dir die Einkaufsliste " + title + " zum Ansehen freigegeben (lesend)."
	case activityItemsAdded, activityItemsDone:
		verb := "gesetzt"
		if kind == activityItemsDone {
			verb = "abgehakt"
		}
		if count <= 1 && first != "" {
			return who + " hat " + first + " auf " + title + " " + verb + "."
		}
		return fmt.Sprintf("%s hat %d Artikel auf %s %s: %s.", who, count, title, verb, shortList(names, count))
	}
	return who + " hat etwas geändert."
}

// shortList names the first few, and how many more there are.
func shortList(names []string, count int) string {
	const shown = 4
	list := names
	if len(list) > shown {
		list = list[:shown]
	}
	text := strings.Join(list, ", ")
	if count > shown {
		text += fmt.Sprintf(" und %d weitere", count-shown)
	}
	return text
}

// anyInt is a number as the databases give it: SQLite as int64, Postgres by its type.
func anyInt(v any) int {
	switch n := v.(type) {
	case int64:
		return int(n)
	case int32:
		return int(n)
	case int:
		return n
	}
	return 0
}
