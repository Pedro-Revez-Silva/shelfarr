# Backend volume upgrade and rollback (M2)

Status: **experimental, unreachable proof.** Rails is still the only implementation that serves Shelfarr and the
only owner of the persistent volume. Nothing here changes the shipped Dockerfile, entrypoint, schema, routes or
UI. The Go checker and workflow binaries are added to an *experimental packaging image* that sits on top of the
unchanged Rails image; that image is a Rails-plus-tools proof, **not the finished Go server package**.

The proof answers one question before any Go handover: does a production-shaped persistent volume written by a
real released image survive the real candidate startup, and can the previous code run on it again without losing
the activity written in between?

## What is proven and what is not

| Claim | Evidence | Limit |
| --- | --- | --- |
| A volume written by the **released v2026.11.05.1 image** upgrades through the real candidate entrypoint (17 shipped migrations) with every released row, ciphertext, key file and media identity intact | `test/upgrade_test.rb` | Synthetic rows written by the released app through its models, not a customer volume |
| The same for the **beta predecessor** (`ca3ce810`) | `test/upgrade_test.rb` | Rails code, schema and Gemfile of the predecessor and candidate are identical, so this exercises startup, keys, WAL and queue, not a schema change |
| Repeat startup, interrupted and failed migrations, a crash that leaves a write-ahead log, missing and environment-provided keys | `test/upgrade_test.rb` | Interruptions are SIGKILL and a forced migration conflict; no power-loss simulation |
| **Code rollback keeps post-upgrade activity** (progress version, position and original `observed_at`, tokens, admitted queue work, writes made by the old code) for both the stable release and the beta predecessor, and rolling forward again still serves it | `test/rollback_test.rb` | Holds because every shipped change is additive (see "Why the old image can run"); a future destructive migration must re-prove it |
| Restoring the **pre-upgrade backup is not activity-preserving**: everything written after the snapshot is gone | `test/rollback_test.rb` | This is the documented loss boundary of that path |
| Snapshot/restore refuse running, ambiguous, corrupt, tampered and incomplete state | `test/backup_test.rb`, `test/cli_test.rb` | Process detection reads `/proc` of this host and the container runtime; other hosts' processes cannot be seen |
| Queued Ruby work is never dropped; unknown classes are retained and reported blocked | `test/queue_inventory_test.rb`, `test/cli_test.rb`, `test/upgrade_test.rb` | Nothing is deserialized or executed; porting jobs is not claimed |
| Negative controls fail on assertions | `test/negative_controls_test.rb`, `test/comparison_test.rb` | |
| Packaging: amd64 executed, arm64 cross-built and executed under emulation | `packaging/verify-packages` | arm64 was **not** run on arm64 hardware and the arm64 Rails bundle was not built |

Not claimed: any Go write-domain handover, a Go-only server, porting of any Ruby job, HTTP or browser parity,
production data, power-loss durability, or running arm64 natively.

## Images

| Role | Source | Build |
| --- | --- | --- |
| `stable` | release `v2026.11.05.1`, commit `96333c6674a21701f7229c1a51038dc3b117c1a0`, tree `c9a17fcfa4591898ac47a299e8fab09ecd2c15c1` | `git archive` of the pinned commit read from local history (replacement objects and lazy fetch disabled, tree id re-verified), release Dockerfile |
| `beta` | beta predecessor `ca3ce810a50053b1279048c7b705c1fae97c0a9a`, tree `6f21bc30ef3a2d2b43614d6fdb3582a6c72733c8` | same |
| `candidate-rails` | clean `HEAD` | the production `Dockerfile`, unchanged |
| `candidate` | `candidate-rails` plus `tools/migration/packaging/Dockerfile` | adds `/usr/local/bin/shelfarr-compat` and `shelfarr-workflows`; `ENTRYPOINT` and `CMD` are the production ones (asserted) |

`tools/migration/packaging/build-images` builds them. Base images (`ruby:3.3.13-slim`, `golang:1.27.4`) and the
packages and gems the unchanged Dockerfile needs are fetched by the container build itself; no source revision is
fetched. Images are tagged `shelfarr-m2/<role>:<commit12>`; nothing is pushed.

