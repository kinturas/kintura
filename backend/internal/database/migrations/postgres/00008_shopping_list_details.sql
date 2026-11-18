-- Einkaufslisten bekommen eine optionale Kategorie (die des Kalenders) und ein Fälligkeitsdatum
-- (YYYY-MM-DD oder leer); mit Datum erscheinen sie im Kalender „Geplante Aufgaben“.
-- shopping_last merkt sich je Person und Kreis die zuletzt geöffnete Liste, die die App beim
-- Öffnen von Einkaufen direkt zeigt.

-- +goose Up
ALTER TABLE shopping_lists ADD COLUMN category_id TEXT REFERENCES categories(id) ON DELETE SET NULL;
ALTER TABLE shopping_lists ADD COLUMN due_date TEXT NOT NULL DEFAULT '';
CREATE TABLE shopping_last (
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	list_id TEXT NOT NULL REFERENCES shopping_lists(id) ON DELETE CASCADE,
	PRIMARY KEY (family_id, user_id)
);

-- +goose Down
DROP TABLE shopping_last;
ALTER TABLE shopping_lists DROP COLUMN due_date;
ALTER TABLE shopping_lists DROP COLUMN category_id;
