#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import SwiftUI

/// Underline-style tab strip used in the Organize workspace.
///
/// Replaces the platform segmented picker with a row of icon+label buttons
/// and a single filmic underline that slides between the active tab. Built
/// generically so other workspaces can adopt the same shape later.
struct WorkspaceTabStrip<Tab: Hashable & Identifiable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String
    let systemImage: (Tab) -> String
    var accessibilityIdentifier: (Tab) -> String? = { _ in nil }

    @Namespace private var underlineNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 2)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.ColorSystem.hairline)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func tabButton(for tab: Tab) -> some View {
        let isSelected = (tab == selection)
        Button {
            withAnimation(reduceMotion ? nil : Motion.filmic) {
                selection = tab
            }
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage(tab))
                        .font(.system(size: 12, weight: .medium))
                    Text(title(tab))
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                }
                .foregroundStyle(isSelected
                    ? DesignTokens.ColorSystem.inkPrimary
                    : DesignTokens.ColorSystem.inkSecondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .contentShape(Rectangle())

                ZStack {
                    Capsule()
                        .fill(Color.clear)
                        .frame(height: 2)
                    if isSelected {
                        Capsule()
                            .fill(DesignTokens.ColorSystem.accentWaypoint)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: underlineNamespace)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier(tab) ?? "")
        .accessibilityLabel(title(tab))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
