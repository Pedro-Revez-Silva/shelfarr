# Filesystem Contract Tests

These tests exercise Shelfarr's file-publication guarantees against real
mounted filesystems. Unit tests still inject individual syscall failures, but
they cannot reproduce combined client/server behavior such as a successful
`linkat()` followed by an unusable destination pathname.

The contract suite verifies application behavior rather than requiring every
filesystem to expose identical Unix metadata. It covers nested directory
creation, complete no-clobber copies, concurrent publication, hardlink
fallback, durable move behavior, cross-process locking, and cleanup artifacts.

Run the local-filesystem control:

```bash
PARALLEL_WORKERS=1 \
  bin/rails test test/filesystem_contracts/file_copy_service_contract_test.rb
```

Run the same suite against an existing mount:

```bash
SHELFARR_FILESYSTEM_CONTRACT_ROOT=/absolute/path/to/mount \
SHELFARR_FILESYSTEM_CONTRACT_PROFILE=my-filesystem \
PARALLEL_WORKERS=1 \
  bin/rails test test/filesystem_contracts/file_copy_service_contract_test.rb
```

Run the containerized Samba/CIFS matrix:

```bash
test/filesystem_contracts/cifs-smoke.sh
```

The CIFS harness requires Docker, the host CIFS kernel module, `mount.cifs`,
and permission to mount and unmount filesystems. It builds a disposable Samba
server and runs both `serverino` and `noserverino` profiles with the fixed
`0775` modes reported in production issues.

When adding another filesystem, mount it in a disposable harness and pass its
root to the same Rails contract file. Add a new assertion only when it
represents a Shelfarr guarantee; filesystem capabilities should result in a
safe typed fallback rather than filesystem-specific expectations in the test.
