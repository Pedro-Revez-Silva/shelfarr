# syntax=docker/dockerfile:1

ARG RAILS_IMAGE
ARG GO_IMAGE=docker.io/library/golang:1.27.4
ARG BUN_IMAGE=docker.io/oven/bun:1.4.4

FROM --platform=$BUILDPLATFORM ${BUN_IMAGE} AS web-build
WORKDIR /source/apps/web
COPY apps/web/package.json apps/web/bun.lock ./
RUN bun install --frozen-lockfile
COPY apps/web ./
COPY apps/design/assets/fonts /source/apps/design/assets/fonts
COPY app/javascript/consumer_progress_sync.js app/javascript/consumer_epub_places.js /source/app/javascript/
COPY vendor/javascript/consumer_reader_engine.js /source/vendor/javascript/
RUN bun run build:go --out /out/web

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS go-build
ENV GOTOOLCHAIN=local GOFLAGS=-mod=readonly CGO_ENABLED=0
WORKDIR /source
COPY apps/server/go.mod apps/server/go.sum ./
RUN go mod download
COPY apps/server ./
ARG TARGETARCH
RUN GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/ ./cmd/shelfarr-compat ./cmd/shelfarr-workflows ./cmd/shelfarr-http

FROM ${RAILS_IMAGE}
COPY --from=go-build /out/shelfarr-compat /out/shelfarr-workflows /out/shelfarr-http /usr/local/bin/
COPY --from=web-build /out/web /usr/local/share/shelfarr/web
LABEL org.shelfarr.packaging="experimental: Rails image plus Go checker, workflow and HTTP binaries and the static web build; the entrypoint and command are the production ones"
