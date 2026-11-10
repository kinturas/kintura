# Kintura

Termine, Aufgaben, Listen und mehr für den ganzen Kreis.
Frontend: Flutter (`app/`), Backend: Go mit SQLite oder Postgres (`backend/`).

## Starten

Backend:

```powershell
cd backend
go run ./cmd/kintura
```

Ohne `SMTP_HOST` werden Mails samt Login-Code nur ins Server-Log geschrieben.

App:

```powershell
cd app
flutter run -d chrome
```

Die App spricht standardmäßig mit `http://localhost:8080`. Andere Adresse:
`flutter run --dart-define=APP_URL=http://192.168.1.10:8080`
(der Android-Emulator erreicht den PC über `http://10.0.2.2:8080`).

## Version

Die Version steht in der Datei `VERSION`. `make build` gibt sie an App und Backend
weiter, die Build-Nummer ist die Anzahl der Commits. Das Backend nennt seine Version
unter `GET /api/version`, ohne `make build` heißt sie dort `dev`.

## Docker

`make docker` baut das Image `kintura:<version>` mit Backend und Web-App. `make build-android` baut zum Testen nur die
Android-APK in Docker und legt sie als `builds/kintura-<version>-<build>.apk` ab, ohne lokales Android-SDK. Die APK spricht
mit der `APP_URL` aus der `.env`, sie muss also vom Handy aus erreichbar sein. `make build-windows` legt die Windows-App als Zip ebenfalls
in `builds` ab. Das läuft ohne Docker und nur unter Windows mit lokalem Flutter, weil Flutter Windows-Apps nur dort bauen kann.
`make build-windows-installer` legt dort zusätzlich einen Installer als einzelne Datei ab und braucht Inno Setup (`winget install JRSoftware.InnoSetup`).

```powershell
docker run -p 1316:8080 -v kintura-data:/data -e APP_URL=http://192.168.1.10:1316 kintura:1.0.0
```

Die Web-App liegt unter `/` und spricht mit demselben Server. Datenbank und Dateien liegen im Volume unter `/data`.

`make deploy-dev` baut dasselbe Image wie `make docker` und pusht es als `$DOCKER_HUB_URL:dev`.
`DOCKER_HUB_URL` steht in der `.env`, etwa `DOCKER_HUB_URL=meinname/kintura`; vorher einmal `docker login` ausführen.

## Deploy

Jeder Befehl setzt einen Tag und pusht ihn, den Rest erledigt GitHub Actions ([deploy.yml](.github/workflows/deploy.yml)).
Es muss auf `main` alles committet sein. Nur `make deploy` erhöht die Hauptversion in `VERSION`. Android und Windows nehmen die aktuelle
Hauptversion und zählen je eine eigene Build-Nummer hoch, die auch bei einer neuen Hauptversion weiterläuft.

| Befehl | Tag | Ergebnis |
| --- | --- | --- |
| `make deploy` | `web-v1.2.3` | Image `ghcr.io/kinturas/kintura:1.2.3` und `:latest` |
| `make deploy-android` | `android-v1.2.3-7` | APK als GitHub-Release |
| `make deploy-windows` | `windows-v1.2.3-4` | Installer als GitHub-Release |
| `make deploy-website` | `website-v1.2.3-5` | Website als GitHub Pages |

Standardmäßig steigt die letzte Stelle der Hauptversion, sonst etwa `make deploy BUMP=minor` oder `BUMP=major`.
Android und Windows brauchen die Adresse des Backends als Repository-Variable `APP_URL` in GitHub, im Betrieb `https://app.kintura.de`.

## Website

`website/` ist eine eigenständige statische Seite, unabhängig vom Backend. Die Anmelde-Links zeigen auf die Repository-Variable
`APP_URL`, lokal auf `APP_URL` aus der `.env`.

`make deploy-website` zählt wie Android und Windows eine eigene Build-Nummer hoch, GitHub veröffentlicht die Seite dann als GitHub Pages.
Nach jedem Android- oder Windows-Deploy wird sie automatisch neu veröffentlicht, damit die Download-Links stimmen. Die Builds stehen in
`website/public/releases.json`: `make deploy-android` und `make deploy-windows` tragen ihren Build dort ein und committen das mit,
die Links stimmen also auch beim lokalen Bauen. Schlägt ein Build in GitHub fehl, muss sein Eintrag von Hand wieder raus.

