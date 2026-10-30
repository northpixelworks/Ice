# Installer failure handling

Run from the repository root with Python 3.9+ and Bash:

```sh
python3 scripts/test-build-and-install.py
bash -n build-and-install.sh
```

No third-party Python packages, Xcode, built application, certificate, or macOS
host are needed. `.github/workflows/test-installer.yml` runs the same tests on
Linux and macOS. The macOS job still uses mocks; it is not live signing or TCC QA.

## Isolation

Each test creates its own temporary directory (including spaces in its name),
fake old/new app bundles, destination, backup directory, HOME, and TMPDIR. The
installer runs as a subprocess with a fresh environment rather than inheriting
the caller's `ICE_*` settings. `ICE_INSTALL_SOURCE` bypasses builds/downloads;
`ICE_INSTALL_APP_PATH` always points inside the test directory.

PATH is a closed directory containing only selected shell utilities and mocks.
`security`, `openssl`, `codesign`, `ditto`, `open`, `pkill`, `sleep`, `date`, `mv`,
`rm`, `ln` and `readlink` cannot fall through to the host's versions. The mock `find` delegates
to the host's read-only utility except when injecting an enumeration failure.
The mocks `mkdir` and `mktemp` check every path (and `mktemp`'s created path)
against the test root before delegating to the host utility; `mktemp` also
requires an explicit template, since macOS ignores `TMPDIR` without one.
Filesystem mocks reject paths outside the test root and any path with a `..`
component (`mkdir -p` would create folders along the way before resolving it), and keychain import is
simulated against a fake path. No real keychain is read or changed, no app is
launched or stopped, and `/Applications/Ice.app` is never targeted. Fake private
key files are created so failure-path cleanup can be asserted. The harness
removes each fixture after the assertions, even when a test fails. The mocks
start with `#!/usr/bin/env python3` and the closed PATH links `python3` to the
interpreter running the tests, so a Python path with spaces (e.g. a virtual
environment in a folder named `Ice fork`) still works.

## Coverage and expected behavior

The 34 black-box tests invoke the complete production installer (plus one
harness self-test for the `..` guard):

| Scenario | Expected result |
| --- | --- |
| Missing identity; certificate generation, PKCS#12 export, or import failure | Nonzero exit before stopping Ice or moving the destination; remove fake secrets |
| Root or nested bundle signing failure | Existing app unchanged; no stop/launch; remove staging |
| Staging copy or staged signature verification failure | Existing app unchanged; no stop/launch; remove staging |
| Nested-bundle enumeration failure | Abort before installation instead of silently skipping nested signing |
| Destination copy partially writes then fails | Restore the exact old fixture; preserve failure status; relaunch only if stopped and launch enabled |
| Destination verification failure | Remove replacement and restore old fixture; honor no-launch |
| Failed first copy or first verification | Remove incomplete app when there was no previous installation; if removal fails, report the app path |
| Backup collision: directory, file, dangling symlink | Abort before stop/move; leave old app and collision untouched |
| Moving old app to backup fails, or creating the backup folder fails | Existing app retained; staging cleaned; failure status preserved |
| Backup move fails after writing a partial backup (cross-filesystem `mv` copies) | Existing app retained, never replaced by the partial backup |
| SIGTERM (e.g. closed terminal) while the backup `mv` is still running, right after it, or during the destination copy | Wait for the running command, then restore the old fixture; relaunch only if stopped; exit by the signal |
| SIGTERM while rollback's `mv` puts the old app back | Finish that rollback once, keep the restored app, then exit by the signal |
| Removing incomplete app fails during rollback | Leave backup recoverable at its original path; never move it into the partial app; clean staging |
| Moving backup back fails | Keep backup at reported path; clean staging; preserve original error status |
| Successful replacement | Sign nested bundles before containing app; verify before launch; retain old backup |
| Explicit ad-hoc opt-in | Sign with `-`; do not create an identity |
| Second installer while the first holds the lock (after the backup name is chosen, or during the copy) | Exit 75 before building, keychain or `/Applications` work; old app, partial copy and backup untouched; first installer finishes with exactly one backup |
| Any normal, failed or signal exit | Lock released last, after recovery and cleanup |
| Lock left by a SIGKILLed installer, or held by a live process | Exit 75; report PID and whether it runs; never remove someone else's lock |
| Lock path occupied by a directory | Exit 1 without using or changing it |
| Stale lock in a folder whose name has an apostrophe or spaces | Printed `rm` command is shell-escaped (`%q`) and removes the lock when pasted |
| First install into a folder that does not exist yet | Create the folder, take the lock, install; no backup |

The mocks deliberately return status 23 for injected command failures, allowing
tests to detect an EXIT handler that accidentally replaces the original status.
Assertions inspect bundle contents, source immutability, backup contents,
temporary directory removal, and logged command arguments/order.

## Review findings and fixes

Reviewed baseline:
[`44070b6`](https://github.com/northpixelworks/Ice/commit/44070b6df7ff189f990f272a9709437008bdac01).
The successful [artifact build](https://github.com/northpixelworks/Ice/actions/runs/40852527987)
does not exercise installer recovery.

- The early bare `return` in `restore_backup_if_incomplete` could retain the
  failing status when called from the EXIT trap. Under `set -e`, this skipped
  `cleanup_tmpdirs`, leaving staging or private-key files. The trap now captures
  the original status, disables errexit for recovery/cleanup, and exits with the
  captured status. The no-recovery branch explicitly returns zero.
- A failed first installation left its partial/unverified destination behind.
  `INSTALL_STARTED` now marks when destination copying may have written files;
  incomplete destinations are removed even without a previous backup.
- `[[ -e ... ]]` did not detect a dangling symlink occupying the backup name.
  Backup/destination existence checks now include `-L`.
- A failed removal during rollback previously prevented later cleanup. With
  recovery made best-effort, removal must also be explicitly checked to avoid
  nesting the old app inside a still-existing partial destination. On failure,
  the backup stays at its reported location.
- A follow-up review found that `BACKUP_PATH` and `INSTALL_STARTED` were only
  set after the backup `mv`. A SIGTERM or SIGHUP arriving during that `mv` ran
  the EXIT trap with recovery still off, leaving the destination missing (the
  old app only in the backup folder). Both are now set before the move;
  recovery skips the rollback when the recorded backup does not exist yet, so a
  failure before or during the move never deletes the installed app. The mocks
  send SIGTERM to the installer to cover this. A failed removal on a first
  install now names the app path instead of an empty backup path.
- A Copilot review of that fix found two remaining gaps. (1) With only an EXIT
  trap, bash ran recovery as soon as SIGTERM arrived, while the backup `mv` was
  still running; recovery saw no backup yet and skipped, then `mv` moved the app
  away. HUP, INT and TERM now have their own trap: bash runs it only after the
  running command returns, then recovers, cleans up and exits by the same
  signal. (2) The "backup exists" check let recovery replace an intact app with
  a partial backup left by a failed cross-filesystem `mv`. Recovery now never
  touches an app at the destination until `COPY_STARTED` marks that the copy of
  the new app has begun.
- Copilot's review of that change found that the new signal traps stayed active
  during recovery: a SIGTERM while rollback's `mv` put the old app back ran
  recovery a second time, which deleted the restored app with the backup already
  used up. Recovery now runs once; a signal arriving during it is only recorded,
  and the installer exits by that signal after recovery and cleanup finish.
- Concurrent installers (2026-10-29): there was no lock. With the clock mocked
  to one second, a second installer started while the first sat between the
  backup-name check and its `mv` chose the same backup name and installed
  completely; the first would then have moved the second's app into that
  backup. Reproduced against the unlocked script by
  `test_second_installer_refused_in_backup_name_window` (and the copy-window
  test), not on a real Mac. The installer now takes a per-destination lock
  first: a symlink `.<App>.app.install-lock` next to the app whose target is
  `<PID>-<random>`. `ln -sn` creates it atomically together with its owner, so
  no signal leaves an ownerless lock; ownership is checked by reading it back.
  `finish` releases it after recovery and cleanup (once, also on HUP/INT/TERM),
  and only if the token is its own. A refused installer exits 75 without
  touching anything.
- Process substitution hid `find` failures. On this Linux execution host,
  `/dev/fd` process substitution also failed and nested bundles were skipped.
  Enumeration now writes a NUL-delimited list inside staging and checks `find`'s
  status before signing. This retains inside-out traversal and filenames with
  spaces without relying on process substitution.

Local validation on 2026-10-29: all 21 tests passed under Linux, Python 3.12.14,
Bash 5.2.21; shell syntax and `git diff --check` passed. Real macOS/Xcode tests
were not run in this Linux environment. The new macOS CI job must be checked
separately; its presence is not evidence that it has already passed.

macOS validation on 2026-10-29: all 21 tests passed on a Mac mini (Apple
silicon), Python 3.14.10, system Bash 3.2.57; shell syntax and `git diff --check`
passed. This needed one fix: macOS `mktemp -d` ignores `TMPDIR` without a
template, so the installer now creates temporary directories via `make_tmpdir`
with an explicit `${TMPDIR:-/tmp}/ice.XXXXXX` template. Still mocks only, not
the real-Mac checks below.

Lock validation on 2026-10-29: all 35 tests (34 installer tests plus the
harness self-test) passed on a MacBook (Apple silicon), Python 3.15.2, system
Bash 3.2.57; the six concurrency/lock tests also passed five repeated runs.
Before the fix, five of them failed against the unlocked script, reproducing
the race in mocks. Shell syntax and `git diff --check` passed. Linux (Bash 5)
was not run locally; check the CI job.

Review follow-up on 2026-10-30 (Copilot on PR 6): the lock broke first installs
into a missing folder (`ln` cannot create the lock there) and printed an `rm`
command with unmatched quotes for paths containing `'`. The installer now
creates the destination folder before locking and prints the command with
`printf %q`. Both new tests failed against the previous script and pass now;
all 37 tests passed on a MacBook (Apple silicon), system Bash 3.2.57.

## Additional checks on a real Mac

Use a disposable macOS account or VM snapshot and a test copy of Ice. Keep the
production `/Applications/Ice.app`, production keychain, and user's TCC grants
out of the exercise. A redirected app destination alone does **not** isolate
keychain access or `pkill -x Ice`: use the no-stop/no-launch flags for file-only
checks, and isolate the user/session before exercising real stopping/launching.
For real identity creation, use a disposable account with a disposable default
keychain; restore that account's keychain settings afterward. Do not run a real
`tccutil reset` against the production account as part of this test suite.

Record macOS version/build, architecture, Bash/OpenSSL versions, certificate
fingerprints, designated requirements, command results, and observed prompts.

- **Signing/keychain:** exercise existing self-signed identity lookup (without
  `find-identity -v`), new identity creation/import, locked keychain or denied
  private-key access, and OpenSSL PKCS#12 compatibility. Confirm reuse of the
  same certificate fingerprint, not merely the same common name. Inspect the
  installed bundle with `codesign -d -r- --verbose=4 <app>` and verify with
  `codesign --verify --deep --strict <app>`. Check real nested XPC/framework code
  and Sparkle loading; mock fixtures contain no Mach-O executables.
- **TCC:** in the disposable account, approve Accessibility and Screen Recording
  for the old test installation, install two distinct builds using the same
  certificate, and verify the grants and actual event/capture functionality
  after relaunch. Repeat rollback and compare the restored app's requirement.
  Separately test missing permissions, changed certificates, and explicit
  ad-hoc signing. Record whether reapproval is needed. Signature verification
  alone cannot establish TCC continuity; the installer's success message is an
  expectation, not a measured guarantee.
- **Launch Services:** verify explicit-path launching opens the installed
  bundle, and rollback relaunches the restored one only when the installer
  stopped it. Inspect the running executable's path and registrations for
  stale build/staging/backup copies with the same bundle identifier. Exercise
  Finder reopening and Settings activation. Temporary `.noindex` paths and
  mocked `open` cannot establish Launch Services registration behavior.
- **Real filesystem behavior:** exercise `ditto` on APFS with a test bundle,
  resource forks, extended attributes, symlinks and permissions. Inject copy
  and verification failures only against the disposable destination; compare
  restored contents/metadata/signature. Test unwritable paths and record the
  backup location if recovery itself cannot complete. The filesystem mocks
  check control flow, not APFS/ditto metadata semantics.

Recovery covers ordinary command failures reaching the EXIT trap. It is not a
crash-safe transaction. Remaining limits of recovery and the install lock:

- **SIGKILL, crash, power loss:** no trap runs. The destination may be missing
  (old app only in `Ice-backups.noindex`) or half-copied, staging/key temp
  folders stay, and the lock stays (it is on disk, so it survives a reboot).
  Every later installer refuses with exit 75 and prints the PID. Restore by
  hand from the newest backup if needed, then remove the lock with the printed
  `rm` command.
- **Orphaned locks are never broken automatically.** `kill -0` is only a hint:
  after a reboot the PID may belong to an unrelated process (reported as still
  running), and another user's process looks "not running". Deciding that the
  owner is gone stays with the user, because a wrong guess would reopen the race.
- **Scope:** the lock only coordinates this installer for the same destination
  folder and app name. Different destinations still share the keychain
  identity creation and the `build.noindex` build folder, and Finder, other
  tools or a manual copy ignore the lock. A different filesystem view of the
  folder (e.g. a network mount without symlink support) is not covered.
- **Same-second reinstall:** a sequential second install within the same second
  still aborts on the backup collision check (unchanged, before stopping Ice).

Concurrency tests use real processes held at file gates inside the mocks, so
they are deterministic, but they still run against mocks and temp folders only. The harness does not
validate the build/artifact download paths or replace the app's XCTest suite.
