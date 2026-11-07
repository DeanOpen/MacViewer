import SwiftUI

/// Shown on the session canvas until the first screen image arrives.
struct SessionProgressView: View {
    let phase: ConnectionModel.Phase
    let status: String
    let cancel: () -> Void
    let back: () -> Void

    @State private var reachedStep = 0
    @State private var started = Date()
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let steps = [
        "Registering this Mac",
        "Finding the Windows computer",
        "Connecting to the Windows computer",
        "Waiting for Windows to accept",
        "Loading the screen",
    ]

    /// Maps the session's status text to a step; unknown text keeps the last step.
    private static func step(for status: String) -> Int? {
        if status.hasPrefix("Registering this Mac") || status.hasPrefix("Connecting to "),
           !status.hasPrefix("Connecting to the Windows") { return 0 }
        if status.hasPrefix("Finding the Windows") { return 1 }
        if status.hasPrefix("Connecting to the Windows") || status.hasPrefix("Restoring the Windows relay") { return 2 }
        if status.hasPrefix("Waiting for Windows") { return 3 }
        if status.hasPrefix("Refreshing the Windows screen") || status.hasPrefix("Connected") { return 4 }
        return nil
    }

    var body: some View {
        Group {
            if phase == .connecting || phase == .connected { progressCard } else { endedCard }
        }
        .frame(maxWidth: 380)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .onAppear { reachedStep = Self.step(for: status) ?? 0; started = Date(); now = started }
        .onReceive(clock) { now = $0 }
        .onChange(of: status) { text in
            if let step = Self.step(for: text) { reachedStep = step }
        }
        .onChange(of: phase) { value in
            if value == .connecting, Self.step(for: status) == 0 { reachedStep = 0; started = Date(); now = started }
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L("Connecting")).font(.headline)
                Spacer()
                Text(Self.elapsed(now.timeIntervalSince(started)))
                    .font(.caption).digitsMonospaced().foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.steps.indices, id: \.self) { index in stepRow(index) }
            }
            Group {
                if now.timeIntervalSince(started) > 15 {
                    Label(L(reachedStep == 3
                            ? "Someone at the Windows computer needs to click Accept."
                            : "This is taking longer than usual. MacViewer keeps trying other servers."),
                          systemImage: "clock")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(L("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
            }
        }
    }

    private func stepRow(_ index: Int) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if index < reachedStep {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                } else if index == reachedStep {
                    Image(systemName: "circle.dotted").foregroundColor(.accentColor)
                } else {
                    Image(systemName: "circle").foregroundColor(.secondary.opacity(0.5))
                }
            }
            .frame(width: 16)
            Text(L(Self.steps[index]))
                .foregroundColor(index <= reachedStep ? .primary : .secondary)
                .fontWeight(index == reachedStep ? .medium : .regular)
        }
        .font(.callout)
    }

    private var endedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 34)).foregroundColor(.secondary)
            Text(L(status)).multilineTextAlignment(.center).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Back"), action: back)
        }
        .frame(maxWidth: .infinity)
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Round-trip time to the other computer, colored by quality.
struct PingBadge: View {
    let milliseconds: Int?
    var showsLabel = true

    var body: some View {
        if let milliseconds {
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 9, weight: .semibold))
                Text(showsLabel ? LF("Ping %ld ms", milliseconds) : "\(milliseconds) ms").digitsMonospaced()
            }
            .foregroundColor(color(for: milliseconds))
            .help(LF("Round trip to the other computer: %ld ms", milliseconds))
        }
    }

    private func color(for milliseconds: Int) -> Color {
        switch milliseconds {
        case ..<80: .green
        case ..<200: .orange
        default: .red
        }
    }
}
