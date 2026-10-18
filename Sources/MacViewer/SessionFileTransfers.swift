import AppKit
import Foundation

/// One file sent or received in the session chat.
struct SessionFileTransfer: Identifiable, Equatable {
    enum State: Equatable {
        /// Incoming, waiting for Save or Cancel on this Mac.
        case offered
        /// Outgoing, waiting for the other computer to accept.
        case waiting
        case transferring
        case completed
        case canceled
        case failed(String)
    }

    let id: String
    let name: String
    let size: Int64
    let isOutgoing: Bool
    var bytes: Int64 = 0
    var state: State
    /// Where an incoming file is written.
    var location: URL?

    var isFinished: Bool {
        switch state {
        case .completed, .canceled, .failed: true
        default: false
        }
    }

    var fraction: Double { size > 0 ? min(1, Double(bytes) / Double(size)) : (state == .completed ? 1 : 0) }
}

/// Folder that received files are saved to, chosen once and remembered.
enum ReceivedFilesFolder {
    static let key = "MacViewer.receivedFilesFolder"

    static func current(_ defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: key), !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Asks for a folder and remembers it; nil when the user cancels.
    @MainActor
    static func choose(_ defaults: UserDefaults = .standard) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.message = L("Choose where MacViewer saves files received in chat. You can change it later in Settings.")
        panel.directoryURL = current(defaults)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        defaults.set(url.path, forKey: key)
        return url
    }

    /// `folder/name`, or `folder/name (2).ext` … when that name is taken.
    static func uniqueURL(for name: String, in folder: URL) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = folder.appendingPathComponent(safe.isEmpty ? "file" : safe)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base.isEmpty ? "file" : base) (\(number))"
            candidate = folder.appendingPathComponent(ext.isEmpty ? numbered : "\(numbered).\(ext)")
            number += 1
        }
        return candidate
    }
}