Für GitHub Pages einmalig einrichten:

- Settings, Pages, Source auf **GitHub Actions** stellen. Eine eigene Domain wird dort ebenfalls eingetragen.
- Repository-Variablen `CONTENT_IMPRESSUM` und `CONTENT_DATENSCHUTZ` mit dem ganzen Markdown anlegen (Settings, Secrets and variables,
  Actions, Variables; mehrzeilig erlaubt). Ohne sie bricht der Deploy ab, damit nie die Beispieldaten online gehen.
- Die Datenschutzerklärung muss GitHub als Hoster nennen: GitHub, Inc. in den USA speichert die IP-Adressen der Besucher in Zugriffsprotokollen.
- Eigene HTTP-Header gehen auf Pages nicht. Die Content-Security-Policy steht deshalb auch als `<meta>`-Tag in den Seiten.

Das Docker-Image mit nginx (`website/Dockerfile`) bleibt zum lokalen Testen und für einen eigenen Betrieb. Lokal startet
`docker compose --env-file ../.env up --build` im Ordner `website` die Seite auf Port 8088.

```powershell
make docker-website
docker run -p 8088:80 kintura-website
```

Impressum und Datenschutz stehen als Markdown in `website/content/impressum.md` und `website/content/datenschutz.md`, im Repository nur mit
Beispieldaten. `page.js` lädt sie beim Aufruf der Seite. Im Image liegen sie unter `/usr/share/nginx/html/content`, im Betrieb werden sie dort
mit den echten Dateien überdeckt, ohne neuen Build:

```powershell
docker run -p 8088:80 -v ${PWD}/content:/usr/share/nginx/html/content:ro kintura-website
```

Verstanden werden `#`-Überschriften, Absätze, Listen mit `- `, `**fett**`, `*kursiv*` und `[Links](https://…)`. Ein einfacher Zeilenumbruch bleibt
ein Zeilenumbruch, etwa in einer Anschrift.

Statt der Dateien geht auch der ganze Inhalt als Umgebungsvariable: `CONTENT_IMPRESSUM` und `CONTENT_DATENSCHUTZ`, allgemein
`CONTENT_<NAME>` für `content/<name>.md`. Beim Start des Containers schreibt `website/content-from-env.sh` sie in die Dateien; leere Variablen
zählen nicht. Mit einem schreibgeschützten Volume auf `content` zusammen bricht der Start ab. In Compose geht mehrzeilig mit `|`:

```yaml
environment:
  CONTENT_IMPRESSUM: |
    # Impressum

    ## Angaben gemäß § 5 DDG

    Max Mustermann
    Musterstraße 1
```

Die Download-Links setzt die Seite aus `REPO_URL` und den Einträgen in `releases.json` zusammen. Lokal steht `REPO_URL` in der `.env`, in GitHub gilt das
aktuelle Repository, solange keine Repository-Variable `REPO_URL` gesetzt ist.

## Android-Release-Schlüssel

`make android-key` erzeugt einmalig `app/android/app/release.keystore` und `app/android/key.properties` mit zufälligem Passwort.
Beide Dateien sind nicht im Git und müssen sicher gesichert werden: Ohne sie kann die installierte App nie wieder aktualisiert werden.

Für GitHub Actions gehören sie als Repository-Secrets hinterlegt. Diese Befehle legen den Inhalt in die Zwischenablage:

```powershell
# Secret ANDROID_KEYSTORE_BASE64
[Convert]::ToBase64String([IO.File]::ReadAllBytes("app/android/app/release.keystore")) | Set-Clipboard
# Secret ANDROID_KEY_PROPERTIES
Get-Content app/android/key.properties -Raw | Set-Clipboard
```

