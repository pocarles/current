# Contributing

Keep Current native and small. Prefer fixes with a clear user-visible outcome and a focused regression test. Avoid new dependencies unless they solve a problem that the system frameworks cannot handle simply.

Run `./scripts/swift.sh test` and `./scripts/build-app.sh` before submitting a pull request. Explain the trigger, changed behavior and checks performed. Native window tests need a connected Mac window server. Use isolated preferences and synthetic network failures.

Preserve the accounting and history rules. Rebaseline on wake and counter resets, exclude VPN tunnel counters from physical totals, keep retention queries disjoint, and distinguish observed zero from sleep and missing data. Bound connectivity requests and confirm failures before outage alerts. Never put credentials or personal history in tests, logs or issue attachments.

Release signing and publication are maintainer operations. Local builds are for development.
