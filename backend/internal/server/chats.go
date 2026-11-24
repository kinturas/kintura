package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/kinturas/kintura/backend/internal/database"
)

// Nachrichten: direct messages between two members of a circle, and groups with a name,
// color, category, the people they concern and who may see them, as shopping lists.
// Who a group concerns writes in it; with visibility all the others of the circle read
// along. What one has read and archived is one's own. New messages are not entries of
// Aktuelles, but come as push messages, see sendDueChatPushes.

// chatTimeFormat orders messages within a second too; fixed width, so that the text
// sorts as the time does.
const chatTimeFormat = "2006-01-02T15:04:05.000000Z"

func chatNow() string { return time.Now().UTC().Format(chatTimeFormat) }

// maxChatMessages is how many messages a chat sends at once, the newest.
const maxChatMessages = 100

// chatVisible limits a query on chats ch to what a user may see. It takes the user id twice.
const chatVisible = ` AND (ch.visibility = 'all' OR ch.assignees_all = 1 OR ch.created_by = ?
	OR EXISTS (SELECT 1 FROM chat_members cm WHERE cm.chat_id = ch.id AND cm.user_id = ?)) `

// chatWriter limits a query on chats ch to those the user writes in: the ones it concerns.
// It takes the user id twice.
const chatWriter = ` AND (ch.assignees_all = 1 OR ch.created_by = ?
	OR EXISTS (SELECT 1 FROM chat_members cm WHERE cm.chat_id = ch.id AND cm.user_id = ?)) `

const chatReadOnly = "In dieser Gruppe kannst du nur mitlesen. Schreiben können die Personen, die sie betrifft."

func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?, ", n), ", ")
}

// chatAccess checks that the user sees the chat, in the family of the route.
func (s *Server) chatAccess(ctx context.Context, c reqCtx, id string) error {
	var found int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM chats ch WHERE ch.id = ? AND ch.family_id = ?`+chatVisible,
		id, c.familyID, c.userID, c.userID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	return err
}

// chatWriteAccess is for writing in a chat: only who it concerns.
func (s *Server) chatWriteAccess(ctx context.Context, c reqCtx, id string) error {
	if err := s.chatAccess(ctx, c, id); err != nil {
		return err
	}
	var found int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM chats ch WHERE ch.id = ?`+chatWriter, id, c.userID, c.userID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return fail(http.StatusForbidden, chatReadOnly)
	}
	return err
}

// chatChangeAccess is for the settings of a group and deleting it: its creator, the
// managers and the admins, as with shopping lists. Direct messages have no settings.
func (s *Server) chatChangeAccess(ctx context.Context, c reqCtx, id string) error {
	if err := s.chatAccess(ctx, c, id); err != nil {
		return err
	}
	var kind string
	var creator sql.NullString
	if err := s.db.QueryRowContext(ctx, `SELECT kind, created_by FROM chats WHERE id = ?`, id).Scan(&kind, &creator); err != nil {
		return err
	}
	if kind != "group" {
		return fail(http.StatusBadRequest, "Direktnachrichten lassen sich nur archivieren.")
	}
	if c.isManager() || c.isAdmin || creator.String == c.userID {
		return nil
	}
	return fail(http.StatusForbidden, "Gruppen anderer Mitglieder können nur Manager ändern.")
}

