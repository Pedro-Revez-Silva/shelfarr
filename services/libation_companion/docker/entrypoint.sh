#!/bin/sh
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
CHOWN_ON_START="${CHOWN_ON_START:-auto}"

case "${PUID}" in
  ''|*[!0-9]*)
    echo "PUID and PGID must be positive numeric IDs." >&2
    exit 64
    ;;
esac
case "${PGID}" in
  ''|*[!0-9]*)
    echo "PUID and PGID must be positive numeric IDs." >&2
    exit 64
    ;;
esac
if [ "${#PUID}" -gt 10 ] || [ "${#PGID}" -gt 10 ] \
  || [ "${PUID}" -eq 0 ] || [ "${PGID}" -eq 0 ] \
  || [ "${PUID}" -gt 4294967294 ] || [ "${PGID}" -gt 4294967294 ]; then
  echo "PUID and PGID must be non-root numeric IDs." >&2
  exit 64
fi

case "${CHOWN_ON_START}" in
  auto|always|never) ;;
  *)
    echo "CHOWN_ON_START must be auto, always, or never." >&2
    exit 64
    ;;
esac

umask 077

run_as_companion() {
  setpriv --reuid="${PUID}" --regid="${PGID}" --clear-groups "$@"
}

verify_private_mode() {
  path="$1"
  label="$2"
  actual_mode="$(stat -c '%a' "${path}")"
  case "${actual_mode}" in
    *00) ;;
    *)
      echo "${label} must not grant group or world permissions: ${path} (mode ${actual_mode})" >&2
      echo "Pre-permission private directories as 0700 and sensitive files as 0600 before using CHOWN_ON_START=never." >&2
      exit 1
      ;;
  esac
}

reject_unsafe_directory() {
  path="$1"
  label="$2"
  if [ -L "${path}" ]; then
    echo "${label} must not be a symbolic link: ${path}" >&2
    exit 1
  fi
  if [ -e "${path}" ] && [ ! -d "${path}" ]; then
    echo "${label} must be a directory: ${path}" >&2
    exit 1
  fi
}

verify_directory_writable() {
  path="$1"
  marker="$(run_as_companion mktemp -d "${path%/}/.shelfarr-companion-startup-check.XXXXXX" 2>/dev/null)" || return 1
  run_as_companion rmdir "${marker}" >/dev/null 2>&1 || return 1
}

report_adjustment_failure() {
  path="$1"
  if [ "${CHOWN_ON_START}" = "always" ]; then
    echo "Failed to adjust ${path} and CHOWN_ON_START=always is set." >&2
    exit 1
  fi

  echo "Warning: unable to adjust ownership or mode for ${path}; checking configured-user access." >&2
}

prepare_directory() {
  path="$1"
  mode="$2"
  label="$3"

  reject_unsafe_directory "${path}" "${label}"
  if [ ! -d "${path}" ]; then
    if ! run_as_companion mkdir -p "${path}" 2>/dev/null && ! mkdir -p "${path}"; then
      echo "Could not create ${label}: ${path}" >&2
      exit 1
    fi
  fi
  reject_unsafe_directory "${path}" "${label}"

  if [ "${CHOWN_ON_START}" != "never" ]; then
    owner="$(stat -c '%u:%g' "${path}")"
    if [ "${owner}" != "${PUID}:${PGID}" ]; then
      if ! chown -h "${PUID}:${PGID}" "${path}"; then
        report_adjustment_failure "${path}"
      fi
    fi

    if ! run_as_companion chmod "${mode}" "${path}"; then
      report_adjustment_failure "${path}"
    fi
  fi

  if ! verify_directory_writable "${path}"; then
    echo "${label} is not writable by UID ${PUID} and GID ${PGID}: ${path}" >&2
    echo "Pre-permission the path and use CHOWN_ON_START=never for root-squashed storage." >&2
    exit 1
  fi

  if [ "${mode}" = "0700" ]; then
    if ! run_as_companion test -r "${path}" || ! run_as_companion test -x "${path}"; then
      echo "${label} must be readable and traversable by UID ${PUID} and GID ${PGID}: ${path}" >&2
      exit 1
    fi
    verify_private_mode "${path}" "${label}"
  fi
}

