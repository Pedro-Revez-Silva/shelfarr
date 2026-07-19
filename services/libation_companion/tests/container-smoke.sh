#!/bin/sh
set -eu

image="${1:-shelfarr-libation-companion:smoke}"
suffix="$$"
container="shelfarr-libation-smoke-${suffix}"
config_volume="shelfarr-libation-smoke-config-${suffix}"
control_volume="shelfarr-libation-smoke-control-${suffix}"
books_volume="shelfarr-libation-smoke-books-${suffix}"

cleanup() {
  status="$?"
  if [ "${status}" -ne 0 ] && docker inspect "${container}" >/dev/null 2>&1; then
    docker logs "${container}" >&2 || true
  fi
  docker rm -f "${container}" >/dev/null 2>&1 || true
  docker volume rm "${config_volume}" "${control_volume}" "${books_volume}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_for_health() {
  port="$(docker port "${container}" 8080/tcp | sed 's/.*://')"
  attempt=0
  until curl --fail --silent "http://127.0.0.1:${port}/health" >/dev/null; do
    attempt=$((attempt + 1))
    if [ "${attempt}" -ge 30 ]; then
      docker logs "${container}"
      exit 1
    fi
    sleep 1
  done
}

assert_owner_marker() {
  expected="$1"
  path="$2"
  marker="${path%/}/.shelfarr-companion-owner"

  owner="$(docker exec -u 0 "${container}" stat -c '%u:%g' "${marker}")"
  test "${owner}" = "${expected}:${expected}"
  mode="$(docker exec -u 0 "${container}" stat -c '%a' "${marker}")"
  test "${mode}" = "600"
  value="$(docker exec -u "${expected}:${expected}" "${container}" sed -n '1p' "${marker}")"
  test "${value}" = "${expected}:${expected}"
}

assert_runtime_privileges() {
  expected_uid="$1"
  status="$(docker exec -u 0 "${container}" cat /proc/1/status)"

  uid="$(printf '%s\n' "${status}" | awk '/^Uid:/ { print $2 }')"
  gid="$(printf '%s\n' "${status}" | awk '/^Gid:/ { print $2 }')"
  no_new_privs="$(printf '%s\n' "${status}" | awk '/^NoNewPrivs:/ { print $2 }')"
  test "${uid}" = "${expected_uid}"
  test "${gid}" = "${expected_uid}"
  test "${no_new_privs}" = "1"

  for capability_set in CapInh CapPrm CapEff CapBnd CapAmb; do
    value="$(printf '%s\n' "${status}" | awk -v name="${capability_set}:" '$1 == name { print $2 }')"
    test "${value}" = "0000000000000000"
  done
}

docker build --quiet -t "${image}" . >/dev/null
image_healthcheck="$(docker image inspect --format '{{json .Config.Healthcheck.Test}}' "${image}")"
printf '%s' "${image_healthcheck}" | grep -q -- '--healthcheck'
docker volume create "${config_volume}" >/dev/null
docker volume create "${control_volume}" >/dev/null
docker volume create "${books_volume}" >/dev/null

docker run -d \
  --name "${container}" \
  -e PUID=23456 \
  -e PGID=23456 \
  -p 127.0.0.1::8080 \
  -v "${config_volume}:/config" \
  -v "${control_volume}:/control" \
  -v "${books_volume}:/data" \
  "${image}" >/dev/null

if docker run --rm -e PUID=0 "${image}" >/dev/null 2>&1; then
  echo "The image unexpectedly accepted a root PUID." >&2
  exit 1
fi
if docker run --rm -e CHOWN_ON_START=invalid "${image}" >/dev/null 2>&1; then
  echo "The image unexpectedly accepted an invalid CHOWN_ON_START policy." >&2
  exit 1
fi

wait_for_health
assert_owner_marker 23456 /config
assert_owner_marker 23456 /control
assert_owner_marker 23456 /data

for file in AccountsSettings.json Settings.json LibationContext.db; do
  docker exec -u 0 "${container}" test -f "/config/${file}"
  owner="$(docker exec -u 0 "${container}" stat -c '%u:%g' "/config/${file}")"
  test "${owner}" = "23456:23456"
done
accounts_json="$(docker exec -u 23456:23456 "${container}" cat /config/AccountsSettings.json)"
settings_json="$(docker exec -u 23456:23456 "${container}" cat /config/Settings.json)"
test "${accounts_json}" = "{}"
test "${settings_json}" = "{}"

