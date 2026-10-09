import SwiftUI
import ChargeLedgerCore

enum LedgerStyle {
    static let accent = Color(red: 0.08, green: 0.49, blue: 0.40)
    static let outside = Color(red: 0.94, green: 0.58, blue: 0.24)
    static let background = Color(uiColor: .systemGroupedBackground)

    static func number(_ value: Decimal?, digits: Int = 1) -> String {
        guard let value else { return "—" }
        return NSDecimalNumber(decimal: value).doubleValue.formatted(
            .number.precision(.fractionLength(0...digits)))
    }

    static func month(_ date: Date) -> String { date.formatted(.dateTime.month(.wide).year()) }
}

struct Metric: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SummaryCard: View {
    let title: String
    let subtitle: String
    let summary: PeriodSummary?
    let emptyMessage: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if let summary {
                if !summary.homeEnergyKnown {
                    Label("Partial data", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                HStack {
                    Metric(title: "Distance", value: LedgerStyle.number(summary.distance), unit: "km")
                    Metric(title: summary.homeEnergyKnown ? "Charging energy" : "Outside energy logged",
                           value: LedgerStyle.number(summary.homeEnergyKnown ? summary.totalEnergy : summary.outsideEnergy), unit: "kWh")
                }
                if !summary.homeEnergyKnown {
                    Text(summary.month == nil ? "Add home data to complete consumption and cost totals." : "Monthly mileage is complete. Home energy is measured at 100% checkpoints.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Metric(title: "Consumption", value: LedgerStyle.number(summary.energyPer100KM), unit: "kWh/100 km")
                    Metric(title: "Estimated cost", value: LedgerStyle.number(summary.costPerKM, digits: 2), unit: "AMD/km")
                }
            } else {
                Text(emptyMessage).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct DecimalField: View {
    let title: String
    let unit: String
    @Binding var text: String
    var previous: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.title3.weight(.medium)).monospacedDigit()
                    .frame(minWidth: 80, maxWidth: 170)
                    .accessibilityLabel(title)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if let previous {
                Text("Previous: \(previous) \(unit)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
