package server

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"net/http"
	"strings"
	"time"
)

// A login code lets someone without an address log in: an admin makes one and hands it
// over, and it works once. Anyone can try a code without naming an account first, so
// unlike a code from a mail it has to be too long to guess. A person types it from a
// note, so the alphabet leaves out what looks alike. Its 32 letters give 60 bits.
const (
	loginCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	loginCodeLength   = 12
	loginCodeTTL      = 7 * 24 * time.Hour
)

func newLoginCode() (string, error) {
	random := make([]byte, loginCodeLength)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	var code strings.Builder
	for i, b := range random {
		if i > 0 && i%4 == 0 {
			code.WriteByte('-')
		}
		code.WriteByte(loginCodeAlphabet[int(b)%len(loginCodeAlphabet)])
	}
	return code.String(), nil
}

// normalizeLoginCode accepts a code however it was typed or pasted.
func normalizeLoginCode(code string) string {
	return strings.NewReplacer("-", "", " ", "").Replace(strings.ToUpper(strings.TrimSpace(code)))
}

// createLoginCode makes the code of a managed member. Only the latest one works.
func (s *Server) createLoginCode(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx, target := r.Context(), r.PathValue("uid")
	if err := s.managedMember(ctx, c, target); err != nil {
		return err
	}
	code, err := newLoginCode()
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO login_codes (user_id, code_hash, expires_at) VALUES (?, ?, ?)
		 ON CONFLICT (user_id) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at`,
		target, hashToken(normalizeLoginCode(code)), time.Now().UTC().Add(loginCodeTTL).Format(timeFormat)); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"code": code})
	return nil
}

// authCode logs in with a login code and uses it up. Taking it out of the table in one
// statement means that of two tries at the same moment, only one gets a session.
func (s *Server) authCode(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Code string `json:"code"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var userID string
	err = tx.QueryRowContext(ctx,
		`DELETE FROM login_codes WHERE code_hash = ? AND expires_at > ?
		 AND user_id IN (SELECT u.id FROM users u JOIN memberships m ON m.user_id = u.id WHERE u.is_managed = 1)
		 RETURNING user_id`, hashToken(normalizeLoginCode(in.Code)), now()).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		return fail(http.StatusBadRequest, "Der Code ist ungültig oder abgelaufen.")
	}
	if err != nil {
		return err
	}
	token, err := createSession(ctx, tx, userID, sessionTTL)
	if err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "authenticated", "token": token})
	return nil
}

// refuseManaged keeps someone without an address away from what only makes sense with
// one. Being logged in with a login code does not make them an account of their own.
func (s *Server) refuseManaged(r *http.Request, c reqCtx, message string) error {
	var managed bool
	if err := s.db.QueryRowContext(r.Context(), `SELECT is_managed FROM users WHERE id = ?`, c.userID).Scan(&managed); err != nil {
		return err
	}
	if managed {
		return fail(http.StatusForbidden, message)
	}
	return nil
}
