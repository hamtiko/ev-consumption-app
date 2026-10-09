# Verification

Development environment: Linux. A temporary official Swift 6.0.3 toolchain was used to compile and test the independent calculation package. The app itself has no toolchain-download dependency.

## Passed

- **14 XCTest calculation tests compiled and ran with zero failures.** They cover the screenshot's January values (736.98 kWh, 35,006.55 AMD using the single price, and 34,868.0904 AMD using T1/T2); overlapping month/cycle boundaries; partial outside charging; charge ownership at a 100% boundary; per-record prices; T1/T2 pricing; missing months; late readings; weighted consumption; zero distance; backdated validation; decimal input; stable month identifiers; and preserving optional partial-charge Trip B readings without adding their distance twice or closing the cycle.
- Swift compiler parsing of all native app and native test sources in Swift 5 language mode.
- Parsing of all Swift sources and the package manifest with the Swift tree-sitter grammar.
- Parsing and structural validation of the Xcode project: all object references resolve, every app source is included, test files exist, the shared scheme points to the correct targets, and asset catalog files resolve.

## Requires Xcode / an iPhone

Apple frameworks and an iOS SDK are unavailable on Linux, so the following have **not** been run:

- Full iOS app type checking, linking, simulator launch, and visual review.
- Native `AppTests` for SwiftData persistence (including outside-charge kilometres), CSV export, and the notification trigger.
- Notification permission acceptance/denial, time changes, disabling, foreground presentation, and tapping a reminder to launch the month form from a closed app.

Run the app and press **⌘U** in Xcode. Exercise all three entry flows; edit an older reading and price; verify partial charging and combined month/full-charge entries; export CSV; and test the reminder on a device. No iOS build success is claimed from the source checks alone.