docker exec -u 0 "${container}" test -s /control/token
token_owner="$(docker exec -u 0 "${container}" stat -c '%u:%g' /control/token)"
test "${token_owner}" = "23456:23456"
token_mode="$(docker exec -u 0 "${container}" stat -c '%a' /control/token)"
test "${token_mode}" = "600"
assert_runtime_privileges 23456

# Shelfarr runs with the same PUID/PGID in the supplied Compose file and mounts
# this volume read-only. Verify that exact reader contract without weakening the
# token's owner-only permissions.
docker run --rm \
  --user 23456:23456 \
  --entrypoint /bin/sh \
  -v "${control_volume}:/control:ro" \
  "${image}" -c 'test -r /control/token'
if docker run --rm \
  --user 23457:23457 \
  --entrypoint /bin/sh \
  -v "${control_volume}:/control:ro" \
  "${image}" -c 'test -r /control/token' >/dev/null 2>&1; then
  echo "The bridge token was unexpectedly readable by a different UID/GID." >&2
  exit 1
fi

expected_license="$(sha256sum LICENSES/Libation-GPL-3.0.txt | sed 's/ .*//')"
image_license="$(docker exec -u 0 "${container}" sha256sum /companion/LICENSES/Libation-GPL-3.0.txt | sed 's/ .*//')"
test "${image_license}" = "${expected_license}"
shelfarr_license="$(docker exec -u 0 "${container}" sha256sum /companion/LICENSES/Shelfarr-GPL-3.0.txt | sed 's/ .*//')"
test "${shelfarr_license}" = "${expected_license}"
docker exec -u 23456:23456 "${container}" test -r /companion/SOURCES/Libation-13.5.1-source.tar.gz
source_archive_sha="$(docker exec -u 23456:23456 "${container}" \
  sha256sum /companion/SOURCES/Libation-13.5.1-source.tar.gz | sed 's/ .*//')"
test "${source_archive_sha}" = "7391b9e4e34375e5d134932246ce0a50e0561efe1a24c2a3aa8f32a1217fac9f"
docker exec -u 23456:23456 "${container}" tar -tzf /companion/SOURCES/Libation-13.5.1-source.tar.gz \
  Libation-13.5.1/Source/LibationCli/LibationCli.csproj >/dev/null
libation_output="$(docker exec -u 23456:23456 "${container}" /libation/LibationCli 2>&1 || true)"
libation_version="$(printf '%s\n' "${libation_output}" | sed -n '1s/^LibationCli v//p')"
test "${libation_version}" = "13.5.1"

unauthorized="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}/version")"
test "${unauthorized}" = "401"

token="$(docker exec -u 23456:23456 "${container}" sed -n '1p' /control/token)"
version_response="$(curl --fail --silent -H "Authorization: Bearer ${token}" "http://127.0.0.1:${port}/version")"
printf '%s' "${version_response}" | grep -q '"companionVersion":"0.0.0"'
printf '%s' "${version_response}" | grep -q '"libationVersion":"13.5.1"'
accounts_response="$(curl --fail --silent -H "Authorization: Bearer ${token}" "http://127.0.0.1:${port}/v1/accounts")"
printf '%s' "${accounts_response}" | grep -q '"accounts":\[\]'

# ASP.NET's default request diagnostics include literal route values. Backup
# paths carry owned-title ASINs, so Information-level framework access logs
# must remain suppressed while application warnings and errors stay enabled.
private_asin="B012345678"
backup_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H "Authorization: Bearer ${token}" \
  -X POST "http://127.0.0.1:${port}/v1/backups/${private_asin}")"
test "${backup_status}" = "422"
if docker logs "${container}" 2>&1 | grep -Fq "${private_asin}"; then
  echo "The companion unexpectedly wrote an owned-title ASIN to its container logs." >&2
  exit 1
fi

# Root startup code must reject pre-existing symlinks instead of following them
# while adjusting a state file's owner or mode.
docker rm -f "${container}" >/dev/null
docker run --rm \
  --entrypoint /bin/sh \
  -v "${config_volume}:/config" \
  -v "${books_volume}:/data" \
  "${image}" -c \
  'rm -f /config/Settings.json && printf preserved > /data/sentinel && chmod 0644 /data/sentinel && ln -s /data/sentinel /config/Settings.json'
if docker run --name "${container}" \
  -e PUID=23456 \
  -e PGID=23456 \
  -v "${config_volume}:/config" \
  -v "${control_volume}:/control" \
  -v "${books_volume}:/data" \
  "${image}" >/dev/null 2>&1; then
  echo "The image unexpectedly accepted a symlinked Libation settings file." >&2
  exit 1
