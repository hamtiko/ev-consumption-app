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
| Partial outside charging | Add kWh and actual total AMD when logging the next 100% cycle | None at the partial charge |
| Partial home charging | Nothing | None |
| Any charging to 100% | Trip B kilometres, home counter(s) when available, and any outside sessions | Trip B |
| First of each month | Home meter counter(s); optionally Trip A kilometres | Trip A only if recorded |

**Log 100% cycle** is the single charging action for both home and outside charging. Enter Trip B, update the prefilled home counter(s), and **Add outside session** for the final outside charge or earlier partial charges. Each session has its date, kWh and actual payment. Already saved sessions are included automatically; don’t add them again. Old standalone outside sessions remain editable in Journal, including their existing upgrade-to-100% flow.

**Start new month** records the dedicated home meter and optional Trip A. The completed month is automatically the month before the reading date: October 1 or October 2 both complete September. Changing the reading date updates the completed month. **Change completed month** offers a month/year override for older records; editing an existing record preserves its saved month. Older mileage-only records can still be edited without inventing a meter reading.

Cycle and monthly forms prefill the latest known home meter before the entry’s date, whether it came from a 100% cycle or a monthly record. Changing the date refreshes the prefill until you edit the counters yourself. Pending readings are skipped. Single counters can use the sum of a previous T1/T2 reading; T1/T2 values cannot be inferred from a previous single counter. Update prefilled values to the current reading, or leave them unchanged only when there has been no home charging.

A saved full-charge record reminds you to reset Trip B, including when converting a saved partial session to a full-charge checkpoint. A new monthly record reminds you to reset Trip A only if you entered its kilometres. Monthly readings never reset Trip B. The app cannot reset the car's counters itself.

You can log cycles or monthly readings before setting a home baseline. **Set starting meter** establishes one; optionally confirm the car is at 100% and reset Trip B to begin a complete measurement interval. Without an earlier 100% checkpoint, the first full charge starts a cycle rather than inventing earlier consumption. Two consecutive monthly readings establish a monthly home-energy report; the first monthly reading supplies the next month’s starting counter.

## Complete a partial report later

Turn off **Home meter reading available** when logging a 100% cycle while away and unable to confirm the counter. It creates a checkpoint with **home data pending**. Overview, Journal, and the cycle report highlight **Partial data**.

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
- **Monthly:** home kWh and estimated utility bill contribution between consecutive monthly meter readings, with outside payments shown separately. Home cost uses every intervening meter segment’s saved prices. Trip A is optional; omitted mileage is shown as unrecorded and excluded from distance charts and efficiency calculations. Late readings use their actual timestamps, displayed in the report, so totals may differ from the exact calendar month or utility billing period. Without both monthly meter boundaries, home cost remains unavailable. Legacy month-end meter readings and mileage-only records remain supported.

Charging energy per 100 km includes electricity supplied and charging losses. Weighted consumption uses total energy divided by total distance for reports with **complete energy and recorded distance** only. Zero-distance efficiency is unavailable. An outside session at a 100% checkpoint belongs to the ending cycle, not the next one. Missing home data is distinct from a confirmed unchanged meter.

Backdated meter edits are validated against preceding and following known readings. Total counter continuity is checked when formats change; unknown readings are skipped. Month identifiers are stable across time-zone changes. Dates can be backdated to the actual event time.

## Monthly reminder

Enable **Settings → Monthly reminder**, allow notifications, and choose a local time (default 09:00). A repeating local notification on day 1 reminds you to enter the home meter and optional Trip A. Tapping opens **Monthly readings**, including a cold app launch. No Trip B or battery information is requested. Rescheduling replaces one stable notification; disabling removes it. iOS settings and Focus modes govern presentation.

## Existing data and export

SwiftData stores records on-device. The update adds optional/defaulted checkpoint fields and a separate monthly-mileage entity. At launch, old monthly Trip A values are copied once into monthly records while the original meter readings are kept for historical calculations. The conversion is idempotent; deleted converted mileage is not recreated.

The unified-flow update uses the existing model schema. A monthly record and its meter checkpoint share an ID; a blank monthly distance means mileage was not recorded. The journal groups a standalone monthly meter with its monthly record. Deleting a monthly entry deletes its standalone meter checkpoint, or clears only monthly data when it shares a checkpoint with a cycle/baseline.

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
