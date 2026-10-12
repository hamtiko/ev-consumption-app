import SwiftUI
import ChargeLedgerCore

struct StationBrandField: View {
    @Binding var brand: String
    let choices: [String]
    @State private var choosing = false
    @FocusState private var typing: Bool

    var body: some View {
        HStack {
            TextField("Charging brand (optional)", text: $brand)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($typing)
                .submitLabel(.done)
                .onSubmit { typing = false }
                .accessibilityLabel("Charging station brand")
            Button { choosing = true } label: {
                Label("Choose", systemImage: "chevron.down").font(.subheadline)
            }
            .buttonStyle(.borderless)
        }
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
    private var matches: [String] { choices.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        NavigationStack {
            List {
                Button("Unspecified") { choose("") }
                Section("Saved brands") {
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
                        Text("Type a brand in the search field to add one. It will be available again after saving the session.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $search, prompt: "Find or add a brand")
            .navigationTitle("Charging brand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func choose(_ name: String) { brand = name; dismiss() }
}
