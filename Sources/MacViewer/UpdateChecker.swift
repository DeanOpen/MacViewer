import AppKit
import Foundation
import Security

/// Checks GitHub Releases for a newer MacViewer, then downloads, verifies and
/// installs it in place and relaunches. Only public release metadata is
/// requested; nothing about this Mac is sent.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable, Sendable {
        let version: String
        let pageURL: URL
        let dmgURL: URL?
        var notes = ""
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(String)
    }

    static let automaticKey = "MacViewer.checkForUpdates"
    static let lastCheckKey = "MacViewer.lastUpdateCheck"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/DeanOpen/MacViewer/releases/latest")!

    @Published private(set) var state = State.idle
    /// Set when the user asked for the check, or an install failed, so the result is shown.
    @Published var showResult = false
    /// Presents the update sheet (new version details, progress and install).
    @Published var showSheet = false
    @Published private(set) var installError: String?

    let currentVersion: String
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         defaults: UserDefaults = .standard) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        defaults.register(defaults: [Self.automaticKey: true])
    }

    var availableRelease: Release? {
        switch state {
        case let .available(release), let .downloading(release, _), let .installing(release): release
        default: nil
        }
    }

    /// Checks at launch and every few hours while running, unless turned off in Settings.
    func startAutomaticChecks(every interval: Duration = .seconds(4 * 60 * 60)) {
        guard automaticTask == nil else { return }
        automaticTask = Task {
            while !Task.isCancelled {
                checkAutomatically()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func checkAutomatically() {
        guard defaults.bool(forKey: Self.automaticKey), availableRelease == nil else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard task == nil else { if userInitiated { showResult = true }; return }
        state = .checking
        task = Task {
            defer { task = nil }
            do {
                var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 15)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let release = try Self.parseRelease(data)
                defaults.set(Date(), forKey: Self.lastCheckKey)
                state = Self.isVersion(release.version, newerThan: currentVersion) ? .available(release) : .upToDate
            } catch {
                state = .failed(L("Couldn’t check for updates. Check your internet connection and try again."))
            }
            if userInitiated {
                if availableRelease != nil { showSheet = true } else { showResult = true }
            }
        }
    }

    /// Downloads the new version, replaces this app with it and relaunches.
    /// When this copy can't replace itself (a development build, or a
    /// read-only location), the downloaded DMG is opened instead.
    func install() {
        guard let release = availableRelease, task == nil else { return }
        guard let dmgURL = release.dmgURL else { NSWorkspace.shared.open(release.pageURL); return }
        installError = nil
        state = .downloading(release, progress: 0)
        task = Task {
            defer { task = nil }
            do {
                let installer = SelfInstaller(appURL: Bundle.main.bundleURL)
                let folder = installer == nil
                    ? try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    : FileManager.default.temporaryDirectory
                let dmg = try await Self.downloadDMG(from: dmgURL, into: folder) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.state { self.state = .downloading(release, progress: fraction) }
                    }
                }
                guard let installer else {
                    state = .available(release)
                    NSWorkspace.shared.open(dmg)
                    return
                }
                state = .installing(release)
                defer { try? FileManager.default.removeItem(at: dmg) }
                try await installer.install(from: dmg)
                try installer.relaunchAfterExit()
                // AppKit refuses to quit while the update sheet is attached, so
                // close it first. Quit from the run loop, not from inside this
                // main-actor job: AppKit waits on the main thread for the
                // delegate's async reply, which would otherwise deadlock.
                showSheet = false
                try? await Task.sleep(for: .milliseconds(500))
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            } catch {
                state = .available(release)
                installError = L("The update couldn’t be installed. Download it from the release page instead.")
            }
        }
    }

    nonisolated static func parseRelease(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let html_url: URL
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.draft != true, payload.prerelease != true else { throw URLError(.cannotParseResponse) }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let dmg = payload.assets.first { $0.name.hasPrefix("MacViewer-") && $0.name.hasSuffix(".dmg") }
        guard dmg.map({ $0.browser_download_url.host == "github.com" }) ?? true else { throw URLError(.cannotParseResponse) }
        return Release(version: version, pageURL: payload.html_url, dmgURL: dmg?.browser_download_url,
                       notes: releaseNotes(payload.body ?? ""))
    }

    /// Release notes without the "## Install" section the release page shows to new users.
    nonisolated static func releaseNotes(_ body: String) -> String {
        var kept: [Substring] = [], skipping = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { skipping = trimmed.lowercased() == "## install" }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Numeric comparison of dotted versions ("0.10.0" > "0.9.1"); suffixes after "-" are ignored.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let lhs = parts(candidate), rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0, b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    nonisolated private static func downloadDMG(from url: URL, into folder: URL,
                                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let expected = max(response.expectedContentLength, 1)
        let partial = folder.appendingPathComponent(url.lastPathComponent + ".download")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                    progress(Double(received) / Double(expected))
                }
            }
            try handle.write(contentsOf: buffer)
            try handle.close()
        } catch {
            try? handle.close(); try? FileManager.default.removeItem(at: partial)
            throw error
        }
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var copy = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            copy += 1
            destination = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(copy)).dmg")
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        progress(1)
        return destination
    }
}

/// Replaces the running MacViewer.app with the copy inside a downloaded DMG.
/// The new app must be signed by the same Apple team as the running one.
struct SelfInstaller: Sendable {
    enum Failure: Error { case mountFailed, appMissing, signatureRejected, notSameApp }

    let appURL: URL
    let teamIdentifier: String

    /// Nil when this copy can't update itself: unsigned/ad-hoc builds, apps run
    /// from a disk image or App Translocation, or a folder the user can't write.
    init?(appURL: URL) {
        guard appURL.pathExtension == "app", !appURL.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path),
              let values = try? appURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly != true,
              let team = Self.teamIdentifier(of: appURL)
        else { return nil }
        self.appURL = appURL
        self.teamIdentifier = team
    }

    func install(from dmg: URL) async throws {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("MacViewer-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard try await Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly",
                                                      "-mountpoint", mountPoint.path]) == 0
        else { throw Failure.mountFailed }
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-force", "-quiet"]
            try? detach.run(); detach.waitUntilExit()
            try? FileManager.default.removeItem(at: mountPoint)
        }
        let newApp = mountPoint.appendingPathComponent(appURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw Failure.appMissing }
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle(url: appURL)?.bundleIdentifier else { throw Failure.notSameApp }

        // Copy next to the current app (same volume), verify that copy, then swap.
        let staged = appURL.deletingLastPathComponent().appendingPathComponent(".MacViewer-update-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: newApp, to: staged)
        do {
            guard Self.isValid(staged, team: teamIdentifier) else { throw Failure.signatureRejected }
            _ = try FileManager.default.replaceItemAt(appURL, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Opens the (replaced) app once this process has exited.
    func relaunchAfterExit() throws {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                                appURL.path]
        try relauncher.run()
    }

    static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Valid, Apple-anchored signature from the expected team, including nested code.
    static func isValid(_ url: URL, team: String) -> Bool {
        guard team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString,
                                             [], &requirement) == errSecSuccess
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
