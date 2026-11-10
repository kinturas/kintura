// Command kintura is the backend of the app. It is configured by environment
// variables, see .env.example.
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/kinturas/kintura/backend/internal/database"
	"github.com/kinturas/kintura/backend/internal/mail"
	"github.com/kinturas/kintura/backend/internal/server"
	"github.com/kinturas/kintura/backend/internal/storage"
)

// version is set by make build, see the Makefile.
var version = "dev"

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func openDatabase(ctx context.Context, dataDir string) (*database.DB, error) {
	driver := env("DB_DRIVER", database.SQLite)
	path := filepath.Join(dataDir, "kintura.db")
	if driver == database.SQLite {
		if err := os.MkdirAll(dataDir, 0o700); err != nil {
			return nil, err
		}
	}
	return database.Open(ctx, database.Config{
		Driver: driver,
		Path:   path,
		URL:    os.Getenv("DATABASE_URL"),
	})
}

func openStorage(ctx context.Context, dataDir string) (storage.Store, error) {
	switch driver := env("STORAGE_DRIVER", "local"); driver {
	case "local":
		return storage.NewLocal(filepath.Join(dataDir, "files"))
	case "s3":
		return storage.NewS3(ctx, storage.S3Config{
			Endpoint:  os.Getenv("S3_ENDPOINT"),
			Region:    os.Getenv("S3_REGION"),
			Bucket:    os.Getenv("S3_BUCKET"),
			Prefix:    os.Getenv("S3_PREFIX"),
			AccessKey: os.Getenv("S3_ACCESS_KEY"),
			SecretKey: os.Getenv("S3_SECRET_KEY"),
			PathStyle: os.Getenv("S3_PATH_STYLE") == "true",

			CreateBucket: os.Getenv("S3_CREATE_BUCKET") == "true",
		})
	default:
		return nil, fmt.Errorf("unbekannte Dateiablage %q", driver)
	}
}

func openMailer() mail.Mailer {
	host := os.Getenv("SMTP_HOST")
	if host == "" {
		log.Println("WARNUNG: SMTP_HOST nicht gesetzt - Mails inkl. Login-Codes werden nur ins Log geschrieben (nur für Entwicklung)")
		return mail.Log{}
	}
	return &mail.SMTP{
		Host: host,
		Port: env("SMTP_PORT", "587"),
		User: os.Getenv("SMTP_USER"),
		Pass: os.Getenv("SMTP_PASS"),
		From: env("SMTP_FROM", os.Getenv("SMTP_USER")),
	}
}

func main() {
	ctx := context.Background()
	dataDir := env("DATA_DIR", "data")

	db, err := openDatabase(ctx, dataDir)
	if err != nil {
		log.Fatalf("Datenbank: %v", err)
	}
	defer db.Close()

	files, err := openStorage(ctx, dataDir)
	if err != nil {
		log.Fatalf("Dateiablage: %v", err)
	}

	s, err := server.New(ctx, server.Config{
		DB:         db,
		Files:      files,
		Mailer:     openMailer(),
		Timezone:   os.Getenv("DEFAULT_TIMEZONE"),
		PublicURL:  strings.TrimRight(env("PUBLIC_URL", "http://localhost:8080"), "/"),
		CORSOrigin: env("CORS_ORIGIN", "*"),
		AdminKey:   os.Getenv("ADMIN_API_KEY"),
		Version:    version,
	})
	if err != nil {
		log.Fatal(err)
	}
	s.RunBackground(ctx)

	addr := env("ADDR", ":8080")
	log.Printf("Kintura Backend %s läuft auf %s", version, addr)
	srv := &http.Server{
		Addr:              addr,
		Handler:           s.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}
