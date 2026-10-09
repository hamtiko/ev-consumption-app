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
    @Query(sort: \MonthlyMileage.month) private var mileage: [MonthlyMileage]
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
                Picker("Home meter", selection: $tariffs) {
                    Text("Single counter").tag(false)
                    Text("T1 / T2 counters").tag(true)
                }
                if tariffs {
                    DecimalField(title: "T1 price", unit: "AMD/kWh", text: $t1Rate).focused($fieldFocused)
                    DecimalField(title: "T2 price", unit: "AMD/kWh", text: $t2Rate).focused($fieldFocused)
                } else {
                    DecimalField(title: "Price", unit: "AMD/kWh", text: $rate).focused($fieldFocused)
                }
                Button("Save meter settings", action: savePrices)
            } header: { Text("Home meter and prices") } footer: {
                Text("New home entries ask for a single cumulative counter or T1/T2 counters based on this setting. Each record keeps its saved price, which you can override.")
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
                Text("A local notification reminds you on the first day of every month. Tap it to enter Trip A kilometres and reset Trip A. The time follows your iPhone’s time zone.")
            }

            Section {
                Button {
                    exportDocument = LedgerCSV(text: CSVExport.make(readings: checkpoints, charges: charges, mileage: mileage))
                    exporting = true
                } label: { Label("Export all entries as CSV", systemImage: "square.and.arrow.up") }
                .disabled(checkpoints.isEmpty && charges.isEmpty && mileage.isEmpty)
            } header: { Text("Your data") } footer: {
                Text("Entries are stored locally on this iPhone. Export includes raw readings, trip distances, battery levels, saved prices, and outside charging. Keep exports for your own backup or spreadsheet analysis.")
            }
            Section("About") {
                LabeledContent("Distance", value: "Kilometres")
                LabeledContent("Currency", value: "AMD")
                LabeledContent("Storage", value: "On-device · SwiftData")
                Text("Trip A is recorded once a month. Trip B resets after every 100% charge. Outside cycles can be completed with home data later.")
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
        message = "Meter settings saved. Existing records keep their format and prices."
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
    static func make(readings: [Checkpoint], charges: [OutsideCharge], mileage: [MonthlyMileage] = []) -> String {
        let headers = ["record_type", "id", "recorded_at", "reading_time", "month_boundary", "is_baseline", "closes_cycle",
                       "t1_kwh", "t2_kwh", "trip_a_km", "trip_b_km", "battery_percent", "home_pricing",
                       "single_price_amd_kwh", "t1_price_amd_kwh", "t2_price_amd_kwh", "outside_kwh", "outside_amd", "location", "linked_charge_id",
                       "has_home_meter", "meter_total_kwh", "home_data_status", "home_data_added_at", "meter_format", "month_closed"]
        var rows = [headers]
        for reading in readings {
            var row = [String](repeating: "", count: headers.count)
            row[0] = "checkpoint"; row[1] = reading.id.uuidString
            row[2] = reading.recordedAt.ISO8601Format(); row[3] = reading.date.ISO8601Format()
            row[4] = reading.monthBoundary?.ISO8601Format() ?? ""
            row[5] = String(reading.isBaseline); row[6] = String(reading.closesCycle)
            if reading.hasMeterReading && reading.meterTotalText == nil { row[7] = reading.t1Text; row[8] = reading.t2Text }
            row[9] = reading.tripAText ?? ""; row[10] = reading.tripBText ?? ""
            row[11] = reading.battery.map(String.init) ?? ""
            row[12] = reading.useTariffRates ? "t1_t2" : "single"
            row[13] = reading.averageRateText; row[14] = reading.t1RateText; row[15] = reading.t2RateText
            row[19] = reading.linkedChargeID?.uuidString ?? ""
            row[20] = String(reading.hasMeterReading); row[21] = reading.meterTotalText ?? ""
            row[22] = reading.homeDataStatus ?? ""; row[23] = reading.homeDataAddedAt?.ISO8601Format() ?? ""
            row[24] = reading.hasMeterReading ? (reading.meterTotalText == nil ? "t1_t2" : "single") : ""
            rows.append(row)
        }
        for charge in charges {
            var row = [String](repeating: "", count: headers.count)
            row[0] = "outside_charge"; row[1] = charge.id.uuidString; row[3] = charge.date.ISO8601Format()
            row[10] = charge.tripBText ?? ""; row[16] = charge.energyText
            row[17] = charge.costText; row[18] = charge.location
            rows.append(row)
        }
        for record in mileage {
            var row = [String](repeating: "", count: headers.count)
            row[0] = "monthly_mileage"; row[1] = record.id.uuidString
            row[3] = record.date.ISO8601Format(); row[9] = record.distanceText
            row[25] = record.month.ISO8601Format()
            rows.append(row)
        }
        return "\u{FEFF}" + rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
