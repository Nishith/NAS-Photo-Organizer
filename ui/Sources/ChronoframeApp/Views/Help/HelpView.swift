#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import SwiftUI

/// Single help window. Opened from the Help menu (Cmd-?) or from the
/// Apple-menu "About Chronoframe" replacement. Four sections, navigated by
/// segmented control so the window stays one resizable pane instead of a
/// thicket of sub-windows.
struct HelpView: View {
    @State private var section: HelpSection = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HelpHeader()

            Picker("", selection: $section) {
                ForEach(HelpSection.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DesignTokens.Layout.contentPadding)
            .padding(.bottom, DesignTokens.Spacing.md)

            Divider()

            ScrollView {
                Group {
                    switch section {
                    case .overview:    HelpOverviewSection()
                    case .shortcuts:   HelpShortcutsSection()
                    case .privacy:     HelpPrivacySection()
                    case .credits:     HelpCreditsSection()
                    }
                }
                .padding(DesignTokens.Layout.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .darkroom()
        .frame(minWidth: 540, idealWidth: 620, minHeight: 480, idealHeight: 560)
    }
}

private enum HelpSection: String, CaseIterable, Identifiable {
    case overview, shortcuts, privacy, credits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:  return "Overview"
        case .shortcuts: return "Shortcuts"
        case .privacy:   return "Privacy"
        case .credits:   return "Credits"
        }
    }
}

// MARK: - Header

private struct HelpHeader: View {
    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DesignTokens.ColorSystem.accentWaypoint)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Chronoframe")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                Text(versionString)
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                    .monospacedDigit()
            }

            Spacer()
        }
        .padding(.horizontal, DesignTokens.Layout.contentPadding)
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.md)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(short)" : "Version \(short) (\(build))"
    }
}

// MARK: - Sections

private struct HelpOverviewSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("Chronoframe is a darkroom for time. Point it at a folder of photos and videos and it organizes a clean, dated copy at your destination — never moving, never overwriting your originals.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HelpListPanel(title: "How a run works") {
                HelpStep(number: "1", title: "Choose a source", detail: "Drag a folder onto the window or click Choose Source. Read-only — nothing is moved.")
                HelpStep(number: "2", title: "Choose a destination", detail: "Where the organized copy lives. Files are arranged into year/month/day folders by default.")
                HelpStep(number: "3", title: "Preview", detail: "A non-destructive dry run. Shows the planned file moves, dedupes, and any issues. No files are copied.")
                HelpStep(number: "4", title: "Transfer", detail: "Copies files to the destination, verifies hashes, and writes a receipt for revert if you ever need it.")
            }

            HelpListPanel(title: "Good to know") {
                HelpBullet("Source files are never modified, renamed, or deleted.")
                HelpBullet("Duplicates land in a Duplicates folder, not the main archive — easy to review and discard.")
                HelpBullet("Each transfer writes a receipt to .organize_logs/ inside the destination so the run can be reverted.")
                HelpBullet("Profiles save your favorite source/destination pairs. Switch with one click.")
            }
        }
    }
}

private struct HelpShortcutsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("Keyboard shortcuts work from any screen.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)

            HelpListPanel(title: "Library") {
                ShortcutRow(keys: "⌘O",   label: "Choose Source…")
                ShortcutRow(keys: "⇧⌘O",  label: "Choose Destination…")
                ShortcutRow(keys: "⇧⌘P",  label: "Refresh Profiles")
            }

            HelpListPanel(title: "Run") {
                ShortcutRow(keys: "⌘R",   label: "Preview (non-destructive dry run)")
                ShortcutRow(keys: "⌘↩",   label: "Transfer (copies files for real)")
            }

            HelpListPanel(title: "App") {
                ShortcutRow(keys: "⌘,",   label: "Settings")
                ShortcutRow(keys: "⌘?",   label: "Chronoframe Help (this window)")
                ShortcutRow(keys: "⌘W",   label: "Close window")
                ShortcutRow(keys: "⌘Q",   label: "Quit")
            }
        }
    }
}

private struct HelpPrivacySection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            HelpListPanel(title: "Your files stay on your Mac") {
                HelpBullet("Chronoframe runs entirely on-device. No photos, paths, or filenames are sent over the network.")
                HelpBullet("There is no telemetry, no analytics, no crash reporting service. Nothing phones home.")
                HelpBullet("The app needs read access to your source folder and read/write access to your destination — granted by macOS through the standard folder picker. Access is per-folder; it never asks for whole-disk access.")
            }

            HelpListPanel(title: "What lives where") {
                PathRow(label: "Profiles file", url: RuntimePaths.profilesFileURL())
                PathRow(label: "App support folder", url: RuntimePaths.applicationSupportDirectory())
                Text("Run logs and revert receipts live in a hidden .organize_logs folder inside each destination you choose.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                    .padding(.top, DesignTokens.Spacing.xs)
            }
        }
    }
}

private struct HelpCreditsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("Chronoframe is built on a small set of open-source libraries. Their licenses require attribution; the full notices are reproduced here.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HelpListPanel(title: "Bundled components") {
                CreditRow(name: "ExifRead",  version: "3.3.0",  license: "BSD 3-Clause", url: "https://github.com/ianare/exif-py")
                CreditRow(name: "Tenacity",  version: "8.2.3",  license: "Apache 2.0",   url: "https://github.com/jd/tenacity")
                CreditRow(name: "Rich",      version: "13.7.1", license: "MIT",          url: "https://github.com/Textualize/rich")
                CreditRow(name: "PyYAML",    version: "6.0.1",  license: "MIT",          url: "https://pyyaml.org")
            }

            HelpListPanel(title: "Chronoframe") {
                Text("Copyright © 2026 Nishith Nand. All rights reserved.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                Text("Use of this software is governed by the Chronoframe Proprietary Software License included with the application.")
                    .font(DesignTokens.Typography.subtitle)
                    .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Building blocks

private struct HelpListPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.ColorSystem.inkMuted)

            DarkroomPanel(variant: .panel) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    content
                }
            }
        }
    }
}

private struct HelpStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Text(number)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.ColorSystem.accentWaypoint)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                Text(detail)
                    .font(DesignTokens.Typography.subtitle)
                    .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct HelpBullet: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Circle()
                .fill(DesignTokens.ColorSystem.inkMuted.opacity(0.5))
                .frame(width: 4, height: 4)
                .padding(.top, 7)
            Text(text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Text(keys)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                .frame(width: 56, alignment: .leading)
            Text(label)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
            Spacer(minLength: 0)
        }
    }
}

private func reveal(_ url: URL) {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    if !exists, url.pathExtension.isEmpty {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

private struct PathRow: View {
    let label: String
    let url: URL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Text(label)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                .frame(width: 140, alignment: .leading)

            Text(url.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button("Reveal") {
                reveal(url)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Reveal \(label) in Finder")
        }
    }
}

private struct CreditRow: View {
    let name: String
    let version: String
    let license: String
    let url: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.ColorSystem.inkPrimary)
                if let link = URL(string: url) {
                    Link(url, destination: link)
                        .font(DesignTokens.Typography.subtitle)
                        .foregroundStyle(DesignTokens.ColorSystem.inkMuted)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Text("\(license) · \(version)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignTokens.ColorSystem.inkSecondary)
        }
    }
}
