import AppKit
import SwiftUI

/// Modal shown when a new version is available: details, progress and install.
struct UpdateSheet: View {
    @ObservedObject var updater: UpdateChecker
    /// True while a connection is open; installing restarts the app and ends it.
    let endsConnections: Bool
    @Environment(\.presentationMode) private var presentationMode

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
                        .font(.callout).foregroundColor(.secondary)
                }
            }

            if let notes = updater.availableRelease?.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What’s new").font(.subheadline.weight(.semibold))
                    ScrollView {
                        notesText(notes)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .selectableText()
                            .padding(10)
                    }
                    .frame(height: 150)
                    .shapeBackground(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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
                Button("Later") { presentationMode.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button("Update and Restart") { updater.install() }
                    .keyboardShortcut(.defaultAction)
                    .prominentButton()
                    .disabled(isBusy || updater.availableRelease == nil)
            }
        }
        .padding(22)
        .frame(width: 480)
        .dismissDisabled(isBusy)
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case let .downloading(_, progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                Text("Downloading… \(Int((progress * 100).rounded()))%")
                    .font(.caption).foregroundColor(.secondary).digitsMonospaced()
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing update… MacViewer will restart.").font(.caption).foregroundColor(.secondary)
            }
        default:
            if let error = updater.installError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.red)
            } else if endsConnections {
                Label("Updating restarts MacViewer and ends current connections.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundColor(.orange)
            }
        }
    }

    /// Markdown in `Text` needs macOS 12; older systems show the notes as plain text.
    @ViewBuilder private func notesText(_ notes: String) -> some View {
        if #available(macOS 12, *) { Text(Self.markdown(notes)) } else { Text(notes) }
    }

    @available(macOS 12, *)
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