fi
docker rm -f "${container}" >/dev/null
docker run --rm \
  --entrypoint /bin/sh \
  -v "${config_volume}:/config" \
  -v "${books_volume}:/data" \
  "${image}" -c \
  'test "$(cat /data/sentinel)" = preserved && test "$(stat -c "%u:%g:%a" /data/sentinel)" = 0:0:644 && rm /config/Settings.json && printf "{}" > /config/Settings.json && chown 23456:23456 /config/Settings.json && chmod 0600 /config/Settings.json'

# `never` must validate rather than silently repair pre-permissioned mounts.
# Reject credentials, the shared bearer token, and private state directories
# when group/world mode bits would expose them.
docker run --rm \
  --entrypoint /bin/sh \
  -v "${config_volume}:/config" \
  "${image}" -c 'chmod 0644 /config/Settings.json'
if docker run --name "${container}" \
  -e PUID=23456 \
  -e PGID=23456 \
  -e CHOWN_ON_START=never \
  -v "${config_volume}:/config" \
  -v "${control_volume}:/control" \
  -v "${books_volume}:/data" \
  "${image}" >/dev/null 2>&1; then
  echo "The image unexpectedly accepted a group/world-readable Libation settings file with CHOWN_ON_START=never." >&2
  exit 1
fi
docker rm -f "${container}" >/dev/null
settings_mode="$(docker run --rm --entrypoint /bin/sh -v "${config_volume}:/config" "${image}" -c 'stat -c "%a" /config/Settings.json')"
test "${settings_mode}" = "644"
docker run --rm --entrypoint /bin/sh -v "${config_volume}:/config" "${image}" -c 'chmod 0600 /config/Settings.json'

docker run --rm \
  --entrypoint /bin/sh \
  -v "${control_volume}:/control" \
  "${image}" -c 'chmod 0644 /control/token'
if docker run --name "${container}" \
  -e PUID=23456 \
  -e PGID=23456 \
  -e CHOWN_ON_START=never \
  -v "${config_volume}:/config" \
  -v "${control_volume}:/control" \
  -v "${books_volume}:/data" \
  "${image}" >/dev/null 2>&1; then
  echo "The image unexpectedly accepted a group/world-readable companion token with CHOWN_ON_START=never." >&2
  exit 1
fi
docker rm -f "${container}" >/dev/null
token_mode="$(docker run --rm --entrypoint /bin/sh -v "${control_volume}:/control" "${image}" -c 'stat -c "%a" /control/token')"
test "${token_mode}" = "644"
docker run --rm --entrypoint /bin/sh -v "${control_volume}:/control" "${image}" -c 'chmod 0600 /control/token'

docker run --rm \
  --entrypoint /bin/sh \
  -v "${config_volume}:/config" \
  "${image}" -c 'chmod 0755 /config'
if docker run --name "${container}" \
  -e PUID=23456 \
  -e PGID=23456 \
  -e CHOWN_ON_START=never \
  -v "${config_volume}:/config" \
  -v "${control_volume}:/control" \
  -v "${books_volume}:/data" \
  "${image}" >/dev/null 2>&1; then
  echo "The image unexpectedly accepted a group/world-accessible Libation config directory with CHOWN_ON_START=never." >&2
  exit 1
fi
docker rm -f "${container}" >/dev/null
config_mode="$(docker run --rm --entrypoint /bin/sh -v "${config_volume}:/config" "${image}" -c 'stat -c "%a" /config')"
test "${config_mode}" = "755"
docker run --rm --entrypoint /bin/sh -v "${config_volume}:/config" "${image}" -c 'chmod 0700 /config'

# A second boot with pre-owned state and ownership changes disabled models the
# contract required by NFS/root-squashed bind mounts.
docker run -d \
  --name "${container}" \
  -e PUID=23456 \
  -e PGID=23456 \
  -e CHOWN_ON_START=never \
  -p 127.0.0.1::8080 \
  -v "${config_volume}:/config" \
  -v "${control_volume}:/control" \
  -v "${books_volume}:/data" \
  "${image}" >/dev/null
wait_for_health
assert_runtime_privileges 23456
token_mode="$(docker exec -u 0 "${container}" stat -c '%a' /control/token)"
test "${token_mode}" = "600"

