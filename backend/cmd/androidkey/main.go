// Command androidkey creates the release key of the Android app with a random
// password. It runs from the backend directory and only once, because Android
// accepts updates only from the key an app was first installed with.
package main

import (
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

const (
	keystorePath   = "../app/android/app/release.keystore"
	propertiesPath = "../app/android/key.properties"
	alias          = "kintura"
	passwordEnv    = "KINTURA_KEY_PASSWORD"
)

func keytool() (string, error) {
	if path, err := exec.LookPath("keytool"); err == nil {
		return path, nil
	}
	if home := os.Getenv("JAVA_HOME"); home != "" {
		return filepath.Join(home, "bin", "keytool"), nil
	}
	return "", errors.New("keytool nicht gefunden: JDK in den PATH aufnehmen oder JAVA_HOME setzen")
}

func run() error {
	for _, path := range []string{keystorePath, propertiesPath} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%s existiert schon, der Schlüssel darf nicht ersetzt werden", path)
		}
	}
	tool, err := keytool()
	if err != nil {
		return err
	}
	password := rand.Text()
	cmd := exec.Command(tool, "-genkeypair", "-keystore", keystorePath, "-storetype", "PKCS12", "-alias", alias,
		"-keyalg", "RSA", "-keysize", "4096", "-validity", "10000", "-dname", "CN=Kintura", "-storepass:env", passwordEnv)
	cmd.Env = append(os.Environ(), passwordEnv+"="+password)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("keytool: %w\n%s", err, out)
	}
	properties := fmt.Sprintf("storeFile=release.keystore\nstorePassword=%s\nkeyPassword=%s\nkeyAlias=%s\n", password, password, alias)
	if err := os.WriteFile(propertiesPath, []byte(properties), 0o600); err != nil {
		os.Remove(keystorePath)
		return err
	}
	fmt.Println("Schlüssel erzeugt. Beide Dateien sicher aufbewahren:")
	fmt.Println("  app/android/app/release.keystore")
	fmt.Println("  app/android/key.properties")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
