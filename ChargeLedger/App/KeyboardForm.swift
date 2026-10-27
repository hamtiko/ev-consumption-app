import SwiftUI
import UIKit

enum InputField: Hashable {
    case meter, t1, t2, tripA, tripB, energy, cost, brand, location, homePrice, t1Price, t2Price, brandSearch
    case sessionEnergy(UUID), sessionCost(UUID), sessionBrand(UUID), sessionLocation(UUID)
    case tripBCounter, tripBPreviousCounter
}

private struct DismissFormKeyboardKey: EnvironmentKey {
    static var defaultValue: () -> Void { {} }
}

extension EnvironmentValues {
    var dismissFormKeyboard: () -> Void {
        get { self[DismissFormKeyboardKey.self] }
        set { self[DismissFormKeyboardKey.self] = newValue }
    }
}

private struct InputFocus: ViewModifier {
    let id: InputField
    let focus: FocusState<InputField?>.Binding
    func body(content: Content) -> some View {
        content
            .focused(focus, equals: id)
            .submitLabel(.done)
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

    init(focus: FocusState<InputField?>.Binding, @ViewBuilder content: @escaping () -> Content) {
        self.focus = focus; self.content = content
    }

    var body: some View {
        ScrollViewReader { scroll in
            GeometryReader { viewport in
                Form { content() }
                    .environment(\.dismissFormKeyboard, { focus.wrappedValue = nil })
                    // Extra scrollable room keeps the final input above the keyboard's Done bar.
                    .contentMargins(.bottom, focus.wrappedValue == nil ? 0 : 64, for: .scrollContent)
                    .scrollDismissesKeyboard(.interactively)
                    .background {
                        OutsideInputTapObserver(isActive: { focus.wrappedValue != nil }) { focus.wrappedValue = nil }
                    }
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

/// Observe outside taps without putting a SwiftUI gesture on the Form's controls.
/// This small UIKit bridge never cancels or delays the touches delivered to buttons,
/// disclosure rows, pickers, or text inputs; the form and its content remain SwiftUI.
@MainActor
private struct OutsideInputTapObserver: UIViewRepresentable {
    let isActive: () -> Bool
    let onTap: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(isActive: isActive, onTap: onTap) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(frame: .zero)
        view.isUserInteractionEnabled = false
        view.onWindowChange = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onTap = onTap
    }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.attach(to: nil)
    }

    final class Probe: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isActive: () -> Bool
        var onTap: () -> Void
        private weak var window: UIWindow?
        private var recognizer: UITapGestureRecognizer!
        init(isActive: @escaping () -> Bool, onTap: @escaping () -> Void) {
            self.isActive = isActive; self.onTap = onTap
            super.init()
            recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
        }
        func attach(to next: UIWindow?) {
            guard window !== next else { return }
            window?.removeGestureRecognizer(recognizer)
            window = next
            next?.addGestureRecognizer(recognizer)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isActive() else { return false }
            var view = touch.view
            while let current = view {
                if current is UITextInput { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        @objc private func tapped() {
            // Let the tapped control finish its action before keyboard layout changes.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive() else { return }
                self.onTap()
            }
        }
    }
}
