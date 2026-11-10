# Bauen mit make docker oder make build-android, siehe README.

ARG VERSION=0.0.0
ARG BUILD_NUMBER=0

# Flutter und der Quelltext der App, gemeinsame Grundlage für Web und Android.
FROM debian:bookworm-slim AS flutter
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils
RUN git clone --depth 1 --branch 3.44.8 https://github.com/flutter/flutter.git /flutter
ENV PATH=/flutter/bin:$PATH
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./

# Leeres APP_URL: Die Web-App spricht mit dem Server, der sie ausgeliefert hat.
FROM flutter AS web
ARG VERSION
ARG BUILD_NUMBER
RUN flutter build web --release --build-name=$VERSION --build-number=$BUILD_NUMBER --dart-define=APP_URL=

FROM flutter AS android
ARG VERSION
ARG BUILD_NUMBER
ARG APP_URL
ENV ANDROID_HOME=/android-sdk
RUN apt-get install -y --no-install-recommends openjdk-17-jdk-headless
RUN curl -fsSL -o /tmp/tools.zip https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip \
    && mkdir -p $ANDROID_HOME/cmdline-tools \
    && unzip -q /tmp/tools.zip -d $ANDROID_HOME/cmdline-tools \
    && mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest \
    && rm /tmp/tools.zip
RUN yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses > /dev/null
# Der Release-Schlüssel kommt als Build-Secret und landet so in keiner Image-Schicht.
RUN --mount=type=secret,id=android_keystore,target=/src/app/android/app/release.keystore \
    --mount=type=secret,id=android_key_properties,target=/src/app/android/key.properties \
    test -n "$APP_URL" \
    && flutter build apk --release --build-name=$VERSION --build-number=$BUILD_NUMBER --dart-define=APP_URL=$APP_URL

FROM golang:1.27.3-alpine AS backend
ARG VERSION
ARG BUILD_NUMBER
WORKDIR /src/backend
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=$VERSION+$BUILD_NUMBER" -o /kintura ./cmd/kintura

FROM alpine:3.22 AS runtime
RUN apk add --no-cache ca-certificates \
    && adduser -D -H kintura \
    && mkdir /data \
    && chown kintura /data
WORKDIR /app
COPY --from=backend /kintura ./kintura
COPY --from=web /src/app/build/web ./web
ENV DATA_DIR=/data
VOLUME /data
USER kintura
EXPOSE 8080
CMD ["./kintura"]

# Nur die APK als Datei, für make build-android.
FROM scratch AS apk
ARG VERSION
ARG BUILD_NUMBER
COPY --from=android /src/app/build/app/outputs/flutter-apk/app-release.apk /kintura-${VERSION}-${BUILD_NUMBER}.apk

FROM runtime AS production
