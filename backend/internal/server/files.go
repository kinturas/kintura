package server

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"io"
	"mime"
	"net/http"
	"path/filepath"
	"strconv"
	"time"
)

const (
	maxUploadSize = 25 << 20
	downloadTTL   = 5 * time.Minute
)

var photoTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/gif": true, "image/webp": true}

func (s *Server) listFiles(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	rows, err := queryRows(r.Context(), s.db,
		`SELECT f.id, f.kind, f.name, f.mime, f.size, f.created_at, COALESCE(m.name, u.name) AS uploaded_by_name
		 FROM files f JOIN users u ON u.id = f.uploaded_by
		 LEFT JOIN memberships m ON m.user_id = f.uploaded_by AND m.family_id = f.family_id
		 WHERE f.family_id = ? AND f.kind = ? AND f.event_id IS NULL ORDER BY f.created_at DESC`, c.familyID, r.URL.Query().Get("kind"))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, rows)
	return nil
}

func (s *Server) uploadFile(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	kind := r.URL.Query().Get("kind")
	if kind != "document" && kind != "photo" {
		return fail(http.StatusBadRequest, "Ungültige Dateiart")
	}
	return s.storeUpload(w, r, c, kind, "")
}

// storeUpload saves the uploaded file. With an eventID it becomes an attachment,
// which only the routes of that event reach, because the event may be private.
func (s *Server) storeUpload(w http.ResponseWriter, r *http.Request, c reqCtx, kind, eventID string) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadSize)
	mr, err := r.MultipartReader()
	if err != nil {
		return fail(http.StatusBadRequest, "Ungültiger Upload")
	}
	part, err := mr.NextPart()
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			return err
		}
		return fail(http.StatusBadRequest, "Ungültiger Upload")
	}
	defer part.Close()
	name, err := required(filepath.Base(part.FileName()), "Dateiname", 255)
	if err != nil {
		return err
	}

	// The type is detected from the content, never taken from the client.
	head := make([]byte, 512)
	n, err := io.ReadFull(part, head)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return err
	}
	head = head[:n]
	if n == 0 {
		return fail(http.StatusBadRequest, "Die Datei ist leer.")
	}
	contentType := http.DetectContentType(head)
	if kind == "photo" && !photoTypes[contentType] {
		return fail(http.StatusBadRequest, "Nur JPEG, PNG, GIF und WebP werden unterstützt.")
	}

	id := newID()
	ctx := r.Context()
	size, err := s.files.Put(ctx, id, io.MultiReader(bytes.NewReader(head), part), contentType)
	if err != nil {
		return err
	}
	stored := false
	defer func() {
		if !stored {
			s.files.Delete(context.WithoutCancel(ctx), id)
		}
	}()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO files (id, family_id, kind, name, mime, size, uploaded_by, created_at, event_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, c.familyID, kind, name, contentType, size, c.userID, now(), nullable(eventID)); err != nil {
		return err
	}
	stored = true
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

// serveFile sends a stored file. nosniff keeps browsers from executing uploads.
func (s *Server) serveFile(w http.ResponseWriter, r *http.Request, id, name, contentType, disposition string) error {
	f, size, err := s.files.Get(r.Context(), id)
	if err != nil {
		return err
	}
	defer f.Close()
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Disposition", mime.FormatMediaType(disposition, map[string]string{"filename": name}))
	_, err = io.Copy(w, f)
	return err
}

func (s *Server) fileContent(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	id := r.PathValue("id")
	var name, contentType string
	err := s.db.QueryRowContext(r.Context(), `SELECT name, mime FROM files WHERE id = ? AND family_id = ? AND event_id IS NULL`, id, c.familyID).
		Scan(&name, &contentType)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	return s.serveFile(w, r, id, name, contentType, "attachment")
}

// fileLink creates a short-lived URL the system browser can open without the
// session token, which gives every platform the same download path.
func (s *Server) fileLink(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	id := r.PathValue("id")
	var exists string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM files WHERE id = ? AND family_id = ? AND event_id IS NULL`, id, c.familyID).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	return s.writeDownloadLink(w, r, id)
}

func (s *Server) writeDownloadLink(w http.ResponseWriter, r *http.Request, id string) error {
	token := randomHex(32)
	if _, err := s.db.ExecContext(r.Context(), `INSERT INTO download_tokens (token_hash, file_id, expires_at) VALUES (?, ?, ?)`,
		hashToken(token), id, time.Now().UTC().Add(downloadTTL).Format(timeFormat)); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"url": s.publicURL + "/dl/" + token})
	return nil
}

func (s *Server) download(w http.ResponseWriter, r *http.Request) {
	var id, name, contentType string
	err := s.db.QueryRowContext(r.Context(),
		`SELECT f.id, f.name, f.mime FROM download_tokens t JOIN files f ON f.id = t.file_id
		 WHERE t.token_hash = ? AND t.expires_at > ?`, hashToken(r.PathValue("token")), now()).Scan(&id, &name, &contentType)
	if err != nil {
		http.Error(w, "Link ungültig oder abgelaufen", http.StatusGone)
		return
	}
	if err := s.serveFile(w, r, id, name, contentType, "attachment"); err != nil {
		s.logError(r, http.StatusInternalServerError, "Download: "+err.Error())
	}
}

func (s *Server) deleteFile(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	id := r.PathValue("id")
	var exists string
	err := s.db.QueryRowContext(r.Context(), `SELECT id FROM files WHERE id = ? AND family_id = ? AND event_id IS NULL`, id, c.familyID).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	return s.removeFile(w, r, id)
}

func (s *Server) removeFile(w http.ResponseWriter, r *http.Request, id string) error {
	res, err := s.db.ExecContext(r.Context(), `DELETE FROM files WHERE id = ?`, id)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	if err := s.files.Delete(context.WithoutCancel(r.Context()), id); err != nil {
		s.logError(r, http.StatusInternalServerError, "Datei löschen: "+err.Error())
	}
	return noContent(w)
}
