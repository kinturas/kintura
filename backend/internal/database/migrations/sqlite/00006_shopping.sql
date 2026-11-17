-- Einkaufen: Einkaufslisten eines Kreises mit Farbe, zugeteilten Personen und Sichtbarkeit wie bei
-- Terminen. Artikel heißen wie im Katalog der App; shopping_articles hält die eigenen Artikel eines
-- Kreises (custom = 1) und geänderte Symbole oder Kategorien von Katalogartikeln (custom = 0).
-- Erledigte Einträge bleiben mit done = 1 als „Zuletzt verwendet“ an ihrer Liste.

-- +goose Up
CREATE TABLE shopping_lists (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	name TEXT NOT NULL,
	color TEXT NOT NULL DEFAULT '',
	created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
	assignees_all INTEGER NOT NULL DEFAULT 1,
	visibility TEXT NOT NULL DEFAULT 'all',
	created_at TEXT NOT NULL
);
CREATE INDEX shopping_lists_family ON shopping_lists(family_id);
CREATE TABLE shopping_list_assignees (
	list_id TEXT NOT NULL REFERENCES shopping_lists(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	PRIMARY KEY (list_id, user_id)
);
CREATE TABLE shopping_articles (
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	name TEXT NOT NULL,
	custom INTEGER NOT NULL DEFAULT 0,
	icon TEXT NOT NULL DEFAULT '',
	category TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL,
	PRIMARY KEY (family_id, name)
);
CREATE TABLE shopping_items (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	list_id TEXT NOT NULL REFERENCES shopping_lists(id) ON DELETE CASCADE,
	name TEXT NOT NULL,
	amount TEXT NOT NULL DEFAULT '',
	note TEXT NOT NULL DEFAULT '',
	urgency TEXT NOT NULL DEFAULT '',
	done INTEGER NOT NULL DEFAULT 0,
	done_at TEXT NOT NULL DEFAULT '',
	added_by TEXT REFERENCES users(id) ON DELETE SET NULL,
	created_at TEXT NOT NULL,
	UNIQUE (list_id, name)
);
CREATE TABLE shopping_item_photos (
	id TEXT PRIMARY KEY,
	item_id TEXT NOT NULL REFERENCES shopping_items(id) ON DELETE CASCADE,
	mime TEXT NOT NULL,
	data BLOB NOT NULL,
	created_at TEXT NOT NULL
);
CREATE INDEX shopping_item_photos_item ON shopping_item_photos(item_id);
