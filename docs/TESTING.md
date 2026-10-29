# XCTest verification

`.github/workflows/test.yml` runs the shared `Ice` scheme, including
`IceTests.xctest`, for every push to `main` and every pull request targeting
`main`. There are no path filters or test exclusions. A failed `xcodebuild`
command fails the check; the job has a 30-minute timeout.

Use a full Xcode installation and inspect the schemes before running locally:

```sh
xcodebuild -list -project Ice.xcodeproj
xcodebuild -project Ice.xcodeproj -scheme Ice -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

## Runner and toolchain

The test job uses the ARM64 `macos-26` hosted runner and explicitly selects
`/Applications/Xcode_26.6.app/Contents/Developer` through `DEVELOPER_DIR`.
This matches the macOS 26.6.2 / Xcode 26.6 combination in the successful
[October 18 build](https://github.com/northpixelworks/Ice/actions/runs/39128613586).
The [runner image inventory](https://github.com/actions/runner-images/blob/macos-26-arm64/20261013.0424/images/macos/macos-26-arm64-Readme.md)
lists that installation. Runner images can change; the workflow logs the OS,
Xcode version, and schemes so a removed toolchain or environment change is
visible. The previous successful build established app build compatibility,
not XCTest success.

The test command disables signing only for this job. The existing build and
lint workflows, release artifact packaging, and signing configuration are
unchanged.

## Platform dependencies and coverage limits

- `ModernVisibilityLifecycleTests` injects a fake workspace, snapshots, and
  assertion operations. Its lifecycle and allowlist regressions can run on
  macOS 26 without the private macOS 27 hiding service. Sleep/wake and session
  tests post workspace notifications rather than changing the real session.
- `MenuBarAccessDiagnosticTests` injects permission checks, including the
  explicit retry regression. It does not require granting Accessibility or
  Screen Recording access. Smart-rehide permission cases also use supplied
  data rather than live Screen Recording authorization.
- `ModernMenuBarHealthTests.testRunningSystemAgentHasUsableKernelIdentity`
  looks for a real `com.apple.MenuBarAgent`. Its existing `XCTSkip` reports an
  unavailable service; if the service is present, identity assertions still
  run and can fail. Do not interpret a skipped test as verified integration.
- `MenuBarPointerEventTests.testMenuBarFrameReusesOneAutoHidePreferenceRead`
  requires an AppKit screen (`NSScreen.main` or `NSScreen.screens.first`). The
  hosted test bundle also launches `Ice.app`. A usable macOS GUI session is
  therefore required; a headless machine without a screen is not equivalent.

No blanket skips, automatic retries, or ignored failures are added for these
dependencies. Inspect the XCTest output when a runner-specific failure occurs.
Actual macOS 27 MenuBarAgent/private assertion behavior, real permission grant
and revocation, login-item status, and launch paths with permissions granted
or missing still require manual verification on an appropriate macOS system.
See [the architecture verification guidance](../ARCHITECTURE.md#build-and-verification)
and [macOS 27 verification](MACOS_27.md).

## Initial validation

The workflow YAML, event filters, permissions, shell syntax, and exact test
command were checked during implementation. On 29 October 2026 the exact test
command ran locally on macOS 27 with Xcode 27.1 (Mac mini, GUI session):
97 tests passed, 0 failed, 0 skipped (`** TEST SUCCEEDED **`).
`testRunningSystemAgentHasUsableKernelIdentity` found a live
`com.apple.MenuBarAgent` and passed rather than skipping. The hosted
`macos-26` / Xcode 26.6 run has not happened yet; the first Actions run must
confirm test compilation, unsigned host launch, and execution there.
