# Eigene Werte stehen in .env oder z. B.: make app APP_URL=http://192.168.1.10:1316
-include .env
APP_URL ?= http://localhost:1316
WEB_PORT ?= 5000
AIR_VERSION ?= v1.67.4

# Unter Windows immer cmd.exe nutzen, auch wenn ein sh im PATH liegt.
ifeq ($(OS),Windows_NT)
SHELL := cmd.exe
.SHELLFLAGS := /c
EXE := .exe
RM_DIR = if exist $(subst /,\,$(1)) rmdir /s /q $(subst /,\,$(1))
READ_FILE = type $(subst /,\,$(1))
else
EXE :=
RM_DIR = rm -rf $(1)
READ_FILE = cat $(1)
endif

# Die Version steht in der Datei VERSION, die Build-Nummer ist die Anzahl der Commits.
VERSION := $(strip $(shell $(call READ_FILE,VERSION)))
BUILD_NUMBER ?= $(or $(shell git rev-list --count HEAD),0)
DOCKER_ARGS = --build-arg VERSION=$(VERSION) --build-arg BUILD_NUMBER=$(BUILD_NUMBER)
APK_SECRET_ARGS = --secret id=android_keystore,src=app/android/app/release.keystore --secret id=android_key_properties,src=app/android/key.properties
APK_SECRETS = $(if $(wildcard app/android/key.properties),$(APK_SECRET_ARGS))
# Welcher Teil der Version beim Deploy steigt: patch, minor oder major.
BUMP ?= patch

# Auf dem Handy waere localhost das Handy selbst.
CHECK_APP_URL = $(if $(or $(findstring localhost,$(APP_URL)),$(findstring 127.0.0.1,$(APP_URL))),$(error Die APK braucht die echte Adresse des Backends: APP_URL in .env setzen))

.DEFAULT_GOAL := help
.PHONY: help dev backend app tools test test-backend test-app test-integration build build-backend build-app build-android build-windows build-windows-installer docker deploy-dev docker-website deploy deploy-android deploy-windows deploy-website android-key clean

help:
	@echo make dev            - Backend und App zusammen starten
	@echo make backend        - Backend mit Live-Reload starten, laedt backend/.env
	@echo make app            - App in Chrome starten
	@echo make tools          - Air installieren
	@echo make test           - Alle Tests ausfuehren
	@echo make test-integration - Backend-Tests gegen Postgres und S3, braucht Docker
	@echo make build          - Backend und Web-App bauen
	@echo make docker         - Docker-Image mit Backend und Web-App bauen
	@echo make build-android  - Android-APK in Docker bauen und zum Testen in builds ablegen
	@echo make build-windows  - Windows-App als Zip bauen und zum Testen in builds ablegen, nur unter Windows
	@echo make build-windows-installer - Windows-Installer bauen und in builds ablegen, braucht Inno Setup
	@echo make deploy-dev     - Image mit Backend und Web-App bauen und als DOCKER_HUB_URL:dev pushen
	@echo make deploy         - Neue Hauptversion und Tag web-v..., GitHub baut das Docker-Image
	@echo make deploy-android - Aktuelle Hauptversion mit neuer Build-Nummer, GitHub baut die APK als Release
	@echo make deploy-windows - Aktuelle Hauptversion mit neuer Build-Nummer, GitHub baut das Windows-Release
	@echo make deploy-website - Neue Build-Nummer, GitHub baut das Website-Image mit nginx
	@echo make docker-website - Website-Image mit nginx lokal bauen, zum Testen oder eigenen Betrieb
	@echo make android-key    - Release-Schluessel der Android-App einmalig erzeugen
	@echo make clean          - Build-Ausgaben loeschen, backend/data bleibt erhalten

dev:
	$(MAKE) -j2 backend app

backend:
	cd backend && air

app:
	cd app && flutter run -d chrome --web-port $(WEB_PORT) --dart-define=APP_URL=$(APP_URL)

tools:
	go install github.com/air-verse/air@$(AIR_VERSION)

test: test-backend test-app

test-backend:
	cd backend && go test ./...

test-app:
	cd app && flutter test

test-integration: export TEST_DATABASE_URL = postgres://kintura:kintura@localhost:55432/kintura?sslmode=disable
test-integration: export TEST_S3_ENDPOINT = http://localhost:59000
test-integration: export TEST_S3_BUCKET = kintura-test
test-integration: export TEST_S3_ACCESS_KEY = kintura
test-integration: export TEST_S3_SECRET_KEY = kintura-secret
test-integration:
	cd backend && docker compose -f compose.test.yaml up -d --wait
	cd backend && go test -count=1 ./...
	cd backend && docker compose -f compose.test.yaml down

build: build-backend build-app

build-backend:
	cd backend && go build -ldflags "-X main.version=$(VERSION)+$(BUILD_NUMBER)" -o bin/kintura$(EXE) ./cmd/kintura

build-app:
	cd app && flutter build web --build-name=$(VERSION) --build-number=$(BUILD_NUMBER) --dart-define=APP_URL=$(APP_URL)

docker:
	docker build $(DOCKER_ARGS) --target production -t kintura:$(VERSION) .


# Ueber Compose, weil Umlaute in Argumenten von make unter Windows kaputtgehen.
docker-website:
	cd website && docker compose --env-file ../.env build

build-android:
	$(CHECK_APP_URL)
	docker build $(DOCKER_ARGS) $(APK_SECRETS) --build-arg APP_URL=$(APP_URL) --target apk --output type=local,dest=builds .
	@echo Abgelegt: builds/kintura-$(VERSION)-$(BUILD_NUMBER).apk

# Ohne Docker: Flutter baut Windows-Apps nur auf einem Windows-System.
build-windows:
	$(if $(filter Windows_NT,$(OS)),,$(error build-windows geht nur unter Windows))
	cd app && flutter build windows --release --build-name=$(VERSION) --build-number=$(BUILD_NUMBER) --dart-define=APP_URL=$(APP_URL)
	powershell -NoProfile -Command "New-Item -ItemType Directory -Force builds | Out-Null; Compress-Archive -Force -Path app/build/windows/x64/runner/Release/* -DestinationPath builds/kintura-$(VERSION)-$(BUILD_NUMBER)-windows.zip"
	@echo Abgelegt: builds/kintura-$(VERSION)-$(BUILD_NUMBER)-windows.zip

build-windows-installer: build-windows
	powershell -NoProfile -ExecutionPolicy Bypass -File app/windows/build-installer.ps1 -Version $(VERSION) -Build $(BUILD_NUMBER)
	@echo Abgelegt: builds/kintura-$(VERSION)-$(BUILD_NUMBER)-windows-setup.exe

deploy:
	cd backend && go run ./cmd/release web $(BUMP)

deploy-android deploy-windows deploy-website:
	cd backend && go run ./cmd/release $(patsubst deploy-%,%,$@)

deploy-dev:
	$(if $(DOCKER_HUB_URL),,$(error DOCKER_HUB_URL fehlt, in .env setzen, z. B. DOCKER_HUB_URL=meinname/kintura))
	docker build $(DOCKER_ARGS) --target production -t $(DOCKER_HUB_URL):dev .
	docker push $(DOCKER_HUB_URL):dev

android-key:
	cd backend && go run ./cmd/androidkey

clean:
	$(call RM_DIR,backend/bin)
	$(call RM_DIR,backend/tmp)
	cd app && flutter clean
