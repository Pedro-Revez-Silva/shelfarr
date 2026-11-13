# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Pin the exact multi-architecture SDK manifest. A Shelfarr release must not
# silently acquire a different compiler or runtime pack on a later rebuild.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0.404-noble@sha256:fe0fd4e93bd2fbb47c883b7a6369e5c8d3db8bf01cdc5981f6ee35fbdf3ff4fb AS companion-build
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
RUN git init --quiet /var/cache/libation-source \
    && install -d /source-artifacts \
    && git -C /var/cache/libation-source remote add origin https://github.com/rmcrackan/Libation.git \
    && git -C /var/cache/libation-source fetch --quiet --depth 1 origin 8003ae6f29ef28f057e1df994da13817dbdda670 \
    && test "$(git -C /var/cache/libation-source rev-parse FETCH_HEAD)" = "8003ae6f29ef28f057e1df994da13817dbdda670" \
    && git -C /var/cache/libation-source archive \
      --format=tar.gz \
      --prefix=Libation-14.2.5/ \
      --output=/source-artifacts/Libation-14.2.5-source.tar.gz \
      FETCH_HEAD \
    && printf '%s  %s\n' \
      c7f637fe147bb319aab5dfa337e060ed2cfea17e7ac3929297378e72a8a38fc4 \
      /source-artifacts/Libation-14.2.5-source.tar.gz \
      | sha256sum --check --strict

# Compile the exact shipped source with the serviced runtime; preserve the
# source archive and upstream application behavior.
RUN mkdir /libation-source && \
    tar -xzf /source-artifacts/Libation-14.2.5-source.tar.gz --strip-components=1 -C /libation-source && \
    case "${TARGETARCH}" in amd64) dotnet_arch=x64 ;; arm64) dotnet_arch=arm64 ;; *) exit 64 ;; esac && \
    dotnet publish /libation-source/Source/LibationCli/LibationCli.csproj \
      --configuration Release --runtime "linux-${dotnet_arch}" --self-contained true \
      -p:RuntimeFrameworkVersion=10.0.15 --output /libation-out

# Keep this exact tag and manifest digest in sync with THIRD_PARTY_NOTICES.md.
FROM rmcrackan/libation:14.2.5@sha256:7bb47a417311d154c6691747320d0b62ce15527280ad99f0e2a85ac9a6b07e40

USER root
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
# Service the upstream image's global runtime as well as the self-contained apps.
COPY --from=companion-build /usr/share/dotnet/shared/ /usr/share/dotnet/shared/
COPY --from=companion-build /usr/share/dotnet/host/ /usr/share/dotnet/host/
COPY --from=companion-build /usr/share/dotnet/dotnet /usr/share/dotnet/dotnet
ENV DOTNET_VERSION=10.0.15
RUN rm -rf /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.14 /usr/share/dotnet/shared/Microsoft.AspNetCore.App/10.0.14 /usr/share/dotnet/host/fxr/10.0.14
COPY --from=companion-build /libation-out/ /libation/
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
COPY --from=companion-build --chown=1000:1000 /source-artifacts/Libation-14.2.5-source.tar.gz /companion/SOURCES/Libation-14.2.5-source.tar.gz

ENV ASPNETCORE_URLS=http://0.0.0.0:8080 \
    DOTNET_EnableDiagnostics=0 \
    LIBATION_FILES_DIR=/config \
    LIBATION_BOOKS_DIR=/data \
    LIBATION_IN_PROGRESS_DIR=/config/in-progress \
    COMPANION_STATE_DIR=/config/shelfarr-companion \
    COMPANION_TOKEN_FILE=/control/token

EXPOSE 8080
# Probe the already-running companion. Do not start a second Kestrel listener.
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD ["/companion/Shelfarr.Libation.Companion", "--healthcheck"]
ENTRYPOINT ["/companion/entrypoint.sh"]
