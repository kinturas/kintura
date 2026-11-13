package server

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

type paletteColor struct {
	Color string `json:"color"`
	Label string `json:"label"`
}

// baseColors are the same in every family and cannot be changed.
var baseColors = sortedBaseColors()

func sortedBaseColors() []paletteColor {
	colors := []paletteColor{
		{"#BBDEFB", "Eisblau"},
		{"#90CAF9", "Himmelblau"},
		{"#B71C1C", "Karmin"},
		{"#F48FB1", "Rosé"},
		{"#C2185B", "Magenta"},
		{"#CE93D8", "Flieder"},
		{"#4A148C", "Aubergine"},
		{"#9FA8DA", "Lavendel"},
		{"#1A237E", "Marine"},
		{"#4682B4", "Stahlblau"},
		{"#006064", "Petrol"},
		{"#80DEEA", "Aqua"},
		{"#80CBC4", "Mint"},
		{"#1B5E20", "Smaragd"},
		{"#A5D6A7", "Salbei"},
		{"#827717", "Olive"},
		{"#FFF176", "Zitrone"},
		{"#FFCC80", "Apricot"},
		{"#BF360C", "Terrakotta"},
		{"#D7CCC8", "Sand"},
		{"#D32F2F", "Rot"},
		{"#FF7043", "Koralle"},
		{"#F57C00", "Orange"},
		{"#FFB300", "Bernstein"},
		{"#FDD835", "Gelb"},
		{"#C0CA33", "Limette"},
		{"#7CB342", "Hellgrün"},
		{"#2E7D32", "Grün"},
		{"#00897B", "Türkis"},
		{"#00ACC1", "Cyan"},
		{"#039BE5", "Hellblau"},
		{"#1565C0", "Blau"},
		{"#3949AB", "Indigo"},
		{"#7B1FA2", "Violett"},
		{"#AB47BC", "Lila"},
		{"#D81B60", "Pink"},
		{"#6D4C41", "Braun"},
		{"#546E7A", "Grau"},
	}
	slices.SortStableFunc(colors, func(a, b paletteColor) int { return compareHue(a.Color, b.Color) })
	return colors
}

// compareHue orders colors like a color wheel, with light shades first and
// nearly gray colors at the end.
func compareHue(a, b string) int {
	grayA, hueA, lightA := hueOf(a)
	grayB, hueB, lightB := hueOf(b)
	if grayA != grayB {
		if grayB {
			return -1
		}
		return 1
	}
	if !grayA && hueA != hueB {
		if hueA < hueB {
			return -1
		}
		return 1
	}
	switch {
	case lightA > lightB:
		return -1
	case lightA < lightB:
		return 1
	}
	return strings.Compare(a, b)
}

// hueOf splits a color into its hue, rounded to 30 degree steps so that shades
// of one color stay together, and its lightness.
func hueOf(hex string) (gray bool, hue int, light float64) {
	v, _ := strconv.ParseUint(hex[1:], 16, 32)
	r, g, b := float64(v>>16&255)/255, float64(v>>8&255)/255, float64(v&255)/255
	high, low := max(r, g, b), min(r, g, b)
	delta := high - low
	light = (high + low) / 2
	if delta < 0.16 {
		return true, 0, light
	}
	var degrees float64
	switch high {
	case r:
		degrees = (g - b) / delta
		if degrees < 0 {
			degrees += 6
		}
	case g:
		degrees = (b-r)/delta + 2
	default:
		degrees = (r-g)/delta + 4
	}
	return false, (int(degrees*60) + 15) / 30 % 12, light
}

func isBaseColor(color string) bool {
	return slices.ContainsFunc(baseColors, func(c paletteColor) bool { return c.Color == color })
}

