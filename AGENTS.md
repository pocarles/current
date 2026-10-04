# Current

Current is a native macOS menu-bar utility built with SwiftPM, AppKit and SwiftUI. Keep third-party dependencies minimal. Core accounting, connectivity policy and SQLite storage live in TrafficCore. The app model supports injected clocks, counters, probes and history failures for safe tests.

Use `./scripts/swift.sh test` for the full suite and `./scripts/build-app.sh` for the optimized local app. The wrapper puts compiler caches in this project. Set `TRAFFIC_PREVIEW_DIR="$PWD/docs/previews"` on the test command to regenerate sample-data renders.

Preserve these invariants:

- Count interface deltas, exclude VPN tunnel counters, and rebaseline on resets, interface changes and wake.
- Do not sum overlapping minute/hour/day tiers. Preserve totals, measured peaks, downtime and coverage.
- Keep observed zero, sleep, app gaps and missing readings distinct. Never retry a committed batch because a display query failed.
- Probe responses must match the expected endpoint result. Bound time and stored body size, decline redirects and confirm failures before alerting.
- Use synthetic outages. Do not disrupt the Mac's network for a test.
- Report actual CPU and physical footprint measurements with their duration and UI state. RSS is a different metric. Do not claim battery savings from these tests.

Public repositories, release publication, login installation, signing purchases and security-setting changes require an explicit user request.
