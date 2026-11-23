-- Geräte, die Neues aus Aktuelles als Push-Nachricht bekommen (Android über Firebase
-- Cloud Messaging). Eines je Anmeldung: mit dem Abmelden ist es weg.

-- +goose Up
CREATE TABLE push_devices (
	token TEXT PRIMARY KEY,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
	platform TEXT NOT NULL,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE INDEX push_devices_user ON push_devices(user_id);
-- Bis wann ein Eintrag geschickt ist; was es schon gibt, gilt als geschickt.
ALTER TABLE activities ADD COLUMN pushed_at TEXT;
UPDATE activities SET pushed_at = updated_at;

-- +goose Down
ALTER TABLE activities DROP COLUMN pushed_at;
DROP TABLE push_devices;
