-- Kommentare lassen sich bearbeiten und löschen. Ein gelöschter bleibt als Hinweis stehen,
-- wer ihn gelöscht hat, ohne seinen Text.
-- deleted_by ohne Fremdschlüssel, wie in SQLite, wo sich die Spalte sonst nicht wieder
-- entfernen lässt; wer nicht mehr da ist, hat ohnehin keinen Namen mehr im Kreis.

-- +goose Up
ALTER TABLE event_comments ADD COLUMN edited_at TEXT;
ALTER TABLE event_comments ADD COLUMN deleted_at TEXT;
ALTER TABLE event_comments ADD COLUMN deleted_by TEXT;
ALTER TABLE shopping_list_comments ADD COLUMN edited_at TEXT;
ALTER TABLE shopping_list_comments ADD COLUMN deleted_at TEXT;
ALTER TABLE shopping_list_comments ADD COLUMN deleted_by TEXT;

-- +goose Down
ALTER TABLE shopping_list_comments DROP COLUMN deleted_by;
ALTER TABLE shopping_list_comments DROP COLUMN deleted_at;
ALTER TABLE shopping_list_comments DROP COLUMN edited_at;
ALTER TABLE event_comments DROP COLUMN deleted_by;
ALTER TABLE event_comments DROP COLUMN deleted_at;
ALTER TABLE event_comments DROP COLUMN edited_at;
