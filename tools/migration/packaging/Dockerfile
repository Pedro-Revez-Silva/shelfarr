# syntax=docker/dockerfile:1

ARG RAILS_IMAGE
ARG GO_IMAGE=docker.io/library/golang:1.27.4

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS go-build
ENV GOTOOLCHAIN=local GOFLAGS=-mod=readonly CGO_ENABLED=0
WORKDIR /source
COPY apps/server/go.mod apps/server/go.sum ./
RUN go mod download
COPY apps/server ./
ARG TARGETARCH
RUN GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/ ./cmd/shelfarr-compat ./cmd/shelfarr-workflows

FROM ${RAILS_IMAGE}
COPY --from=go-build /out/shelfarr-compat /out/shelfarr-workflows /usr/local/bin/
LABEL org.shelfarr.packaging="experimental: Rails image plus Go checker and workflow binaries; the entrypoint and command are the production ones"
