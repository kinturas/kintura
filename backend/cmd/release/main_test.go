package main

import (
	"encoding/json"
	"testing"
	"time"
)

func TestAddReleasePutsNewestFirst(t *testing.T) {
	at := time.Date(2026, 11, 10, 8, 0, 0, 0, time.UTC)
	list, err := addRelease([]byte("[]\r\n"), "android-v1.0.6-1", assetName("android", "1.0.6", 1), at)
	if err != nil {
		t.Fatal(err)
	}
	list, err = addRelease(list, "windows-v1.0.6-2", assetName("windows", "1.0.6", 2), at)
	if err != nil {
		t.Fatal(err)
	}
	var releases []release
	if err := json.Unmarshal(list, &releases); err != nil {
		t.Fatal(err)
	}
	if len(releases) != 2 || releases[0].Tag != "windows-v1.0.6-2" || releases[1].Tag != "android-v1.0.6-1" {
		t.Fatalf("%+v", releases)
	}
	if got, want := releases[0].Asset, "kintura-1.0.6-2-windows-setup.exe"; got != want {
		t.Errorf("Windows: %s", got)
	}
	if got, want := releases[1].Asset, "kintura-1.0.6-1.apk"; got != want {
		t.Errorf("Android: %s", got)
	}
}

func TestAddReleaseRefusesBrokenList(t *testing.T) {
	if _, err := addRelease([]byte("kaputt"), "android-v1.0.6-1", "x.apk", time.Now()); err == nil {
		t.Error("kein Fehler")
	}
}

func TestNextBuildContinuesAcrossVersions(t *testing.T) {
	tags := []string{"android-v1.0.4", "android-v1.0.5-2", "android-v1.0.6-10", "android-v1.0.6-9", "windows-v1.0.6-40"}
	if got := nextBuild(tags, "android"); got != 11 {
		t.Errorf("android: %d", got)
	}
	if got := nextBuild(tags, "windows"); got != 41 {
		t.Errorf("windows: %d", got)
	}
	if got := nextBuild([]string{"android-v1.0.4"}, "android"); got != 1 {
		t.Errorf("ohne Build-Nummern: %d", got)
	}
}

func TestNextVersion(t *testing.T) {
	for _, tc := range []struct{ current, part, want string }{
		{"1.2.3", "patch", "1.2.4"},
		{"1.2.3", "minor", "1.3.0"},
		{"1.2.3", "major", "2.0.0"},
		{"1.9.9", "patch", "1.9.10"},
	} {
		got, err := nextVersion(tc.current, tc.part)
		if err != nil || got != tc.want {
			t.Errorf("%s %s: %q, %v", tc.current, tc.part, got, err)
		}
	}
	for _, tc := range []struct{ current, part string }{
		{"1.2", "patch"},
		{"1.2.x", "patch"},
		{"1.2.-3", "patch"},
		{"", "patch"},
		{"1.2.3", "gross"},
	} {
		if got, err := nextVersion(tc.current, tc.part); err == nil {
			t.Errorf("%q %s: %q ohne Fehler", tc.current, tc.part, got)
		}
	}
}
