import SwiftUI

enum InputField: Hashable {
    case meter, t1, t2, tripA, tripB, energy, cost, brand, location, homePrice, t1Price, t2Price, brandSearch
    case sessionEnergy(UUID), sessionCost(UUID), sessionBrand(UUID), sessionLocation(UUID)
}

private struct InputBounds: PreferenceKey {
    static var defaultValue: [InputField: CGRect] { [:] }
    static func reduce(value: inout [InputField: CGRect], nextValue: () -> [InputField: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct InputFocus: ViewModifier {
    let id: InputField
    let focus: FocusState<InputField?>.Binding
    func body(content: Content) -> some View {
        content
            .focused(focus, equals: id)
            .submitLabel(.done)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: InputBounds.self, value: [id: geometry.frame(in: .global)])
                }
            }
    }
}

extension View {
    /// Apply to the actual TextField; identify its containing Form row with the same ID.
    func inputFocus(_ id: InputField, focus: FocusState<InputField?>.Binding) -> some View {
        modifier(InputFocus(id: id, focus: focus))
    }
}

struct KeyboardForm<Content: View>: View {
    let focus: FocusState<InputField?>.Binding
    let content: () -> Content
    @State private var bounds: [InputField: CGRect] = [:]

    init(focus: FocusState<InputField?>.Binding, @ViewBuilder content: @escaping () -> Content) {
        self.focus = focus; self.content = content
    }

    var body: some View {
        ScrollViewReader { scroll in
            GeometryReader { viewport in
                Form { content() }
                    .contentShape(Rectangle())
                    // Extra scrollable room keeps the final input above the keyboard's Done bar.
                    .contentMargins(.bottom, focus.wrappedValue == nil ? 0 : 64, for: .scrollContent)
                    .scrollDismissesKeyboard(.interactively)
                    .onPreferenceChange(InputBounds.self) { bounds = $0 }
                    .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                        // Tapping another field must transfer focus, not immediately dismiss it.
                        if !bounds.values.contains(where: { $0.contains(tap.location) }) { focus.wrappedValue = nil }
                    })
                    .onSubmit { focus.wrappedValue = nil }
                    .toolbar {
                        if focus.wrappedValue != nil {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") { focus.wrappedValue = nil }
                            }
                        }
                    }
                    .task(id: focus.wrappedValue) {
                        guard let field = focus.wrappedValue else { return }
                        await Task.yield()
                        guard !Task.isCancelled, focus.wrappedValue == field else { return }
                        reveal(field, using: scroll)
                        // Recenter once keyboard/accessory layout has settled. Changing or clearing
                        // focus cancels this task so an old field cannot pull the form back.
                        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                        guard !Task.isCancelled, focus.wrappedValue == field else { return }
                        reveal(field, using: scroll)
                    }
                    .onChange(of: viewport.size.height) { previous, current in
                        if current < previous, let field = focus.wrappedValue { reveal(field, using: scroll) }
                    }
            }
        }
        .onDisappear { focus.wrappedValue = nil }
    }

    private func reveal(_ field: InputField, using scroll: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(field, anchor: .center) }
    }
}
