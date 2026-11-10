// Package storage keeps the uploaded files, on the local disk or in an object storage.
package storage

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
)

// ErrNotFound means that there is no file under the key.
var ErrNotFound = errors.New("Datei nicht gefunden")

// Store holds files by key.
type Store interface {
	// Put reads until EOF and returns the size. If reading fails, nothing stays
	// behind and the error of the reader comes back as it is.
	Put(ctx context.Context, key string, content io.Reader, contentType string) (int64, error)
	// Get returns the content and its size. The caller closes it.
	Get(ctx context.Context, key string) (io.ReadCloser, int64, error)
	// Delete succeeds if the file is gone, also if it never existed.
	Delete(ctx context.Context, key string) error
}

// Local keeps files in a directory on the disk.
type Local struct {
	dir string
}

// NewLocal creates the directory if it is missing.
func NewLocal(dir string) (*Local, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Local{dir: dir}, nil
}

func (l *Local) path(key string) string { return filepath.Join(l.dir, filepath.Base(key)) }

func (l *Local) Put(_ context.Context, key string, content io.Reader, _ string) (int64, error) {
	path := l.path(key)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return 0, err
	}
	written, err := io.Copy(file, content)
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		os.Remove(path)
		return 0, err
	}
	return written, nil
}

func (l *Local) Get(_ context.Context, key string) (io.ReadCloser, int64, error) {
	file, err := os.Open(l.path(key))
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, ErrNotFound
	}
	if err != nil {
		return nil, 0, err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, 0, err
	}
	return file, info.Size(), nil
}

func (l *Local) Delete(_ context.Context, key string) error {
	err := os.Remove(l.path(key))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
