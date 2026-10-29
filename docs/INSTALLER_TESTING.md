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
and `rm` cannot fall through to the host's versions. The mock `find` delegates
to the host's read-only utility except when injecting an enumeration failure.
Filesystem mocks reject paths outside the test root, and keychain import is
simulated against a fake path. No real keychain is read or changed, no app is
launched or stopped, and `/Applications/Ice.app` is never targeted. Fake private
key files are created so failure-path cleanup can be asserted. The harness
removes each fixture after the assertions, even when a test fails.

## Coverage and expected behavior

The 25 black-box tests invoke the complete production installer:

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
| SIGTERM (e.g. closed terminal) right after the backup move, or during the destination copy | Restore the old fixture; relaunch only if stopped; exit by the signal |
| Removing incomplete app fails during rollback | Leave backup recoverable at its original path; never move it into the partial app; clean staging |
| Moving backup back fails | Keep backup at reported path; clean staging; preserve original error status |
| Successful replacement | Sign nested bundles before containing app; verify before launch; retain old backup |
| Explicit ad-hoc opt-in | Sign with `-`; do not create an identity |

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
crash-safe transaction: SIGKILL, power loss, concurrent installers, external
destination changes, and backup-name races after the preflight check are not
covered. Run one installer per destination at a time. The harness does not
validate the build/artifact download paths or replace the app's XCTest suite.
