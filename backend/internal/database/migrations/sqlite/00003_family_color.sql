-- Die Farbe des Kreises, in der sich der Kopf des Dashboards einfärbt. Leer heißt: die Farbe der App.

-- +goose Up
ALTER TABLE families ADD COLUMN color TEXT NOT NULL DEFAULT '';
