package storage

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"testing/iotest"
)

func checkStore(t *testing.T, store Store) {
	t.Helper()
	ctx := context.Background()
	if _, _, err := store.Get(ctx, "fehlt"); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing: %v", err)
	}
	if err := store.Delete(ctx, "fehlt"); err != nil {
		t.Errorf("deleting what is missing: %v", err)
	}

	// Bigger than one part of a multipart upload.
	content := bytes.Repeat([]byte("kintura"), (partSize+1024)/9)
	size, err := store.Put(ctx, "datei", bytes.NewReader(content), "text/plain")
	if err != nil {
		t.Fatal(err)
	}
	if size != int64(len(content)) {
		t.Errorf("size: %d", size)
	}
	reader, got, err := store.Get(ctx, "datei")
	if err != nil {
		t.Fatal(err)
	}
	read, err := io.ReadAll(reader)
	reader.Close()
	if err != nil || got != int64(len(content)) || !bytes.Equal(read, content) {
		t.Errorf("reading back: %d of %d, %v", len(read), got, err)
	}
	if err := store.Delete(ctx, "datei"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Get(ctx, "datei"); !errors.Is(err, ErrNotFound) {
		t.Errorf("after deleting: %v", err)
	}

	// A failing upload says why, and leaves nothing behind.
	broken := errors.New("zu groß")
	failing := io.MultiReader(strings.NewReader("anfang"), iotest.ErrReader(broken))
	if _, err := store.Put(ctx, "kaputt", failing, "text/plain"); !errors.Is(err, broken) {
		t.Errorf("failing upload: %v", err)
	}
	if _, _, err := store.Get(ctx, "kaputt"); !errors.Is(err, ErrNotFound) {
		t.Errorf("after the failed upload: %v", err)
	}
}

func TestLocal(t *testing.T) {
	store, err := NewLocal(t.TempDir() + "/neu/files")
	if err != nil {
		t.Fatal(err)
	}
	checkStore(t, store)
}

// TestS3 needs a service, see compose.test.yaml.
func TestS3(t *testing.T) {
	endpoint := os.Getenv("TEST_S3_ENDPOINT")
	if endpoint == "" {
		t.Skip("TEST_S3_ENDPOINT nicht gesetzt")
	}
	cfg := S3Config{
		Endpoint: endpoint, Bucket: os.Getenv("TEST_S3_BUCKET"), Prefix: "storage-test/",
		AccessKey: os.Getenv("TEST_S3_ACCESS_KEY"), SecretKey: os.Getenv("TEST_S3_SECRET_KEY"),
		Region: "us-east-1", PathStyle: true, CreateBucket: true,
	}
	store, err := NewS3(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	checkStore(t, store)
	cfg.CreateBucket = false

	// The same key under another prefix is another file.
	if _, err := store.Put(context.Background(), "gemeinsam", strings.NewReader("a"), "text/plain"); err != nil {
		t.Fatal(err)
	}
	cfg.Prefix = "anderer-test"
	other, err := NewS3(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := other.Get(context.Background(), "gemeinsam"); !errors.Is(err, ErrNotFound) {
		t.Errorf("other prefix: %v", err)
	}
	store.Delete(context.Background(), "gemeinsam")

	cfg.Bucket = "gibt-es-nicht"
	if _, err := NewS3(context.Background(), cfg); err == nil {
		t.Error("missing bucket accepted")
	}
}

func TestS3ChecksItsSettings(t *testing.T) {
	if _, err := NewS3(context.Background(), S3Config{}); err == nil {
		t.Error("no bucket")
	}
	if _, err := NewS3(context.Background(), S3Config{Bucket: "b", Endpoint: "s3.example.com"}); err == nil {
		t.Error("endpoint without a scheme")
	}
}
