import AppKit
import SwiftUI

/// Modal shown when a new version is available: details, progress and install.
struct UpdateSheet: View {
    @ObservedObject var updater: UpdateChecker
    /// True while a connection is open; installing restarts the app and ends it.
    let endsConnections: Bool
    @Environment(\.dismiss) private var dismiss

    private var isBusy: Bool {
        switch updater.state {
        case .downloading, .installing: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    if let release = updater.availableRelease {
                        Text("MacViewer \(release.version) is available").font(.title3.weight(.semibold))
                    }
                    Text("You have version \(updater.currentVersion).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let notes = updater.availableRelease?.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What’s new").font(.subheadline.weight(.semibold))
                    ScrollView {
                        Text(Self.markdown(notes))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(height: 150)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                }
            }

            status

            HStack {
                if let release = updater.availableRelease {
                    Button("Release page") { NSWorkspace.shared.open(release.pageURL) }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button("Update and Restart") { updater.install() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || updater.availableRelease == nil)
            }
        }
        .padding(22)
        .frame(width: 480)
        .interactiveDismissDisabled(isBusy)
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case let .downloading(_, progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                Text("Downloading… \(Int((progress * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing update… MacViewer will restart.").font(.caption).foregroundStyle(.secondary)
            }
        default:
            if let error = updater.installError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else if endsConnections {
                Label("Updating restarts MacViewer and ends current connections.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