## Volume contract

The persistent volume is the directory mounted at `/rails/storage`. Media libraries are separate trees
(`/audiobooks`, `/ebooks`, and the targets of reference-imported symbolic links) and are never part of a snapshot.

| Path | Owner today | Semantics | Upgrade outcome |
| --- | --- | --- | --- |
| `production.sqlite3` (+ `-wal`, `-shm`) | Rails | system of record | every released row and column identical by SQLite type; new tables created empty; schema versions only added |
| `production_queue.sqlite3` | Solid Queue | durable Ruby background work | job and execution rows preserved row for row (startup may add jobs, e.g. `AndroidUpdateRefreshJob`); `solid_queue_processes`, `solid_queue_semaphores`, `solid_queue_recurring_*` are runtime state and not asserted |
| `production_cable.sqlite3` | Solid Cable | one day broadcast buffer | must open; contents disposable, a Go server need not keep this file |
| `production_cache.sqlite3` | Solid Cache | disposable cache | must open; contents disposable |
| `.secret_key_base` | entrypoint | signs sessions and cookies | never regenerated over an existing volume; byte, mode, owner, mtime and inode identical |
| `.encryption_keys` | entrypoint | Active Record Encryption keys | same |
| any other file | unknown | unknown | must stay byte identical; an unexpected extra file is reported |

Key modes: (1) **persisted files** written by the entrypoint (`root:root`, `0600`); (2) **environment** keys
(`SECRET_KEY_BASE`, `ACTIVE_RECORD_ENCRYPTION_*`) with no key files, which the entrypoint then does not create.

WAL: a graceful stop checkpoints and removes `-wal`/`-shm`; a SIGKILL leaves a non-empty `-wal` holding
committed writes. Copying only the `.sqlite3` file of such a volume loses them (shown by a test).

### Behaviours of the unchanged production entrypoint that operators must know

* **Missing key files are silently regenerated.** If `.encryption_keys` is absent the entrypoint generates new
  keys, so every existing encrypted value (OTP secrets, backup codes, download-client and provider credentials)
  becomes unreadable (`ActiveRecord::Encryption::Errors::Decryption`). Ciphertext is not touched, so restoring
  the original file recovers everything (tested). A missing `.secret_key_base` invalidates every session cookie
  the same way. `tools/migration/volume/volume check` refuses such a volume before start.
* A failed migration stops the entrypoint (non-zero exit); the next start resumes with the remaining ones.
* Starting the candidate enqueues `AndroidUpdateRefreshJob` once per start.

### Why the old image can run on an upgraded volume

All 17 migrations since the stable release add tables and nullable or defaulted columns and one index
(`api_tokens.issued_via`, `replaces_api_token_id`, `connection_key`; `books` consumer-title index). The old code
ignores unknown tables and columns, and `db:prepare` does not fail on schema versions it does not know. The new
features answer `404` while the old image runs (tested) but their rows are untouched and served again after
rolling forward. A future migration that renames, drops or constrains an existing column breaks this and must
add its own proof.

## Rollback paths

| Path | Preserves later writes? | Boundary |
| --- | --- | --- |
| Run the previous image on the retained volume, then roll forward | **Yes** | Old code does not serve new features while it runs; its own writes are kept |
| Restore the pre-upgrade snapshot into a new empty directory | **No** | Everything written after the snapshot is lost, including progress, tokens, queued work and settings |

Do not describe the second path as activity-preserving.

## Operator command line

`tools/migration/volume/volume <command>`; one JSON object on stdout, one bounded line on stderr, never a key,
credential, token or job argument.

| Command | Purpose | Exit |
| --- | --- | --- |
| `check --storage DIR [--environment-keys]` | prove the volume is quiescent and key material is present | `0` ok, `3` refused |
| `snapshot --storage DIR --out NEW_DIR [--environment-keys]` | quiescent snapshot | `0`, `3` refused |
| `restore --snapshot DIR --target EMPTY_DIR` | restore into a new empty directory | `0`, `3` refused |
| `queue --storage DIR --known-classes FILE` | classify queued Ruby work | `0` none blocked, `3` unsupported work present (retained, never purged) |
| `known-jobs --image IMAGE` | job classes the image defines (no volume, no network) | `0` |

