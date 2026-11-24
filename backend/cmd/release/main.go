// Command release pushes a tag, which starts .github/workflows/deploy.yml. It runs
// from the backend directory, see the deploy targets in the Makefile.
//
//	release patch|minor|major   raises the version in the VERSION file and tags v1.2.3:
//	                            one release with the Docker image, the APK and the
//	                            Windows installer, then the website
//	release website             only the website, with the next own build number
package main

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

const versionFile = "../VERSION"

const usage = "Aufruf: release patch|minor|major oder release website"

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

// nextBuild is one above the highest build number of the website-v… tags.
func nextBuild(tags []string, prefix string) int {
	pattern := regexp.MustCompile(`^` + prefix + `-v\d+\.\d+\.\d+-(\d+)$`)
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

// releaseVersion commits the new version and pushes it with its tag. The tree is known
// to be clean, so after a failure the reset only takes back what this function did.
func releaseVersion(version string) (string, error) {
	tag := "v" + version
	if err := os.WriteFile(versionFile, []byte(version+"\n"), 0o644); err != nil {
		return "", err
	}
	if _, err := git("add", versionFile); err != nil {
		return "", err
	}
	if _, err := git("commit", "-m", "release: "+tag); err != nil {
		git("reset", "--hard", "HEAD")
		return "", err
	}
	if err := pushTag(tag); err != nil {
		git("reset", "--hard", "HEAD~1")
		return "", err
	}
	return tag, nil
}

func releaseWebsite(version string) (string, error) {
	// Builds from another machine count too.
	if _, err := git("fetch", "--tags", "origin"); err != nil {
		return "", err
	}
	tags, err := git("tag", "--list", "website-v*")
	if err != nil {
		return "", err
	}
	tag := fmt.Sprintf("website-v%s-%d", version, nextBuild(strings.Fields(tags), "website"))
	return tag, pushTag(tag)
}

func run(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf(usage)
	}
	switch args[0] {
	case "patch", "minor", "major", "website":
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
	if args[0] == "website" {
		tag, err = releaseWebsite(current)
	} else {
		var next string
		next, err = nextVersion(current, args[0])
		if err != nil {
			return err
		}
		tag, err = releaseVersion(next)
	}
	if err != nil {
		return err
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
