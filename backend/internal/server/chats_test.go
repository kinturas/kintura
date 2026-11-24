package server

import (
	"context"
	"net/url"
	"strings"
	"testing"
	"time"
)

func (e *testEnv) chats(token, query string) []obj {
	e.t.Helper()
	var out []obj
	if err := e.getJSON("/api/chats"+query, token, &out); err != nil {
		e.t.Fatal(err)
	}
	return out
}

func chatByID(chats []obj, id string) obj {
	for _, c := range chats {
		if c["id"] == id {
			return c
		}
	}
	return nil
}

func chatTexts(e *testEnv, token, base, id string) string {
	e.t.Helper()
	var parts []string
	for _, m := range e.expect(200, "GET", base+"/chats/"+id+"/messages", token, nil)["messages"].([]any) {
		msg := m.(obj)
		text := msg["body"].(string)
		if msg["deleted"] == true {
			text = "-"
		}
		parts = append(parts, text)
	}
	return strings.Join(parts, ",")
}

func TestChatsDirectAndGroups(t *testing.T) {
	e := newEnv(t)
	anna := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(anna)
	annaID := e.expect(200, "GET", "/api/me", anna, nil)["id"].(string)
	ben, benID := e.addMember(fid, anna, "b@example.de")
	cleo, cleoID := e.addMember(fid, anna, "c@example.de")
	base := "/api/families/" + fid

	// Direct messages exist once for two, whoever starts them.
	e.expect(400, "POST", base+"/chats", anna, obj{"kind": "direct", "user_id": annaID})
	e.expect(400, "POST", base+"/chats", anna, obj{"kind": "direct", "user_id": "niemand"})
	direct := e.expect(201, "POST", base+"/chats", anna, obj{"kind": "direct", "user_id": benID})["id"].(string)
	if again := e.expect(200, "POST", base+"/chats", ben, obj{"kind": "direct", "user_id": annaID})["id"]; again != direct {
		t.Fatalf("second direct chat: %v", again)
	}
	e.expect(201, "POST", base+"/chats/"+direct+"/messages", anna, obj{"body": "Hallo Ben"})
	e.expect(400, "POST", base+"/chats/"+direct+"/messages", anna, obj{"body": "  "})
	// Cleo neither sees nor writes in it.
	e.expect(404, "GET", base+"/chats/"+direct+"/messages", cleo, nil)
	e.expect(404, "POST", base+"/chats/"+direct+"/messages", cleo, obj{"body": "Ich auch"})
	if chatByID(e.chats(cleo, ""), direct) != nil {
		t.Fatal("cleo sees the direct chat")
	}
	// Each sees the other's name.
	if got := chatByID(e.chats(ben, ""), direct); got["name"] != "Anna" || got["unread"] != float64(1) || got["can_write"] != true {
		t.Fatalf("ben's view: %v", got)
	}
	if got := chatByID(e.chats(anna, ""), direct); got["name"] == "Anna" || got["unread"] != float64(0) {
		t.Fatalf("anna's view: %v", got)
	}
	e.expect(400, "PUT", base+"/chats/"+direct, anna, obj{"name": "X", "assignees_all": true})
	e.expect(400, "DELETE", base+"/chats/"+direct, anna, nil)

	// A group for Anna and Ben that everyone may read along.
	e.expect(400, "POST", base+"/chats", anna, obj{"kind": "group", "name": " ", "assignees_all": true})
	e.expect(400, "POST", base+"/chats", anna, obj{"kind": "group", "name": "X"})
	e.expect(400, "POST", base+"/chats", anna, obj{"kind": "group", "name": "X", "color": "rot", "assignees_all": true})
	group := e.expect(201, "POST", base+"/chats", anna, obj{
		"kind": "group", "name": "Urlaub", "color": "#3567b5", "assignee_ids": []string{benID}, "visibility": "all",
	})["id"].(string)
	e.expect(201, "POST", base+"/chats/"+group+"/messages", ben, obj{"body": "Wohin fahren wir?"})
	if got := e.expect(403, "POST", base+"/chats/"+group+"/messages", cleo, obj{"body": "Ich will mit"})["error"]; got != chatReadOnly {
		t.Fatalf("cleo writes: %v", got)
	}
	if got := chatTexts(e, cleo, base, group); got != "Wohin fahren wir?" {
		t.Fatalf("cleo reads: %s", got)
	}
	cleoView := chatByID(e.chats(cleo, ""), group)
	if cleoView["can_write"] != false || cleoView["can_edit"] != false || cleoView["unread"] != float64(0) || cleoView["color"] != "#3567B5" {
		t.Fatalf("cleo's view of the group: %v", cleoView)
	}
	// Only the creator and managers change or delete it.
	e.expect(403, "PUT", base+"/chats/"+group, ben, obj{"name": "X", "assignees_all": true})
	e.expect(403, "DELETE", base+"/chats/"+group, ben, nil)
	e.expect(204, "PUT", base+"/chats/"+group, anna, obj{"name": "Sommerurlaub", "assignee_ids": []string{benID}})
	// Now only for the two: Cleo no longer sees it.
	e.expect(404, "GET", base+"/chats/"+group+"/messages", cleo, nil)

	// The chat with the newest message comes first.
	e.expect(201, "POST", base+"/chats/"+direct+"/messages", ben, obj{"body": "Hallo Anna"})
	list := e.chats(anna, "")
	if len(list) != 2 || list[0]["id"] != direct || list[1]["id"] != group {
		t.Fatalf("order: %v", list)
	}
	last := list[0]["last_message"].(obj)
	if last["body"] != "Hallo Anna" || last["sender_name"] != "B" || last["own"] != false {
		t.Fatalf("last message: %v", last)
	}

	// Unread until read, and not in the number of archived chats.
	unread := e.expect(200, "GET", "/api/chats/unread", anna, nil)
	if unread["count"] != float64(2) || unread["families"].(obj)[fid] != float64(2) {
		t.Fatalf("unread: %v", unread)
	}
	e.expect(204, "POST", base+"/chats/"+direct+"/read", anna, nil)
	e.expect(204, "PUT", base+"/chats/"+group+"/archive", anna, obj{"archived": true})
	if got := e.expect(200, "GET", "/api/chats/unread", anna, nil)["count"]; got != float64(0) {
		t.Fatalf("unread after reading and archiving: %v", got)
	}
	if got := chatByID(e.chats(anna, ""), group); got["archived"] != true {
		t.Fatalf("archived: %v", got)
	}
	// Archived is Anna's own: Ben still has it.
	if got := chatByID(e.chats(ben, ""), group); got["archived"] != false {
		t.Fatalf("ben's group: %v", got)
	}
	// A new message brings it back.
	e.expect(201, "POST", base+"/chats/"+group+"/messages", ben, obj{"body": "Ans Meer!"})
	if got := chatByID(e.chats(anna, ""), group); got["archived"] != false || got["unread"] != float64(2) {
		t.Fatalf("after a new message: %v", got)
	}

	// Own messages can be taken back, others' not.
	msgs := e.expect(200, "GET", base+"/chats/"+group+"/messages", anna, nil)["messages"].([]any)
	first := msgs[0].(obj)
	if first["own"] != false || first["can_delete"] != false || first["sender_name"] != "B" {
		t.Fatalf("first message: %v", first)
	}
	e.expect(403, "DELETE", base+"/chats/"+group+"/messages/"+first["id"].(string), anna, nil)
	e.expect(204, "DELETE", base+"/chats/"+group+"/messages/"+first["id"].(string), ben, nil)
	e.expect(404, "DELETE", base+"/chats/"+group+"/messages/"+first["id"].(string), ben, nil)
	if got := chatTexts(e, anna, base, group); got != "-,Ans Meer!" {
		t.Fatalf("after deleting: %s", got)
	}

	// Only a circle of one's own.
	if got := e.chats(anna, "?family="+fid); len(got) != 2 {
		t.Fatalf("one circle: %v", got)
	}
	e.expect(404, "GET", "/api/chats?family=fremd", anna, nil)

	// The group goes with its messages.
	e.expect(204, "DELETE", base+"/chats/"+group, anna, nil)
	e.expect(404, "GET", base+"/chats/"+group+"/messages", ben, nil)
	_ = cleoID
}

