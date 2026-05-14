#if canImport(ChronoframeAppCore)
import ChronoframeAppCore
#endif
import AppKit
import SwiftUI

struct PreviewReviewPanel: View {
    let model: RunWorkspaceModel
    @ObservedObject var store: PreviewReviewStore
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MeridianSurfaceCard(style: .inner, tint: model.context.previewReviewIsStale ? DesignTokens.Color.warning : DesignTokens.Color.sky) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Review Before Transfer")
                                .font(DesignTokens.Typography.cardTitle)
                            Text(headerMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task { await appState.startPreview() }
                        } label: {
                            Label("Rebuild Preview", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(!model.context.canStartRun)

                        Button {
                            Task { await store.acceptVisibleSuggestions() }
                        } label: {
                            Label("Accept Visible Events", systemImage: "text.badge.checkmark")
                        }
                        .disabled(!store.filteredItems.contains { $0.eventSuggestion?.suggestedName != nil })
                    }

                    HStack(spacing: 10) {
                        ForEach(model.previewReviewSummaryTiles) { tile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tile.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(tile.value)
                                    .font(.title3.monospacedDigit())
                                    .foregroundStyle(tile.tone.color)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            Picker("Review Filter", selection: $store.filter) {
                ForEach(PreviewReviewFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("previewReviewFilter")

            if store.isLoading {
                ProgressView("Loading review items...")
            } else if let errorMessage = store.errorMessage {
                EmptyStateView(
                    title: "Review Could Not Load",
                    message: errorMessage,
                    systemImage: "exclamationmark.triangle"
                )
            } else if store.items.isEmpty {
                EmptyStateView(
                    title: "No Review Artifact Yet",
                    message: "Run a preview to generate reviewable copy decisions.",
                    systemImage: "doc.text.magnifyingglass"
                )
            } else if store.filteredItems.isEmpty {
                EmptyStateView(
                    title: "Nothing in This Filter",
                    message: "Choose a different filter to inspect more preview items.",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.filteredItems.prefix(250)) { item in
                        PreviewReviewRow(item: item, store: store)
                    }
                }
            }
        }
    }

    private var headerMessage: String {
        if store.isStale {
            return "Corrections are saved. Rebuild the preview before transfer."
        }
        let summary = store.summary
        if summary.needsAttentionCount > 0 {
            return "\(summary.needsAttentionCount.formatted()) items need attention. Originals stay untouched."
        }
        return "The plan is ready to inspect. Originals stay untouched."
    }
}

private struct PreviewReviewRow: View {
    let item: PreviewReviewItem
    @ObservedObject var store: PreviewReviewStore

    @State private var selectedDate: Date
    @State private var eventName: String

    init(item: PreviewReviewItem, store: PreviewReviewStore) {
        self.item = item
        self.store = store
        self._selectedDate = State(initialValue: item.resolvedDate ?? Date())
        self._eventName = State(initialValue: item.acceptedEventName ?? item.eventSuggestion?.suggestedName ?? "")
    }

    var body: some View {
        MeridianSurfaceCard(style: .inner, tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PreviewReviewThumbnail(path: item.sourcePath)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(URL(fileURLWithPath: item.sourcePath).lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)

                        Text(item.sourcePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 8) {
                            Label(item.status.title, systemImage: statusSymbol)
                            Text("\(item.dateSource.title) · \(item.dateConfidence.title)")
                            if !item.issues.isEmpty {
                                Text(item.issues.map(\.title).joined(separator: ", "))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(tint)

                    }

                    Spacer(minLength: 12)
                }

                visualPlan

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        editorControls
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        editorControls
                    }
                }
            }
        }
    }

    private var visualPlan: some View {
        HStack(alignment: .top, spacing: 10) {
            planEndpoint(title: "Source", path: item.sourcePath, systemImage: "folder")
            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
            planEndpoint(
                title: destinationTitle,
                path: item.plannedDestinationPath ?? destinationFallback,
                systemImage: item.status == .alreadyInDestination ? "tray.full" : "folder.badge.plus"
            )
        }
        .padding(8)
        .background(DesignTokens.ColorSystem.hairline.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview plan from \(item.sourcePath) to \(item.plannedDestinationPath ?? destinationFallback)")
    }

    private var destinationTitle: String {
        switch item.status {
        case .ready:
            return "Will Copy To"
        case .alreadyInDestination:
            return "Already Exists"
        case .duplicate:
            return "Duplicate Route"
        case .hashError:
            return "Needs Attention"
        }
    }

    private var destinationFallback: String {
        switch item.status {
        case .alreadyInDestination:
            return "Destination already contains a matching file"
        case .duplicate:
            return "Duplicate handling will route this away from the main archive"
        case .hashError:
            return "Chronoframe needs a readable file before it can plan this item"
        case .ready:
            return "Destination path will appear after preview rebuild"
        }
    }

    private func planEndpoint(title: String, path: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var editorControls: some View {
        DatePicker("Date", selection: $selectedDate, displayedComponents: [.date])
            .labelsHidden()
            .frame(width: 150)

        TextField("Event", text: $eventName)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 140, maxWidth: 220)

        Button {
            Task {
                await store.saveOverride(for: item, captureDate: selectedDate, eventName: eventName)
            }
        } label: {
            Label("Save", systemImage: "checkmark.circle")
        }
        .disabled(item.identityRawValue == nil)

        if item.eventSuggestion?.suggestedName != nil {
            Button {
                Task { await store.acceptSuggestion(for: item) }
            } label: {
                Label("Accept Event", systemImage: "text.badge.checkmark")
            }
        }
    }

    private var tint: Color {
        if item.issues.contains(.hashError) {
            return DesignTokens.Color.danger
        }
        if item.needsAttention || item.status == .duplicate {
            return DesignTokens.Color.warning
        }
        if item.status == .alreadyInDestination {
            return DesignTokens.Color.inkMuted
        }
        return DesignTokens.Status.ready
    }

    private var statusSymbol: String {
        switch item.status {
        case .ready:
            return "checkmark.circle"
        case .alreadyInDestination:
            return "tray.full"
        case .duplicate:
            return "doc.on.doc"
        case .hashError:
            return "exclamationmark.triangle"
        }
    }
}

private struct PreviewReviewThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) {
            image = nil
            guard let cgImage = await ThumbnailRenderer.cgImage(
                for: URL(fileURLWithPath: path),
                size: CGSize(width: 52, height: 52),
                scale: NSScreen.main?.backingScaleFactor ?? 2
            ) else {
                return
            }
            image = NSImage(cgImage: cgImage, size: NSSize(width: 52, height: 52))
        }
    }
}
