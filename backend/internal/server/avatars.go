package server

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"errors"
	"image"
	"image/jpeg"
	"io"
	"net/http"
	"strconv"

	// Formats an upload may come in; the app sends PNG or JPEG from its cropper.
	_ "image/gif"
	_ "image/png"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

const (
	maxAvatarUpload = 10 << 20
	// Larger images would take too much memory to decode, and no photo needs it.
	maxAvatarPixels = 4096 * 4096
	avatarSmall     = 96
	avatarLarge     = 512
)

// avatarImages crops the upload to the square in its middle and makes the two sizes:
// small for lists and icons, sent along as Base64, and large for the profile page.
func avatarImages(raw []byte) (small string, large []byte, err error) {
	invalid := fail(http.StatusBadRequest, "Das Bild lässt sich nicht lesen. Bitte ein JPEG-, PNG- oder WebP-Bild wählen.")
	config, _, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil {
		return "", nil, invalid
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width*config.Height > maxAvatarPixels {
		return "", nil, fail(http.StatusBadRequest, "Das Bild ist zu groß. Höchstens 4096 × 4096 Pixel.")
	}
	img, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return "", nil, invalid
	}
	bounds := img.Bounds()
	side := min(bounds.Dx(), bounds.Dy())
	square := image.Rect(0, 0, side, side).Add(image.Pt(bounds.Min.X+(bounds.Dx()-side)/2, bounds.Min.Y+(bounds.Dy()-side)/2))
	scaled := func(size int, quality int) ([]byte, error) {
		dst := image.NewRGBA(image.Rect(0, 0, size, size))
		// White under transparent parts, as JPEG has no transparency.
		draw.Draw(dst, dst.Bounds(), image.White, image.Point{}, draw.Src)
		draw.CatmullRom.Scale(dst, dst.Bounds(), img, square, draw.Over, nil)
		var out bytes.Buffer
		err := jpeg.Encode(&out, dst, &jpeg.Options{Quality: quality})
		return out.Bytes(), err
	}
	smallJPEG, err := scaled(avatarSmall, 80)
	if err != nil {
		return "", nil, err
	}
	if large, err = scaled(avatarLarge, 85); err != nil {
		return "", nil, err
	}
	return base64.StdEncoding.EncodeToString(smallJPEG), large, nil
}

func (s *Server) saveAvatar(w http.ResponseWriter, r *http.Request, familyID, userID string) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxAvatarUpload)
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
	raw, err := io.ReadAll(part)
	if err != nil {
		return err
	}
	small, large, err := avatarImages(raw)
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO member_avatars (family_id, user_id, small, large, updated_at) VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT (family_id, user_id) DO UPDATE SET small = excluded.small, large = excluded.large, updated_at = excluded.updated_at`,
		familyID, userID, small, large, now()); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"avatar": small})
	return nil
}

func (s *Server) removeAvatar(w http.ResponseWriter, r *http.Request, familyID, userID string) error {
	if _, err := s.db.ExecContext(r.Context(), `DELETE FROM member_avatars WHERE family_id = ? AND user_id = ?`, familyID, userID); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) putOwnAvatar(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	return s.saveAvatar(w, r, c.familyID, c.userID)
}

// copyOwnAvatar takes the caller's own photo from another family they are in. Only
// their own: a photo row exists only with its membership, so the family is theirs.
func (s *Server) copyOwnAvatar(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		FamilyID string `json:"family_id"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	if in.FamilyID == c.familyID {
		return fail(http.StatusBadRequest, "Das Foto ist bereits in diesem Kreis.")
	}
	var small string
	var large []byte
	err := s.db.QueryRowContext(r.Context(), `SELECT small, large FROM member_avatars WHERE family_id = ? AND user_id = ?`,
		in.FamilyID, c.userID).Scan(&small, &large)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(r.Context(),
		`INSERT INTO member_avatars (family_id, user_id, small, large, updated_at) VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT (family_id, user_id) DO UPDATE SET small = excluded.small, large = excluded.large, updated_at = excluded.updated_at`,
		c.familyID, c.userID, small, large, now()); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]string{"avatar": small})
	return nil
}

func (s *Server) deleteOwnAvatar(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	return s.removeAvatar(w, r, c.familyID, c.userID)
}

// The photo of a managed member is the admin's to change, like the rest of the profile.
func (s *Server) putMemberAvatar(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if err := s.managedMember(r.Context(), c, r.PathValue("uid")); err != nil {
		return err
	}
	return s.saveAvatar(w, r, c.familyID, r.PathValue("uid"))
}

func (s *Server) deleteMemberAvatar(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	if err := s.managedMember(r.Context(), c, r.PathValue("uid")); err != nil {
		return err
	}
	return s.removeAvatar(w, r, c.familyID, r.PathValue("uid"))
}

// getMemberAvatar sends the large photo of a member, for everyone in the family.
func (s *Server) getMemberAvatar(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var large []byte
	err := s.db.QueryRowContext(r.Context(), `SELECT large FROM member_avatars WHERE family_id = ? AND user_id = ?`,
		c.familyID, r.PathValue("uid")).Scan(&large)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Content-Length", strconv.Itoa(len(large)))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, no-cache")
	_, err = w.Write(large)
	return err
}
