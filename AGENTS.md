# Ice Agent Instructions

<!-- BEGIN:cross-agent-agent-rules -->
## Cross-Agent Compatibility

This repository is prepared for both Codex and Claude Code. `AGENTS.md` is the single instruction file for every agent; keep durable project instructions here.

### Start Here
- [README.md](README.md) — README.
- [ARCHITECTURE.md](ARCHITECTURE.md) — architecture, system boundaries, and verification.
- [docs/AGENT_GUIDE.md](docs/AGENT_GUIDE.md) — agent guide.

### Common Commands
- Xcode project: inspect schemes with `xcodebuild -list -project Ice.xcodeproj` before building.
- Debug build after confirming the scheme: `xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Debug build`.
- Use a full Xcode installation; Command Line Tools alone are not enough for normal project builds.
- macOS tests: `xcodebuild -project Ice.xcodeproj -scheme Ice -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`.

### Working Rules
- Keep changes small, reviewable, and tied to the requested behavior.
- Prefer existing architecture, naming, and helper patterns over new abstractions.
- Validate data at system boundaries instead of relying on guessed shapes.
- Update docs when behavior, commands, architecture, or setup changes.
- Run the narrowest relevant verification first, then broader checks when risk warrants it.
- If a command cannot run, record the blocker and the residual risk in the handoff.
<!-- END:cross-agent-agent-rules -->

## Notes

- This app touches menu bar internals, Accessibility, Screen Recording, CoreGraphics windows, event monitoring, and private bridging APIs. Keep changes narrow and verify manually when touching those paths.
- `AppState` owns the long-lived managers; avoid creating parallel global state.
- Persist settings through `Defaults.Key` and add migrations when stored values change.
- Test both missing-permission and granted-permission launch paths when changing startup or permissions code.
