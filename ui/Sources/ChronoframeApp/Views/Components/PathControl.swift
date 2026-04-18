import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSPathControl` — Apple's native breadcrumb control
/// for displaying a filesystem path. Clickable, shows Finder icons, truncates
/// intelligently.
///
/// Usage:
/// ```
/// PathControl(path: sourcePath, placeholder: "Choose a source…") { url in
///     setupStore.sourcePath = url.path
/// }
/// ```
struct PathControl: NSViewRepresentable {
    /// POSIX path to display. Empty string shows the placeholder.
    let path: String
    /// Text shown when `path` is empty.
    var placeholder: String = "Choose a folder…"
    /// Called when the user clicks a component of the path or picks via the
    /// "Choose…" popup. May be nil to ignore interaction.
    var onSelect: ((URL) -> Void)? = nil

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.backgroundColor = .clear
        control.isEditable = false
        control.focusRingType = .none
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.cell?.controlSize = .regular
        control.target = context.coordinator
        control.action = #selector(Coordinator.pathWasClicked(_:))
        applyPath(to: control)
        return control
    }

    func updateNSView(_ nsView: NSPathControl, context: Context) {
        context.coordinator.owner = self
        applyPath(to: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    private func applyPath(to control: NSPathControl) {
        if path.isEmpty {
            control.url = nil
            control.placeholderString = placeholder
        } else {
            control.url = URL(fileURLWithPath: path)
            control.placeholderString = nil
        }
    }

    final class Coordinator {
        var owner: PathControl

        init(owner: PathControl) { self.owner = owner }

        @MainActor @objc func pathWasClicked(_ sender: NSPathControl) {
            guard let url = sender.clickedPathItem?.url ?? sender.url else { return }
            owner.onSelect?(url)
        }
    }
}