// checkFamilyColor rejects colors that are not in the family's color table.
func (s *Server) checkFamilyColor(ctx context.Context, familyID, color string) error {
	if isBaseColor(color) {
		return nil
	}
	var n int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM custom_colors WHERE family_id = ? AND color = ?`, familyID, color).Scan(&n); err != nil {
		return err
	}
	if n == 0 {
		return fail(http.StatusBadRequest, "Ungültige Farbe")
	}
	return nil
}

// colorsInUse lists what members, invited people, categories, the shared calendars
// and the family itself refer to, for family ?1. These custom colors cannot be deleted. What someone chose only
// for themselves does not count: it falls back to the default, see deleteColor.
const colorsInUse = `SELECT color FROM memberships WHERE family_id = ?1
	UNION SELECT color FROM invitations WHERE family_id = ?1
	UNION SELECT color FROM categories WHERE family_id = ?1
	UNION SELECT color FROM calendar_colors WHERE family_id = ?1
	UNION SELECT color FROM families WHERE id = ?1`

func (s *Server) listColors(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	custom, err := queryRows(ctx, s.db,
		`SELECT id, color, label, color IN (`+colorsInUse+`) AS used FROM custom_colors WHERE family_id = ?1`, c.familyID)
	if err != nil {
		return err
	}
	slices.SortStableFunc(custom, func(a, b map[string]any) int {
		return compareHue(a["color"].(string), b["color"].(string))
	})
	inUse, err := s.colorsShownInFamily(ctx, c.familyID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"base": baseColors, "custom": custom, "in_use": inUse})
	return nil
}

// colorsShownInFamily are the colors someone in the family already sees for something:
// members and invited people, categories, and the shared calendars with the color
// they show, their default when nobody chose one. Pickers mark the others as free.
func (s *Server) colorsShownInFamily(ctx context.Context, familyID string) ([]string, error) {
	rows, err := queryRows(ctx, s.db,
		`SELECT color FROM memberships WHERE family_id = ?1
		 UNION SELECT color FROM invitations WHERE family_id = ?1
		 UNION SELECT color FROM categories WHERE family_id = ?1`, familyID)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, row := range rows {
		seen[strings.ToUpper(row["color"].(string))] = true
	}
	chosen, err := queryRows(ctx, s.db, `SELECT key, color FROM calendar_colors WHERE family_id = ?`, familyID)
	if err != nil {
		return nil, err
	}
	calendars := map[string]string{}
	for _, row := range chosen {
		calendars[row["key"].(string)] = row["color"].(string)
	}
	var familyDefault string
	if err := s.db.QueryRowContext(ctx, `SELECT default_color FROM families WHERE id = ?`, familyID).Scan(&familyDefault); err != nil {
		return nil, err
	}
	for kind := range sharedColorKinds {
		color := calendars[kind]
		if color == "" {
			color = calendarColors[kind]
		}
		if kind == "family" && calendars[kind] == "" {
			color = familyDefault
		}
		seen[strings.ToUpper(color)] = true
	}
	delete(seen, "")
	out := make([]string, 0, len(seen))
	for color := range seen {
		out = append(out, color)
	}
	slices.Sort(out)
	return out, nil
}

var hexColor = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)

// readCustomColor validates the fields of a custom color, which must not repeat a base color.
func readCustomColor(w http.ResponseWriter, r *http.Request) (paletteColor, error) {
	var in paletteColor
	if err := readJSON(w, r, &in); err != nil {
		return in, err
	}
	label, err := required(in.Label, "Farbtext", 30)
	if err != nil {
		return in, err
	}
	if !hexColor.MatchString(in.Color) {
		return in, fail(http.StatusBadRequest, "Ungültige Farbe")
	}
	in.Label, in.Color = label, strings.ToUpper(in.Color)
	if isBaseColor(in.Color) {
		return in, errColorExists
	}
	return in, nil
}

var errColorExists = fail(http.StatusConflict, "Diese Farbe gibt es bereits.")

func (s *Server) createColor(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := readCustomColor(w, r)
	if err != nil {
		return err
	}
	id := newID()
	if _, err := s.db.ExecContext(r.Context(), `INSERT INTO custom_colors (id, family_id, color, label) VALUES (?, ?, ?, ?)`,
		id, c.familyID, in.Color, in.Label); err != nil {
		if isUniqueViolation(err) {
			return errColorExists
		}
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
	return nil
}

// updateColor also moves everything that uses the color over to its new value.
func (s *Server) updateColor(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	in, err := readCustomColor(w, r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var old string
	err = tx.QueryRowContext(ctx, `SELECT color FROM custom_colors WHERE id = ? AND family_id = ?`, r.PathValue("id"), c.familyID).Scan(&old)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE custom_colors SET color = ?, label = ? WHERE id = ?`, in.Color, in.Label, r.PathValue("id")); err != nil {
		if isUniqueViolation(err) {
			return errColorExists
		}
		return err
	}
	for _, query := range []string{
		`UPDATE memberships SET color = ?1 WHERE family_id = ?2 AND color = ?3`,
		`UPDATE invitations SET color = ?1 WHERE family_id = ?2 AND color = ?3`,
		`UPDATE categories SET color = ?1 WHERE family_id = ?2 AND color = ?3`,
		`UPDATE families SET default_color = ?1 WHERE id = ?2 AND default_color = ?3`,
		`UPDATE families SET color = ?1 WHERE id = ?2 AND color = ?3`,
		`UPDATE calendar_colors SET color = ?1 WHERE family_id = ?2 AND color = ?3`,
		`UPDATE calendar_settings SET color = ?1 WHERE family_id = ?2 AND color = ?3`,
	} {
		if _, err := tx.ExecContext(ctx, query, in.Color, c.familyID, old); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return noContent(w)
}

