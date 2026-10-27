import SwiftUI
import ChargeLedgerCore

struct StationBrandField: View {
    @Binding var brand: String
    let choices: [String]
    let focus: FocusState<InputField?>.Binding
    let field: InputField
    @State private var choosing = false

    var body: some View {
        HStack {
            TextField("Charging station (optional)", text: $brand)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .inputFocus(field, focus: focus)
                .accessibilityLabel("Charging station")
            Button { focus.wrappedValue = nil; choosing = true } label: {
                Label("Choose", systemImage: "chevron.down").font(.subheadline)
            }
            .buttonStyle(.borderless)
        }
        .id(field)
        .sheet(isPresented: $choosing) {
            StationBrandPicker(brand: $brand, choices: StationBrands.choices(choices.map { Optional($0) }))
        }
    }
}

private struct StationBrandPicker: View {
    @Binding var brand: String
    let choices: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @FocusState private var focused: InputField?
    private var matches: [String] { choices.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        NavigationStack {
            KeyboardForm(focus: $focused) {
                Section {
                    TextField("Find or add a station", text: $search)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .inputFocus(.brandSearch, focus: $focused)
                        .id(InputField.brandSearch)
                }
                Button("Unspecified") { choose("") }
                Section("Saved stations") {
                    ForEach(matches, id: \.self) { name in
                        Button { choose(name) } label: {
                            HStack {
                                Text(name)
                                Spacer()
                                if StationBrands.key(name) == StationBrands.key(brand) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if let name = StationBrands.clean(search), !choices.contains(where: { StationBrands.key($0) == StationBrands.key(name) }) {
                        Button { choose(name) } label: { Label("Add \(name)", systemImage: "plus") }
                    }
                    if choices.isEmpty && search.isEmpty {
                        Text("Type a station name in the search field to add one. It will be available again after saving the session.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Charging station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func choose(_ name: String) { focused = nil; brand = name; dismiss() }
}
