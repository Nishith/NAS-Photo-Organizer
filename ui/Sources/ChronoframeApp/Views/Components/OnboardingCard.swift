import SwiftUI

/// One-card first-run onboarding. Shown on Setup until the user drops a folder
/// or sets a source path. Never a modal, never a tutorial, never re-shown once
/// dismissed (gated by the `didOnboard` AppStorage flag).
struct OnboardingCard: View {
    let onDismiss: () -> Void

    var body: some View {
        DarkroomPanel(variant: .panel) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                Image(systemName: "hand.wave")
                    .font(.system(size: 20))
                    .foregroundStyle(DesignTokens.ColorSystem.accentWaypoint)
                    .frame(width: 28, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Point Chronoframe at your photo source.")
                        .font(DesignTokens.Typography.cardTitle)
                        .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)

                    Text("Drag a folder anywhere on this window, or choose one below. Nothing is copied until you say so.")
                        .font(DesignTokens.Typography.subtitle)
                        .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignTokens.Spacing.md)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss onboarding")
                .accessibilityHint("Hides this welcome card permanently")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome. Point Chronoframe at your photo source.")
    }
}
