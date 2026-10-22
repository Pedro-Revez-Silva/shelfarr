# syntax=docker/dockerfile:1
# check=error=true

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.3.12
FROM docker.io/library/ruby:$RUBY_VERSION-slim-bookworm AS base

WORKDIR /rails

RUN apt-get update -qq && \
    apt-get upgrade -y -qq && \
    apt-get install --no-install-recommends -y curl ffmpeg libjemalloc2 libvips sqlite3 gosu && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

FROM golang:1.27.3 AS thruster-build
WORKDIR /source
RUN git init . && git remote add origin https://github.com/basecamp/thruster.git && \
    git fetch --depth 1 origin 97dd28dc956e79830ff82c3e435c7d2d56977720 && git checkout --detach FETCH_HEAD && \
    go get golang.org/x/net@v0.60.0 github.com/klauspost/compress@v1.18.7 && \
    go test ./...
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/thrust ./cmd/thrust

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock vendor ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

COPY . .

# Inject version from build arg (set by CI when building from a tag)
ARG APP_VERSION=""
RUN if [ -n "$APP_VERSION" ]; then echo "$APP_VERSION" > VERSION; fi

# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

FROM base

# These can be modified at runtime via PUID/PGID environment variables
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
# Note: USER directive removed - entrypoint handles privilege dropping via gosu
# This allows PUID/PGID to work by modifying the rails user at container start

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Preserve the gem launcher while replacing its bundled native executable.
COPY --from=thruster-build /out/thrust /usr/local/bin/thrust-backport
RUN bundle exec ruby -rfileutils -e 'spec = Gem::Specification.find_by_name("thruster"); platform = [:cpu, :os].map { |key| Gem::Platform.local.send(key) }.join("-"); FileUtils.install("/usr/local/bin/thrust-backport", File.join(spec.full_gem_path, "exe", platform, "thrust"), mode: 0755)' && \
    rm /usr/local/bin/thrust-backport

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
# Set HTTP_PORT env var to change the listening port (default: 80)
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
