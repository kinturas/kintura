package server

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"testing"
)

// testPNG is a picture of the given size, red on the left half and blue on the right.
func testPNG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := range height {
		for x := range width {
			c := color.RGBA{R: 255, A: 255}
			if x >= width/2 {
				c = color.RGBA{B: 255, A: 255}
			}
			img.Set(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func (e *testEnv) putAvatar(token, path string, content []byte) (int, obj) {
	e.t.Helper()
	body, contentType := uploadBody(e.t, "foto.png", content)
	req, _ := http.NewRequest("PUT", e.srv.URL+path, body)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", contentType)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	out := obj{}
	json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func jpegSize(t *testing.T, raw []byte) image.Point {
	t.Helper()
	config, err := jpeg.DecodeConfig(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("no JPEG: %v", err)
	}
	return image.Pt(config.Width, config.Height)
}

func TestMemberAvatars(t *testing.T) {
	e := newEnv(t)
	admin := e.register("a@example.de", "A", "F")
	fid := e.firstFamily(admin)
	base := "/api/families/" + fid
	adminID := e.expect(200, "GET", "/api/me", admin, nil)["id"].(string)
	member, memberID := e.addMember(fid, admin, "b@example.de")
	child := e.expect(201, "POST", base+"/members", admin, obj{"name": "Kind", "role": "restrict_user"})["id"].(string)
	stranger := e.register("x@example.de", "X", "Fremd")

	// A landscape picture becomes a square, small for lists and large for the profile.
	status, out := e.putAvatar(admin, base+"/profile/avatar", testPNG(t, 300, 200))
	if status != 200 {
		t.Fatalf("upload: %d %v", status, out)
	}
	small, err := base64.StdEncoding.DecodeString(out["avatar"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if got := jpegSize(t, small); got != image.Pt(avatarSmall, avatarSmall) {
		t.Errorf("small: %v", got)
	}

	// It comes along wherever members are listed, and for the own families.
	listed := func(token, id string) any {
		for _, m := range e.expect(200, "GET", base+"/members", token, nil)["members"].([]any) {
			if m.(obj)["id"] == id {
				return m.(obj)["avatar"]
			}
		}
		return nil
	}
	if listed(member, adminID) != out["avatar"] || listed(member, memberID) != "" {
		t.Errorf("members list: %v / %v", listed(member, adminID), listed(member, memberID))
	}
	if got := e.expect(200, "GET", "/api/me", admin, nil)["families"].([]any)[0].(obj)["avatar"]; got != out["avatar"] {
		t.Errorf("me: %v", got)
	}

	// Everyone in the family sees the large one, nobody else.
	res, err := http.DefaultClient.Do(func() *http.Request {
		req, _ := http.NewRequest("GET", e.srv.URL+base+"/members/"+adminID+"/avatar", nil)
		req.Header.Set("Authorization", "Bearer "+member)
		return req
	}())
	if err != nil {
		t.Fatal(err)
	}
	large, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/jpeg" || jpegSize(t, large) != image.Pt(avatarLarge, avatarLarge) {
		t.Errorf("large: %d %s", res.StatusCode, res.Header.Get("Content-Type"))
	}
	e.expect(404, "GET", base+"/members/"+adminID+"/avatar", stranger, nil)
	e.expect(404, "GET", base+"/members/"+memberID+"/avatar", admin, nil)

	// The admin sets the photo of a managed member, but not of someone with an account,
	// and the others set none but their own.
	if status, out := e.putAvatar(admin, base+"/members/"+child+"/avatar", testPNG(t, 120, 120)); status != 200 {
		t.Errorf("managed by the admin: %d %v", status, out)
	}
	if status, _ := e.putAvatar(admin, base+"/members/"+memberID+"/avatar", testPNG(t, 120, 120)); status != 403 {
		t.Errorf("someone with an account by the admin: %d", status)
	}
	if status, _ := e.putAvatar(member, base+"/members/"+child+"/avatar", testPNG(t, 120, 120)); status != 403 {
		t.Errorf("by someone who is no admin: %d", status)
	}
	if status, _ := e.putAvatar(stranger, base+"/profile/avatar", testPNG(t, 120, 120)); status != 404 {
		t.Errorf("into another family: %d", status)
	}

	// What is no picture is refused.
	if status, out := e.putAvatar(member, base+"/profile/avatar", []byte("kein Bild")); status != 400 {
		t.Errorf("no picture: %d %v", status, out)
	}

	// Removed, it is gone; and it ends with the membership.
	e.expect(204, "DELETE", base+"/profile/avatar", admin, nil)
	e.expect(404, "GET", base+"/members/"+adminID+"/avatar", member, nil)
	if status, _ := e.putAvatar(member, base+"/profile/avatar", testPNG(t, 120, 120)); status != 200 {
		t.Fatal("member's own photo")
	}
	e.expect(204, "POST", base+"/leave", member, obj{})
	var left int
	if err := e.server.db.QueryRow(`SELECT COUNT(*) FROM member_avatars WHERE user_id = ?`, memberID).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Errorf("photo kept after leaving: %d", left)
	}
}

func TestOwnAvatarCopiesFromAnotherFamily(t *testing.T) {
	e := newEnv(t)
	anna := e.register("a@example.de", "A", "Erster")
	first := e.firstFamily(anna)
	ben := e.register("b@example.de", "B", "Zweiter")
	second := e.firstFamily(ben)
	e.expect(201, "POST", "/api/families/"+second+"/invitations", ben, obj{"email": "a@example.de", "role": "user"})
	e.acceptInvitations(anna)
	status, own := e.putAvatar(anna, "/api/families/"+first+"/profile/avatar", testPNG(t, 120, 120))
	if status != 200 {
		t.Fatal("upload")
	}
	if status, _ := e.putAvatar(ben, "/api/families/"+second+"/profile/avatar", testPNG(t, 80, 80)); status != 200 {
		t.Fatal("upload ben")
	}
	copyPath := "/api/families/" + second + "/profile/avatar/copy"

	// Her own photo from the other family, as it is.
	if got := e.expect(200, "POST", copyPath, anna, obj{"family_id": first}); got["avatar"] != own["avatar"] {
		t.Errorf("copy: %v", got)
	}
	for _, m := range e.expect(200, "GET", "/api/families/"+second+"/members", ben, nil)["members"].([]any) {
		if m.(obj)["name"] == "A" && m.(obj)["avatar"] != own["avatar"] {
			t.Errorf("listed: %v", m)
		}
	}
	// Never someone else's, nor from a family she is not in, nor from where she is.
	e.expect(404, "POST", "/api/families/"+first+"/profile/avatar/copy", anna, obj{"family_id": "x"})
	e.expect(404, "POST", copyPath, ben, obj{"family_id": first})
	e.expect(400, "POST", copyPath, anna, obj{"family_id": second})
	stranger := e.register("x@example.de", "X", "Fremd")
	e.expect(404, "POST", copyPath, stranger, obj{"family_id": first})
}
