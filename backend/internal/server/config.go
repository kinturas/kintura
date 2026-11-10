package server

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/kinturas/kintura/backend/internal/database"
	"github.com/kinturas/kintura/backend/internal/mail"
	"github.com/kinturas/kintura/backend/internal/storage"
)

// Config is what the server needs from outside.
type Config struct {
	DB         *database.DB
	Files      storage.Store
	Mailer     mail.Mailer
	Timezone   string // of new events, Europe/Berlin if empty
	PublicURL  string
	CORSOrigin string
	AdminKey   string // of the admin dashboard, ignored if too short
	Version    string // of this build, shown by GET /api/version
}

// New checks the settings and makes sure the account for the token login exists.
func New(ctx context.Context, cfg Config) (*Server, error) {
	if cfg.DB == nil || cfg.Files == nil || cfg.Mailer == nil {
		return nil, errors.New("Datenbank, Dateiablage und Mailer sind Pflicht")
	}
	timezone := cfg.Timezone
	if timezone == "" {
		timezone = defaultTimezone
	}
	if _, err := time.LoadLocation(timezone); err != nil {
		return nil, fmt.Errorf("DEFAULT_TIMEZONE: %w", err)
	}
	adminKey := strings.TrimSpace(cfg.AdminKey)
	if len(adminKey) < minAdminKeyLength {
		log.Printf("WARNUNG: ADMIN_API_KEY fehlt oder hat weniger als %d Zeichen - Token-Anmeldung und Freischalten des Admin-Dashboards sind gesperrt", minAdminKeyLength)
		adminKey = ""
	}
	// Knowing the token is the only way into this account.
	if _, err := cfg.DB.ExecContext(ctx, `INSERT INTO users (id, email, name, created_at, is_sysadmin, admin_verified_at)
		VALUES (?, ?, 'Admin', ?, 1, ?) ON CONFLICT DO NOTHING`, newID(), adminEmail, now(), now()); err != nil {
		return nil, err
	}
	if err := createPages(ctx, cfg.DB); err != nil {
		return nil, err
	}
	return &Server{
		db:        cfg.DB,
		files:     cfg.Files,
		mailer:    cfg.Mailer,
		timezone:  timezone,
		publicURL: cfg.PublicURL,
		corsOrig:  cfg.CORSOrigin,
		adminKey:  adminKey,
		version:   cfg.Version,
		webDir:    "web",
	}, nil
}

// Handler answers all requests.
func (s *Server) Handler() http.Handler { return s.routes() }

// RunBackground starts what happens without a request.
func (s *Server) RunBackground(ctx context.Context) {
	go func() {
		for range time.Tick(time.Hour) {
			s.cleanup(ctx)
		}
	}()
	go func() {
		for now := range time.Tick(time.Minute) {
			s.sendReminders(ctx, now)
		}
	}()
}
