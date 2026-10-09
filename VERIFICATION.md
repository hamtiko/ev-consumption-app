# Verification

Development environment: Linux with an official temporary Swift 6.0.3 toolchain. The app itself has no toolchain-download dependency.

## Passed

- **28 XCTest calculation tests compiled and ran with zero failures.** Coverage includes the screenshot's January totals; independent Trip A/B periods; partial and deferred outside charging; charge ownership at cycle boundaries; per-record prices; tariff and single-counter continuity; backdated validation; weighted consumption; and zero distance.
- New tests exercise pending outside-cycle reports, later home data completing both adjacent reports, carrying forward an unchanged meter, confirming no home charging across several pending checkpoints, excluding future/unknown readings, complete energy windows spanning several trips, and monthly mileage without any meter reading or Trip B reset.
- Unified-flow coverage verifies monthly utility costs with optional mileage, separate outside payments, single/tariff prices and intermediate cycle segments, shared latest-meter selection across cycle/monthly records, and the first monthly reading leaving unavailable totals unknown.
- Swift compiler parsing of all native app and native test sources in Swift 5 language mode.
- Two Foundation date tests passed in a standalone Linux XCTest harness using the app's month helper: automatic month selection for on-time/late readings, January and leap-year boundaries, and local-timezone month boundaries. The SwiftUI form itself still requires Xcode verification.
- Xcode project and source checks: source membership, all object references, shared scheme, local package, test sources, and asset catalog files.

## Requires Xcode / an iPhone

Apple frameworks and an iOS SDK are unavailable on Linux. The following have **not** run:

- Full iOS type checking, linking, simulator launch, and visual review.
- Native tests for SwiftData persistence (including monthly meters with omitted mileage), home-data completion metadata, CSV export, idempotent legacy monthly conversion, and the notification trigger.
- Upgrade of a real pre-update SwiftData store to the expanded model schema. Existing data is retained by design; device migration still needs verification.
- Notification permission, time changes, disabling, foreground presentation, and cold-launch routing.

Run **⌘U** in Xcode. Exercise the unified 100% cycle with home-only, outside-only and mixed charging, deferred sessions and label-only removal, unavailable home data and both completion actions, editing an old linked outside payment after home completion, and upgrading an old standalone outside session. Verify counter prefill from both cycle and monthly records, backdated prefill without overwriting edited counters, both meter formats, monthly meter-only and meter-plus-mileage entries, old mileage-only editing, paired monthly deletion, and notification routing. Check upgrade with existing records and CSV export. No iOS build success is claimed from source checks alone.
