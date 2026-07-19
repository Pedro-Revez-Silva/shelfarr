# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Pin the exact multi-architecture SDK manifest. A Shelfarr release must not
# silently acquire a different compiler or runtime pack on a later rebuild.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0.302-noble@sha256:ed034a8bf0b24ded0cbbac07e17825d8e9ebfe21e308191d0f7421eaf5ad4664 AS companion-build
ARG TARGETARCH
ARG APP_VERSION=0.0.0

WORKDIR /source
COPY global.json ./
COPY src/Shelfarr.Libation.Companion/Shelfarr.Libation.Companion.csproj ./
COPY src/Shelfarr.Libation.Companion/packages.lock.json ./
RUN dotnet restore Shelfarr.Libation.Companion.csproj --locked-mode
COPY src/Shelfarr.Libation.Companion/ ./
RUN case "${TARGETARCH}" in \
      amd64) dotnet_arch=x64 ;; \
      arm64) dotnet_arch=arm64 ;; \
      *) echo "Unsupported target architecture: ${TARGETARCH}" >&2; exit 64 ;; \
    esac \
    && app_version="${APP_VERSION#v}" \
    && if [ -z "${app_version}" ]; then app_version=0.0.0; fi \
    && dotnet publish Shelfarr.Libation.Companion.csproj \
    --configuration Release \
    --output /out \
    --os linux \
    --arch "${dotnet_arch}" \
    --no-restore \
    --self-contained true \
    -p:Version="${app_version}" \
    -p:ContinuousIntegrationBuild=true \
    -p:Deterministic=true \
    -p:PublishSingleFile=true \
    -p:PublishTrimmed=false

# Ship a machine-readable snapshot of the exact unmodified Libation source
# beside its object code. This does not rely on the upstream tag remaining
# available after Shelfarr has distributed the companion image.
RUN git init --quiet /tmp/libation-source \
    && install -d /source-artifacts \
    && git -C /tmp/libation-source remote add origin https://github.com/rmcrackan/Libation.git \
    && git -C /tmp/libation-source fetch --quiet --depth 1 origin 07c2f2b2a1deb8c57601c2b131aba30c95be3097 \
    && test "$(git -C /tmp/libation-source rev-parse FETCH_HEAD)" = "07c2f2b2a1deb8c57601c2b131aba30c95be3097" \
    && git -C /tmp/libation-source archive \
      --format=tar.gz \
      --prefix=Libation-13.5.1/ \
      --output=/source-artifacts/Libation-13.5.1-source.tar.gz \
      FETCH_HEAD \
    && printf '%s  %s\n' \
      7391b9e4e34375e5d134932246ce0a50e0561efe1a24c2a3aa8f32a1217fac9f \
      /source-artifacts/Libation-13.5.1-source.tar.gz \
      | sha256sum --check --strict

# Keep this exact tag and manifest digest in sync with THIRD_PARTY_NOTICES.md.
FROM rmcrackan/libation:13.5.1@sha256:71b9db4bbda7d7e14bb9f5efcdcfe980915c90867599bc0d512d958069fb3da0

USER root
RUN test -x /libation/LibationCli \
    && command -v script >/dev/null \
    && command -v setpriv >/dev/null \
    && install -d -o 1000 -g 1000 -m 0700 /control \
    && install -d -o 1000 -g 1000 -m 0755 /companion/SOURCES

COPY --from=companion-build --chown=1000:1000 /out/ /companion/
COPY --chmod=0555 docker/login-wrapper.sh /companion/login-wrapper.sh
COPY --chmod=0555 docker/entrypoint.sh /companion/entrypoint.sh
COPY --chown=1000:1000 THIRD_PARTY_NOTICES.md /companion/THIRD_PARTY_NOTICES.md
COPY --chown=1000:1000 LICENSES/Libation-GPL-3.0.txt /companion/LICENSES/Libation-GPL-3.0.txt
COPY --chown=1000:1000 LICENSES/Libation-GPL-3.0.txt /companion/LICENSES/Shelfarr-GPL-3.0.txt
COPY --from=companion-build --chown=1000:1000 /source-artifacts/Libation-13.5.1-source.tar.gz /companion/SOURCES/Libation-13.5.1-source.tar.gz

ENV ASPNETCORE_URLS=http://0.0.0.0:8080 \
    DOTNET_EnableDiagnostics=0 \
    LIBATION_FILES_DIR=/config \
    LIBATION_BOOKS_DIR=/data \
    LIBATION_IN_PROGRESS_DIR=/config/in-progress \
    COMPANION_STATE_DIR=/config/shelfarr-companion \
    COMPANION_TOKEN_FILE=/control/token

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD ["/companion/Shelfarr.Libation.Companion", "--healthcheck"]
ENTRYPOINT ["/companion/entrypoint.sh"]
