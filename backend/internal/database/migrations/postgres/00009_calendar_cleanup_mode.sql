-- Die Kalenderbereinigung eines Kreises läuft automatisch (stündlich), nur von Hand über
-- „Jetzt bereinigen“ oder gar nicht: 'auto', 'manual' oder 'off'.

-- +goose Up
ALTER TABLE families ADD COLUMN cleanup_mode TEXT NOT NULL DEFAULT 'auto';

-- +goose Down
ALTER TABLE families DROP COLUMN cleanup_mode;