# Persist representative nested state as the original service identity. A
# subsequent PUID/PGID change must migrate all of it without following the
# symlink out of the private state volume.
job_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
docker exec -u 23456:23456 "${container}" sh -c '
  set -eu
  umask 077
  mkdir -p /config/shelfarr-companion/jobs /config/in-progress/example /data/Example\ Book
  printf "%s" "{\"id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"kind\":\"sync\",\"status\":\"succeeded\",\"createdAt\":\"2026-07-18T00:00:00Z\",\"completedAt\":\"2026-07-18T00:01:00Z\"}" > /config/shelfarr-companion/jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json
  printf "%s" "{\"schemaVersion\":1,\"generatedAt\":\"2026-07-18T00:00:00Z\",\"libationVersion\":\"13.5.1\",\"skippedItems\":0,\"items\":[]}" > /config/shelfarr-companion/library.json
  printf chunk > /config/in-progress/example/chunk.partial
  printf sidecar > /config/LibationContext.db-wal.audit
  printf audio > "/data/Example Book/example.m4b"
  ln -s /companion/THIRD_PARTY_NOTICES.md /config/shelfarr-companion/upstream-notice
'
docker rm -f "${container}" >/dev/null

# With ownership changes disabled, changing IDs must fail closed rather than
# starting a service that silently ignores its old job/cache state.
if docker run --name "${container}" \
  -e PUID=23457 \
  -e PGID=23457 \
  -e CHOWN_ON_START=never \
  -v "${config_volume}:/config" \
  -v "${control_volume}:/control" \
  -v "${books_volume}:/data" \
  "${image}" >/dev/null 2>&1; then
  echo "The image unexpectedly accepted old-owner nested state with CHOWN_ON_START=never." >&2
  exit 1
fi
docker rm -f "${container}" >/dev/null

# The default auto policy performs a one-time, physical (`find -P`) ownership
# migration and records the new IDs so later restarts do not rescan the tree.
docker run -d \
  --name "${container}" \
  -e PUID=23457 \
  -e PGID=23457 \
  -p 127.0.0.1::8080 \
  -v "${config_volume}:/config" \
  -v "${control_volume}:/control" \
  -v "${books_volume}:/data" \
  "${image}" >/dev/null
wait_for_health
assert_runtime_privileges 23457

for path in \
  /config/shelfarr-companion/jobs \
  "/config/shelfarr-companion/jobs/${job_id}.json" \
  /config/shelfarr-companion/library.json \
  /config/in-progress/example \
  /config/in-progress/example/chunk.partial \
  /config/LibationContext.db-wal.audit \
  "/data/Example Book" \
  "/data/Example Book/example.m4b" \
  /control/token; do
  owner="$(docker exec -u 0 "${container}" stat -c '%u:%g' "${path}")"
  test "${owner}" = "23457:23457"
done
assert_owner_marker 23457 /config
assert_owner_marker 23457 /control
assert_owner_marker 23457 /data

symlink_owner="$(docker exec -u 0 "${container}" stat -c '%u:%g' /config/shelfarr-companion/upstream-notice)"
test "${symlink_owner}" = "23457:23457"
notice_owner="$(docker exec -u 0 "${container}" stat -L -c '%u:%g' /config/shelfarr-companion/upstream-notice)"
test "${notice_owner}" = "1000:1000"

token="$(docker exec -u 23457:23457 "${container}" sed -n '1p' /control/token)"
job_response="$(curl --fail --silent -H "Authorization: Bearer ${token}" "http://127.0.0.1:${port}/v1/jobs/${job_id}")"
printf '%s' "${job_response}" | grep -q '"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
library_response="$(curl --fail --silent -H "Authorization: Bearer ${token}" "http://127.0.0.1:${port}/v1/library")"
printf '%s' "${library_response}" | grep -q '"schemaVersion":1'
library_page_response="$(curl --fail --silent -H "Authorization: Bearer ${token}" "http://127.0.0.1:${port}/v1/library?offset=0&limit=250")"
printf '%s' "${library_page_response}" | grep -q '"totalItems":0'
printf '%s' "${library_page_response}" | grep -q '"nextOffset":null'
invalid_page_status="$(curl --silent --output /dev/null --write-out '%{http_code}' -H "Authorization: Bearer ${token}" "http://127.0.0.1:${port}/v1/library?limit=1001")"
test "${invalid_page_status}" = "400"

echo "Companion fresh/pre-owned volume, UID rotation, no-new-privileges/capability, ASIN-log privacy, private-mode, ownership policy, no-symlink-follow, token, health, and bearer-auth smoke checks passed."
