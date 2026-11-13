# Choosing and budgeting validation

Select tests by the behavior changed, then validate a related batch once on its
final sources. A small fix does not start the entire regression, sanitizer,
compiler-profile, performance and crash matrix again. Keep known failures and
unrun hardware gates visible; less repetition does not mean weaker assertions.

## Three validation levels

| Level | When | Required evidence |
| --- | --- | --- |
| Edit | After a behavior change | `git diff --check`, affected compile/typecheck, direct reproduction and the relevant normal/error/retry/ownership checks. Choose the applicable group below. Use ASan immediately for buffer/lifetime changes and TSan for locking/queue changes; an unrelated suite is not required. |
| Related batch | After related fixes and review have stabilized | One final integration pass over the affected contracts, plus applicable sanitizers, memory bounds and concurrency. Reuse an edit-level result if it already covers these contracts with the same final inputs and configuration. |
| Installed system / device | At an explicitly scoped acceptance stage with a suitable disposable medium | Enabled signed extension, actual active driver, mounted read/write/reopen, sync/close/eject, cancellation and errors, memory under real FSKit requests, and the required OS/architecture. Surprise removal/power loss is separate from ordinary eject and returned-error tests. |

Documentation alone requires link/content review. Test-runner changes require
runner dispatch/failure tests and a representative real invocation when compiler
or execution wiring changed; they do not invalidate every product fault matrix.

Before implementation, record the changed contracts, the edit-level checks, the
deferred batch checks and the live gates in the current task. Combine related
fixes before the batch pass. If a batch fails, fix the failure and rerun its direct
reproduction and affected dependents. Do not restart unrelated successful suites.
Record why any additional run is necessary: changed input, new failure, or a
specific unresolved risk. A new conversation turn, journal or archive is not a
validation trigger.

## Local selection map

Commands below are selections, **not a list to execute in order**. `tests/work.ntfs`
denotes the project's clean ordinary-file fixture; runners copy it before writes.
Check the runner's input requirements before substituting another fixture. Use
fresh output names under `_tmp/` for Python runners.

| Changed behavior | Edit-level starting point | Add once for the related batch |
| --- | --- | --- |
| C read/write, error propagation, dirty inode retry, sync or final close | `NFSK_BRIDGE_SUITES=core bash tests/run_bridge_regressions.sh tests/work.ntfs` | Swift lifecycle via `run_volume_concurrency.sh`; basic bridge integration where affected. Shared sync/close changes also require compressed write-guard lifecycle checks. Include ASan for ownership and TSan for changed serialization. |
| Directory lookup/enumeration, cursor or attributes | `NFSK_BRIDGE_SUITES=directory bash tests/run_bridge_regressions.sh tests/work.ntfs` | `run_volume_regressions.sh` for Swift packing/attributes; basic namespace operations if affected. Retain mutation, pagination, case, failed close and callback-stop assertions. |
| xattr read/list/write, allocation limit or buffer transfer | `NFSK_BRIDGE_SUITES=xattr NFSK_SANITIZE=address bash tests/run_bridge_regressions.sh tests/work.ntfs` | Swift xattr ownership in `run_volume_regressions.sh`; compressed named-DATA tests only for changes that reach that path. Retain 128 KiB limits and allocation/final-close failures. |
| Namespace basics, link/unlink/rename | `NFSK_BRIDGE_SUITES='core basic' bash tests/run_bridge_regressions.sh tests/work.ntfs` | Swift lifecycle/open-after-unlink; affected persistence scenarios if metadata ordering changes. |
| Allocation, truncate or preallocation | `bash tests/run_feature_regressions.sh tests/work.ntfs` | Core sync/error checks; compressed write-guard truncate/ENOSPC profiles when affected. `run_mft_allocation_regressions.sh` is a separate allocation-focused harness; inspect its inputs first. |
| Block backend range, partial I/O or workspace | `NFSK_SANITIZE=address bash tests/run_block_backend.sh` | For budget/allocator changes, `NFSK_BLOCK_HARNESS=tests/test_block_memory.m NFSK_SANITIZE=address bash tests/run_block_backend.sh`; TSan for cross-backend accounting/locks, and one volume path if resource/error semantics changed. |
| Swift volume lifecycle, sync/close or cancellation | `bash tests/run_volume_concurrency.sh tests/work.ntfs` | `run_volume_regressions.sh` for affected callbacks; `run_volume_queue.py` when queued sync/write/teardown order is involved. Do not run all C groups for a terminal Swift-only branch. |
| Request admission, retained payload or queue order | `python3 tests/run_volume_queue.py --sanitize thread --output _tmp/queue-edit` | ASan ownership pass and relevant lifecycle checks; `run_volume_memory.py` if returned-object or idle-retention behavior changes. Keep valid accepted writes, exact byte content, failure, cancellation, teardown and per-volume isolation. |
| Host mount identity/completion or sheet actions | `python3 tests/run_mount_completion.py --output _tmp/mount-edit`; use `--denial-case` / `--probe` only when applicable | `run_legacy_sheet.py` / `--modern` for changed UI consumers, ASan/TSan for relevant tasks and lifetime. No filesystem recovery matrix for a host-only identity change. |
| Other host state, diagnostics or preflight | Select `run_extension_status.py`, `run_host_observation.sh`, `run_image_preflight.sh`, `run_host_diagnostics.py`, or `run_diagnostic_tests.py --suite batches|memory` for the modified producer | Its actual consumers and affected availability branches. Read `--help` for output/selection flags. Shared diagnostic code can require both host and volume consumers. |
| Validation scripts or test selection | `python3 -B tests/test_validation_tools.py`, shell syntax / Python syntax checks | One relevant real invocation if wiring changed; no unrelated performance or fault matrix. |

