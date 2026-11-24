package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Live updates: the app keeps GET /api/live open and hears from it when something in
// one of its families changed, so that it reloads what it shows instead of asking
// every few seconds. A message only names the family and the area, never content;
// what the user may see is still decided by the routes the app then calls.
//
// The hub lives in this process. With more than one backend behind a proxy, a change
// would only reach the apps connected to the same one.

// liveHeartbeat keeps proxies such as Cloudflare from closing an idle stream (they
// do after about 100 seconds) and lets the app tell a dead connection from a quiet one.
const liveHeartbeat = 25 * time.Second

// maxLivePerUser bounds the streams one user holds open, one per device or tab.
const maxLivePerUser = 10

type liveMessage struct {
	Family string `json:"family"`
	Topic  string `json:"topic"`
}

type liveSub struct {
	userID string
	ch     chan liveMessage
}

type liveHub struct {
	mu   sync.Mutex
	subs map[string][]*liveSub // by user
}

func newLiveHub() *liveHub { return &liveHub{subs: map[string][]*liveSub{}} }

func (h *liveHub) subscribe(userID string) *liveSub {
	sub := &liveSub{userID: userID, ch: make(chan liveMessage, 16)}
	h.mu.Lock()
	defer h.mu.Unlock()
	list := append(h.subs[userID], sub)
	// The oldest one is most likely a tab long forgotten; it reconnects if not.
	for len(list) > maxLivePerUser {
		close(list[0].ch)
		list = list[1:]
	}
	h.subs[userID] = list
	return sub
}

func (h *liveHub) unsubscribe(sub *liveSub) {
	h.mu.Lock()
	defer h.mu.Unlock()
	list := h.subs[sub.userID]
	for i, other := range list {
		if other == sub {
			close(sub.ch)
			list = append(list[:i:i], list[i+1:]...)
			break
		}
	}
	if len(list) == 0 {
		delete(h.subs, sub.userID)
	} else {
		h.subs[sub.userID] = list
	}
}

// send never blocks: a stream that is behind gets nothing more until it caught up,
// and the app reloads on the next message anyway.
func (h *liveHub) send(userIDs []string, msg liveMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, id := range userIDs {
		for _, sub := range h.subs[id] {
			select {
			case sub.ch <- msg:
			default:
			}
		}
	}
}

func (h *liveHub) listening() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs) > 0
}

// liveTopic names the area a family route belongs to, for the app to know what to reload.
func liveTopic(path string) string {
	// /api/families/{fid}/<segment>/...
	parts := strings.SplitN(strings.TrimPrefix(path, "/api/families/"), "/", 3)
	segment := ""
	if len(parts) > 1 {
		segment = parts[1]
	}
	switch segment {
	case "shopping":
		// Which list one had open last is one's own business.
		if len(parts) > 2 && parts[2] == "last" {
			return ""
		}
		return "shopping"
	case "chats":
		// Read and archived is one's own business.
		if len(parts) > 2 && (strings.HasSuffix(parts[2], "/read") || strings.HasSuffix(parts[2], "/archive")) {
			return ""
		}
		return "messages"
	case "events", "calendars", "categories", "attachments", "calendar-cleanup":
		return "calendar"
	case "activities", "select":
		// What one reads or picks for oneself is nobody else's news.
		return ""
	default:
		return "family"
	}
}

// publish tells everyone in the family who listens that the area changed.
func (s *Server) publish(familyID, topic string) {
	if topic == "" || !s.live.listening() {
		return
	}
	rows, err := queryRows(context.Background(), s.db, `SELECT user_id FROM memberships WHERE family_id = ?`, familyID)
	if err != nil {
		s.logError(nil, 0, "Live: "+err.Error())
		return
	}
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row["user_id"].(string))
	}
	s.live.send(ids, liveMessage{Family: familyID, Topic: topic})
}

// statusWriter remembers the status a handler answered with.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}

// liveStream is GET /api/live, a stream of server-sent events for all families of the user.
func (s *Server) liveStream(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	flusher, ok := w.(http.Flusher)
	if !ok {
		return fail(http.StatusInternalServerError, "Live-Verbindung nicht möglich")
	}
	sub := s.live.subscribe(c.userID)
	defer s.live.unsubscribe(sub)

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache, no-transform")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, ": verbunden\n\n")
	flusher.Flush()

	ticker := time.NewTicker(s.liveHeartbeat)
	defer ticker.Stop()
	for {
		select {
		case <-r.Context().Done():
			return nil
		case msg, open := <-sub.ch:
			if !open {
				return nil
			}
			data, _ := json.Marshal(msg)
			if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
				return nil
			}
			flusher.Flush()
		case <-ticker.C:
			// Signed out meanwhile: the stream ends, and the app learns of it on its next request.
			if _, err := s.sessionUser(r); err != nil {
				return nil
			}
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return nil
			}
			flusher.Flush()
		}
	}
}
