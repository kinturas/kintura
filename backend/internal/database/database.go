// Package database opens SQLite or Postgres and brings the schema up to date. Queries
// are written once, in SQL both understand, with ? or ?1 for their parameters.
package database

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/lock"
	_ "modernc.org/sqlite"
)

const (
	SQLite   = "sqlite"
	Postgres = "postgres"

	postgresConnections = 10
)

//go:embed migrations
var migrations embed.FS

// Config says where the data lives. Path is for SQLite, URL for Postgres.
type Config struct {
	Driver string
	Path   string
	URL    string
}

// Querier is implemented by DB and Tx.
type Querier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// DB is a connection pool that speaks the SQL of its driver.
type DB struct {
	pool     *sql.DB
	postgres bool
}

// Open connects and applies the migrations that are still missing.
func Open(ctx context.Context, cfg Config) (*DB, error) {
	var pool *sql.DB
	var err error
	switch cfg.Driver {
	case SQLite:
		pool, err = sql.Open("sqlite", "file:"+cfg.Path+"?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	case Postgres:
		if cfg.URL == "" {
			return nil, errors.New("für Postgres fehlt DATABASE_URL")
		}
		pool, err = sql.Open("pgx", cfg.URL)
	default:
		return nil, fmt.Errorf("unbekannte Datenbank %q", cfg.Driver)
	}
	if err != nil {
		return nil, err
	}
	if err := migrate(ctx, pool, cfg.Driver); err != nil {
		pool.Close()
		return nil, err
	}
	if cfg.Driver == SQLite {
		// A single connection serializes writes, which is plenty at family scale.
		// Never call the DB while a transaction or a result set is open.
		pool.SetMaxOpenConns(1)
	} else {
		pool.SetMaxOpenConns(postgresConnections)
	}
	return &DB{pool: pool, postgres: cfg.Driver == Postgres}, nil
}

func migrate(ctx context.Context, pool *sql.DB, driver string) error {
	if err := refuseUnversioned(ctx, pool, driver); err != nil {
		return err
	}
	files, err := fs.Sub(migrations, "migrations/"+driver)
	if err != nil {
		return err
	}
	dialect := goose.DialectSQLite3
	options := []goose.ProviderOption{}
	if driver == Postgres {
		dialect = goose.DialectPostgres
		// Several instances may start at once, and only one of them should migrate.
		locker, err := lock.NewPostgresSessionLocker()
		if err != nil {
			return err
		}
		options = append(options, goose.WithSessionLocker(locker))
	}
	provider, err := goose.NewProvider(dialect, pool, files, options...)
	if err != nil {
		return err
	}
	if _, err := provider.Up(ctx); err != nil {
		return fmt.Errorf("Migration: %w", err)
	}
	return nil
}

// refuseUnversioned explains what the first migration would otherwise only fail on:
// tables from before migrations had versions, which there is no way up from.
func refuseUnversioned(ctx context.Context, pool *sql.DB, driver string) error {
	query := `SELECT (SELECT COUNT(*) FROM sqlite_master WHERE name = 'users') > 0, (SELECT COUNT(*) FROM sqlite_master WHERE name = 'goose_db_version') > 0`
	if driver == Postgres {
		query = `SELECT to_regclass('users') IS NOT NULL, to_regclass('goose_db_version') IS NOT NULL`
	}
	var tables, versioned bool
	if err := pool.QueryRowContext(ctx, query).Scan(&tables, &versioned); err != nil {
		return err
	}
	if tables && !versioned {
		return errors.New("die Datenbank stammt aus der Zeit vor den Migrationen und lässt sich nicht übernehmen: bitte neu aufsetzen")
	}
	return nil
}

func (d *DB) Close() error { return d.pool.Close() }

func (d *DB) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	query, args = d.prepare(query, args)
	return d.pool.ExecContext(ctx, query, args...)
}

func (d *DB) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	query, args = d.prepare(query, args)
	return d.pool.QueryContext(ctx, query, args...)
}

func (d *DB) QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row {
	query, args = d.prepare(query, args)
	return d.pool.QueryRowContext(ctx, query, args...)
}

func (d *DB) Exec(query string, args ...any) (sql.Result, error) {
	return d.ExecContext(context.Background(), query, args...)
}

func (d *DB) Query(query string, args ...any) (*sql.Rows, error) {
	return d.QueryContext(context.Background(), query, args...)
}

func (d *DB) QueryRow(query string, args ...any) *sql.Row {
	return d.QueryRowContext(context.Background(), query, args...)
}

func (d *DB) BeginTx(ctx context.Context, opts *sql.TxOptions) (*Tx, error) {
	tx, err := d.pool.BeginTx(ctx, opts)
	if err != nil {
		return nil, err
	}
	return &Tx{tx: tx, db: d}, nil
}

// Tx is a transaction on a DB.
type Tx struct {
	tx *sql.Tx
	db *DB
}

func (t *Tx) Commit() error   { return t.tx.Commit() }
func (t *Tx) Rollback() error { return t.tx.Rollback() }

func (t *Tx) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	query, args = t.db.prepare(query, args)
	return t.tx.ExecContext(ctx, query, args...)
}

func (t *Tx) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	query, args = t.db.prepare(query, args)
	return t.tx.QueryContext(ctx, query, args...)
}

func (t *Tx) QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row {
	query, args = t.db.prepare(query, args)
	return t.tx.QueryRowContext(ctx, query, args...)
}

// prepare adapts a query to Postgres. Flags are whole numbers in both schemas, so that
// the queries can compare and add them up the same way.
func (d *DB) prepare(query string, args []any) (string, []any) {
	if !d.postgres {
		return query, args
	}
	converted := make([]any, len(args))
	for i, arg := range args {
		converted[i] = arg
		switch flag := arg.(type) {
		case bool:
			converted[i] = flagNumber(flag)
		case *bool:
			converted[i] = nil
			if flag != nil {
				converted[i] = flagNumber(*flag)
			}
		}
	}
	return numberParameters(query), converted
}

func flagNumber(flag bool) int {
	if flag {
		return 1
	}
	return 0
}

// numberParameters turns ? and ?1 into $1, outside of string literals. Like in SQLite,
// a plain ? is one more than the highest number so far.
func numberParameters(query string) string {
	if !strings.Contains(query, "?") {
		return query
	}
	var out strings.Builder
	out.Grow(len(query) + 8)
	highest, quoted := 0, false
	for i := 0; i < len(query); i++ {
		c := query[i]
		if c == '\'' {
			quoted = !quoted
		}
		if c != '?' || quoted {
			out.WriteByte(c)
			continue
		}
		end := i + 1
		for end < len(query) && query[end] >= '0' && query[end] <= '9' {
			end++
		}
		number := highest + 1
		if end > i+1 {
			number, _ = strconv.Atoi(query[i+1 : end])
		}
		highest = max(highest, number)
		out.WriteByte('$')
		out.WriteString(strconv.Itoa(number))
		i = end - 1
	}
	return out.String()
}

// IsUniqueViolation reports whether a row failed on a unique constraint.
func IsUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code == "23505"
	}
	return strings.Contains(err.Error(), "UNIQUE constraint failed")
}
