package main

import "testing"

func TestNextBuildContinuesAcrossVersions(t *testing.T) {
	tags := []string{"website-v1.0.4", "website-v1.0.5-2", "website-v1.0.6-10", "website-v1.0.6-9", "android-v1.0.6-40"}
	if got := nextBuild(tags, "website"); got != 11 {
		t.Errorf("website: %d", got)
	}
	if got := nextBuild([]string{"website-v1.0.4"}, "website"); got != 1 {
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

func TestRunRefusesUnknownArguments(t *testing.T) {
	for _, args := range [][]string{nil, {"web", "patch"}, {"android"}, {"patch", "minor"}} {
		if err := run(args); err == nil || err.Error() != usage {
			t.Errorf("%v: %v", args, err)
		}
	}
}
