#!/bin/sh
# Läuft beim Start des Containers, siehe Dockerfile. Jede Umgebungsvariable CONTENT_<NAME>
# ersetzt den Inhalt von content/<name>.md, etwa CONTENT_DATENSCHUTZ die Datei datenschutz.md.
# Leere Variablen zählen nicht, dann bleibt die Datei aus dem Image oder dem Volume.
set -eu

dir="${CONTENT_DIR:-/usr/share/nginx/html/content}"

# Nur die Namen, mehrzeilige Werte stören dabei nicht: printenv prüft jeden Namen nach.
for name in $(env | sed -n 's/^\(CONTENT_[A-Z0-9_]*\)=.*/\1/p' | sort -u); do
	[ "$name" = CONTENT_DIR ] && continue
	value="$(printenv "$name" || true)"
	[ -n "$value" ] || continue
	file="$dir/$(echo "${name#CONTENT_}" | tr 'A-Z_' 'a-z-').md"
	if ! printf '%s\n' "$value" > "$file" 2>/dev/null; then
		echo "$0: $file lässt sich nicht schreiben. $name und ein schreibgeschütztes Volume auf content schließen sich aus." >&2
		exit 1
	fi
	echo "$0: $file aus $name"
done
