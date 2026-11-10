# Eigenständige Website, bauen mit make docker-website oder make deploy-website, siehe README.
FROM nginx:1.29-alpine

# Adresse der Web-App für die Anmelde-Links.
ARG APP_URL
# GitHub-Repository für die Download-Links.
ARG REPO_URL

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/
# Impressum und Datenschutz als Markdown mit Beispieldaten. Im Betrieb mit den echten
# Dateien überdecken, z. B. -v ./content:/usr/share/nginx/html/content:ro, oder den ganzen
# Inhalt in CONTENT_IMPRESSUM und CONTENT_DATENSCHUTZ übergeben, siehe content-from-env.sh.
COPY content/ /usr/share/nginx/html/content/
COPY content-from-env.sh /docker-entrypoint.d/40-content-from-env.sh
RUN test -n "$APP_URL" && test -n "$REPO_URL" \
    && sed -i -e "s|__APP_URL__|$APP_URL|g" -e "s|__REPO_URL__|$REPO_URL|g" /usr/share/nginx/html/index.html \
    && sed -i 's/\r$//' /docker-entrypoint.d/40-content-from-env.sh \
    && chmod +x /docker-entrypoint.d/40-content-from-env.sh
