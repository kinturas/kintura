-- Das Profilfoto eines Mitglieds in einem Kreis, zugeschnitten und verkleinert: small für Listen
-- und Symbole (Base64, geht so ins JSON), large für die Profilseite. Endet mit der Mitgliedschaft.

-- +goose Up
CREATE TABLE member_avatars (
	family_id TEXT NOT NULL,
	user_id TEXT NOT NULL,
	small TEXT NOT NULL,
	large BLOB NOT NULL,
	updated_at TEXT NOT NULL,
	PRIMARY KEY (family_id, user_id),
	FOREIGN KEY (family_id, user_id) REFERENCES memberships (family_id, user_id) ON DELETE CASCADE ON UPDATE CASCADE
);
