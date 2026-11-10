package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

const (
	maxProfileFields = 50
	maxProfileValue  = 500
	maxProfileText   = 200
)

// profileFieldKinds are the extra fields of a profile, each as often as wanted.
var profileFieldKinds = map[string]bool{"phone": true, "email": true, "mobile": true, "work_phone": true, "other": true, "address": true}

type profileField struct {
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

// A profile belongs to a member of a family, so that the same person can appear
// differently in each of them. Only the member reads it; the others get the name.
type memberProfile struct {
	Name         string         `json:"name"`
	FamilyRole   string         `json:"family_role"`
	ContactEmail string         `json:"contact_email"`
	Birthday     string         `json:"birthday"`
	Fields       []profileField `json:"fields"`
}

func (s *Server) getProfile(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	return s.writeProfile(w, r, c.familyID, c.userID)
}

func (s *Server) putProfile(w http.ResponseWriter, r *http.Request, c reqCtx) error {
	return s.saveProfile(w, r, c.familyID, c.userID)
}

func (s *Server) writeProfile(w http.ResponseWriter, r *http.Request, familyID, userID string) error {
	var profile memberProfile
	var fields string
	if err := s.db.QueryRowContext(r.Context(),
		`SELECT name, family_role, contact_email, birthday, profile_fields FROM memberships WHERE family_id = ? AND user_id = ?`,
		familyID, userID).Scan(&profile.Name, &profile.FamilyRole, &profile.ContactEmail, &profile.Birthday, &fields); err != nil {
		return err
	}
	if err := json.Unmarshal([]byte(fields), &profile.Fields); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, profile)
	return nil
}

func (s *Server) saveProfile(w http.ResponseWriter, r *http.Request, familyID, userID string) error {
	var in memberProfile
	if err := readJSON(w, r, &in); err != nil {
		return err
	}
	name, err := required(in.Name, "Name", 100)
	if err != nil {
		return err
	}
	if in.Birthday != "" && !validDate(in.Birthday) {
		return fail(http.StatusBadRequest, "Ungültiges Datum")
	}
	role, email := strings.TrimSpace(in.FamilyRole), strings.TrimSpace(in.ContactEmail)
	if len([]rune(role)) > maxProfileText || len([]rune(email)) > maxProfileText {
		return fail(http.StatusBadRequest, "Der Text ist zu lang")
	}
	if len(in.Fields) > maxProfileFields {
		return fail(http.StatusBadRequest, fmt.Sprintf("Höchstens %d Felder", maxProfileFields))
	}
	fields := []profileField{}
	for _, field := range in.Fields {
		if !profileFieldKinds[field.Kind] {
			return fail(http.StatusBadRequest, "Unbekanntes Feld")
		}
		value := strings.TrimSpace(field.Value)
		if len([]rune(value)) > maxProfileValue {
			return fail(http.StatusBadRequest, "Der Text ist zu lang")
		}
		// A field that stayed empty is as good as none.
		if value != "" {
			fields = append(fields, profileField{field.Kind, value})
		}
	}
	stored, err := json.Marshal(fields)
	if err != nil {
		return err
	}
	res, err := s.db.ExecContext(r.Context(),
		`UPDATE memberships SET name = ?, family_role = ?, contact_email = ?, birthday = ?, profile_fields = ? WHERE family_id = ? AND user_id = ?`,
		name, role, email, in.Birthday, string(stored), familyID, userID)
	if err := requireAffected(res, err); err != nil {
		return err
	}
	return noContent(w)
}
