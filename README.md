# Charge Ledger

A local-first EV charging journal built with SwiftUI, SwiftData, Swift Charts, and UserNotifications. Requires iOS 17+ and Xcode 16+. There are no third-party app dependencies, accounts, servers, or photo workflows.

## Open and run

1. Open `ChargeLedger/ChargeLedger.xcodeproj` on a Mac.
2. Select **ChargeLedger** and an iPhone simulator, then press **⌘R**.
3. For your iPhone, select a development team in **Signing & Capabilities**, update the sample bundle identifier if needed, and select your device.

The checked-in project is ready to open. `python3 Tools/create_project.py` regenerates it after adding/removing Swift files.

## Entry flows

| Situation | What to enter | Counter reset |
|---|---|---|
| Partial outside charging | kWh and actual total AMD; or save it for later | None |
| Partial home charging | Nothing | None |
| Outside charging to 100% | kWh, actual total AMD, and Trip B kilometres | Trip B |
| Home charging to 100% | Home meter counter(s) and Trip B kilometres | Trip B |
| First of each month | Trip A kilometres for the month just completed | Trip A |

**Outside charging** starts as a short form. Enable **Charged to 100%** to reveal Trip B and close the cycle. **Home charge · 100%** asks for the meter and Trip B immediately. **Monthly mileage** is independent of charging: it never asks for meter readings or closes Trip B.

Monthly mileage automatically uses the month before the reading date: October 1 or October 2 both complete September. Changing the reading date updates the completed month. **Change completed month** offers a month/year override for older records; editing an existing record preserves its saved month.

Both full-charge forms list already recorded outside sessions and let you **Add earlier outside session** for every partial charge you deferred. Session dates must fall within the current cycle. If the final outside session is already saved, use that session or edit it in Journal and mark it as 100%; its ID is reused instead of creating a duplicate.

A saved full-charge record reminds you to reset Trip B, including when converting a saved partial session to a full-charge checkpoint. A new monthly record reminds you to reset Trip A. The app cannot reset the car's counters itself.

You can log outside sessions or monthly mileage before setting a home baseline. **Set starting meter** establishes one; optionally confirm the car is at 100% and reset Trip B to begin a complete measurement interval. Without an earlier 100% checkpoint, the first full charge starts a cycle rather than inventing earlier consumption.

## Complete a partial report later

A full outside charge does not require a home reading while you are away. It creates a 100% checkpoint with **home data pending**. Overview, Journal, and the cycle report highlight **Partial data**.

Choose **Add home data** in Overview or the report, or swipe a Journal checkpoint to access home data:

- **Add home meter reading:** enter the counter(s) for that 100% checkpoint when you get home. If reading it later, use a reading taken before further home charging; subsequent charging cannot be assigned exactly to an earlier checkpoint.
- **No home charging since this reading:** explicitly confirm no home charging since the latest known meter reading. The app carries its counter values forward and completes any pending checkpoints within that confirmed interval. This action is unavailable without an earlier meter reading.

The original charging date, Trip B, outside sessions, and outside payments remain intact. Entered versus carried-forward home data is stored separately, with an added-at timestamp. Updating a home reading automatically recalculates both adjacent cycles and removes partial-data labels when both endpoints are known. Later edits to the outside session preserve completed home information. Complete outside checkpoints offer **Edit home data** in the report or Journal.

Partial reports show the distance and known outside energy/payments. They do not present missing home energy as zero or include incomplete consumption in averages.

## Meter and prices

**Settings → Home meter and prices** selects either:

- **Single counter:** one cumulative kWh reading and a default AMD/kWh price.
- **T1/T2 counters:** cumulative readings and prices for both tariffs.

New records use that format. Prices can be overridden under **Price for this record**. Each record saves its own prices; changing defaults never rewrites historical records. Existing records retain their input format and pricing mode when edited.

The price saved at a meter reading applies to energy since the preceding known meter reading. Without a reading at a mid-interval rate change, use an appropriate average. An interval crossing from single to tariff counters has no exact tariff split, so it uses the saved single-price estimate. Home costs remain labelled as estimates; outside prices are actual paid amounts.

## Reports

- **100% cycles:** each Trip B interval, including partial-data status and completion actions.
- **Energy:** complete home-energy windows. If outside checkpoints remain pending, a window can span multiple 100% cycles; the distance is the sum of their Trip B readings. Adding the missing home data can split that window into complete individual cycles.
- **Monthly:** recorded Trip A distance and outside sessions by calendar month. Home energy crossing a month boundary cannot be split exactly from Trip A alone. Legacy month-end meter readings continue to support historical complete monthly reports.

Charging energy per 100 km includes electricity supplied and charging losses. Weighted consumption uses total energy divided by total distance for **complete** reports only. Zero-distance efficiency is unavailable. An outside session at a 100% checkpoint belongs to the ending cycle, not the next one. Missing home data is distinct from a confirmed unchanged meter.

Backdated meter edits are validated against preceding and following known readings. Total counter continuity is checked when formats change; unknown readings are skipped. Month identifiers are stable across time-zone changes. Dates can be backdated to the actual event time.

## Monthly reminder

Enable **Settings → Monthly reminder**, allow notifications, and choose a local time (default 09:00). A repeating local notification on day 1 reminds you to enter Trip A and reset it. Tapping opens **Monthly mileage**, including a cold app launch. No meter or battery information is requested. Rescheduling replaces one stable notification; disabling removes it. iOS settings and Focus modes govern presentation.

## Existing data and export

SwiftData stores records on-device. The update adds optional/defaulted checkpoint fields and a separate monthly-mileage entity. At launch, old monthly Trip A values are copied once into monthly records while the original meter readings are kept for historical calculations. The conversion is idempotent; deleted converted mileage is not recreated.

CSV export includes raw counters, whether a home reading exists, single/tariff prices, Trip A/B, monthly-mileage records, outside sessions, pending/entered/unchanged home status, and home-data timestamps. Old optional partial-session Trip B readings remain preserved in exports, though the new partial-charge form no longer asks for them.

This version does not import Excel/CSV, sync across devices, or restore exports automatically. Keep exports for independent copies and spreadsheet analysis.

## Verification

In Xcode, **⌘U** runs calculation tests and native app tests. The core package also runs independently:

```sh
cd ChargeLedger/Core
swift test
```

Simulator build on a Mac:

```sh
xcodebuild -project ChargeLedger/ChargeLedger.xcodeproj \
  -scheme ChargeLedger -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

See `VERIFICATION.md` for completed checks and remaining native validation.
