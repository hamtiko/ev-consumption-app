# Horizontal chart alignment verification

Verified on November 13, 2026. Work began from main at `9ec06e9c109627e3d182516b0c5da0a60e97159c`; the final fix is based on `f568cfc0ea3e67699350e7bc9f705fa715333642`, which arrived during verification and changes unrelated entry-form scrolling. Its changes were preserved, and the final native build/test copy matches every current Swift source.

## Result

Station names and Home/Outside labels now use a shared layout. Each label's complete layout frame is centered at the category coordinate returned by `ChartProxy.position(forY:)`, translated through the actual plot frame. Category labels have a reserved leading gutter; station values have a separate gutter measured from their formatted text. Row height scales with Dynamic Type. The final row has room above the numeric axis. Larger type uses two numeric endpoint ticks to prevent crowding. Source statistics stack when their full values cannot fit side by side.

The original leading-axis/aligned-preset implementation was reproduced in the simulator: short label glyphs were approximately 18 points above their bars. The final screenshots visibly center both short names and wrapped labels. All 77 measured category frames across 27 final screenshots are within 0.5 points of the colored bar centers (rasterization tolerance); neighboring label frames do not intersect. Category frames stay outside the plot with an 8-point gap. Station amounts, including 110,400 AMD, are readable without overlapping the bars. Numeric axis ticks are readable and separate at the tested sizes.

## Simulators and isolation

- iPhone 17e, iOS 26.5 (23F77), portrait, 390 × 844 points, 3× display scale.
- iPhone SE (3rd generation), iOS 18.3.1 (22D8075), portrait, 375 × 667 points, 2× display scale.
- Xcode 27.2 (27B52), Debug simulator builds, signing disabled.

Both simulators were created specifically for this work. The app target was built with temporary in-memory rendering fixtures and a separate bundle identifier. Fixtures rendered the production `BrandComparisonChart`, `ChargingSourceChart`, and `ReportCard` views inside a navigation stack and scroll view. The fixture's outer padding was 18 points (slightly narrower than ReportsView's 16 points). No journal was opened and no CloudKit service was started by the fixture app. No production data was changed. The fixture app entry point, measure-selection argument, and frame instrumentation were confined to a temporary source copy and are excluded from the commit. No fabricated journal records or import files are included.

The station fixture has Unspecified, iCharge, EVAN, and Long Station Name Downtown, with different energy/spending/session ordering. The single-station fixture has only the long-name station. Source energy is Home 1,223.2 kWh and Outside 1,123.2 kWh. Each matrix screenshot was captured with `simctl io screenshot` after launching the requested fixture and allowing layout to settle. PNGs are unmodified simulator screenshots.

## Before and after

| Chart | Before (`9ec06e9`) | After |
| --- | --- | --- |
| Stations, kWh, default text | [Before](before-stations-kWh.png) | [After](after-stations-kWh-default.png) |
| Home versus outside, default text | [Before](before-source.png) | [After](after-source-default.png) |

## Coverage

Default text is SwiftUI DynamicTypeSize.large; larger text is .xxxLarge; accessibility text is .accessibility1. Long names wrap to three lines and may truncate at accessibility sizes, with their full names retained in chart accessibility labels.

| Device | Case | Default | XXX Large | Accessibility 1 |
| --- | --- | --- | --- | --- |
| iPhone 17e | Multiple stations, kWh | [Screenshot](after-stations-kWh-default.png) | [Screenshot](after-stations-kWh-large.png) | [Screenshot](after-stations-kWh-accessibility.png) |
| iPhone 17e | Multiple stations, AMD | [Screenshot](after-stations-AMD-default.png) | [Screenshot](after-stations-AMD-large.png) | [Screenshot](after-stations-AMD-accessibility.png) |
| iPhone 17e | Multiple stations, Sessions | [Screenshot](after-stations-Sessions-default.png) | [Screenshot](after-stations-Sessions-large.png) | [Screenshot](after-stations-Sessions-accessibility.png) |
| iPhone 17e | Single station, kWh | [Screenshot](after-single-kWh-default.png) | [Screenshot](after-single-kWh-large.png) | — |
| iPhone 17e | Single station, AMD | [Screenshot](after-single-AMD-default.png) | [Screenshot](after-single-AMD-large.png) | — |
| iPhone 17e | Single station, Sessions | [Screenshot](after-single-Sessions-default.png) | [Screenshot](after-single-Sessions-large.png) | — |
| iPhone 17e | Home versus outside | [Screenshot](after-source-default.png) | [Screenshot](after-source-large.png) | [Screenshot](after-source-accessibility.png) |
| iPhone SE | Multiple stations, kWh | [Screenshot](after-narrow-stations-kWh-default.png) | [Screenshot](after-narrow-stations-kWh-large.png) | — |
| iPhone SE | Multiple stations, AMD | [Screenshot](after-narrow-stations-AMD-default.png) | [Screenshot](after-narrow-stations-AMD-large.png) | — |
| iPhone SE | Multiple stations, Sessions | [Screenshot](after-narrow-stations-Sessions-default.png) | [Screenshot](after-narrow-stations-Sessions-large.png) | — |
| iPhone SE | Single station, AMD | — | [Screenshot](after-narrow-single-AMD-large.png) | — |
| iPhone SE | Home versus outside | [Screenshot](after-narrow-source-default.png) | [Screenshot](after-narrow-source-large.png) | — |

Additional screenshots inspect values below the fold: [iPhone SE prices at XXX Large](after-narrow-source-large-bottom.png) and [iPhone 17e prices at Accessibility 1](after-source-accessibility-bottom.png). The top-of-card screenshots above establish chart alignment; the scrolled screenshots establish price readability.

## Measurements

[alignment-results.json](alignment-results.json) records the measured global label rectangles, the bar-center positions extracted from the screenshot's orange/green pixels, and the error in points. Temporary `onGeometryChange` instrumentation measured the whole Text frame after wrapping, rather than inferring the frame from glyph baselines. Pixel bands were measured independently from those frames and converted using the device display scale. The maximum absolute error is 0.5 points. Every pair of neighboring label rectangles was checked for vertical separation. Screenshots were also inspected for outside-plot placement, numeric clipping, and axis crowding; the clipped/crowded ticks found during iteration were fixed before these final captures.

## Native build and tests

The app was rebuilt from the final shipping sources with the original app entry point, without fixtures or frame instrumentation. The native suite passed on iPhone SE / iOS 18.3.1: **84 tests, zero failures**, including app, storage, ledger, analytics, and backup tests. `git diff --check` also passes. No new calculation tests were needed for this layout change.

Builds used a temporary copy outside Documents because macOS denied Xcode's asset compiler access to the workspace asset catalog there. Temporary project copies scoped isolated bundle IDs to app/test targets; repository signing and bundle-ID settings were preserved and are excluded from the fix commit.

The native test command was:

```sh
xcodebuild -project ChargeLedger/ChargeLedger.xcodeproj \
  -scheme ChargeLedger -configuration Debug \
  -destination 'platform=iOS Simulator,id=536CE1BC-5B0E-4579-9BEE-B713D5130661' \
  -derivedDataPath /private/tmp/charge-ledger-chart-verification/ProductionBuild \
  -resultBundlePath /private/tmp/charge-ledger-chart-verification/NativeTestsVerified.xcresult \
  CODE_SIGNING_ALLOWED=NO test
```

The screenshot and native test checks establish the requested chart layout on these simulators. Physical-device testing, live iCloud sync, and unrelated interaction flows were outside this change.
