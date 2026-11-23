package server

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Pusher sends a push message to one device.
type Pusher interface {
	Push(ctx context.Context, msg PushMessage) error
}

// PushMessage is a notification for one device.
type PushMessage struct {
	Token, Title, Body string
	// Tag replaces an earlier notification with the same one, as when an entry grows.
	Tag  string
	Data map[string]string
}

// errPushGone is returned when the device is no longer there, as after the app was
// removed; its token is forgotten then.
var errPushGone = errors.New("Gerät nicht mehr erreichbar")

const fcmScope = "https://www.googleapis.com/auth/firebase.messaging"

// FCM sends through Firebase Cloud Messaging (HTTP v1), as a service account of the
// Firebase project.
type FCM struct {
	projectID, email, tokenURI string
	key                        *rsa.PrivateKey
	client                     *http.Client
	// sendURL is where messages go; changed in tests.
	sendURL string

	mu      sync.Mutex
	access  string
	expires time.Time
}

// NewFCM reads the key file of a service account, as Firebase hands it out under
// Project settings → Service accounts.
func NewFCM(credentials []byte) (*FCM, error) {
	var account struct {
		Type       string `json:"type"`
		ProjectID  string `json:"project_id"`
		Email      string `json:"client_email"`
		PrivateKey string `json:"private_key"`
		TokenURI   string `json:"token_uri"`
	}
	if err := json.Unmarshal(credentials, &account); err != nil {
		return nil, fmt.Errorf("Firebase-Schlüsseldatei: %w", err)
	}
	if account.Type != "service_account" || account.ProjectID == "" || account.Email == "" {
		return nil, errors.New("Firebase-Schlüsseldatei: kein Dienstkonto")
	}
	block, _ := pem.Decode([]byte(account.PrivateKey))
	if block == nil {
		return nil, errors.New("Firebase-Schlüsseldatei: kein privater Schlüssel")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("Firebase-Schlüsseldatei: %w", err)
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("Firebase-Schlüsseldatei: kein RSA-Schlüssel")
	}
	if account.TokenURI == "" {
		account.TokenURI = "https://oauth2.googleapis.com/token"
	}
	return &FCM{
		projectID: account.ProjectID, email: account.Email, tokenURI: account.TokenURI, key: key,
		client:  &http.Client{Timeout: 20 * time.Second},
		sendURL: "https://fcm.googleapis.com/v1/projects/" + account.ProjectID + "/messages:send",
	}, nil
}

// accessToken returns a token of Google for sending, fetched again shortly before it ends.
func (f *FCM) accessToken(ctx context.Context) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.access != "" && time.Now().Before(f.expires) {
		return f.access, nil
	}
	assertion, err := f.assertion(time.Now())
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.tokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := f.client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("Google-Anmeldung: %s: %s", res.Status, body)
	}
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &out); err != nil || out.AccessToken == "" {
		return "", fmt.Errorf("Google-Anmeldung: unerwartete Antwort: %s", body)
	}
	f.access = out.AccessToken
	f.expires = time.Now().Add(time.Duration(out.ExpiresIn)*time.Second - time.Minute)
	return f.access, nil
}

// assertion is the signed JWT with which the service account asks for a token.
func (f *FCM) assertion(at time.Time) (string, error) {
	enc := base64.RawURLEncoding
	header := enc.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, err := json.Marshal(map[string]any{
		"iss": f.email, "scope": fcmScope, "aud": f.tokenURI,
		"iat": at.Unix(), "exp": at.Add(time.Hour).Unix(),
	})
	if err != nil {
		return "", err
	}
	unsigned := header + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(unsigned))
	signature, err := rsa.SignPKCS1v15(rand.Reader, f.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return unsigned + "." + enc.EncodeToString(signature), nil
}

// Push sends one message. A device that is gone gives errPushGone.
func (f *FCM) Push(ctx context.Context, msg PushMessage) error {
	access, err := f.accessToken(ctx)
	if err != nil {
		return err
	}
	android := map[string]any{
		"priority":     "high",
		"notification": map[string]any{"channel_id": "activities", "tag": msg.Tag},
	}
	payload, err := json.Marshal(map[string]any{"message": map[string]any{
		"token":        msg.Token,
		"notification": map[string]string{"title": msg.Title, "body": msg.Body},
		"data":         msg.Data,
		"android":      android,
	}})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.sendURL, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	res, err := f.client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode == http.StatusOK {
		return nil
	}
	if res.StatusCode == http.StatusUnauthorized {
		// Next time with a new token.
		f.mu.Lock()
		f.access = ""
		f.mu.Unlock()
	}
	if res.StatusCode == http.StatusNotFound || strings.Contains(string(body), "UNREGISTERED") {
		return errPushGone
	}
	return fmt.Errorf("FCM: %s: %s", res.Status, body)
}