// chatPeople are the ones a chat concerns: who writes in it and is told of new messages.
func chatPeople(ctx context.Context, q dbtx, chatID string) ([]string, error) {
	rows, err := queryRows(ctx, q, `SELECT family_id, COALESCE(created_by, '') AS created_by, assignees_all FROM chats WHERE id = ?`, chatID)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	if rows[0]["assignees_all"] == true {
		return familyMemberIDs(ctx, q, rows[0]["family_id"].(string))
	}
	ids := []string{}
	if creator := rows[0]["created_by"].(string); creator != "" {
		ids = append(ids, creator)
	}
	members, err := queryRows(ctx, q, `SELECT user_id FROM chat_members WHERE chat_id = ?`, chatID)
	if err != nil {
		return nil, err
	}
	for _, row := range members {
		if id := row["user_id"].(string); !slices.Contains(ids, id) {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

// --- Chats ---

// userChats are the chats the user sees in the families, the one with the newest
// message first, each with what the app shows in the list.
func (s *Server) userChats(ctx context.Context, c reqCtx, families []string) ([]map[string]any, error) {
	if len(families) == 0 {
		return []map[string]any{}, nil
	}
	in := placeholders(len(families))
	args := []any{c.userID, c.userID, c.userID, c.userID, c.userID}
	for _, f := range families {
		args = append(args, f)
	}
	args = append(args, c.userID, c.userID)
	rows, err := queryRows(ctx, s.db,
		`SELECT ch.id, ch.family_id, ch.kind, ch.name, ch.color, COALESCE(ch.created_by, '') AS created_by, ch.assignees_all,
			ch.visibility, ch.last_message_at,
			COALESCE(ch.category_id, '') AS category_id, COALESCE(k.name, '') AS category_name, COALESCE(k.color, '') AS category_color,
			EXISTS (SELECT 1 FROM chat_archived a WHERE a.chat_id = ch.id AND a.user_id = ?) AS archived,
			(SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = ch.id AND m.deleted_at IS NULL AND COALESCE(m.sender_id, '') <> ?
				AND m.created_at > COALESCE((SELECT r.read_at FROM chat_reads r WHERE r.chat_id = ch.id AND r.user_id = ?), '')) AS unread,
			EXISTS (SELECT 1 FROM chats w WHERE w.id = ch.id`+strings.ReplaceAll(chatWriter, "ch.", "w.")+`) AS concerns_me
		 FROM chats ch LEFT JOIN categories k ON k.id = ch.category_id
		 WHERE ch.family_id IN (`+in+`)`+chatVisible+`
		 ORDER BY ch.last_message_at DESC, ch.id`, args...)
	if err != nil {
		return nil, err
	}
	familyArgs := make([]any, len(families))
	for i, f := range families {
		familyArgs[i] = f
	}
	members, err := queryRows(ctx, s.db,
		`SELECT cm.chat_id, cm.user_id FROM chat_members cm JOIN chats ch ON ch.id = cm.chat_id
		 WHERE ch.family_id IN (`+in+`) ORDER BY cm.user_id`, familyArgs...)
	if err != nil {
		return nil, err
	}
	byChat := map[string][]string{}
	for _, m := range members {
		byChat[m["chat_id"].(string)] = append(byChat[m["chat_id"].(string)], m["user_id"].(string))
	}
	people, err := queryRows(ctx, s.db,
		`SELECT m.family_id, m.user_id, m.name, m.color, COALESCE(a.small, '') AS avatar FROM memberships m
		 LEFT JOIN member_avatars a ON a.family_id = m.family_id AND a.user_id = m.user_id
		 WHERE m.family_id IN (`+in+`)`, familyArgs...)
	if err != nil {
		return nil, err
	}
	person := map[string]map[string]any{}
	for _, p := range people {
		person[p["family_id"].(string)+"/"+p["user_id"].(string)] = p
	}
	last, err := queryRows(ctx, s.db,
		`SELECT m.chat_id, m.body, m.created_at, COALESCE(m.sender_id, '') AS sender_id, m.deleted_at IS NOT NULL AS deleted,
			COALESCE(ms.name, u.name, '') AS sender_name,
			(SELECT COUNT(*) FROM files f WHERE f.chat_message_id = m.id AND f.kind = 'photo') AS photos,
			(SELECT COUNT(*) FROM files f WHERE f.chat_message_id = m.id AND f.kind <> 'photo') AS documents
		 FROM chat_messages m JOIN chats ch ON ch.id = m.chat_id
		 LEFT JOIN users u ON u.id = m.sender_id
		 LEFT JOIN memberships ms ON ms.user_id = m.sender_id AND ms.family_id = m.family_id
		 WHERE ch.family_id IN (`+in+`)
			AND m.id = (SELECT x.id FROM chat_messages x WHERE x.chat_id = m.chat_id ORDER BY x.created_at DESC, x.id DESC LIMIT 1)`,
		familyArgs...)
	if err != nil {
		return nil, err
	}
	lastOf := map[string]map[string]any{}
	for _, m := range last {
		chatID := m["chat_id"].(string)
		delete(m, "chat_id")
		m["deleted"] = isTrue(m["deleted"])
		m["own"] = m["sender_id"] == c.userID
		lastOf[chatID] = m
	}
	// The newest reaction of someone else to one's own messages, for the app to tell of it.
	reactionArgs := append(append([]any{}, familyArgs...), c.userID, c.userID)
	reacted, err := queryRows(ctx, s.db,
		`SELECT m.chat_id, x.emoji, x.created_at, m.body, COALESCE(ms.name, '') AS reactor_name,
			COALESCE((SELECT MIN(y.name) FROM files y WHERE y.chat_message_id = m.id), '') AS file_name,
			(SELECT COUNT(*) FROM files y WHERE y.chat_message_id = m.id AND y.kind = 'photo') AS photos
		 FROM chat_reactions x JOIN chat_messages m ON m.id = x.message_id JOIN chats ch ON ch.id = m.chat_id
		 LEFT JOIN memberships ms ON ms.family_id = m.family_id AND ms.user_id = x.user_id
		 WHERE ch.family_id IN (`+in+`) AND m.sender_id = ? AND x.user_id <> ? AND m.deleted_at IS NULL
		 ORDER BY x.created_at`, reactionArgs...)
	if err != nil {
		return nil, err
	}
	reactionOf := map[string]map[string]any{}
	for _, x := range reacted {
		reactionOf[x["chat_id"].(string)] = map[string]any{
			"emoji":      x["emoji"],
			"created_at": x["created_at"],
			"text": reactionText(x["reactor_name"].(string), x["emoji"].(string), x["body"].(string),
				anyInt(x["photos"]), x["file_name"].(string)),
		}
	}
	for _, row := range rows {
		id, family := row["id"].(string), row["family_id"].(string)
		ids := byChat[id]
		if ids == nil {
			ids = []string{}
		}
		row["archived"] = isTrue(row["archived"])
		concerns := isTrue(row["concerns_me"])
		delete(row, "concerns_me")
		row["can_write"] = concerns
		row["can_edit"] = row["kind"] == "group" && (c.isManagerIn(ctx, s, family) || row["created_by"] == c.userID)
		// Only what one takes part in counts as unread.
		if !concerns {
			row["unread"] = int64(0)
		}
		if row["kind"] == "direct" {
			// The other one; gone from the circle, the chat stays without them.
			row["assignee_ids"] = ids
			for _, uid := range ids {
				if uid == c.userID {
					continue
				}
				row["other_id"] = uid
				if p := person[family+"/"+uid]; p != nil {
					row["name"] = p["name"]
					row["color"] = p["color"]
					row["avatar"] = p["avatar"]
				}
			}
			if row["name"] == "" {
				row["name"] = "Ehemaliges Mitglied"
			}
		} else {
			row["assignee_ids"] = ids
		}
		if m := lastOf[id]; m != nil {
			row["last_message"] = m
		} else {
			row["last_message"] = nil
		}
		row["reaction"] = reactionOf[id]
	}
	return rows, nil
}

// isManagerIn tells whether the user manages or administers the family; c may be of
// another family when listing all of them.
func (c reqCtx) isManagerIn(ctx context.Context, s *Server, familyID string) bool {
	if familyID == c.familyID {
		return c.isManager() || c.isAdmin
	}
	var admin bool
	var role string
	if err := s.db.QueryRowContext(ctx, `SELECT is_admin, role FROM memberships WHERE family_id = ? AND user_id = ?`,
		familyID, c.userID).Scan(&admin, &role); err != nil {
		return false
	}
	return admin || role == "manager"
}

// isTrue reads what EXISTS gives: a number from SQLite, a bool from Postgres.
func isTrue(v any) bool { return v == true || v == int64(1) }

// listChats is GET /api/chats: the chats of all circles of the user, or only of one
// with ?family=.
func (s *Server) listChats(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	families, err := s.activityFamilies(r, c)
	if err != nil {
		return err
	}
	rows, err := s.userChats(r.Context(), c, families)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

// unreadChats is GET /api/chats/unread: the unread messages, in all and by circle,
// without archived chats.
func (s *Server) unreadChats(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	families, err := s.activityFamilies(r, c)
	if err != nil {
		return err
	}
	rows, err := s.userChats(r.Context(), c, families)
	if err != nil {
		return err
	}
	byFamily := map[string]int{}
	total := 0
	for _, row := range rows {
		if row["archived"] == true {
			continue
		}
		n := anyInt(row["unread"])
		byFamily[row["family_id"].(string)] += n
		total += n
	}
	writeJSON(w, http.StatusOK, map[string]any{"count": total, "families": byFamily})
	return nil
}

// searchChats is GET /api/chats/search?q=: messages with the words, or with a file of
// that name, in the chats the user sees, the newest first.
func (s *Server) searchChats(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if len([]rune(query)) < 2 {
		writeJSON(w, http.StatusOK, []any{})
		return nil
	}
	families, err := s.activityFamilies(r, c)
	if err != nil {
		return err
	}
	if len(families) == 0 {
		writeJSON(w, http.StatusOK, []any{})
		return nil
	}
	escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(strings.ToLower(query))
	pattern := "%" + escaped + "%"
	args := []any{}
	for _, f := range families {
		args = append(args, f)
	}
	args = append(args, c.userID, c.userID, pattern, pattern)
	rows, err := queryRows(r.Context(), s.db,
		`SELECT m.id, m.chat_id, ch.family_id, m.body, m.created_at, COALESCE(m.sender_id, '') AS sender_id,
			COALESCE(ms.name, u.name, '') AS sender_name,
			COALESCE((SELECT MIN(f.name) FROM files f WHERE f.chat_message_id = m.id), '') AS file_name
		 FROM chat_messages m JOIN chats ch ON ch.id = m.chat_id
		 LEFT JOIN users u ON u.id = m.sender_id
		 LEFT JOIN memberships ms ON ms.user_id = m.sender_id AND ms.family_id = m.family_id
		 WHERE ch.family_id IN (`+placeholders(len(families))+`)`+chatVisible+` AND m.deleted_at IS NULL
			AND (LOWER(m.body) LIKE ? ESCAPE '\'
				OR EXISTS (SELECT 1 FROM files f WHERE f.chat_message_id = m.id AND LOWER(f.name) LIKE ? ESCAPE '\'))
		 ORDER BY m.created_at DESC LIMIT 50`, args...)
	if err != nil {
		return err
	}
	for _, row := range rows {
		row["own"] = row["sender_id"] == c.userID
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

type chatInput struct {
	Kind         string   `json:"kind"`
	UserID       string   `json:"user_id"`
	Name         string   `json:"name"`
	Color        string   `json:"color"`
	AssigneesAll bool     `json:"assignees_all"`
	AssigneeIDs  []string `json:"assignee_ids"`
	Visibility   string   `json:"visibility"`
	CategoryID   string   `json:"category_id"`
}

func (s *Server) isFamilyMember(ctx context.Context, familyID, userID string) (bool, error) {
	var found int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM memberships WHERE family_id = ? AND user_id = ?`, familyID, userID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// readChatGroup checks the settings of a group, as readShoppingList does for a list.
func (s *Server) readChatGroup(ctx context.Context, c reqCtx, in *chatInput) error {
	var err error
	if in.Name, err = required(in.Name, "Name", 100); err != nil {
		return err
	}
	if in.Color != "" && !hexColor.MatchString(in.Color) {
		return fail(http.StatusBadRequest, "Ungültige Farbe")
	}
	in.Color = strings.ToUpper(in.Color)
	if in.Visibility == "" {
		in.Visibility = "participants"
	}
	if in.Visibility != "all" && in.Visibility != "participants" {
		return fail(http.StatusBadRequest, "Ungültige Sichtbarkeit")
	}
	if in.AssigneesAll {
		in.AssigneeIDs = nil
	} else if len(in.AssigneeIDs) == 0 {
		return fail(http.StatusBadRequest, "Bitte mindestens eine Person auswählen.")
	}
	slices.Sort(in.AssigneeIDs)
	in.AssigneeIDs = slices.Compact(in.AssigneeIDs)
	for _, id := range in.AssigneeIDs {
		ok, err := s.isFamilyMember(ctx, c.familyID, id)
		if err != nil {
			return err
		}
		if !ok {
			return fail(http.StatusBadRequest, "Diese Person gehört nicht "+familyTypes[c.familyType].to+".")
		}
	}
	if in.CategoryID != "" {
		var found int
		err := s.db.QueryRowContext(ctx, `SELECT 1 FROM categories WHERE id = ? AND family_id = ?`, in.CategoryID, c.familyID).Scan(&found)
		if errors.Is(err, sql.ErrNoRows) {
			return fail(http.StatusBadRequest, "Unbekannte Kategorie")
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func setChatMembers(ctx context.Context, tx *database.Tx, chatID string, ids []string) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM chat_members WHERE chat_id = ?`, chatID); err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := tx.ExecContext(ctx, `INSERT INTO chat_members (chat_id, user_id) VALUES (?, ?)`, chatID, id); err != nil {
			return err
		}
	}
	return nil
}

// createChat is POST /families/{fid}/chats: a group, or the direct messages with
// another member, which exist only once for the two; then they are answered with 200.
func (s *Server) createChat(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in chatInput
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	switch in.Kind {
	case "direct":
		if in.UserID == "" || in.UserID == c.userID {
			return fail(http.StatusBadRequest, "Bitte eine andere Person auswählen.")
		}
		ok, err := s.isFamilyMember(ctx, c.familyID, in.UserID)
		if err != nil {
			return err
		}
		if !ok {
			return fail(http.StatusBadRequest, "Diese Person gehört nicht "+familyTypes[c.familyType].to+".")
		}
		var id string
		err = s.db.QueryRowContext(ctx,
			`SELECT ch.id FROM chats ch WHERE ch.family_id = ? AND ch.kind = 'direct'
				AND EXISTS (SELECT 1 FROM chat_members a WHERE a.chat_id = ch.id AND a.user_id = ?)
				AND EXISTS (SELECT 1 FROM chat_members b WHERE b.chat_id = ch.id AND b.user_id = ?)`,
			c.familyID, c.userID, in.UserID).Scan(&id)
		if err == nil {
			writeJSON(w, http.StatusOK, map[string]string{"id": id})
			return nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		in.AssigneeIDs = []string{c.userID, in.UserID}
		in.Name, in.Color, in.Visibility, in.CategoryID, in.AssigneesAll = "", "", "participants", "", false
	case "group":
		if err := s.readChatGroup(ctx, c, &in); err != nil {
			return err
		}
	default:
		return fail(http.StatusBadRequest, "Ungültige Art")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	id, at := newID(), chatNow()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO chats (id, family_id, kind, name, color, category_id, created_by, assignees_all, visibility, created_at, last_message_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, c.familyID, in.Kind, in.Name, in.Color, nullable(in.CategoryID), c.userID, in.AssigneesAll, in.Visibility, at, at); err != nil {
		return err
	}
	if err := setChatMembers(ctx, tx, id, in.AssigneeIDs); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

func (s *Server) updateChat(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.chatChangeAccess(ctx, c, id); err != nil {
		return err
	}
	var in chatInput
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if err := s.readChatGroup(ctx, c, &in); err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`UPDATE chats SET name = ?, color = ?, category_id = ?, assignees_all = ?, visibility = ? WHERE id = ? AND family_id = ?`,
		in.Name, in.Color, nullable(in.CategoryID), in.AssigneesAll, in.Visibility, id, c.familyID); err != nil {
		return err
	}
	if err := setChatMembers(ctx, tx, id, in.AssigneeIDs); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

// chatFileKeys are the storage keys of the files of the messages the condition selects.
func chatFileKeys(ctx context.Context, q dbtx, condition string, args ...any) ([]string, error) {
	return fileIDs(ctx, q, `SELECT f.id, f.family_id FROM files f JOIN chat_messages m ON m.id = f.chat_message_id WHERE `+condition, args...)
}

// deleteChat deletes a group with its messages and files.
func (s *Server) deleteChat(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.chatChangeAccess(ctx, c, id); err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	keys, err := chatFileKeys(ctx, tx, `m.chat_id = ?`, id)
	if err != nil {
		return err
	}
	res, err := tx.ExecContext(ctx, `DELETE FROM chats WHERE id = ? AND family_id = ?`, id, c.familyID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	for _, key := range keys {
		s.removeStoredFile(r, key)
	}
	return noContent(w)
}

// archiveChat is PUT /families/{fid}/chats/{id}/archive: out of the user's list, until
// a new message comes.
func (s *Server) archiveChat(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.chatAccess(ctx, c, id); err != nil {
		return err
	}
	var in struct {
		Archived bool `json:"archived"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	query := `DELETE FROM chat_archived WHERE chat_id = ? AND user_id = ?`
	if in.Archived {
		query = `INSERT INTO chat_archived (chat_id, user_id) VALUES (?, ?) ON CONFLICT (chat_id, user_id) DO NOTHING`
	}
	if _, err := s.db.ExecContext(ctx, query, id, c.userID); err != nil {
		return err
	}
	return noContent(w)
}

// markChatRead is POST /families/{fid}/chats/{id}/read: all of it is read now.
func (s *Server) markChatRead(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.chatAccess(ctx, c, id); err != nil {
		return err
	}
	if err := markRead(ctx, s.db, id, c.userID); err != nil {
		return err
	}
	return noContent(w)
}

func markRead(ctx context.Context, q dbtx, chatID, userID string) error {
	_, err := q.ExecContext(ctx,
		`INSERT INTO chat_reads (chat_id, user_id, read_at) VALUES (?, ?, ?)
		 ON CONFLICT (chat_id, user_id) DO UPDATE SET read_at = excluded.read_at`, chatID, userID, chatNow())
	return err
}

// --- Messages ---

// listChatMessages is GET .../chats/{id}/messages: the newest, the oldest of them first,
// or those before ?before=. more tells whether there are older ones. Each comes with its
// files, the reactions to it and, for an answer, a little of the message it answers.
func (s *Server) listChatMessages(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, id := r.Context(), r.PathValue("id")
	if err := s.chatAccess(ctx, c, id); err != nil {
		return err
	}
	before := r.URL.Query().Get("before")
	if before == "" {
		before = "9999"
	}
	rows, err := queryRows(ctx, s.db,
		`SELECT m.id, COALESCE(m.sender_id, '') AS sender_id, COALESCE(ms.name, u.name, '') AS sender_name,
			COALESCE(ms.color, '') AS sender_color, m.body, m.created_at, m.deleted_at IS NOT NULL AS deleted,
			m.forwarded, COALESCE(m.reply_to, '') AS reply_to
		 FROM chat_messages m LEFT JOIN users u ON u.id = m.sender_id
		 LEFT JOIN memberships ms ON ms.user_id = m.sender_id AND ms.family_id = m.family_id
		 WHERE m.chat_id = ? AND m.created_at < ? ORDER BY m.created_at DESC, m.id DESC LIMIT ?`,
		id, before, maxChatMessages+1)
	if err != nil {
		return err
	}
	more := len(rows) > maxChatMessages
	if more {
		rows = rows[:maxChatMessages]
	}
	slices.Reverse(rows)
	files, err := queryRows(ctx, s.db,
		`SELECT f.id, f.chat_message_id, f.name, f.mime, f.size, f.kind FROM files f JOIN chat_messages m ON m.id = f.chat_message_id
		 WHERE m.chat_id = ? AND m.created_at < ? ORDER BY f.created_at, f.id`, id, before)
	if err != nil {
		return err
	}
	byMessage := map[string][]map[string]any{}
	for _, f := range files {
		message := f["chat_message_id"].(string)
		delete(f, "chat_message_id")
		byMessage[message] = append(byMessage[message], f)
	}
	reactions, err := queryRows(ctx, s.db,
		`SELECT x.message_id, x.user_id, x.emoji, COALESCE(ms.name, u.name, '') AS name
		 FROM chat_reactions x JOIN chat_messages m ON m.id = x.message_id
		 LEFT JOIN users u ON u.id = x.user_id
		 LEFT JOIN memberships ms ON ms.user_id = x.user_id AND ms.family_id = m.family_id
		 WHERE m.chat_id = ? AND m.created_at < ? ORDER BY x.created_at, x.user_id`, id, before)
	if err != nil {
		return err
	}
	reactionsOf := map[string][]map[string]any{}
	for _, x := range reactions {
		message := x["message_id"].(string)
		list := reactionsOf[message]
		var entry map[string]any
		for _, e := range list {
			if e["emoji"] == x["emoji"] {
				entry = e
			}
		}
		if entry == nil {
			entry = map[string]any{"emoji": x["emoji"], "count": 0, "mine": false, "names": []string{}}
			list = append(list, entry)
		}
		entry["count"] = entry["count"].(int) + 1
		entry["names"] = append(entry["names"].([]string), x["name"].(string))
		if x["user_id"] == c.userID {
			entry["mine"] = true
		}
		reactionsOf[message] = list
	}
	quotes, err := s.chatQuotes(ctx, rows)
	if err != nil {
		return err
	}
	for _, row := range rows {
		messageID := row["id"].(string)
		attachments := byMessage[messageID]
		if attachments == nil {
			attachments = []map[string]any{}
		}
		row["attachments"] = attachments
		row["deleted"] = isTrue(row["deleted"])
		row["forwarded"] = isTrue(row["forwarded"])
		own := row["sender_id"] == c.userID
		row["own"] = own
		row["can_delete"] = own && row["deleted"] == false
		list := reactionsOf[messageID]
		if list == nil || row["deleted"] == true {
			list = []map[string]any{}
		}
		row["reactions"] = list
		row["reply"] = quotes[row["reply_to"].(string)]
		delete(row, "reply_to")
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": rows, "more": more})
	return nil
}

// chatQuotes are the messages the rows answer, by id, with what an answer shows of them.
func (s *Server) chatQuotes(ctx context.Context, rows []map[string]any) (map[string]any, error) {
	quotes := map[string]any{}
	for _, row := range rows {
		replyTo := row["reply_to"].(string)
		if replyTo == "" || quotes[replyTo] != nil {
			continue
		}
		found, err := queryRows(ctx, s.db,
			`SELECT m.id, COALESCE(m.sender_id, '') AS sender_id, COALESCE(ms.name, u.name, '') AS sender_name,
				m.body, m.deleted_at IS NOT NULL AS deleted,
				(SELECT COUNT(*) FROM files f WHERE f.chat_message_id = m.id AND f.kind = 'photo') AS photos,
				(SELECT COUNT(*) FROM files f WHERE f.chat_message_id = m.id AND f.kind <> 'photo') AS documents
			 FROM chat_messages m LEFT JOIN users u ON u.id = m.sender_id
			 LEFT JOIN memberships ms ON ms.user_id = m.sender_id AND ms.family_id = m.family_id
			 WHERE m.id = ?`, replyTo)
		if err != nil {
			return nil, err
		}
		if len(found) == 1 {
			quote := found[0]
			quote["deleted"] = isTrue(quote["deleted"])
			quotes[replyTo] = quote
		}
	}
	return quotes, nil
}

// addChatMessage writes a message in the transaction: the chat moves to the top, comes
// back for whoever archived it, and the sender has read it.
func addChatMessage(ctx context.Context, tx *database.Tx, c reqCtx, chatID, body, replyTo string, forwarded bool) (string, error) {
	id, at := newID(), chatNow()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO chat_messages (id, chat_id, family_id, sender_id, body, created_at, reply_to, forwarded) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		id, chatID, c.familyID, c.userID, body, at, nullable(replyTo), forwarded); err != nil {
		return "", err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE chats SET last_message_at = ? WHERE id = ?`, at, chatID); err != nil {
		return "", err
	}
	people, err := chatPeople(ctx, tx, chatID)
	if err != nil {
		return "", err
	}
	for _, person := range people {
		if _, err := tx.ExecContext(ctx, `DELETE FROM chat_archived WHERE chat_id = ? AND user_id = ?`, chatID, person); err != nil {
			return "", err
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO chat_reads (chat_id, user_id, read_at) VALUES (?, ?, ?)
		 ON CONFLICT (chat_id, user_id) DO UPDATE SET read_at = excluded.read_at`, chatID, c.userID, at); err != nil {
		return "", err
	}
	return id, nil
}

// postChatMessage is POST .../chats/{id}/messages: words, maybe as the answer to a
// message of the same chat; or a message forwarded from another chat the user sees,
// with its files, which are copied.
func (s *Server) postChatMessage(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, chatID := r.Context(), r.PathValue("id")
	if err := s.chatWriteAccess(ctx, c, chatID); err != nil {
		return err
	}
	var in struct {
		Body       string `json:"body"`
		ReplyTo    string `json:"reply_to"`
		ForwardOf  string `json:"forward_of"`
		ForwardFam string `json:"forward_family_id"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if in.ForwardOf != "" {
		return s.forwardChatMessage(w, r, c, chatID, in.ForwardFam, in.ForwardOf)
	}
	body, err := required(in.Body, "Nachricht", 4000)
	if err != nil {
		return err
	}
	if in.ReplyTo != "" {
		var found int
		err := s.db.QueryRowContext(ctx, `SELECT 1 FROM chat_messages WHERE id = ? AND chat_id = ?`, in.ReplyTo, chatID).Scan(&found)
		if errors.Is(err, sql.ErrNoRows) {
			return fail(http.StatusBadRequest, "Diese Nachricht gibt es in diesem Chat nicht.")
		}
		if err != nil {
			return err
		}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	id, err := addChatMessage(ctx, tx, c, chatID, body, in.ReplyTo, false)
	if err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

// forwardChatMessage copies a message the user sees, from any of their circles, into
// the chat: its words and its files, which get copies of their own in this circle.
func (s *Server) forwardChatMessage(w http.ResponseWriter, r *http.Request, c reqCtx, chatID, fromFamily, messageID string) error {
	ctx := r.Context()
	if fromFamily == "" {
		fromFamily = c.familyID
	}
	ok, err := s.isFamilyMember(ctx, fromFamily, c.userID)
	if err != nil {
		return err
	}
	if !ok {
		return errNotFound
	}
	var body, fromChat string
	var deleted bool
	err = s.db.QueryRowContext(ctx,
		`SELECT m.body, m.chat_id, m.deleted_at IS NOT NULL FROM chat_messages m WHERE m.id = ? AND m.family_id = ?`,
		messageID, fromFamily).Scan(&body, &fromChat, &deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	from := c
	from.familyID = fromFamily
	if err := s.chatAccess(ctx, from, fromChat); err != nil {
		return err
	}
	if deleted {
		return fail(http.StatusBadRequest, "Eine gelöschte Nachricht lässt sich nicht weiterleiten.")
	}
	files, err := queryRows(ctx, s.db,
		`SELECT id, name, mime, size, kind FROM files WHERE chat_message_id = ? ORDER BY created_at, id`, messageID)
	if err != nil {
		return err
	}
	// The copies go into the storage first; what is not kept goes out again.
	type copied struct {
		id, key string
		file    map[string]any
	}
	var copies []copied
	kept := false
	defer func() {
		if kept {
			return
		}
		for _, f := range copies {
			s.files.Delete(context.WithoutCancel(ctx), f.key)
		}
	}()
	for _, f := range files {
		content, _, err := s.files.Get(ctx, fileKey(fromFamily, f["id"].(string)))
		if err != nil {
			return err
		}
		id := newID()
		key := fileKey(c.familyID, id)
		_, err = s.files.Put(ctx, key, content, f["mime"].(string))
		content.Close()
		if err != nil {
			return err
		}
		copies = append(copies, copied{id: id, key: key, file: f})
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	id, err := addChatMessage(ctx, tx, c, chatID, body, "", true)
	if err != nil {
		return err
	}
	for _, f := range copies {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO files (id, family_id, kind, name, mime, size, uploaded_by, created_at, chat_message_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			f.id, c.familyID, f.file["kind"], f.file["name"], f.file["mime"], f.file["size"], c.userID, now(), id); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	kept = true
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

// reactToChatMessage is PUT .../chats/{id}/messages/{mid}/reaction: one emoji of the user
// for the message, which replaces the one before; an empty one takes it back.
func (s *Server) reactToChatMessage(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, chatID, id := r.Context(), r.PathValue("id"), r.PathValue("mid")
	if err := s.chatWriteAccess(ctx, c, chatID); err != nil {
		return err
	}
	var in struct {
		Emoji string `json:"emoji"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	emoji := strings.TrimSpace(in.Emoji)
	if len(emoji) > 64 || strings.IndexFunc(emoji, func(r rune) bool {
		return r < 0x80 && r != '#' && r != '*' && !(r >= '0' && r <= '9')
	}) >= 0 {
		return fail(http.StatusBadRequest, "Ungültige Reaktion")
	}
	var found int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM chat_messages WHERE id = ? AND chat_id = ? AND deleted_at IS NULL`, id, chatID).Scan(&found)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	if emoji == "" {
		_, err = s.db.ExecContext(ctx, `DELETE FROM chat_reactions WHERE message_id = ? AND user_id = ?`, id, c.userID)
	} else {
		_, err = s.db.ExecContext(ctx,
			`INSERT INTO chat_reactions (message_id, user_id, emoji, created_at) VALUES (?, ?, ?, ?)
			 ON CONFLICT (message_id, user_id) DO UPDATE SET emoji = excluded.emoji, created_at = excluded.created_at, pushed_at = NULL`,
			id, c.userID, emoji, chatNow())
	}
	if err != nil {
		return err
	}
	return noContent(w)
}

// uploadChatFile is POST .../chats/{id}/attachments: a picture or a document, as a
// message of its own.
func (s *Server) uploadChatFile(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, chatID := r.Context(), r.PathValue("id")
	if err := s.chatWriteAccess(ctx, c, chatID); err != nil {
		return err
	}
	up, err := s.receiveUpload(w, r, c, "")
	if err != nil {
		return err
	}
	defer up.discard()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	id, err := addChatMessage(ctx, tx, c, chatID, "", "", false)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO files (id, family_id, kind, name, mime, size, uploaded_by, created_at, chat_message_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		up.id, c.familyID, up.kind, up.name, up.mime, up.size, c.userID, now(), id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	up.keep()
	writeJSON(w, http.StatusCreated, map[string]string{"id": id, "file_id": up.id})
	return nil
}

// deleteChatMessage takes back one's own message: its words and files go, a note stays.
func (s *Server) deleteChatMessage(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, chatID, id := r.Context(), r.PathValue("id"), r.PathValue("mid")
	if err := s.chatAccess(ctx, c, chatID); err != nil {
		return err
	}
	var sender sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT sender_id FROM chat_messages WHERE id = ? AND chat_id = ? AND deleted_at IS NULL`, id, chatID).Scan(&sender)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	if sender.String != c.userID {
		return fail(http.StatusForbidden, "Nur eigene Nachrichten lassen sich löschen.")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	keys, err := chatFileKeys(ctx, tx, `m.id = ?`, id)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM chat_reactions WHERE message_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM files WHERE chat_message_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE chat_messages SET body = '', deleted_at = ? WHERE id = ?`, chatNow(), id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	for _, key := range keys {
		s.removeStoredFile(r, key)
	}
	return noContent(w)
}

// chatFile checks that the file belongs to a message of the chat the user sees.
func (s *Server) chatFile(r *http.Request, c reqCtx) (id, name, mime string, err error) {
	ctx, chatID := r.Context(), r.PathValue("id")
	if err := s.chatAccess(ctx, c, chatID); err != nil {
		return "", "", "", err
	}
	id = r.PathValue("fileId")
	err = s.db.QueryRowContext(ctx,
		`SELECT f.name, f.mime FROM files f JOIN chat_messages m ON m.id = f.chat_message_id WHERE f.id = ? AND m.chat_id = ?`,
		id, chatID).Scan(&name, &mime)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", "", errNotFound
	}
	return id, name, mime, err
}

// chatFileContent is GET .../chats/{id}/attachments/{fileId}, for showing pictures in the app.
func (s *Server) chatFileContent(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	id, name, mime, err := s.chatFile(r, c)
	if err != nil {
		return err
	}
	return s.serveFile(w, r, fileKey(c.familyID, id), name, mime, "attachment")
}

// chatFileLink is POST .../chats/{id}/attachments/{fileId}/link, for opening a document.
func (s *Server) chatFileLink(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	id, _, _, err := s.chatFile(r, c)
	if err != nil {
		return err
	}
	return s.writeDownloadLink(w, r, id)
}
