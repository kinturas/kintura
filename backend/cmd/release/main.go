// Command release pushes a tag, which starts the matching job in
// .github/workflows/deploy.yml. It runs from the backend directory, see the
// deploy targets in the Makefile.
//
//	release web patch|minor|major   raises the version in the VERSION file
//	release android|windows|website current version with the next own build number
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	versionFile  = "../VERSION"
	releasesFile = "../website/public/releases.json"
)

// release is a build in the list the website makes its download links from.
type release struct {
	Tag       string `json:"tag"`
	Published string `json:"published"`
	Asset     string `json:"asset"`
}

const usage = "Aufruf: release web patch|minor|major oder release android|windows|website"

func nextVersion(current, part string) (string, error) {
	fields := strings.Split(current, ".")
	if len(fields) != 3 {
		return "", fmt.Errorf("Version %q hat nicht die Form 1.2.3", current)
	}
	var numbers [3]int
	for i, field := range fields {
		number, err := strconv.Atoi(field)
		if err != nil || number < 0 {
			return "", fmt.Errorf("Version %q hat nicht die Form 1.2.3", current)
		}
		numbers[i] = number
	}
	switch part {
	case "major":
		numbers = [3]int{numbers[0] + 1, 0, 0}
	case "minor":
		numbers = [3]int{numbers[0], numbers[1] + 1, 0}
	case "patch":
		numbers[2]++
	default:
		return "", fmt.Errorf("BUMP %q: erlaubt sind patch, minor und major", part)
	}
	return fmt.Sprintf("%d.%d.%d", numbers[0], numbers[1], numbers[2]), nil
}

// nextBuild is one above the highest build number of the platform. It continues
// across versions because Android refuses an update with a lower number.
func nextBuild(tags []string, platform string) int {
	pattern := regexp.MustCompile(`^` + platform + `-v\d+\.\d+\.\d+-(\d+)$`)
	highest := 0
	for _, tag := range tags {
		if match := pattern.FindStringSubmatch(tag); match != nil {
			if number, err := strconv.Atoi(match[1]); err == nil && number > highest {
				highest = number
			}
		}
	}
	return highest + 1
}

// assetName has to match what .github/workflows/deploy.yml uploads.
func assetName(platform, version string, build int) string {
	if platform == "windows" {
		return fmt.Sprintf("kintura-%s-%d-windows-setup.exe", version, build)
	}
	return fmt.Sprintf("kintura-%s-%d.apk", version, build)
}

// addRelease puts a build in front of the list the website reads.
func addRelease(list []byte, tag, asset string, published time.Time) ([]byte, error) {
	var releases []release
	if err := json.Unmarshal(list, &releases); err != nil {
		return nil, fmt.Errorf("%s: %w", releasesFile, err)
	}
	entry := release{Tag: tag, Published: published.UTC().Format(time.RFC3339), Asset: asset}
	out, err := json.MarshalIndent(append([]release{entry}, releases...), "", "  ")
	if err != nil {
		return nil, err
	}
	return append(out, '\n'), nil
}

func git(args ...string) (string, error) {
	out, err := exec.Command("git", args...).CombinedOutput()
	text := strings.TrimSpace(string(out))
	if err != nil {
		return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), text)
	}
	return text, nil
}

func pushTag(tag string) error {
	if _, err := git("tag", tag); err != nil {
		return err
	}
	// Atomic, so that no tag exists without its commit on the remote.
	if _, err := git("push", "--atomic", "origin", "HEAD:refs/heads/main", "refs/tags/"+tag); err != nil {
		git("tag", "-d", tag)
		return err
	}
	return nil
}

// publish commits the file and pushes it with the tag. The tree is known to be
// clean, so after a failure the reset only takes back what this function did.
func publish(tag, path, message string, content []byte) error {
	if err := os.WriteFile(path, content, 0o644); err != nil {
		return err
	}
	if _, err := git("add", path); err != nil {
		return err
	}
	if _, err := git("commit", "-m", message); err != nil {
		git("reset", "--hard", "HEAD")
		return err
	}
	if err := pushTag(tag); err != nil {
		git("reset", "--hard", "HEAD~1")
		return err
	}
	return nil
}

func releaseVersion(version string) (string, error) {
	tag := "web-v" + version
	return tag, publish(tag, versionFile, "release: web v"+version, []byte(version+"\n"))
}

func releaseBuild(platform, version string) (string, error) {
	// Builds from another machine count too.
	if _, err := git("fetch", "--tags", "origin"); err != nil {
		return "", err
	}
	tags, err := git("tag", "--list", platform+"-v*")
	if err != nil {
		return "", err
	}
	build := nextBuild(strings.Fields(tags), platform)
	tag := fmt.Sprintf("%s-v%s-%d", platform, version, build)
	if platform == "website" {
		return tag, pushTag(tag)
	}
	list, err := os.ReadFile(releasesFile)
	if err != nil {
		return "", err
	}
	content, err := addRelease(list, tag, assetName(platform, version, build), time.Now())
	if err != nil {
		return "", err
	}
	return tag, publish(tag, releasesFile, fmt.Sprintf("release: %s v%s-%d", platform, version, build), content)
}

func run(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf(usage)
	}
	platform := args[0]
	switch {
	case platform == "web" && len(args) == 2:
	case (platform == "android" || platform == "windows" || platform == "website") && len(args) == 1:
	default:
		return fmt.Errorf(usage)
	}
	branch, err := git("branch", "--show-current")
	if err != nil {
		return err
	}
	if branch != "main" {
		return fmt.Errorf("Deploys laufen nur von main, aktuell: %q", branch)
	}
	status, err := git("status", "--porcelain")
	if err != nil {
		return err
	}
	if status != "" {
		return fmt.Errorf("Es gibt nicht committete Änderungen, bitte erst committen:\n%s", status)
	}
	content, err := os.ReadFile(versionFile)
	if err != nil {
		return err
	}
	current := strings.TrimSpace(string(content))

	var tag string
	if platform == "web" {
		next, err := nextVersion(current, args[1])
		if err != nil {
			return err
		}
		tag, err = releaseVersion(next)
		if err != nil {
			return err
		}
	} else {
		tag, err = releaseBuild(platform, current)
		if err != nil {
			return err
		}
	}
	fmt.Printf("Tag %s gepusht, GitHub Actions baut jetzt.\n", tag)
	return nil
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