## Konfiguration des Backends

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `ADDR` | `:8080` | Adresse des HTTP-Servers |
| `DATA_DIR` | `data` | Ablage für die SQLite-Datenbank und lokale Dateien |
| `DB_DRIVER` | `sqlite` | Datenbank: `sqlite` oder `postgres` |
| `DATABASE_URL` | | Bei Postgres die Adresse, etwa `postgres://user:pass@host:5432/kintura` |
| `STORAGE_DRIVER` | `local` | Dateiablage: `local` (in `DATA_DIR/files`) oder `s3` |
| `S3_BUCKET` | | Bei S3 der Bucket, er muss schon existieren |
| `S3_CREATE_BUCKET` | `false` | `true` legt einen fehlenden Bucket an, etwa auf einem eigenen Dienst |
| `S3_ENDPOINT` | `https://s3.amazonaws.com` | Adresse des Dienstes, auch S3-kompatible wie MinIO oder RustFS |
| `S3_REGION` | | Region des Buckets |
| `S3_ACCESS_KEY`, `S3_SECRET_KEY` | | Zugangsdaten; ohne sie gilt die Rolle der Maschine (AWS IAM) |
| `S3_PREFIX` | | Ordner im Bucket, für mehrere Installationen in einem Bucket |
| `S3_PATH_STYLE` | `false` | `true` für Dienste ohne Bucket-Subdomains |
| `APP_URL` | `http://localhost:8080` | Basis für Links in Mails und Downloads |
| `CORS_ORIGIN` | `*` | Erlaubter Ursprung der Web-App |
| `SMTP_HOST`, `SMTP_PORT` | Port `587` | Mailserver (Port 465 nutzt direktes TLS) |
| `SMTP_USER`, `SMTP_PASS` | | Zugangsdaten |
| `SMTP_FROM` | `SMTP_USER` | Absenderadresse |
| `ADMIN_API_KEY` | | API-Token des Admin-Dashboards, mindestens 16 Zeichen |
| `DEFAULT_TIMEZONE` | `Europe/Berlin` | Vorgabe für die Zeitzone neuer Termine (IANA-Name) |

Ein Beispiel für den Betrieb mit Postgres liegt in `example/`: `.env.example` nach `.env` kopieren, anpassen und dort
`docker compose up -d` starten.

Für den Betrieb außerhalb des Heimnetzes gehört das Backend hinter einen
HTTPS-Reverse-Proxy. Zur Sicherung `DATA_DIR` kopieren, bei Postgres und S3 die jeweiligen Dienste sichern.

Dateien laufen immer durch das Backend, das auch die Rechte prüft. Der Bucket muss also nicht öffentlich sein und sollte es
auch nicht. Beim Start prüft das Backend den Zugriff auf Datenbank und Bucket und bricht bei einer falschen Einstellung ab.

## Backend-Struktur

| Ordner | Inhalt |
| --- | --- |
| `backend/cmd/kintura` | Einstieg: liest die Umgebungsvariablen und startet den Server |
| `backend/internal/server` | HTTP-Routen und Fachlogik, das Admin-Dashboard in `admin/` |
| `backend/internal/database` | SQLite und Postgres, Migrationen in `migrations/` |
| `backend/internal/storage` | Dateiablage lokal und S3 |
| `backend/internal/mail` | Versand per SMTP oder ins Log |

## Datenbank und Migrationen

