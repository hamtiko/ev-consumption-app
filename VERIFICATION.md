# Verification

Development environment: Linux with an official temporary Swift 6.0.3 toolchain. The app itself has no toolchain-download dependency.

## Passed

- **42 XCTest calculation tests compiled and ran with zero failures.** Coverage includes the screenshot's January totals; independent Trip A/B periods; partial and deferred outside charging; charge ownership at cycle boundaries; per-record prices; tariff and single-counter continuity; backdated validation; weighted consumption; and zero distance.
- New tests exercise pending outside-cycle reports, later home data completing both adjacent reports, carrying forward an unchanged meter, confirming no home charging across several pending checkpoints, excluding future/unknown readings, complete energy windows spanning several trips, and monthly mileage without any meter reading or Trip B reset.
- Unified-flow coverage verifies monthly utility costs with optional mileage, separate outside payments, single/tariff prices and intermediate cycle segments, shared latest-meter selection across cycle/monthly records, and the first monthly reading leaving unavailable totals unknown.
- Fourteen report-analytics tests cover weighted averages versus cycle extrema, exclusion of pending/unknown/zero-distance cycles, automatic inclusion after home-data completion, source shares and prices, case/whitespace brand grouping, separate unspecified brands and locations, free/zero energy, date-window and timezone boundaries, year-to-date filtering, consecutive monthly comparisons, and zero comparison baselines.
- Swift compiler parsing of all native app and native test sources in Swift 5 language mode.
- Two Foundation date tests passed in a standalone Linux XCTest harness using the app's month helper: automatic month selection for on-time/late readings, January and leap-year boundaries, and local-timezone month boundaries. The SwiftUI form itself still requires Xcode verification.
- Xcode project and source checks: source membership, all object references, shared scheme, local package, test sources, and asset catalog files.

## Requires Xcode / an iPhone

Apple frameworks and an iOS SDK are unavailable on Linux. The following have **not** run:

- Full iOS type checking, linking, simulator launch, and visual review.
- Native tests for SwiftData persistence (including monthly meters with omitted mileage and optional station brands), home-data completion metadata, CSV export (including quoted brand names and preserved column positions), idempotent legacy monthly conversion, and the notification trigger.
- Upgrade of a real pre-update SwiftData store to the expanded model schema. Existing data is retained by design; device migration still needs verification.
- Notification permission, time changes, disabling, foreground presentation, and cold-launch routing.
- Native chart selection and navigation, searchable brand entry, Dynamic Type layouts, and upgrading an existing store with the new optional brand field.

Run **⌘U** in Xcode. Exercise the unified 100% cycle with home-only, outside-only and mixed charging, deferred sessions and label-only removal, unavailable home data and both completion actions, editing an old linked outside payment after home completion, and upgrading an old standalone outside session. Verify counter prefill from both cycle and monthly records, backdated prefill without overwriting edited counters, both meter formats, monthly meter-only and meter-plus-mileage entries, old mileage-only editing, paired monthly deletion, and notification routing. Check upgrade with existing records and CSV export. No iOS build success is claimed from source checks alone.

For Reports, check both trend charts and point-to-detail navigation, minimum/maximum and weighted averages, pending cycles joining after home completion, all date filters, monthly comparisons, brand entry in new/deferred/old linked sessions, brand chart switches, unassigned-brand visibility, session editing from brand/cycle details, and CSV brands with quotes. Core test files are discovered by the project generator so these calculation tests also run under ⌘U.
