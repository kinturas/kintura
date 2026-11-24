-- Nachrichten: Reaktionen mit einem Emoji (eine je Person und Nachricht), Antworten auf eine
-- Nachricht und weitergeleitete Nachrichten. pushed_at hält, ob der Verfasser der Nachricht
-- schon von der Reaktion erfahren hat.

-- +goose Up
ALTER TABLE chat_messages ADD COLUMN reply_to TEXT REFERENCES chat_messages(id) ON DELETE SET NULL;
ALTER TABLE chat_messages ADD COLUMN forwarded INTEGER NOT NULL DEFAULT 0;
CREATE TABLE chat_reactions (
	message_id TEXT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	emoji TEXT NOT NULL,
	created_at TEXT NOT NULL,
	pushed_at TEXT,
	PRIMARY KEY (message_id, user_id)
);

-- +goose Down
DROP TABLE chat_reactions;
ALTER TABLE chat_messages DROP COLUMN forwarded;
-- SQLite entfernt keine Spalte mit Fremdschlüssel; reply_to bleibt.
UPDATE chat_messages SET reply_to = NULL;
