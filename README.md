# Charge Ledger

A local-first iPhone/iPad app for your EV charging journal. Built entirely with SwiftUI, SwiftData, Swift Charts, and UserNotifications. Requires iOS 17 or later; open with Xcode 16 or later. There are no third-party app dependencies, accounts, servers, camera permissions, or photo workflows.

## Open and run

1. Open `ChargeLedger/ChargeLedger.xcodeproj` on a Mac.
2. Select the **ChargeLedger** scheme and an iPhone simulator, then press **⌘R**.
3. To run on your iPhone, choose your development team under the app target's **Signing & Capabilities**, change the sample `com.example.ChargeLedger` bundle identifier if needed, and select your device.

The checked-in project is ready to open; project-generation tools are not required. `python3 Tools/create_project.py` regenerates the project if you add or remove Swift source files.

## Your everyday routine

- **Starting readings:** establish the meter baseline. Enable “Reset Trip A now” only if you reset the monthly counter, and “At 100% · reset Trip B now” only if you are fully charged and reset that counter. Starting mid-month produces a partial first monthly period.
- **Start new month:** record Trip A distance, cumulative home T1/T2 readings, and optional battery percentage. The form defaults to closing the previous calendar month. Record the actual reading time even if entering it later. Select “Also reached 100%” when resetting Trip B at the same time.
- **Reached 100%:** record Trip B distance and cumulative home T1/T2 readings, even after charging outside. Include an outside session in the same entry when applicable.
- **Outside charging:** log every outside session, including partial charges, with kWh and actual total AMD from the charger app. “Also reached 100%” opens the Trip B and meter fields.

After saving a new checkpoint, the app reminds you which physical trip counter to reset. It cannot reset the car's counters automatically. Journal entries can be edited or deleted; calculations update from their original data.

## Prices

Settings stores editable defaults for a single home price and separate T1/T2 prices. Each checkpoint has its own editable pricing mode and price override. Changing defaults only affects future entries. Editing a record's price changes its historical calculations deliberately.

A checkpoint's price applies to home energy consumed **since the preceding meter reading**. If a price changes partway through an interval without a meter reading, an exact split is unavailable; enter an appropriate average for that record. Intermediate monthly readings contribute separate priced segments to an overlapping 100% cycle.

Use single-price estimates while the meter and grid tariff time windows differ. T1/T2 mode uses each counter's saved price when the windows are aligned. Reports conservatively label home and combined costs as estimates, while outside amounts are actual paid prices. No estimate is presented as a utility bill.

## Calculations and boundaries

```
Home energy = ending T1 + T2 − starting T1 − T2
Outside energy/cost = sum of sessions after start, up to and including end
Total charging energy = home energy + outside energy
Charging energy per 100 km = total energy / distance × 100
Estimated AMD/km = (home cost + outside cost) / distance
```

- Trip A and Trip B boundaries are independent. Monthly checkpoints do not close a full-charge cycle automatically.
- A session entered alongside a 100% checkpoint belongs to the **ending** cycle. It is never counted again in the next cycle.
- The first reset establishes an anchor; without an earlier corresponding reset, no completed interval is fabricated.
- Monthly reports require consecutive calendar-month boundaries. Missing months are not interpolated.
- A late monthly reset extends the actual measurement period. Details show actual start/end timestamps and the attributed month. The app cannot reconstruct an exact calendar-month split from late readings.
- Current-month distance cannot be known until Trip A is read. Overview therefore shows current-month logged outside charging, the latest completed month, and the latest completed full-charge cycle.
- Energy includes charging losses. Monthly battery levels are shown for context without an assumed battery-capacity adjustment.
- Aggregate efficiency uses total energy / total distance, not the average of individual efficiency ratios. Zero-distance efficiency is unavailable rather than infinity.
- Monetary and energy calculations use `Decimal`; chart coordinates use `Double` only for rendering. Decimal commas and points are accepted; ambiguous grouped numbers are rejected.
- Backdated meter edits are validated against both neighboring readings. Duplicate month checkpoints are rejected.

## Monthly reminder

Enable **Settings → Monthly reminder**, grant notification permission, and choose a local time (default 09:00). A repeating `UNCalendarNotificationTrigger` fires on day 1 each month without network access. Tapping it opens **Start new month**, including when the app launches from a closed state. If no starting readings exist, it opens setup first.

The reminder uses one stable identifier, so time changes replace the pending request. Disabling it removes pending and delivered reminders. iOS notification settings and Focus modes govern presentation. Test permission, time changes, and cold-launch routing on an iPhone.

## Data and export

SwiftData stores readings and charging sessions on the device. CSV export includes IDs, actual reading times, entry times, monthly boundaries, Trip A/B, battery levels, record-specific prices, charging costs, and linked session IDs. Export from Settings to Files or your preferred destination.

This initial version does not import the Excel screenshot, import CSV, sync across devices, or restore exports automatically. It starts empty. Keep CSV exports for spreadsheet analysis and independent copies of your data.

## Verification

In Xcode, **⌘U** runs the core calculation tests and the native app tests (SwiftData persistence, CSV escaping, and the monthly calendar trigger).

The calculation package can also run independently on a machine with Swift installed:

```sh
cd ChargeLedger/Core
swift test
```

For a simulator build from a Mac terminal:

```sh
xcodebuild -project ChargeLedger/ChargeLedger.xcodeproj \
  -scheme ChargeLedger -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

See `VERIFICATION.md` for the checks actually performed in the development environment and remaining native checks.
