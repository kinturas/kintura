-- Aktuelles: was im Kreis passiert ist und eine Person betrifft, je Empfänger eine Zeile.
-- kind sagt, was passiert ist (die App macht den Satz daraus), title ist der Name des Termins
-- oder der Liste zu dem Zeitpunkt, detail hält bei gesammelten Einträgen die Namen der Artikel
-- zeilenweise. activity_seen merkt sich, bis wann jemand Aktuelles gelesen hat.

-- +goose Up
CREATE TABLE activities (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	actor_id TEXT REFERENCES users(id) ON DELETE SET NULL,
	kind TEXT NOT NULL,
	ref_id TEXT NOT NULL DEFAULT '',
	title TEXT NOT NULL DEFAULT '',
	detail TEXT NOT NULL DEFAULT '',
	count INTEGER NOT NULL DEFAULT 1,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
CREATE INDEX activities_user ON activities(family_id, user_id, updated_at);
CREATE TABLE activity_seen (
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	seen_at TEXT NOT NULL,
	PRIMARY KEY (family_id, user_id)
);

-- +goose Down
DROP TABLE activity_seen;
DROP TABLE activities;