func (s *Server) deleteColor(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	ctx := r.Context()
	id := r.PathValue("id")
	var color string
	err := s.db.QueryRowContext(ctx, `SELECT color FROM custom_colors WHERE family_id = ? AND id = ?`, c.familyID, id).Scan(&color)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx,
		`DELETE FROM custom_colors WHERE family_id = ?1 AND id = ?2 AND color NOT IN (`+colorsInUse+`)`, c.familyID, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		// Whoever picked it for a calendar of their own gets its default back.
		if _, err := tx.ExecContext(ctx, `UPDATE calendar_settings SET color = '' WHERE family_id = ? AND color = ?`, c.familyID, color); err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		return noContent(w)
	}
	// Only one connection exists, and the check below needs it.
	if err := tx.Rollback(); err != nil {
		return err
	}
	var exists int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM custom_colors WHERE family_id = ? AND id = ?`, c.familyID, id).Scan(&exists); err != nil {
		return err
	}
	if exists > 0 {
		return fail(http.StatusConflict, "Diese Farbe wird noch verwendet.")
	}
	return errNotFound
}

// checkMemberColor accepts a color from the family's table, or none for an empty value.
func (s *Server) checkMemberColor(ctx context.Context, familyID, color string) error {
	if color == "" {
		return nil
	}
	return s.checkFamilyColor(ctx, familyID, color)
}

// setOwnColor lets a member pick their color in this family, unless an admin took
// that away. Admins can set any color anyway, so it never holds for them.
func (s *Server) setOwnColor(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Color string `json:"color"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	if err := s.checkMemberColor(ctx, c.familyID, in.Color); err != nil {
		return err
	}
	var allowed bool
	if err := s.db.QueryRowContext(ctx, `SELECT can_change_color FROM memberships WHERE family_id = ? AND user_id = ?`,
		c.familyID, c.userID).Scan(&allowed); err != nil {
		return err
	}
	if !allowed && !c.isAdmin {
		return fail(http.StatusForbidden, "Deine Profilfarbe kann nur ein Admin ändern.")
	}
	res, err := s.db.ExecContext(ctx, `UPDATE memberships SET color = ? WHERE family_id = ? AND user_id = ?`, in.Color, c.familyID, c.userID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}

// setMemberColor lets an admin set the color of a member, and whether they may change it.
func (s *Server) setMemberColor(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	var in struct {
		Color          string `json:"color"`
		CanChangeColor *bool  `json:"can_change_color"`
	}
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	if err := s.checkMemberColor(ctx, c.familyID, in.Color); err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE memberships SET color = ?, can_change_color = COALESCE(?, can_change_color) WHERE family_id = ? AND user_id = ?`,
		in.Color, in.CanChangeColor, c.familyID, r.PathValue("uid"))
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}