func TestChatFilesAndSearch(t *testing.T) {
	e := newEnv(t)
	anna := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(anna)
	ben, benID := e.addMember(fid, anna, "b@example.de")
	cleo, _ := e.addMember(fid, anna, "c@example.de")
	base := "/api/families/" + fid
	direct := e.expect(201, "POST", base+"/chats", anna, obj{"kind": "direct", "user_id": benID})["id"].(string)

	status, out := e.uploadTo(anna, base+"/chats/"+direct+"/attachments", "strand.png", pngHeader)
	if status != 201 {
		t.Fatalf("picture: %d %v", status, out)
	}
	picture := out["file_id"].(string)
	status, out = e.uploadTo(ben, base+"/chats/"+direct+"/attachments", "Packliste.txt", []byte("Badehose"))
	if status != 201 {
		t.Fatalf("document: %d %v", status, out)
	}
	document := out["file_id"].(string)
	e.expect(201, "POST", base+"/chats/"+direct+"/messages", ben, obj{"body": "Vergiss die Sonnencreme nicht"})

	msgs := e.expect(200, "GET", base+"/chats/"+direct+"/messages", anna, nil)["messages"].([]any)
	if len(msgs) != 3 {
		t.Fatalf("messages: %v", msgs)
	}
	first := msgs[0].(obj)["attachments"].([]any)[0].(obj)
	second := msgs[1].(obj)["attachments"].([]any)[0].(obj)
	if first["kind"] != "photo" || first["name"] != "strand.png" || second["kind"] != "document" || second["id"] != document {
		t.Fatalf("attachments: %v %v", first, second)
	}
	if status, content := e.getRaw(base+"/chats/"+direct+"/attachments/"+document, anna); status != 200 || content != "Badehose" {
		t.Fatalf("content: %d %q", status, content)
	}
	link := e.expect(200, "POST", base+"/chats/"+direct+"/attachments/"+document+"/link", ben, nil)["url"].(string)
	if !strings.Contains(link, "/dl/") {
		t.Fatalf("link: %s", link)
	}
	// Not for Cleo, not among the documents of the circle, not under another chat.
	e.expect(404, "GET", base+"/chats/"+direct+"/attachments/"+document, cleo, nil)
	e.expect(404, "GET", base+"/files/"+document+"/content", anna, nil)
	var docs []obj
	if err := e.getJSON(base+"/files?kind=document", anna, &docs); err != nil || len(docs) != 0 {
		t.Fatalf("documents: %v %v", docs, err)
	}
	other := e.expect(201, "POST", base+"/chats", anna, obj{"kind": "group", "name": "Andere", "assignees_all": true})["id"].(string)
	e.expect(404, "GET", base+"/chats/"+other+"/attachments/"+document, anna, nil)

	// The search finds words and file names, upper or lower case, only where one may look.
	search := func(token, q string) []obj {
		t.Helper()
		var out []obj
		if err := e.getJSON("/api/chats/search?q="+url.QueryEscape(q), token, &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	if got := search(anna, "SONNEN"); len(got) != 1 || got[0]["chat_id"] != direct || got[0]["sender_name"] != "B" {
		t.Fatalf("search words: %v", got)
	}
	if got := search(ben, "packl"); len(got) != 1 || got[0]["file_name"] != "Packliste.txt" || got[0]["own"] != true {
		t.Fatalf("search file: %v", got)
	}
	if got := search(anna, "50%"); len(got) != 0 {
		t.Fatalf("search with %%: %v", got)
	}
	if got := search(cleo, "sonnen"); len(got) != 0 {
		t.Fatalf("cleo finds: %v", got)
	}
	if got := search(anna, "s"); len(got) != 0 {
		t.Fatalf("one letter: %v", got)
	}

	// Deleting the message takes the file off the disk.
	if !e.fileStored(picture) {
		t.Fatal("picture missing")
	}
	e.expect(204, "DELETE", base+"/chats/"+direct+"/messages/"+msgs[0].(obj)["id"].(string), anna, nil)
	if e.fileStored(picture) {
		t.Fatal("picture still on disk")
	}
}

func TestChatPushes(t *testing.T) {
	e := newEnv(t)
	anna := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(anna)
	ben, benID := e.addMember(fid, anna, "b@example.de")
	base := "/api/families/" + fid
	push := &fakePusher{gone: map[string]bool{}}
	e.server.push = push
	e.expect(204, "PUT", "/api/me/push-device", anna, obj{"token": "tok-a", "platform": "android"})
	e.expect(204, "PUT", "/api/me/push-device", ben, obj{"token": "tok-b", "platform": "android"})

	direct := e.expect(201, "POST", base+"/chats", anna, obj{"kind": "direct", "user_id": benID})["id"].(string)
	e.expect(201, "POST", base+"/chats/"+direct+"/messages", anna, obj{"body": "Kommst du zum Essen?"})
	e.server.sendPushes(context.Background(), time.Now())
	e.server.sendPushes(context.Background(), time.Now())
	if len(push.sent) != 1 {
		t.Fatalf("sent: %v", push.sent)
	}
	msg := push.sent[0]
	if msg.Token != "tok-b" || msg.Title != "Anna" || msg.Body != "Kommst du zum Essen?" ||
		msg.Data["kintura"] != "message" || msg.Data["chat_id"] != direct || msg.Data["family_id"] != fid {
		t.Fatalf("push: %+v", msg)
	}

	// In a group with the sender's name; nothing for who has read it already.
	group := e.expect(201, "POST", base+"/chats", ben, obj{"kind": "group", "name": "Familie", "assignees_all": true})["id"].(string)
	e.expect(201, "POST", base+"/chats/"+group+"/messages", ben, obj{"body": "Pizza?"})
	e.expect(204, "POST", base+"/chats/"+group+"/read", anna, nil)
	e.expect(201, "POST", base+"/chats/"+group+"/messages", ben, obj{"body": "Oder Nudeln?"})
	e.server.sendPushes(context.Background(), time.Now())
	if len(push.sent) != 2 {
		t.Fatalf("sent: %v", push.sent)
	}
	if msg := push.sent[1]; msg.Token != "tok-a" || msg.Title != "Familie" || !strings.HasSuffix(msg.Body, ": Oder Nudeln?") {
		t.Fatalf("group push: %+v", msg)
	}
	// Messages are no news of Aktuelles.
	if got := e.expect(200, "GET", "/api/activities", anna, nil)["items"].([]any); len(got) != 0 {
		t.Fatalf("activities: %v", got)
	}
}

func messageByID(t *testing.T, e *testEnv, token, base, chat, id string) obj {
	t.Helper()
	for _, m := range e.expect(200, "GET", base+"/chats/"+chat+"/messages", token, nil)["messages"].([]any) {
		if m.(obj)["id"] == id {
			return m.(obj)
		}
	}
	t.Fatalf("message %s missing", id)
	return nil
}

func TestChatReactionsRepliesAndForwarding(t *testing.T) {
	e := newEnv(t)
	anna := e.register("a@example.de", "Anna", "F")
	fid := e.firstFamily(anna)
	ben, benID := e.addMember(fid, anna, "b@example.de")
	cleo, _ := e.addMember(fid, anna, "c@example.de")
	base := "/api/families/" + fid
	push := &fakePusher{gone: map[string]bool{}}
	e.server.push = push
	e.expect(204, "PUT", "/api/me/push-device", anna, obj{"token": "tok-a", "platform": "android"})

	group := e.expect(201, "POST", base+"/chats", anna, obj{
		"kind": "group", "name": "Urlaub", "assignee_ids": []string{benID}, "visibility": "all",
	})["id"].(string)
	question := e.expect(201, "POST", base+"/chats/"+group+"/messages", anna, obj{"body": "Wohin fahren wir im Sommer?"})["id"].(string)
	e.server.sendPushes(context.Background(), time.Now())
	push.sent = nil

	// One reaction per person: another replaces it, none takes it back.
	reaction := base + "/chats/" + group + "/messages/" + question + "/reaction"
	e.expect(400, "PUT", reaction, ben, obj{"emoji": "lol"})
	e.expect(403, "PUT", reaction, cleo, obj{"emoji": "❤️"})
	e.expect(204, "PUT", reaction, ben, obj{"emoji": "👍"})
	e.expect(204, "PUT", reaction, ben, obj{"emoji": "❤️"})
	e.expect(204, "PUT", reaction, anna, obj{"emoji": "❤️"})
	got := messageByID(t, e, cleo, base, group, question)["reactions"].([]any)
	if len(got) != 1 || got[0].(obj)["emoji"] != "❤️" || got[0].(obj)["count"] != float64(2) || got[0].(obj)["mine"] != false {
		t.Fatalf("reactions: %v", got)
	}
	if names := got[0].(obj)["names"].([]any); len(names) != 2 {
		t.Fatalf("names: %v", names)
	}
	if mine := messageByID(t, e, ben, base, group, question)["reactions"].([]any)[0].(obj)["mine"]; mine != true {
		t.Fatalf("ben's own: %v", mine)
	}
	// Anna hears of Ben's, once, but not of her own.
	e.server.sendPushes(context.Background(), time.Now())
	e.server.sendPushes(context.Background(), time.Now())
	if len(push.sent) != 1 || push.sent[0].Token != "tok-a" || push.sent[0].Title != "Urlaub" ||
		push.sent[0].Body != "B hat mit ❤️ auf „Wohin fahren wir im Sommer?“ reagiert." || push.sent[0].Data["chat_id"] != group {
		t.Fatalf("reaction push: %+v", push.sent)
	}
	// And the app, while it runs, from the list.
	if r := chatByID(e.chats(anna, ""), group)["reaction"].(obj); r["emoji"] != "❤️" || !strings.HasPrefix(r["text"].(string), "B hat mit ❤️") {
		t.Fatalf("reaction in the list: %v", r)
	}
	e.expect(204, "PUT", reaction, anna, obj{"emoji": ""})
	if got := messageByID(t, e, ben, base, group, question)["reactions"].([]any); len(got) != 1 || got[0].(obj)["count"] != float64(1) {
		t.Fatalf("after taking back: %v", got)
	}

	// An answer shows a little of what it answers; only in the same chat.
	other := e.expect(201, "POST", base+"/chats", anna, obj{"kind": "direct", "user_id": benID})["id"].(string)
	e.expect(400, "POST", base+"/chats/"+other+"/messages", ben, obj{"body": "Ans Meer", "reply_to": question})
	answer := e.expect(201, "POST", base+"/chats/"+group+"/messages", ben, obj{"body": "Ans Meer!", "reply_to": question})["id"].(string)
	reply := messageByID(t, e, anna, base, group, answer)["reply"].(obj)
	if reply["id"] != question || reply["body"] != "Wohin fahren wir im Sommer?" || reply["sender_name"] != "Anna" {
		t.Fatalf("reply: %v", reply)
	}

	// Forwarded with its file, which is a copy of its own.
	status, out := e.uploadTo(anna, base+"/chats/"+group+"/attachments", "strand.png", pngHeader)
	if status != 201 {
		t.Fatalf("picture: %d %v", status, out)
	}
	picture, original := out["id"].(string), out["file_id"].(string)
	forwarded := e.expect(201, "POST", base+"/chats/"+other+"/messages", anna, obj{"forward_of": picture})["id"].(string)
	copy := messageByID(t, e, ben, base, other, forwarded)
	files := copy["attachments"].([]any)
	if copy["forwarded"] != true || len(files) != 1 || files[0].(obj)["name"] != "strand.png" || files[0].(obj)["id"] == original {
		t.Fatalf("forwarded: %v", copy)
	}
	e.expect(201, "POST", base+"/chats/"+other+"/messages", anna, obj{"forward_of": answer})
	// Deleting the original leaves the copy.
	e.expect(204, "DELETE", base+"/chats/"+group+"/messages/"+picture, anna, nil)
	if !e.fileStored(files[0].(obj)["id"].(string)) {
		t.Fatal("copy gone with the original")
	}
	// Nothing deleted, nothing one cannot see, nothing into a chat one only reads.
	e.expect(400, "POST", base+"/chats/"+other+"/messages", anna, obj{"forward_of": picture})
	secret := e.expect(201, "POST", base+"/chats", ben, obj{"kind": "group", "name": "Geheim", "assignee_ids": []string{benID}})["id"].(string)
	hidden := e.expect(201, "POST", base+"/chats/"+secret+"/messages", ben, obj{"body": "Überraschung"})["id"].(string)
	e.expect(404, "POST", base+"/chats/"+other+"/messages", anna, obj{"forward_of": hidden})
	e.expect(404, "POST", base+"/chats/"+other+"/messages", anna, obj{"forward_of": question, "forward_family_id": "fremd"})
	e.expect(403, "POST", base+"/chats/"+group+"/messages", cleo, obj{"forward_of": question})

	// A deleted message keeps no reactions.
	e.expect(204, "PUT", reaction, ben, obj{"emoji": "🔥"})
	e.expect(204, "DELETE", base+"/chats/"+group+"/messages/"+question, anna, nil)
	if got := messageByID(t, e, ben, base, group, question)["reactions"].([]any); len(got) != 0 {
		t.Fatalf("reactions of a deleted message: %v", got)
	}
	e.expect(404, "PUT", reaction, ben, obj{"emoji": "🔥"})
	// The answer to it says so.
	if reply := messageByID(t, e, anna, base, group, answer)["reply"].(obj); reply["deleted"] != true || reply["body"] != "" {
		t.Fatalf("reply to a deleted message: %v", reply)
	}
	_ = ben
}

func TestChatForwardingAcrossCircles(t *testing.T) {
	e := newEnv(t)
	anna := e.register("a@example.de", "Anna", "F")
	first := e.firstFamily(anna)
	_, benID := e.addMember(first, anna, "b@example.de")
	second := e.expect(201, "POST", "/api/families", anna, obj{"name": "Verein", "type": "friends"})["id"].(string)
	_, cleoID := e.addMember(second, anna, "c@example.de")
	from := e.expect(201, "POST", "/api/families/"+first+"/chats", anna, obj{"kind": "direct", "user_id": benID})["id"].(string)
	status, out := e.uploadTo(anna, "/api/families/"+first+"/chats/"+from+"/attachments", "plan.txt", []byte("Plan"))
	if status != 201 {
		t.Fatalf("file: %d %v", status, out)
	}
	to := e.expect(201, "POST", "/api/families/"+second+"/chats", anna, obj{"kind": "direct", "user_id": cleoID})["id"].(string)
	// Without saying where it comes from, it is looked for in the circle of the chat.
	e.expect(404, "POST", "/api/families/"+second+"/chats/"+to+"/messages", anna, obj{"forward_of": out["id"]})
	id := e.expect(201, "POST", "/api/families/"+second+"/chats/"+to+"/messages", anna,
		obj{"forward_of": out["id"], "forward_family_id": first})["id"].(string)
	file := messageByID(t, e, anna, "/api/families/"+second, to, id)["attachments"].([]any)[0].(obj)
	if status, content := e.getRaw("/api/families/"+second+"/chats/"+to+"/attachments/"+file["id"].(string), anna); status != 200 || content != "Plan" {
		t.Fatalf("copy: %d %q", status, content)
	}
}
