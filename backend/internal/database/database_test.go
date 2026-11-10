package database

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"
)

func TestNumberParameters(t *testing.T) {
	for query, want := range map[string]string{
		`SELECT 1`:                        `SELECT 1`,
		`a = ? AND b = ?`:                 `a = $1 AND b = $2`,
		`a = ?1 AND b = ?2 OR c = ?1`:     `a = $1 AND b = $2 OR c = $1`,
		`a = ?2 AND b = ?`:                `a = $2 AND b = $3`,
		`a = '?' AND b = ? AND c = 'x?y'`: `a = '?' AND b = $1 AND c = 'x?y'`,
		`a = 'it''s ?' AND b = ?10`:       `a = 'it''s ?' AND b = $10`,
	} {
		if got := numberParameters(query); got != want {
			t.Errorf("%s: %s", query, got)
		}
	}
}

func TestFlagsBecomeNumbersOnPostgresOnly(t *testing.T) {
	yes, none := true, (*bool)(nil)
	args := []any{true, false, "x", &yes, none}
	_, got := (&DB{postgres: true}).prepare("a = ?", args)
	if got[0] != 1 || got[1] != 0 || got[2] != "x" || got[3] != 1 || got[4] != nil {
		t.Errorf("postgres: %v", got)
	}
	_, got = (&DB{}).prepare("a = ?", args)
	if got[0] != true {
		t.Errorf("sqlite: %v", got)
	}
}

func TestOpenMigratesOnceAndKeepsTheData(t *testing.T) {
	ctx := context.Background()
	cfg := Config{Driver: SQLite, Path: filepath.Join(t.TempDir(), "x.db")}
	db, err := Open(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO users (id, email, name, created_at) VALUES ('u', 'a@x.de', 'A', 'x')`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	if db, err = Open(ctx, cfg); err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var users int
	if err := db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&users); err != nil || users != 1 {
		t.Errorf("users: %d %v", users, err)
	}
	var version int
	if err := db.QueryRow(`SELECT MAX(version_id) FROM goose_db_version`).Scan(&version); err != nil || version < 1 {
		t.Errorf("version: %d %v", version, err)
	}
}

func TestDatabaseFromBeforeMigrationsIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	old, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := old.Exec(`CREATE TABLE users (id TEXT PRIMARY KEY)`); err != nil {
		t.Fatal(err)
	}
	old.Close()
	_, err = Open(context.Background(), Config{Driver: SQLite, Path: path})
	if err == nil || !strings.Contains(err.Error(), "neu aufsetzen") {
		t.Errorf("err: %v", err)
	}
}

// TestPostgres needs a service, see compose.test.yaml.
func TestPostgres(t *testing.T) {
	address := os.Getenv("TEST_DATABASE_URL")
	if address == "" {
		t.Skip("TEST_DATABASE_URL nicht gesetzt")
	}
	admin, err := sql.Open("pgx", address)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	ctx := context.Background()
	schema := func(name string) Config {
		t.Helper()
		if _, err := admin.Exec(`CREATE SCHEMA ` + name); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { admin.Exec(`DROP SCHEMA ` + name + ` CASCADE`) })
		parsed, err := url.Parse(address)
		if err != nil {
			t.Fatal(err)
		}
		query := parsed.Query()
		query.Set("search_path", name)
		parsed.RawQuery = query.Encode()
		return Config{Driver: Postgres, URL: parsed.String()}
	}

	t.Run("migrates once and keeps the data", func(t *testing.T) {
		cfg := schema("test_database_again")
		db, err := Open(ctx, cfg)
		if err != nil {
			t.Fatal(err)
		}
		insert := `INSERT INTO users (id, email, name, created_at, is_managed) VALUES (?, 'a@x.de', ?, 'x', ?)`
		if _, err := db.Exec(insert, "u", "A", true); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(insert, "v", "B", false); !IsUniqueViolation(err) {
			t.Errorf("unique: %v", err)
		}
		db.Close()
		if db, err = Open(ctx, cfg); err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		var managed bool
		if err := db.QueryRow(`SELECT is_managed FROM users WHERE id = ?1`, "u").Scan(&managed); err != nil || !managed {
			t.Errorf("flag: %v %v", managed, err)
		}
	})

	t.Run("refuses tables from before migrations", func(t *testing.T) {
		cfg := schema("test_database_old")
		if _, err := admin.Exec(`CREATE TABLE test_database_old.users (id TEXT PRIMARY KEY)`); err != nil {
			t.Fatal(err)
		}
		if _, err := Open(ctx, cfg); err == nil || !strings.Contains(err.Error(), "neu aufsetzen") {
			t.Errorf("err: %v", err)
		}
	})

	t.Run("several instances starting at once", func(t *testing.T) {
		cfg := schema("test_database_race")
		var wg sync.WaitGroup
		errs := make([]error, 4)
		for i := range errs {
			wg.Go(func() {
				db, err := Open(ctx, cfg)
				errs[i] = err
				if err == nil {
					db.Close()
				}
			})
		}
		wg.Wait()
		for _, err := range errs {
			if err != nil {
				t.Error(err)
			}
		}
	})
}

// Both schemas have to stay the same, or queries work on one database only.
func TestMigrationsExistForBothDatabases(t *testing.T) {
	names := func(driver string) []string {
		entries, err := migrations.ReadDir("migrations/" + driver)
		if err != nil {
			t.Fatal(err)
		}
		out := []string{}
		for _, entry := range entries {
			out = append(out, entry.Name())
		}
		return out
	}
	if a, b := names(SQLite), names(Postgres); len(a) == 0 || !slices.Equal(a, b) {
		t.Errorf("sqlite %v, postgres %v", a, b)
	}
	table := regexp.MustCompile(`(?m)^CREATE TABLE \w+|^\t\w+ `)
	read := func(driver, name string) []string {
		content, err := migrations.ReadFile("migrations/" + driver + "/" + name)
		if err != nil {
			t.Fatal(err)
		}
		return table.FindAllString(string(content), -1)
	}
	for _, name := range names(SQLite) {
		if a, b := read(SQLite, name), read(Postgres, name); !slices.Equal(a, b) {
			t.Errorf("%s: tables and columns differ", name)
		}
	}
}

func TestUnknownDriverAndMissingAddress(t *testing.T) {
	if _, err := Open(context.Background(), Config{Driver: "mysql"}); err == nil {
		t.Error("unknown driver accepted")
	}
	if _, err := Open(context.Background(), Config{Driver: Postgres}); err == nil {
		t.Error("postgres without an address accepted")
	}
}

func TestUniqueViolation(t *testing.T) {
	db, err := Open(context.Background(), Config{Driver: SQLite, Path: filepath.Join(t.TempDir(), "x.db")})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	insert := `INSERT INTO users (id, email, name, created_at) VALUES ('u', 'a@x.de', 'A', 'x')`
	if _, err := db.Exec(insert); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(insert); !IsUniqueViolation(err) {
		t.Errorf("err: %v", err)
	}
	if IsUniqueViolation(nil) {
		t.Error("nil")
	}
}
