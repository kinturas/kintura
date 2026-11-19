package server

import (
	"net/http"
	"strconv"
	"strings"
)

// minAppVersion is the oldest app the API still works with. Raise it to the version
// that is about to be released whenever a change breaks older apps, such as a route
// they use going away. Older apps are then told to update instead of failing.
const minAppVersion = "0.0.0"

// appVersionHeader carries the version of the app (1.2.3+45) with every request. Apps
// from before it send none and are let through: what they are is not known.
const appVersionHeader = "X-App-Version"

// parseAppVersion reads 1.2.3, with or without +build; ok is false for anything else.
func parseAppVersion(text string) (version [3]int, ok bool) {
	core, _, _ := strings.Cut(strings.TrimSpace(text), "+")
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return version, false
	}
	for i, part := range parts {
		n, err := strconv.Atoi(part)
		if err != nil || n < 0 {
			return version, false
		}
		version[i] = n
	}
	return version, true
}

// appTooOld tells whether an app that sent this version is older than min.
func appTooOld(sent, min string) bool {
	version, ok := parseAppVersion(sent)
	if !ok {
		return false
	}
	oldest, _ := parseAppVersion(min)
	for i := range version {
		if version[i] != oldest[i] {
			return version[i] < oldest[i]
		}
	}
	return false
}

// requireAppVersion turns away apps older than s.minAppVersion with 426, except for
// GET /api/version, from which the app learns what to do.
func (s *Server) requireAppVersion(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") && r.URL.Path != "/api/version" && appTooOld(r.Header.Get(appVersionHeader), s.minAppVersion) {
			writeJSON(w, http.StatusUpgradeRequired, map[string]string{
				"error":           "Diese Version von Kintura ist zu alt. Bitte installiere die neue Version.",
				"min_app_version": s.minAppVersion,
			})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// getVersion tells the version of the server, the oldest app it works with, and where
// apps can be downloaded, if the website is known.
func (s *Server) getVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"version":         s.version,
		"min_app_version": s.minAppVersion,
		"download_url":    s.websiteURL,
	})
}
