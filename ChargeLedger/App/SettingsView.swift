import SwiftUI
import SwiftData
import UserNotifications
import UniformTypeIdentifiers
import ChargeLedgerCore

struct SettingsView: View {
    @EnvironmentObject private var reminders: ReminderService
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Checkpoint.date) private var checkpoints: [Checkpoint]
    @Query(sort: \OutsideCharge.date) private var charges: [OutsideCharge]
    @AppStorage("averageRate") private var savedRate = "47.5"
    @AppStorage("t1Rate") private var savedT1 = "53.48"
    @AppStorage("t2Rate") private var savedT2 = "43.48"
    @AppStorage("useTariffRates") private var savedTariffs = false
    @AppStorage("reminderEnabled") private var reminderEnabled = false
    @AppStorage("reminderHour") private var reminderHour = 9
    @AppStorage("reminderMinute") private var reminderMinute = 0
    @State private var rate = ""
    @State private var t1Rate = ""
    @State private var t2Rate = ""
    @State private var tariffs = false
    @State private var loaded = false
    @State private var message: String?
    @State private var permissionDenied = false
    @State private var exporting = false
    @State private var exportDocument = LedgerCSV(text: "")
    @State private var scheduling = false
    @FocusState private var fieldFocused: Bool

    private var reminderTime: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: reminderHour, minute: reminderMinute, second: 0, of: .now)!
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            reminderHour = parts.hour ?? 9; reminderMinute = parts.minute ?? 0
            if reminderEnabled { Task { await schedule(requestPermission: false) } }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Default pricing", selection: $tariffs) {
                    Text("Single price").tag(false)
                    Text("T1 / T2 prices").tag(true)
                }
                DecimalField(title: "Single price", unit: "AMD/kWh", text: $rate).focused($fieldFocused)
                DecimalField(title: "T1 price", unit: "AMD/kWh", text: $t1Rate).focused($fieldFocused)
                DecimalField(title: "T2 price", unit: "AMD/kWh", text: $t2Rate).focused($fieldFocused)
                Button("Save default prices", action: savePrices)
            } header: { Text("Home charging prices") } footer: {
                Text("New checkpoints start with these prices. Override them on any record, including older entries. Changing defaults leaves existing records untouched.")
            }

            Section {
                Toggle("Monthly reminder", isOn: $reminderEnabled)
                    .disabled(scheduling)
                    .onChange(of: reminderEnabled) { _, enabled in
                        if enabled { Task { await schedule(requestPermission: true) } }
                        else { reminders.cancel() }
                    }
                DatePicker("On the 1st at", selection: reminderTime, displayedComponents: .hourAndMinute)
                    .disabled(!reminderEnabled || scheduling)
                if permissionDenied {
                    Button("Open notification settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } header: { Text("Monthly checkpoint") } footer: {
                Text("A local notification reminds you on the first day of every month. Tap it to open Start new month. The time follows your iPhone’s time zone.")
            }

            Section {
                Button {
                    exportDocument = LedgerCSV(text: CSVExport.make(readings: checkpoints, charges: charges))
                    exporting = true
                } label: { Label("Export all entries as CSV", systemImage: "square.and.arrow.up") }
                .disabled(checkpoints.isEmpty && charges.isEmpty)
            } header: { Text("Your data") } footer: {
                Text("Entries are stored locally on this iPhone. Export includes raw readings, trip distances, battery levels, saved prices, and outside charging. Keep exports for your own backup or spreadsheet analysis.")
            }
            Section("About") {
                LabeledContent("Distance", value: "Kilometres")
                LabeledContent("Currency", value: "AMD")
                LabeledContent("Storage", value: "On-device · SwiftData")
                Text("Trip A follows monthly resets. Trip B follows 100% charges. A monthly reading never closes a cycle unless you explicitly select it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer(); Button("Done") { fieldFocused = false }
            }
        }
        .task {
            if !loaded {
                rate = savedRate; t1Rate = savedT1; t2Rate = savedT2; tariffs = savedTariffs; loaded = true
            }
            await checkPermission()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await checkPermission() } }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "charge-ledger-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .alert("Charge Ledger", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func savePrices() {
        guard let average = Numbers.parse(rate), let first = Numbers.parse(t1Rate), let second = Numbers.parse(t2Rate) else {
            message = "Enter valid prices using digits and a decimal point or comma."; return
        }
        savedRate = Numbers.string(average); savedT1 = Numbers.string(first); savedT2 = Numbers.string(second)
        savedTariffs = tariffs
        message = "Default prices saved. Existing records keep their prices."
        fieldFocused = false
    }

    private func schedule(requestPermission: Bool) async {
        scheduling = true
        defer { scheduling = false }
        do {
            try await reminders.schedule(hour: reminderHour, minute: reminderMinute, requestPermission: requestPermission)
            if !reminderEnabled { reminders.cancel() }
            await checkPermission()
        } catch {
            reminderEnabled = false; reminders.cancel()
            message = error.localizedDescription
            await checkPermission()
        }
    }

    private func checkPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permissionDenied = settings.authorizationStatus == .denied
    }
}

struct LedgerCSV: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum CSVExport {
    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func make(readings: [Checkpoint], charges: [OutsideCharge]) -> String {
        var rows = [["record_type", "id", "recorded_at", "reading_time", "month_boundary", "is_baseline", "closes_cycle",
                     "t1_kwh", "t2_kwh", "trip_a_km", "trip_b_km", "battery_percent", "home_pricing",
                     "single_price_amd_kwh", "t1_price_amd_kwh", "t2_price_amd_kwh", "outside_kwh", "outside_amd", "location", "linked_charge_id"]]
        for reading in readings {
            rows.append(["checkpoint", reading.id.uuidString, reading.recordedAt.ISO8601Format(), reading.date.ISO8601Format(),
                         reading.monthBoundary?.ISO8601Format() ?? "", String(reading.isBaseline), String(reading.closesCycle),
                         reading.t1Text, reading.t2Text, reading.tripAText ?? "", reading.tripBText ?? "",
                         reading.battery.map(String.init) ?? "", reading.useTariffRates ? "t1_t2" : "single",
                         reading.averageRateText, reading.t1RateText, reading.t2RateText, "", "", "", reading.linkedChargeID?.uuidString ?? ""])
        }
        for charge in charges {
            rows.append(["outside_charge", charge.id.uuidString, "", charge.date.ISO8601Format(), "", "", "", "", "", "", charge.tripBText ?? "", "", "",
                         "", "", "", charge.energyText, charge.costText, charge.location, ""])
        }
        return "\u{FEFF}" + rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