Das Schema entsteht und wächst über [goose](https://github.com/pressly/goose): Beim Start wendet das Backend an, was noch fehlt, und
merkt sich den Stand in `goose_db_version`. Für eine Änderung kommt eine neue, fortlaufend nummerierte Datei dazu, und zwar in beiden
Ordnern `migrations/sqlite` und `migrations/postgres`. Bestehende Dateien bleiben unverändert. Eine Datenbank aus der Zeit vor den
Migrationen wird beim Start abgelehnt, dafür `DATA_DIR` löschen oder die Datenbank neu anlegen.

Abfragen stehen nur einmal im Code, in SQL, das beide Datenbanken verstehen: Parameter als `?` oder `?1`, `ON CONFLICT` statt
`INSERT OR REPLACE`, `LOWER(name)` statt `COLLATE NOCASE`. Schalter sind in beiden Schemas ganze Zahlen. Daten von SQLite nach Postgres
zu übernehmen ist nicht vorgesehen.

## Admin-Dashboard

Das Backend liefert unter `/admin` ein Dashboard mit allen Kreisen, allen Mitgliedern, den Seiten und einem Fehler-Log aus.

Unter **Seiten** stehen Impressum und Datenschutzerklärung der App als Markdown. Sie liegen in der Tabelle `pages` und werden beim ersten
Start mit Beispieldaten aus `backend/internal/server/pages/*.md` angelegt; solange eine Seite noch den Beispieltext enthält, warnt das
Backend beim Start. Die App liest sie ohne Anmeldung über `GET /api/pages/{slug}`. Eine weitere Seite braucht einen Eintrag in
`defaultPages` (`pages.go`), eine Vorlage in `pages/` und einen Link in der App.
Zugang hat nur, wer das Flag `is_sysadmin` trägt. Das bekommt automatisch das erste Konto im System; bei bestehenden
Datenbanken das älteste.

- **Anmeldung per Mail:** wie in der App mit Code oder Link. Beim ersten Mal fragt das Dashboard einmalig nach dem Token
  aus `ADMIN_API_KEY`. Das Konto selbst wird in der App registriert.
- **Anmeldung per Token:** `/login/token` muss von Hand aufgerufen werden und ist nirgends verlinkt. Die Maske fragt nur
  den Token ab und meldet als `admin@kintura` an. Dieses Konto legt das Backend selbst an, per Mail ist es nicht
  erreichbar. Die Sitzung gilt 12 Stunden. Nach 10 Fehlversuchen in 15 Minuten ist der Token für alle gesperrt, bis das
  Zeitfenster abgelaufen ist.

Das Log enthält Serverfehler (5xx), fehlgeschlagene Mails und falsche Tokens mit Datum, Benutzer, Kreis, Endpunkt und
Meldung, aber keine Eingaben der Benutzer wie Anfrageinhalte oder Tokens. Einträge bleiben 90 Tage, höchstens die
letzten 10.000.

## Anmeldung

1. Die App schickt die E-Mail-Adresse an `POST /api/auth/request`; die Mail enthält Code und Link.
2. Mit dem Code bestätigt `POST /api/auth/verify`. Der Link öffnet eine Bestätigungsseite im Browser,
   währenddessen fragt die App `POST /api/auth/poll` ab. So funktioniert der Link auf allen Plattformen,
   auch wenn die Mail auf einem anderen Gerät geöffnet wird.
3. Bekannte Benutzer erhalten eine Sitzung. Neue Benutzer registrieren sich über `POST /api/auth/register`,
   dabei entsteht ihr Kreis mit ihnen als Admin. Eingeladene treten dem einladenden Kreis bei.

## Kreise

Jeder Kreis hat einen Typ, der seine Bezeichnung in App und Mails bestimmt: `family` (Familie, Standard), `friends`
(Freundeskreis), `relatives` (Verwandtschaft) oder `workgroup` (Arbeitsgruppe). „Kreis“ erscheint nur dort, wo noch kein
einzelner Kreis gemeint ist, etwa bei „Neuer Kreis“. Admins können den Typ in den Einstellungen ändern.

Mitglieder haben eine Rolle und unabhängig davon ein Admin-Flag. Nur das Flag berechtigt zur Verwaltung des Kreises. Wer
einen Kreis anlegt, wird `manager` und Admin. Admins können sich das Flag nicht selbst entziehen. Die Bezeichnung einer
Person ergibt sich allein aus Rolle und Typ und wird nicht gespeichert.

Eine Einladung lässt sich auf zwei Wegen annehmen: Die Person meldet sich mit der eingeladenen Adresse an, oder sie gibt den Code
aus der Einladungsmail an einen Admin weiter, der ihn unter „Code eingeben“ einträgt. Hat die Adresse noch kein Konto, fragt die App
dabei den Namen ab und legt es an; die Person bekommt in jedem Fall eine Mail, dass sie aufgenommen wurde. Der Code gilt 7 Tage und
für 5 Versuche, nur für diesen Kreis. „Erneut senden“ verschickt eine neue Mail mit neuem Code, der den alten ablöst. Pro Kreis und
Adresse gehen in 24 Stunden höchstens 5 Einladungsmails hinaus, auch wenn die Einladung dazwischen zurückgezogen wird.

Neben „Mitglied einladen“ legen Admins mit „Benutzer hinzufügen“ jemanden ohne E-Mail-Adresse an, etwa ein kleines Kind. So
ein Benutzer erscheint wie jedes Mitglied, bekommt aber keine Mails und kann kein Admin sein. Beim Bearbeiten stehen unter „Verwaltung“
drei Punkte, die nur für solche Benutzer erscheinen: „E-Mail hinzufügen“ schickt einen Code an die Adresse und ordnet sie mit diesem
Code zu. Ist die Adresse neu, wird daraus ein normales Konto. Hat sie schon ein Konto in einem anderen Kreis, übernimmt dieses das
Mitglied samt allem, was dazugehört. Nur im selben Kreis darf sie nicht schon vergeben sein. „Profil bearbeiten“ öffnet dieselbe Seite
wie das eigene Profil. „Anmeldecode erstellen“ zeigt einmalig einen Code, mit dem sich die Person auf der Anmeldeseite unter
„Alternative Anmeldung“ anmeldet (`POST /api/auth/code`). Er gilt einmal und höchstens 7 Tage, ein neuer Code löst den alten ab, und
gespeichert wird nur sein Hash. Nach dem Abmelden oder Ablauf der Sitzung braucht die Person einen neuen Code. Angemeldet kann sie
keinen Kreis anlegen, den Kreis nicht selbst verlassen und weder Adresse noch Mitteilungen einstellen. Anders als bei allen anderen
löscht das Entfernen so einen Benutzer endgültig samt seiner Daten, denn ohne Adresse könnte ihn niemand zurückholen; gemeinsame
Termine und Listen bleiben.

Den Kreis verlässt man über „Profil bearbeiten“, ganz unten. Konten werden dabei nie gelöscht.

- **Nur verlassen** und auch das Entfernen durch einen Admin deaktiviert nur die Mitgliedschaft. Nach einer neuen Einladung sind
  Profil, Termine und alles andere wieder da; Rolle und Admin-Flag bestimmt die Einladung.
  Admins sehen solche Personen weiter in der Mitgliederliste, als „Gelöscht“ markiert, und können sie von dort wieder einladen
  oder endgültig löschen. Letzteres entfernt dasselbe wie die nächste Option; das Konto bleibt für andere Kreise bestehen.
- **Verlassen und alle Daten löschen** löscht endgültig Profil, Nachrichten, Kommentare, hochgeladene Dateien, die eigenen
  Kalender-Einstellungen und Termine, die nur die Person selbst sah. Gemeinsame Termine und Listen bleiben für die anderen, ohne
  Namen. Private Termine anderer werden dadurch nie öffentlich.
- **Letzter Admin mit weiteren Mitgliedern:** kann nicht verlassen und muss zuerst jemand anderen zum Admin machen. Auch wer den
  Kreis verlassen hat und noch als „Gelöscht“ in der Liste steht, muss vorher endgültig gelöscht sein.
- **Letztes Mitglied:** bekommt den Hinweis, dass danach niemand mehr Zugang hat. Bei „Nur verlassen“ bleibt der Kreis bestehen und
  ist höchstens über den Support wieder erreichbar, offene Einladungen entfallen. Mit „alle Daten löschen“ wird der ganze Kreis gelöscht.

| Rolle | Familie | Andere Typen |
| --- | --- | --- |
| `manager` | Eltern | Manager |
| `user` | Erwachsenes Kind | User |
| `restrict_user` | Kind | Restricted |
| `guest` | kommt später mit dem Kiosk-Modus | kommt später mit dem Kiosk-Modus |

Das Profil gilt pro Kreis. Unter „Profil bearbeiten“ stehen Name, Familienrolle, E-Mail-Adresse, Geburtstag, Profilfarbe und
beliebig viele weitere Felder (Telefon, E-Mail, Handy, Telefon Arbeit, Sonstige, Adresse). Ein neuer Kreis startet mit Name und
Geburtstag des Kontos. Die anderen im Kreis sehen davon den Namen und die Farbe, im Geburtstagskalender auch den Geburtstag; die
übrigen Angaben liest bisher nur das Mitglied selbst. Die Anmelde-Adresse bleibt davon unberührt, ein Button fügt sie aber ins
Feld E-Mail-Adresse ein.

Darunter stehen im Profil die Einstellungen für alle Kreise:

- **E-Mail-Adresse:** die Anmelde-Adresse. Geändert wird sie erst mit einem Code, der an die neue Adresse geht; sie darf noch
  nicht vergeben sein. Die alte Adresse bekommt danach einen Hinweis.
- **Mitteilungen erhalten:** Ausgeschaltet gehen keine Erinnerungen mehr per Mail raus. Anmeldecodes kommen weiter an.
- **Dunkelmodus automatisch:** folgt dem Gerät. Ausgeschaltet entscheidet ein eigener Schalter. Das gilt pro Gerät und bleibt
  auch nach dem Abmelden.
- **Feedback:** schickt einen Text samt Name und Adresse per Mail an alle Sysadmins.
- **Über:** Version, Copyright und Datenschutzerklärung.
- **Benachrichtigungen verwalten, Hilfe und Sprache** kommen später.

Die Einstellungen haben die Reiter Mitglieder, den Kreis selbst, Kategorien und Farben. Ändern können dort nur Admins.

- **Farben:** die festen Stammfarben und die eigenen Farben des Kreises, jeweils nach Farbton geordnet. Eigene Farben
  haben Text und Farbwert. Beim Ändern ziehen alle mit, die sie nutzen; löschen lassen sie sich nur ungenutzt.
- **Mitglieder:** Mitglieder einladen und ihnen Rolle, Profilfarbe aus der Tabelle oder keine und das Recht zuweisen, die
  Farbe selbst im Profil zu ändern (Vorgabe: ja); für Admins selbst gilt diese Sperre nicht. Die Farbe gilt pro Kreis.
- **Kategorien:** anlegen, ändern, entfernen und sortieren, jeweils mit oder ohne Farbe. Neue Kreise starten mit
  „Allgemein“ und „Wichtig“. Termine ohne Kategorie oder mit einer Kategorie ohne Farbe zeigen die Farbe ihres
  Kalenders. Kategorien, die Termine verwenden, lassen sich nicht löschen.

## Kalender

Oben rechts wählt man die Ansicht (Tagebuch, Tag, 3 Tage, Woche, Monat) und öffnet die Kalenderverwaltung, die von rechts
hereingleitet. Dort gilt alles pro Benutzer und Kreis, nur die Kalenderbereinigung gilt für den ganzen Kreis.

Der Titel nennt Monat und Jahr und öffnet die Auswahl eines Tages. Im Tagebuch und in der Monatsansicht laufen die Wochen
frei durch, der Monat in der Mitte ist der aktuelle. In Tag, 3 Tage und Woche bewegt Scrollen die Stunden, dort bleiben Pfeile.

Das Tagebuch zeigt unter dem Monat eine fortlaufende Liste, die beim gewählten Tag beginnt. Weil Serien ohne Ende unendlich
viele Termine haben, lädt die App jeweils 6 Monate und beim Scrollen die nächsten. Nach zwei leeren Blöcken hört sie auf und
bietet „Weiter suchen“ an. Die Uhrzeit steht links neben dem farbigen Termin, nicht auf der Farbe.

Die Farbe eines Termins kommt von seiner Kategorie, falls sie eine hat. Sonst nimmt ein Termin mit genau einem Teilnehmer
dessen Farbe in diesem Kreis, und alles Übrige die Farbe des Kalenders.

Die Fußleiste hat „Heute“, „Hinzufügen“ und „Mitgliederfilter“. Der Filter zeigt aus dem Standardkalender nur Termine, bei
denen die gewählten Mitglieder Teilnehmer sind, Termine für alle bleiben. Wer sie angelegt hat, zählt dabei nicht. Alle
anderen Kalender blendet er aus. Er gilt, solange der Kalender offen ist.

Die Rolle Manager (in Familien Eltern) hat dort ganz oben zusätzlich „Alle Einträge anzeigen“, solange der Kalender offen
ist. Das blendet die Auswahl der Mitglieder aus und zeigt alle Termine des Kreises, auch solche nur für Teilnehmer und
Ersteller. Manager können diese Termine samt Anhängen öffnen und bearbeiten. Ohne den Schalter listet der Kalender auch für
sie und für Admins nur, was für jeden sichtbar ist oder wo sie Teilnehmer oder Ersteller sind.

- **Kalender:** der Standardkalender des Kreises, die Standardkalender anderer Kreise des Benutzers (nur lesend und nur mit
  dem, was er dort sehen darf), geplante Aufgaben, Schulferien, Feiertage pro Land, Geburtstage aus Profilen und besonderen
  Tagen, die übrigen besonderen Tage und Kalender per URL. Jeder hat eine Farbe aus der Farbtabelle des Kreises, Stammfarben oder
  eigene. Eine eigene Farbe, die ein Kalender des Kreises nutzt, lässt sich nicht löschen; hat sie nur jemand für einen eigenen
  Kalender gewählt, geht der beim Löschen zurück auf seine Standardfarbe. Die Farbe einer Kategorie geht vor.
  Die Farben von Standardkalender, geplanten Aufgaben, Schulferien, Feiertagen, Geburtstagen und besonderen Tagen gelten für alle
  im Kreis und nur die Rolle Manager ändert sie; das prüft das Backend. Die Farbe anderer Kreise und von Kalendern per URL wählt
  jeder selbst. Persönlich bleiben auch, welche Kalender jemand einblendet, die Bundesländer der Schulferien und die Länder der Feiertage.
  Wer noch nichts gewählt hat, startet in jedem Kreis mit Deutschland und Baden-Württemberg; alles abzuwählen bleibt bestehen.
  Feiertage sind ein einziger Kalender für alle gewählten Länder, der auch ohne gewähltes Land stehen bleibt, samt Farbe und Link. Die
  Länder wählt man auf seiner Seite. Bei mehreren Ländern nennen die Einträge ihr Land im Titel.
- **Ferien und Feiertage:** kommen von der öffentlichen OpenHolidays-API und werden 7 Tage zwischengespeichert. Fällt der
  Dienst aus, bleiben die alten Daten. Regionale Feiertage nennen ihre Region im Titel, etwa „Buß- und Bettag (Sachsen)“; ab 4 Regionen steht dort nur die Anzahl und die Liste in der Beschreibung. Schulferien tragen ihr Bundesland im Titel.
- **Kalender per URL:** Das Backend lädt die Adresse (auch `webcal://`) beim Anzeigen höchstens alle 30 Minuten, in den
  Optionen des Kalenders auch sofort. Adressen im eigenen Netz des Servers werden abgelehnt. Wiederholungen, die der Kalender nicht abbilden kann, zeigen nur ihren ersten Termin.
- **Freigabe-Link:** Standardkalender, Aufgaben, Geburtstage, besondere Tage, Schulferien und Feiertage lassen sich als ICS abonnieren.
  Wer den Link hat, sieht ohne Anmeldung, was der Ersteller sehen darf; Ferien und Feiertage nach dessen aktueller Auswahl, von
  letztem Jahr bis Ende nächsten Jahres. Der Link endet, wenn er gelöscht wird oder der Ersteller den Kreis verlässt. Die Rolle `restrict_user` (in Familien Kind) kann nur Schulferien und Feiertage freigeben, die App
  blendet die Freigabe sonst aus. Wer diese Rolle bekommt, verliert seine übrigen Links in diesem Kreis endgültig.
- **Rolle Kind:** Unter „Meine Kalender“ schaltet `restrict_user` Kalender nur an und aus. Die Seiten der einzelnen Kalender öffnen sich
  nicht, außer bei den Schulferien für die Bundesländer und den Feiertagen für die Länder, jeweils auch mit der Freigabe. Farben ändern und Kalender per URL hinzufügen lehnt auch das Backend ab.
- **Kalenderbereinigung:** Einzelne Termine, die länger als der eingestellte Zeitraum zurückliegen (Standard 1 Jahr),
  löscht das Backend stündlich endgültig samt Anhängen. Serien bleiben. Einstellen können das nur Admins.

Ein Tipp auf einen Eintrag öffnet immer die Seite „Termin“. Beim Standardkalender zeigt sie Zeit, Teilnehmer, Kalender,
Erinnerung, Ersteller und die letzte Änderung, darunter die Kommentare. Das Feld für einen neuen steht fest unten, am PC schickt Umschalt + Enter ihn ab. Oben rechts gibt es „Bearbeiten“ und
ein Menü mit „Duplikat“ (fragt nach dem Tag und öffnet das Formular wie beim Anlegen, erst „Speichern“ legt den Eintrag an),
„In mehrere Termine kopieren“ (bis zu 10 Tage, gleiche Uhrzeit, Serien werden zu einzelnen Terminen),
„In anderen Kreis kopieren“, „Teilen“ (als ICS-Datei, Serien komplett) und „Löschen“. Kopien gehören dem, der sie anlegt,
Anhänge und Kommentare bleiben beim Original. Im anderen Kreis bleiben nur die Teilnehmer, die dort Mitglied sind; ist
niemand übrig, nimmt die Kopie den Kopierenden und vergibt keine Kategorie. Andere Kalender zeigen auf dieser Seite nur
Zeit, Kalender, Ort und Beschreibung. Ihr Menü hat „Duplikat“, das wie oben einen einzelnen Termin im Standardkalender anlegt, und
„Teilen“ für diesen einen Termin. Das Duplikat gilt für alle, außer das Original war nur für Teilnehmer und Ersteller sichtbar:
Dann bleibt es privat bei dem, der es anlegt.

Termine werden auf einer eigenen Seite bearbeitet. Ändern, löschen und Anhänge verwalten darf nur, wer den Termin angelegt hat, und
die Rolle Manager (in Familien Eltern); das prüft das Backend. Termine ohne Ersteller, etwa weil er gelöscht wurde, bleiben den
Managern. Kommentieren, kopieren und teilen kann jeder, der den Termin sieht. Wer mit Änderungen zurückgeht, wird gefragt, ob sie verworfen werden sollen oder es weitergeht. Die Kopfzeile zeigt beim
Anlegen und Bearbeiten sofort die Farbe, die der Termin mit der aktuellen Auswahl bekommt.

- **Zeitzone:** Beginn und Ende gelten in der Zeitzone des Termins, angezeigt werden sie in der des Geräts. Die Vorgabe
  kommt aus `DEFAULT_TIMEZONE`. Zonen mit Sommerzeit behalten ihre Uhrzeit, ein Termin um 10:00 bleibt also um 10:00.
- **Teilnehmer und Sichtbarkeit:** Vorgabe sind alle Mitglieder, auch künftige. Bei „Dich und Teilnehmer“ (beim Bearbeiten „Teilnehmer und Ersteller“) sehen
  nur sie und wer den Termin angelegt hat ihn und seine Anhänge; das prüft das Backend.
- **Ersteller:** Steht für alle unter „Sichtbar für“, auch beim Anlegen. Nur Manager können ihn antippen und auf einer
  eigenen Seite ein anderes Mitglied oder sich selbst wählen; das gilt mit „Speichern“. Danach sieht der bisherige Ersteller einen
  Termin nur für Teilnehmer und Ersteller nicht mehr, wenn er nicht Teilnehmer und nicht Manager ist.
- **Wiederholung:** Eine Serie ist ein Eintrag, den das Backend beim Abruf in einzelne Termine auflöst. Änderungen gelten
  immer für die ganze Serie. Einen Tag, den ein Monat nicht hat, ersetzt sein letzter Tag.
- **Erinnerung:** Neue Termine starten ohne. Das Backend prüft jede Minute und schickt den Teilnehmern eine Mail. War es länger als 10 Minuten
  aus, entfallen verpasste Erinnerungen.
- **Ort:** Die Adresssuche startet nach einer kurzen Tipp-Pause ab 3 Zeichen und läuft über das Backend zum öffentlichen
  Dienst Photon von Komoot, der OpenStreetMap-Daten nutzt; der Suchbegriff geht also an diesen Dienst. Freitext geht auch.
  Der Knopf „In Google Maps öffnen“ braucht keinen API-Schlüssel.
- **Karte:** Ein Ort aus der Suche speichert seine Koordinaten und zeigt einen festen Kartenausschnitt. Die Kacheln lädt
  die App direkt von OpenStreetMap, dieser Dienst sieht also die IP-Adresse des Geräts und den Kartenausschnitt.
- **Anhänge:** Sie liegen wie andere Dateien in der Dateiablage, erscheinen aber nicht unter Dokumenten und sind nur über
  ihren Termin erreichbar.

## Mandantentrennung

Alle Fachdaten hängen an `/api/families/{fid}/...`. Die Middleware `member` in `backend/internal/server/server.go` prüft die
Mitgliedschaft, und jede Abfrage ist zusätzlich auf `family_id` eingeschränkt. `TestTenantIsolation` prüft das.

## Tests

```powershell
cd backend; go test ./...
cd app; flutter test
```

`go test` nutzt SQLite und das lokale Dateisystem. `make test-integration` startet mit Docker ein Postgres und ein RustFS (S3) aus
`backend/compose.test.yaml` und führt dieselben Tests dagegen aus. Dafür sorgen `TEST_DATABASE_URL` und `TEST_S3_ENDPOINT`.
