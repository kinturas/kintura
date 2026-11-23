-- Kommentare zu einer Einkaufsliste, wie zu einem Termin.

-- +goose Up
CREATE TABLE shopping_list_comments (
	id TEXT PRIMARY KEY,
	list_id TEXT NOT NULL REFERENCES shopping_lists(id) ON DELETE CASCADE,
	user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
	body TEXT NOT NULL,
	created_at TEXT NOT NULL,
	seq INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX shopping_list_comments_list ON shopping_list_comments(list_id, created_at);

-- +goose Down
DROP TABLE shopping_list_comments;