Shell runners generally take `NFSK_SANITIZE=address|thread|undefined` where
supported; Python runners take `--sanitize`. Read each runner's accepted values:
bridge regressions support address/undefined; volume concurrency supports
address/thread; volume regressions support address only. Never silently substitute
one sanitizer for another.

The bridge runner accepts `NFSK_BRIDGE_SUITES='core basic directory xattr symlink'` (or
`all`, the default). Names are deduplicated in the original order; empty/unknown
selections fail before building. Core uses three compiler commands; the default
uses ten. The symlink group separately copies images for normal contents, retryable
faults, backend failures, a partial write, failed cleanup and Windows target resolution.
Core includes one small, unchanged upstream reparse source file with
allocation-lifetime observation hooks; it does not rebuild the archive. This
covers malformed reparse rejection without mistaking a caller-only ASan build
for upstream coverage. Every selected group keeps its complete assertions and a fresh image.
Do not use a narrow group as evidence that omitted groups ran.

## Preserving integrity and failure coverage

- **Content and structure:** retain exact native readback, reopen length/content,
  unrelated-file checks and the applicable independent allocation/structure
  oracle. `ntfs_image_check.py` supports uncompressed fixtures; use the compressed
  oracle for genuine compressed DATA. A test that only checks a return code is
  not an integrity test.
- **Errors, sync and close:** retain short-transfer/partial-success semantics,
  injected errno, failed flush/final-close propagation, retry ownership and
  queued/repeated sync after teardown. ASan alone does not replace these checks.
- **Memory and concurrency:** keep the relevant allocation limits, failure before
  unsafe I/O, zero remaining test-owned objects and overlapping allocation peaks.
  Preserve stalled I/O, cancellation, multiple volumes and cleanup assertions
  where affected. A wrapper-only sanitizer does not instrument a prebuilt libntfs
  archive or Apple frameworks. Use the already-built matching instrumented
  library for upstream concurrency acceptance when required; report coverage
  limits if it is unavailable.

For the current release restriction, run:

```sh
python3 tests/run_compressed_write_guard.py tests/work.ntfs \
  --sanitize address --swift --output _tmp/compressed-write-guard
```

This checks that compressed writable opens/writes/truncates return ENOTSUP and named-stream
changes return EPERM before any data mutation or backend write, preserve all contents/structure and
leave sync/close healthy. It includes empty/resident/nonresident data, inheritance,
per-stream flags, natural space pressure and prevented single-fault sites. Those
sites are prevented, not recovered. Ordinary writes and xattrs remain controls.
`test_compressed_write_guard.swift` checks actual Swift error propagation, writable
open admission in both lifecycle modes, and size request consumption against
regular-file fixtures; it is not installed acceptance.