reject_unsafe_file() {
  path="$1"
  label="$2"
  if [ -L "${path}" ]; then
    echo "${label} must not be a symbolic link: ${path}" >&2
    exit 1
  fi
  if [ -e "${path}" ] && [ ! -f "${path}" ]; then
    echo "${label} must be a regular file: ${path}" >&2
    exit 1
  fi
}

seed_file_atomically() {
  path="$1"
  contents="$2"
  label="$3"
  parent="$(dirname "${path}")"

  reject_unsafe_file "${path}" "${label}"
  [ -e "${path}" ] && return 0

  temporary="$(run_as_companion mktemp "${parent%/}/.shelfarr-companion-seed.XXXXXX")" || {
    echo "Could not create temporary ${label}." >&2
    exit 1
  }
  if ! printf '%s' "${contents}" | run_as_companion tee "${temporary}" >/dev/null; then
    run_as_companion rm -f "${temporary}" >/dev/null 2>&1 || true
    echo "Could not initialize ${label}." >&2
    exit 1
  fi

  # A hard link publishes the fully written seed only if the destination is
  # still absent. It cannot replace or follow an attacker-controlled symlink.
  if ! run_as_companion ln "${temporary}" "${path}" 2>/dev/null; then
    run_as_companion rm -f "${temporary}" >/dev/null 2>&1 || true
    reject_unsafe_file "${path}" "${label}"
    if [ ! -f "${path}" ]; then
      echo "Could not publish ${label}." >&2
      exit 1
    fi
    return 0
  fi
  run_as_companion rm -f "${temporary}"
}

prepare_file() {
  path="$1"
  mode="$2"
  label="$3"

  reject_unsafe_file "${path}" "${label}"
  if [ ! -f "${path}" ]; then
    echo "${label} is missing: ${path}" >&2
    exit 1
  fi

  if [ "${CHOWN_ON_START}" != "never" ]; then
    owner="$(stat -c '%u:%g' "${path}")"
    if [ "${owner}" != "${PUID}:${PGID}" ]; then
      if ! chown -h "${PUID}:${PGID}" "${path}"; then
        report_adjustment_failure "${path}"
      fi
    fi

    if ! run_as_companion chmod "${mode}" "${path}"; then
      report_adjustment_failure "${path}"
    fi
  fi

  if ! run_as_companion test -r "${path}" || ! run_as_companion test -w "${path}"; then
    echo "${label} must be readable and writable by UID ${PUID} and GID ${PGID}: ${path}" >&2
    exit 1
  fi
  verify_private_mode "${path}" "${label}"
}

verify_tree_access() {
  path="$1"
  label="$2"

  # Run the traversal as the final service identity. `find -P` never follows a
  # symbolic link, and `-xdev` prevents a nested mount from expanding the
  # ownership boundary unexpectedly.
  if ! unusable="$(run_as_companion find -P "${path}" -xdev \
    \( \
      \( -type d \( ! -readable -o ! -writable -o ! -executable \) \) -o \
      \( -type f \( ! -readable -o ! -writable \) \) \
    \) -print -quit 2>/dev/null)"; then
    echo "${label} cannot be traversed by UID ${PUID} and GID ${PGID}: ${path}" >&2
    exit 1
  fi

  if [ -n "${unusable}" ]; then
    echo "${label} contains state that UID ${PUID} and GID ${PGID} cannot read and write." >&2
    echo "Pre-permission the complete volume tree before using CHOWN_ON_START=never." >&2
    exit 1
  fi
}

write_owner_marker() {
  marker="$1"
  label="$2"
  parent="$(dirname "${marker}")"

  temporary="$(run_as_companion mktemp "${parent%/}/.shelfarr-owner.XXXXXX")" || {
    echo "Could not create the ${label} ownership marker." >&2
    exit 1
  }
  if ! printf '%s\n' "${PUID}:${PGID}" | run_as_companion tee "${temporary}" >/dev/null \
    || ! run_as_companion chmod 0600 "${temporary}"; then
    run_as_companion rm -f "${temporary}" >/dev/null 2>&1 || true
    echo "Could not write the ${label} ownership marker." >&2
    exit 1
  fi

  # rename(2) replaces a marker path rather than following it. The marker was
  # checked immediately before this operation and lives below a private mount.
  if ! run_as_companion mv -f "${temporary}" "${marker}"; then
    run_as_companion rm -f "${temporary}" >/dev/null 2>&1 || true
    echo "Could not publish the ${label} ownership marker." >&2
    exit 1
  fi
}

