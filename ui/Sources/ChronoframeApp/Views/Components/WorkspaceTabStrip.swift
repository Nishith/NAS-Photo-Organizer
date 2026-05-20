import SwiftUI

/// A Lightroom-style module switcher: a horizontal row of text tabs with an
/// animated underline that glides between the selected tab. Replaces the stock
/// `Picker(.segmented)` so workspace navigation reads like a pro tool rather
/// than a settings control.
///
/// Generic over any `Hashable & Identifiable` tab; the caller supplies the tab
/// list and a title closure, so it stays decoupled from any specific enum.
struct WorkspaceTabStrip<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String

    @Namespace private var underlineNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(tabs) { tab in
                TabButton(
                    title: title(tab),
                    isSelected: tab == selection,
                    namespace: underlineNamespace
                ) {
                    withAnimation(reduceMotion ? nil : Motion.filmic) {
                        selection = tab
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace sections")
    }

    private struct TabButton: View {
        let title: String
        let isSelected: Bool
        let namespace: Namespace.ID
        let onTap: () -> Void

        @State private var hovering = false

        private var foreground: Color {
            if isSelected { return DesignTokens.ColorSystem.inkPrimary }
            return hovering ? DesignTokens.ColorSystem.inkPrimary : DesignTokens.ColorSystem.inkSecondary
        }

        var body: some View {
            Button(action: onTap) {
                VStack(spacing: 5) {
                    Text(title)
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(foreground)

                    ZStack {
                        // Reserve the underline's vertical space on every tab so
                        // selecting one never shifts the row.
                        Capsule()
                            .fill(Color.clear)
                            .frame(height: 2)

                        if isSelected {
                            Capsule()
                                .fill(DesignTokens.ColorSystem.accentAction)
                                .frame(height: 2)
                                .matchedGeometryEffect(id: "workspaceTabUnderline", in: namespace)
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.instant, value: hovering)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }
}