The xattr error must be EPERM: Darwin can turn ENOTSUP into a successful
AppleDouble fallback. The opt-in installed image check
`XNTFS_TEST_COMPRESSED_GUARD=1` in `run_macos27_images.sh` requires a fixture with
the explicitly seeded compressed file, empty file, directory and named stream.
It verifies writable open/append/O_TRUNC/O_CREAT rejection (including inherited
compression), path truncate, xattr errors, unchanged bytes after each step,
successful sync/remount, and absence of a `._` sidecar. Reject writable opens
before the kernel caches bytes: a write-callback error alone left rejected bytes
visible during the live mount even though persisted data stayed unchanged.
Use the authorized disposable-image workflow; never enable this check on user
media. A failed run retains its image even after successful ordinary detach.

The following former finalization/recovery runners remain research tools for
frozen historical source or a future candidate that re-enables compressed writes.
They are not current-product acceptance commands: the release restriction
intentionally rejects writes that these historical tests expect to succeed.
Do not weaken their old recovery assertions to hide that policy change.

For historical ordinary compressed finalization, the bounded lifecycle command is:

```sh
python3 tests/run_compressed_regressions.py tests/work.ntfs \
  --new-tail --swift --sanitize address --output _tmp/compressed-batch
```

Read its reports: known old-tail and single-I/O recovery gaps remain. Neither a
successful comparison nor completion of a selected new-tail scope establishes
general compressed recovery. When changing compressed named-DATA, start with
`run_compressed_prefix.py --normal-only` and relevant
`run_compressed_xattr_matrix.py --profiles ...` (both require `--baseline-dir`
and `--output`). Select profiles from the changed layout/operation, not to hide
failures. Run the complete applicable matrix at the stable batch only when
compression/recovery logic, persistence ordering, oracle, fixture, fault schedule
or compiler/library configuration changed, or a new failure requires it.

Do not rerun unchanged crash-prefix or combined-failure matrices merely because
another test finished. Keep normal corruption, natural fragmented ENOSPC, single
I/O failures and failed rollback after an earlier failure classified separately.
For combined failures, stop expanding when errors remain honest, unsafe writes
stop, resources are released, and no simple bounded repair is supported by
evidence. Retain failing samples and the known-limit status; do not relabel them
as passed. A new or broader corruption still blocks that candidate.

## Build and result reuse

1. Rebuild the ntfs-3g archive only when its source/configuration, compiler/SDK,
   target architecture, feature macros or instrumentation changes. A wrapper edit
   does not require rebuilding it. Keep experimental libraries/configs isolated.
2. Freeze one related batch. Existing compressed matrix and benchmark runners
   already build each variant once and reuse the executable inside their loops.
   Do not invoke a whole driver again for each fault or timing round. Reuse the
   same baseline within a batch; do not recreate it for each adjacent fix.
3. Share compiled objects only when all source/generated-source/header inputs,
   flags/macros, SDK/compiler, architecture and sanitizer match. Different fault
   hooks produce different programs. ASan, TSan, uninstrumented timings and
   differently optimized builds are not interchangeable. No generic cross-runner
   cache is currently implemented; do not assume an old executable is current.
4. A prior result also depends on harness/oracle, fixture, selected cases, fault
   schedule and runtime environment. Record exact input fingerprints, scope,
   command and result path. If these cannot be established, rerun the affected
   test at the batch gate. Mark omitted or reused evidence explicitly rather than
   counting it as newly executed. A source change invalidates affected evidence,
   not automatically unrelated host/filesystem suites.
5. Reuse immutable build/seed inputs; give each mutating scenario an independent
   ordinary-file copy. Never hard-link writable images or reuse a failed working
   image as a clean seed. Remove owned large images after preserving required
   failure evidence. Do not build/register an app to satisfy a local harness.

Performance acceptance runs only for a candidate making a performance claim,
after correctness is stable. Keep the existing A/A noise control, alternating
A/B pairs, separate counting runs and memory observations. Do not time against
concurrent builds/tests. Reuse baseline measurements only within matching inputs
and comparable conditions; changed conditions or noise require fresh controls.
Do not repeat unchanged rejected candidates, all compiler profiles, or speed
benchmarks after documentation, host-only or correctness-only changes.

