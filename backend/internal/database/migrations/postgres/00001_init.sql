-- Schalter sind wie bei SQLite ganze Zahlen (0 und 1), damit dieselben Abfragen für beide gelten.
-- Das Schema, mit dem Kintura startet. Eine Änderung kommt als neue Datei dazu, und zwar
-- auch im Ordner der anderen Datenbank.

-- +goose Up
CREATE TABLE users (
	id TEXT PRIMARY KEY,
	email TEXT NOT NULL UNIQUE,
	name TEXT NOT NULL,
	last_family_id TEXT,
	created_at TEXT NOT NULL,
	is_sysadmin INTEGER NOT NULL DEFAULT 0,
	admin_verified_at TEXT,
	birthday TEXT NOT NULL DEFAULT '',
	notifications INTEGER NOT NULL DEFAULT 1,
	is_managed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE email_changes (
	user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
	email TEXT NOT NULL,
	code_hash TEXT NOT NULL,
	attempts INTEGER NOT NULL DEFAULT 0,
	sends INTEGER NOT NULL DEFAULT 0,
	expires_at TEXT NOT NULL
);
CREATE TABLE login_codes (
	user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
	code_hash TEXT NOT NULL UNIQUE,
	expires_at TEXT NOT NULL
);
CREATE TABLE error_log (
	id BIGSERIAL PRIMARY KEY,
	created_at TEXT NOT NULL,
	email TEXT NOT NULL DEFAULT '',
	family_name TEXT NOT NULL DEFAULT '',
	endpoint TEXT NOT NULL DEFAULT '',
	status INTEGER NOT NULL DEFAULT 0,
	message TEXT NOT NULL
);
CREATE TABLE sessions (
	token_hash TEXT PRIMARY KEY,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	expires_at TEXT NOT NULL
);
CREATE TABLE login_requests (
	id_hash TEXT PRIMARY KEY,
	email TEXT NOT NULL,
	code_hash TEXT NOT NULL,
	link_hash TEXT NOT NULL UNIQUE,
	attempts INTEGER NOT NULL DEFAULT 0,
	verified_at TEXT,
	consumed_at TEXT,
	expires_at TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE INDEX login_requests_email ON login_requests(email, created_at);
CREATE TABLE families (
	id TEXT PRIMARY KEY,
	name TEXT NOT NULL,
	created_at TEXT NOT NULL,
	type TEXT NOT NULL DEFAULT 'family' CHECK (type IN ('family', 'friends', 'relatives', 'workgroup')),
	default_color TEXT NOT NULL DEFAULT '#BBDEFB',
	cleanup_months INTEGER NOT NULL DEFAULT 12
);
CREATE TABLE calendar_settings (
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	key TEXT NOT NULL,
	enabled INTEGER NOT NULL,
	color TEXT NOT NULL DEFAULT '',
	regions TEXT NOT NULL DEFAULT '',
	PRIMARY KEY (user_id, family_id, key)
);
CREATE TABLE calendar_colors (
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	key TEXT NOT NULL,
	color TEXT NOT NULL,
	PRIMARY KEY (family_id, key)
);
CREATE TABLE calendar_prefs (
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	week_numbers INTEGER NOT NULL DEFAULT 0,
	week_start TEXT NOT NULL DEFAULT 'monday',
	default_reminder INTEGER NOT NULL DEFAULT 0,
	holiday_countries TEXT NOT NULL DEFAULT '["DE"]',
	view TEXT NOT NULL DEFAULT 'agenda',
	PRIMARY KEY (user_id, family_id)
);
CREATE TABLE calendar_shares (
	token TEXT PRIMARY KEY,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	key TEXT NOT NULL,
	created_at TEXT NOT NULL,
	UNIQUE (user_id, family_id, key)
);
CREATE TABLE calendar_feeds (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	name TEXT NOT NULL,
	url TEXT NOT NULL,
	body TEXT NOT NULL DEFAULT '',
	fetched_at TEXT NOT NULL DEFAULT '',
	last_error TEXT NOT NULL DEFAULT ''
);
CREATE TABLE holiday_cache (
	kind TEXT NOT NULL,
	scope TEXT NOT NULL,
	year INTEGER NOT NULL,
	payload BYTEA NOT NULL,
	fetched_at TEXT NOT NULL,
	PRIMARY KEY (kind, scope, year)
);
CREATE TABLE memberships (
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	role TEXT NOT NULL CHECK (role IN ('manager', 'user', 'restrict_user', 'guest')),
	is_admin INTEGER NOT NULL DEFAULT 0,
	color TEXT NOT NULL DEFAULT '',
	can_change_color INTEGER NOT NULL DEFAULT 1,
	name TEXT NOT NULL DEFAULT '',
	birthday TEXT NOT NULL DEFAULT '',
	family_role TEXT NOT NULL DEFAULT '',
	contact_email TEXT NOT NULL DEFAULT '',
	profile_fields TEXT NOT NULL DEFAULT '[]',
	PRIMARY KEY (family_id, user_id)
);
CREATE TABLE former_memberships (
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	color TEXT NOT NULL DEFAULT '',
	name TEXT NOT NULL DEFAULT '',
	birthday TEXT NOT NULL DEFAULT '',
	family_role TEXT NOT NULL DEFAULT '',
	contact_email TEXT NOT NULL DEFAULT '',
	profile_fields TEXT NOT NULL DEFAULT '[]',
	left_at TEXT NOT NULL,
	PRIMARY KEY (family_id, user_id)
);
CREATE TABLE custom_colors (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	color TEXT NOT NULL,
	label TEXT NOT NULL,
	UNIQUE (family_id, color)
);
CREATE TABLE categories (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	name TEXT NOT NULL,
	color TEXT NOT NULL DEFAULT '',
	position INTEGER NOT NULL,
	UNIQUE (family_id, name)
);
CREATE TABLE invitations (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	email TEXT NOT NULL,
	role TEXT NOT NULL CHECK (role IN ('manager', 'user', 'restrict_user', 'guest')),
	is_admin INTEGER NOT NULL DEFAULT 0,
	created_at TEXT NOT NULL,
	color TEXT NOT NULL DEFAULT '',
	can_change_color INTEGER NOT NULL DEFAULT 1,
	code_hash TEXT NOT NULL DEFAULT '',
	code_attempts INTEGER NOT NULL DEFAULT 0,
	code_expires_at TEXT NOT NULL DEFAULT '',
	UNIQUE (family_id, email)
);
CREATE TABLE invitation_mails (
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	email TEXT NOT NULL,
	expires_at TEXT NOT NULL
);
CREATE INDEX invitation_mails_address ON invitation_mails(family_id, email);
CREATE TABLE lists (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	name TEXT NOT NULL,
	kind TEXT NOT NULL CHECK (kind IN ('shopping', 'tasks')),
	created_at TEXT NOT NULL
);
CREATE TABLE list_items (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	list_id TEXT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,
	title TEXT NOT NULL,
	note TEXT NOT NULL DEFAULT '',
	done INTEGER NOT NULL DEFAULT 0,
	due_date TEXT,
	assignee_id TEXT REFERENCES users(id) ON DELETE SET NULL,
	created_at TEXT NOT NULL
);
CREATE INDEX list_items_list ON list_items(list_id);
CREATE TABLE events (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	title TEXT NOT NULL,
	description TEXT NOT NULL DEFAULT '',
	start_at TEXT NOT NULL,
	end_at TEXT NOT NULL,
	all_day INTEGER NOT NULL DEFAULT 0,
	timezone TEXT NOT NULL DEFAULT '',
	created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
	participants_all INTEGER NOT NULL DEFAULT 1,
	visibility TEXT NOT NULL DEFAULT 'all',
	category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
	recurrence TEXT NOT NULL DEFAULT '',
	location TEXT NOT NULL DEFAULT '',
	location_lat DOUBLE PRECISION,
	location_lon DOUBLE PRECISION,
	updated_at TEXT,
	updated_by TEXT REFERENCES users(id) ON DELETE SET NULL
);
CREATE INDEX events_range ON events(family_id, start_at);
CREATE TABLE event_comments (
	id TEXT PRIMARY KEY,
	event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
	user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
	body TEXT NOT NULL,
	created_at TEXT NOT NULL,
	seq INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX event_comments_event ON event_comments(event_id, created_at);
CREATE TABLE event_participants (
	event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	PRIMARY KEY (event_id, user_id)
);
CREATE TABLE event_reminders (
	event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
	minutes INTEGER NOT NULL,
	PRIMARY KEY (event_id, minutes)
);
CREATE TABLE reminder_sent (
	event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
	minutes INTEGER NOT NULL,
	occurrence TEXT NOT NULL,
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	sent_at TEXT NOT NULL,
	PRIMARY KEY (event_id, minutes, occurrence, user_id)
);
CREATE TABLE meals (
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	date TEXT NOT NULL,
	slot TEXT NOT NULL CHECK (slot IN ('breakfast', 'lunch', 'dinner')),
	title TEXT NOT NULL,
	note TEXT NOT NULL DEFAULT '',
	PRIMARY KEY (family_id, date, slot)
);
CREATE TABLE messages (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	sender_id TEXT NOT NULL REFERENCES users(id),
	body TEXT NOT NULL,
	created_at TEXT NOT NULL,
	seq INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX messages_family ON messages(family_id, created_at);
CREATE TABLE special_days (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	title TEXT NOT NULL,
	kind TEXT NOT NULL CHECK (kind IN ('feast', 'memorial', 'birthday', 'other')),
	date TEXT NOT NULL,
	yearly INTEGER NOT NULL DEFAULT 1,
	note TEXT NOT NULL DEFAULT ''
);
CREATE TABLE files (
	id TEXT PRIMARY KEY,
	family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
	kind TEXT NOT NULL CHECK (kind IN ('document', 'photo')),
	name TEXT NOT NULL,
	mime TEXT NOT NULL,
	size BIGINT NOT NULL,
	uploaded_by TEXT NOT NULL REFERENCES users(id),
	created_at TEXT NOT NULL,
	event_id TEXT REFERENCES events(id) ON DELETE CASCADE
);
CREATE INDEX files_family ON files(family_id, kind, created_at);
CREATE TABLE download_tokens (
	token_hash TEXT PRIMARY KEY,
	file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
	expires_at TEXT NOT NULL
);
-- Texte wie Impressum und Datenschutzerklärung, die im Admin-Dashboard bearbeitet werden.
-- Die Seiten selbst legt das Backend beim Start mit Beispieltext an, siehe server/pages.
CREATE TABLE pages (
	slug TEXT PRIMARY KEY,
	title TEXT NOT NULL,
	content TEXT NOT NULL,
	updated_at TEXT NOT NULL
);
