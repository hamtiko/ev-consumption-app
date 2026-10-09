# Verification

Development environment: Linux with an official temporary Swift 6.0.3 toolchain. The app itself has no toolchain-download dependency.

## Passed

- **23 XCTest calculation tests compiled and ran with zero failures.** Coverage includes the screenshot's January totals; independent Trip A/B periods; partial and deferred outside charging; charge ownership at cycle boundaries; per-record prices; tariff and single-counter continuity; backdated validation; weighted consumption; and zero distance.
- New tests exercise pending outside-cycle reports, later home data completing both adjacent reports, carrying forward an unchanged meter, confirming no home charging across several pending checkpoints, excluding future/unknown readings, complete energy windows spanning several trips, and monthly mileage without any meter reading or Trip B reset.
- Swift compiler parsing of all native app and native test sources in Swift 5 language mode.
- Xcode project and source checks: source membership, all object references, shared scheme, local package, test sources, and asset catalog files.

## Requires Xcode / an iPhone

Apple frameworks and an iOS SDK are unavailable on Linux. The following have **not** run:

- Full iOS type checking, linking, simulator launch, and visual review.
- Native tests for SwiftData persistence, home-data completion metadata, CSV export, idempotent legacy monthly conversion, and the notification trigger.
- Upgrade of a real pre-update SwiftData store to the expanded model schema. Existing data is retained by design; device migration still needs verification.
- Notification permission, time changes, disabling, foreground presentation, and cold-launch routing.

Run **⌘U** in Xcode. Exercise all five workflows, deferred sessions, upgrading a saved outside session to 100%, both home-data completion actions, editing an outside payment after completing its home reading, and monthly notification routing. Check upgrade with existing records and CSV export. No iOS build success is claimed from source checks alone.
