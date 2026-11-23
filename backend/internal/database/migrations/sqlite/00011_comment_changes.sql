-- Kommentare lassen sich bearbeiten und löschen. Ein gelöschter bleibt als Hinweis stehen,
-- wer ihn gelöscht hat, ohne seinen Text.
-- SQLite: deleted_by ohne Fremdschlüssel, sonst lässt sich die Spalte nicht wieder entfernen;
-- wer nicht mehr da ist, hat ohnehin keinen Namen mehr im Kreis.

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
