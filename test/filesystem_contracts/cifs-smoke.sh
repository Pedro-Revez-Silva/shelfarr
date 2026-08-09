#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
suffix="$$"
image="shelfarr-filesystem-contract-samba:${suffix}"
container="shelfarr-filesystem-contract-samba-${suffix}"
mount_root="$(mktemp -d "${TMPDIR:-/tmp}/shelfarr-cifs-contract-XXXXXX")"
mounted=false

if [[ "${EUID}" -eq 0 ]]; then
  root_command=()
else
  root_command=(sudo)
fi

mount_state() {
  local result
  timeout --kill-after=2s 5s mountpoint -q "${mount_root}"
  result="$?"
  [[ "${result}" -eq 0 ]] && return 0
  [[ "${result}" -eq 1 || "${result}" -eq 32 ]] && return 1
  return 2
}

cleanup() {
  local exit_status="$1"
  local mount_status
  local detach_status
  local cleanup_status=0
  local resource_ids
  if mount_state; then
    mount_status=0
  else
    mount_status="$?"
  fi
  if [[ "${mounted}" = true || "${mount_status}" -eq 0 ]]; then
    if ! timeout --kill-after=5s 30s "${root_command[@]}" umount "${mount_root}" >/dev/null 2>&1; then
      echo "Normal CIFS unmount failed; attempting a lazy detach." >&2
      timeout --kill-after=5s 30s "${root_command[@]}" umount --lazy "${mount_root}" >/dev/null 2>&1 || true
    fi
    if mount_state; then
      echo "CIFS cleanup could not detach ${mount_root}; retaining container ${container}." >&2
      return 1
    else
      detach_status="$?"
      if [[ "${detach_status}" -ne 1 ]]; then
        echo "CIFS cleanup could not determine whether ${mount_root} is still mounted; retaining container ${container}." >&2
        return 1
      fi
    fi
    mounted=false
  elif [[ "${mount_status}" -ne 1 ]]; then
    echo "CIFS cleanup could not determine whether ${mount_root} is mounted; retaining container ${container}." >&2
    return 1
  fi
  if [[ "${exit_status}" -ne 0 ]] && timeout --kill-after=2s 10s docker inspect "${container}" >/dev/null 2>&1; then
    timeout --kill-after=2s 10s docker logs "${container}" >&2 || true
  fi
  if resource_ids="$(timeout --kill-after=2s 10s docker container ls -a \
    --filter "name=^/${container}$" --format '{{.ID}}')"; then
    if [[ -n "${resource_ids}" ]]; then
      timeout --kill-after=2s 15s docker rm -f "${container}" >/dev/null 2>&1 || cleanup_status=1
    fi
  else
    cleanup_status=1
  fi
  if resource_ids="$(timeout --kill-after=2s 10s docker image ls \
    --filter "reference=${image}" --format '{{.ID}}')"; then
    if [[ -n "${resource_ids}" ]]; then
      timeout --kill-after=2s 15s docker image rm -f "${image}" >/dev/null 2>&1 || cleanup_status=1
    fi
  else
    cleanup_status=1
  fi
  rmdir "${mount_root}" >/dev/null 2>&1 || cleanup_status=1
  return "${cleanup_status}"
}

on_exit() {
  local status="$?"
  trap - EXIT
  cleanup "${status}" || status=1
  exit "${status}"
}

on_signal() {
  local status="$1"
  trap - EXIT INT TERM
  cleanup "${status}"
  exit "${status}"
}

trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

if ! command -v mount.cifs >/dev/null 2>&1; then
  echo "mount.cifs is required; install cifs-utils before running this test." >&2
  exit 1
fi

cd "${root}"
timeout --kill-after=10s 5m docker build --quiet \
  -f test/filesystem_contracts/samba.Dockerfile -t "${image}" . >/dev/null
timeout --kill-after=5s 30s docker run -d \
  --name "${container}" \
  --publish 127.0.0.1::445 \
  "${image}" >/dev/null

attempt=0
until timeout --kill-after=2s 5s docker exec "${container}" \
  smbclient -L 127.0.0.1 -m SMB3 -U 'shelfarr%shelfarr-test' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [[ "${attempt}" -ge 30 ]]; then
    echo "Samba did not become ready." >&2
    exit 1
  fi
  sleep 1
done

endpoint="$(timeout --kill-after=2s 10s docker port "${container}" 445/tcp)"
port="${endpoint##*:}"
common_options="username=shelfarr,password=shelfarr-test,vers=3.1.1,nounix,noperm,uid=$(id -u),gid=$(id -g),forceuid,forcegid,file_mode=0775,dir_mode=0775,cache=strict,actimeo=1,port=${port}"

run_profile() {
  profile="$1"
  inode_option="$2"
  options="${common_options},${inode_option}"
  profile_status=0

  echo "Running filesystem contracts against CIFS profile ${profile}."
  if ! timeout --kill-after=5s 30s "${root_command[@]}" mount \
    -t cifs //127.0.0.1/contracts "${mount_root}" -o "${options}"; then
    echo "Failed to mount CIFS profile ${profile}." >&2
    return 1
  fi
  mounted=true
  timeout --kill-after=2s 10s findmnt --noheadings --output FSTYPE,OPTIONS --target "${mount_root}"

  if ! env SHELFARR_FILESYSTEM_CONTRACT_ROOT="${mount_root}" \
    SHELFARR_FILESYSTEM_CONTRACT_PROFILE="cifs-${profile}" \
    SHELFARR_FILESYSTEM_CONTRACT_OPTIONS="${options//password=shelfarr-test/password=[FILTERED]}" \
    PARALLEL_WORKERS=1 \
    timeout --kill-after=30s 5m bin/rails test test/filesystem_contracts/file_copy_service_contract_test.rb; then
    profile_status=1
  fi

  if timeout --kill-after=5s 30s "${root_command[@]}" umount "${mount_root}"; then
    mounted=false
  else
    echo "Failed to unmount CIFS profile ${profile}." >&2
    profile_status=1
  fi
  return "${profile_status}"
}

status=0
run_profile serverino serverino || status=1
if [[ "${mounted}" = true ]]; then
  exit "${status}"
fi
run_profile noserverino noserverino || status=1
exit "${status}"