Exit `2` is a usage error, `4` an unexpected failure.

**Refusals** (nothing is written): the path is relative, missing, crosses a symbolic link, or has no
`production.sqlite3`; a container that mounts the volume is running, paused or restarting; the container runtime
cannot answer; a process holds a volume file open; a hot rollback journal exists; encrypted values exist but
key material is missing (unless `--environment-keys` declares environment keys); a database fails its integrity
check; the output directory exists or is inside the volume. After copying, quiescence is checked again. Restore
refuses a target that is not an empty plain directory or is mounted by an active container, a manifest that is
missing (an interrupted snapshot never has one), a database inventory that omits the primary database,
and any database or archive whose SHA-256 differs. These manifest checks run before the restore target is written.

Databases are copied with SQLite's backup API from a private copy of the database and its `-wal` (never from the
live file pair). Everything else goes into `files.tar` (GNU tar, numeric owners, nanosecond mtimes) written by a
short-lived root helper container so `root:root 0600` keys are preserved.

### Snapshot format 1

```
<snapshot>/snapshot.json   {format, created_at, databases{name: sha256,size,uid,gid,mode,wal_bytes_at_source},
                            files{path: kind,mode,uid,gid,size,mtime_ns,digest,target}, archive_sha256, key_files_present}
<snapshot>/databases/<each database file>
<snapshot>/files.tar
```

`snapshot.json` is written last by an atomic rename. Key contents are only inside `files.tar`.

## Verification

```
tools/migration/volume/verify-volume      # Ruby 3.3.13 first on PATH, a usable container runtime
```

It runs rubocop, the unit tests, builds the images, runs the container scenarios, the operator CLI test and the
package checks, requires that no container of the run remains and that the repository is untouched. Unit tests
alone: `bundle exec ruby -Itest tools/migration/volume/test/comparison_test.rb` (and `queue_inventory_test.rb`).

Schema comparison is exact: the captured `CREATE TABLE` text of every existing table and every existing index
must be byte identical. A table whose text may change is listed in the contract with the **one exact text** it may
change to (`api_tokens` on the stable upgrade, whose three added columns SQLite writes into the `CREATE TABLE`
text); any other text, including a behaviour-preserving rewrite, is reported as `definition-changed` and has to
be allowed explicitly. There is no SQL parsing. The pinned text is the one Rails produces from the shipped
migrations, so a changed migration fails loudly until the contract is updated.

State comparison reads typed rows (`typeof` per cell, floats by IEEE bits, blobs by bytes), schema, indexes,
autoincrement counters, per-file content/mode/owner/mtime/inode and per-media identity (device-independent:
inode, size, mtime, ctime, symlink target). Violations name `area:table[key].column:reason` only.

Negative controls (each fails on its assertion): omitted database, mutated password digest, mutated ciphertext,
reset activity time and rewound version, lost progress row, dropped queued job, changed job class, reset row
counter, changed/deleted/identically-rewritten/regenerated/`chmod`ed key, touched/replaced/retargeted media,
extra database file, dropped index, naive copy that omits the WAL, snapshot of a running or paused volume,
tampered snapshot, populated restore target.

## Packaging

`tools/migration/packaging/Dockerfile` has two build arguments (`RAILS_IMAGE`, `GO_IMAGE`) and changes nothing
else. `verify-packages` records, per check, whether it was **natively executed**, **executed under qemu
emulation** or **cross-build inspected**: Go binaries are reproducible (two builds hash equal) and ELF-checked
for both architectures; on the host architecture the candidate image runs the tools, ffmpeg (a synthetic AAC
encode), sqlite3, vips, gosu, jemalloc and the unchanged entrypoint check; for the other architecture the
production Dockerfile's `base` stage and the binaries layer are built for that platform and the same runtime
checks run under qemu-user. The full arm64 Rails bundle is not built and no arm64 hardware was used.

## Compatibility

New files only (`tools/migration/volume`, `tools/migration/packaging`, this document). No existing CLI, schema,
route, volume file, image or verifier changed; the M0 and M1 verifiers are untouched. Nothing to deprecate.