migrate_volume_tree() {
  migration_path="$1"
  migration_label="$2"
  migration_marker="${migration_path%/}/.shelfarr-companion-owner"

  reject_unsafe_file "${migration_marker}" "${migration_label} ownership marker"
  marker_value=""
  marker_owner=""
  if [ -f "${migration_marker}" ]; then
    marker_value="$(sed -n '1p' "${migration_marker}")"
    marker_owner="$(stat -c '%u:%g' "${migration_marker}")"
  fi

  if [ "${marker_value}" != "${PUID}:${PGID}" ] || [ "${marker_owner}" != "${PUID}:${PGID}" ]; then
    if [ "${CHOWN_ON_START}" != "never" ]; then
      # Do not use `chown -R`: an untrusted nested symlink must never redirect a
      # root ownership change outside the mounted volume. `find -P`, `-xdev`,
      # and `chown -h` keep every adjustment on the discovered inode itself.
      if ! find -P "${migration_path}" -xdev \
        \( ! -uid "${PUID}" -o ! -gid "${PGID}" \) \
        -exec chown -h "${PUID}:${PGID}" {} +; then
        report_adjustment_failure "${migration_label} tree at ${migration_path}"
      fi
    fi

    verify_tree_access "${migration_path}" "${migration_label}"
    write_owner_marker "${migration_marker}" "${migration_label}"
  fi

  prepare_file "${migration_marker}" 0600 "${migration_label} ownership marker"
}

token_parent="$(dirname "${COMPANION_TOKEN_FILE}")"

# Fresh named volumes need one ownership adjustment. Correctly pre-owned bind
# mounts are instead prepared as PUID/PGID, so root-squashed storage never sees
# a root chown. No network listener starts until every path is verified.
prepare_directory "${token_parent}" 0700 "Companion control directory"
prepare_directory "${LIBATION_FILES_DIR}" 0700 "Libation config directory"
prepare_directory "${COMPANION_STATE_DIR}" 0700 "Companion state directory"
prepare_directory "${LIBATION_IN_PROGRESS_DIR}" 0700 "Libation in-progress directory"
prepare_directory "${COMPANION_STATE_DIR}/home" 0700 "Companion home directory"
prepare_directory "${LIBATION_BOOKS_DIR}" 0750 "Libation books directory"

accounts_file="${LIBATION_FILES_DIR}/AccountsSettings.json"
settings_file="${LIBATION_FILES_DIR}/Settings.json"
database_file="${LIBATION_FILES_DIR}/LibationContext.db"

seed_file_atomically "${accounts_file}" '{}' "Libation accounts file"
seed_file_atomically "${settings_file}" '{}' "Libation settings file"
seed_file_atomically "${database_file}" '' "Libation database"
prepare_file "${accounts_file}" 0600 "Libation accounts file"
prepare_file "${settings_file}" 0600 "Libation settings file"
prepare_file "${database_file}" 0600 "Libation database"

if [ -e "${COMPANION_TOKEN_FILE}" ]; then
  prepare_file "${COMPANION_TOKEN_FILE}" 0600 "Companion token file"
fi

# A PUID/PGID change must migrate state created by the previous service
# identity, not merely the mount roots. Per-volume markers avoid a recursive
# scan on every normal restart while still handling first use, restored legacy
# volumes, and deliberate ID changes.
migrate_volume_tree "${LIBATION_FILES_DIR}" "Libation config volume"
migrate_volume_tree "${token_parent}" "Companion control volume"
migrate_volume_tree "${LIBATION_BOOKS_DIR}" "Libation books volume"

export HOME="${COMPANION_STATE_DIR}/home"
exec setpriv \
  --reuid="${PUID}" \
  --regid="${PGID}" \
  --clear-groups \
  --no-new-privs \
  --bounding-set=-all \
  /companion/Shelfarr.Libation.Companion