## Cost records and stopping repeated work

`run_bridge_regressions.sh`, `run_compressed_regressions.py` and
`run_volume_queue.py` write `timings.jsonl` next to their artifacts. Each record
contains phase, label, command, cwd, monotonic elapsed seconds and exit/timeout/
spawn-error outcome. Failed steps are retained; the record does not override the
runner's exit status or known-failure semantics. Logs stream as before; there is
no result cache or growing in-memory timing list.

These records measure child commands. Python oracles, image copies, hashing,
archiving and runner startup also cost time. Measure a **selected** full invocation
when a total is needed (create the parent report directory first):

```sh
mkdir -p _tmp/validation-batch
NFSK_BRIDGE_SUITES=core python3 tests/validation_timing.py \
  --output _tmp/validation-batch/suite-times.jsonl --phase suite --label bridge-core \
  -- bash tests/run_bridge_regressions.sh tests/work.ntfs
```

Report build time, child test time and outer suite time separately. Do not add
nested suite and child durations together. Do not infer total minutes saved from
compiler-command counts. The historical roughly two-hour workflow is a user
observation, not a measured per-stage baseline.

Use 5 minutes per edit pass and 30 minutes per related local batch as **review
thresholds**, not promises or permission to skip required checks. If a selected
pass exceeds them, inspect the timing breakdown and split independent work or
defer unrelated checks. Record necessary expensive coverage and its trigger;
do not silently time out the correctness gate or launch further matrices.
Keep logs/results for a batch and archive them once after review. Re-archiving
unchanged artifacts after every small fix has no acceptance value.

## Live acceptance remains separate

Mounted-image runners such as `run_macos27_images.sh` can sign/copy apps,
register extensions and attach images. They are not part of the default local
pass. Follow [build and signing](build.md),
[macOS 15 compatibility](macos15-compatibility.md) and
[macOS 27 support](macos27-support.md) for that stage.

Record each unavailable case as **NOT RUN**: enabled signed build, actual mounted
driver, sustained I/O and memory, sync/close/reopen/eject, unplug/reconnect,
Windows repair checks, required macOS versions and native Intel execution.
Compile/link on another architecture is not native execution; regular-file
`fsync` and modeled faults do not prove physical flush durability. Local passes
do not establish the cause of the earlier GAME incident.

For an authorized finite installed-image stability check, reuse the current
signed candidate and the owned MBR device route:

```sh
python3 -B tests/mounted_stability.py --self-test
XNTFS_TEST_STABILITY=1 bash tests/run_macos27_images.sh \
  /Applications/xntfs.app SIGNING_IDENTITY ntfs-test-mbr.img device
```

The opt-in is refused for `image` and `device-ro` before creating test artifacts.
The host validates the mounted driver/source/mode; the Python workload also
binds the device to the runner's exact attached image. It runs 2 warmup and 32
measured rounds, 4 workers, a 512 KiB body and 8 small files per worker/round.
It verifies every body and name set, calls fsync/close explicitly, and checks
the last 4 bodies against regenerated expectations after read-only remount.
The oracle self-test rejects corrupted, truncated and oversized controls; it is
not FSKit acceptance.

`stability-rw.json`, `stability-remount-ro.json` and `stability-events.jsonl`
contain completed work, operation latencies and ps RSS observations for the
installed extension instance that holds the owned partition's device descriptor,
including 10 seconds of idle. `lsof -b -nP` selects that instance from matching
executable paths before the load and confirms it afterwards; other idle/probe
instances are recorded separately. A missing/ambiguous device owner or changed
PID/start time fails the observation gate. Memory
samples are observed resident memory, not live allocations or a general limit.
Report actual workload duration; a finite pass is not long-duration, arbitrary
concurrency, physical-device or power-loss acceptance. After 120 seconds the
workload stops admitting the next work unit; an admitted unit still waits for
its operations to return. Pending system I/O is never declared cancelled.
Failures retain the test image through the existing normal-detach cleanup.
