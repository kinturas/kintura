-- Nachrichten: Direktnachrichten zwischen zwei Mitgliedern eines Kreises und Gruppen mit
-- Name, Farbe, Kategorie, Betroffenen und Sichtbarkeit wie bei Einkaufslisten. Anhänge
-- liegen in files mit chat_message_id. Gelesen und Archiviert hält jeder für sich.
-- Die alte Tabelle messages war ein einziger Chat je Kreis und wurde nie freigegeben.

-- +goose Up
DROP TABLE messages;
CREATE TABLE chats (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	kind TEXT NOT NULL CHECK (kind IN ('direct', 'group')),
	name TEXT NOT NULL DEFAULT '',
	color TEXT NOT NULL DEFAULT '',
	category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
	created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
	assignees_all INTEGER NOT NULL DEFAULT 0,
	visibility TEXT NOT NULL DEFAULT 'participants',
	created_at TEXT NOT NULL,
	last_message_at TEXT NOT NULL
);
CREATE INDEX chats_family ON chats(family_id, last_message_at);
CREATE TABLE chat_members (
	chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	PRIMARY KEY (chat_id, user_id)
);
CREATE TABLE chat_messages (
	id TEXT PRIMARY KEY,
	chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	sender_id TEXT REFERENCES users(id) ON DELETE SET NULL,
	body TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL,
	deleted_at TEXT,
	pushed_at TEXT
);
CREATE INDEX chat_messages_chat ON chat_messages(chat_id, created_at);
CREATE TABLE chat_reads (
	chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	read_at TEXT NOT NULL,
	PRIMARY KEY (chat_id, user_id)
);
CREATE TABLE chat_archived (
	chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	PRIMARY KEY (chat_id, user_id)
);
ALTER TABLE files ADD COLUMN chat_message_id TEXT REFERENCES chat_messages(id) ON DELETE CASCADE;
CREATE INDEX files_chat_message ON files(chat_message_id);

-- +goose Down
-- SQLite entfernt keine Spalte mit Fremdschlüssel; sie bleibt, ohne die Anhänge.
DELETE FROM files WHERE chat_message_id IS NOT NULL;
DROP INDEX files_chat_message;
DROP TABLE chat_archived;
DROP TABLE chat_reads;
DROP TABLE chat_messages;
DROP TABLE chat_members;
DROP TABLE chats;
CREATE TABLE messages (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	sender_id TEXT NOT NULL REFERENCES users(id),
	body TEXT NOT NULL,
	created_at TEXT NOT NULL,
	seq INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX messages_family ON messages(family_id, created_at);
