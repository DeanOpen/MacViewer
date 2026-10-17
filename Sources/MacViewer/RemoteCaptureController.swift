import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Saves the decoded peer bitmap. This does not capture the local display and
/// never requests Screen Recording permission.
@MainActor
final class RemoteCaptureController: ObservableObject {
    @Published private(set) var isSaving = false
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPreparingRecording = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishingRecording = false
    @Published private(set) var recordingSeconds = 0
    private var editors: [UUID: RemoteCaptureEditorController] = [:]
    private var recorder: RemoteVideoRecorder?
    private var recordingURL: URL?
    private var recordingStarted: TimeInterval = 0
    private var lastSubmitted: TimeInterval = -.infinity
    private var pendingFrame: Task<Void, Never>?
    private var recordingRequest = UUID()
    private var recordingSavePanel: NSSavePanel?
    private var recordingClock: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?

    private var captureDirectory: URL {
        lastCaptureURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacViewer Captures", isDirectory: true)
    }

    func saveScreenshot(_ image: CGImage, peerName: String) {
        guard !isSaving else { return }
        errorMessage = nil
        let panel = NSSavePanel()
        panel.title = L("Save remote screen")
        panel.message = LF("Save the current image from %@.", peerName)
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.captureName(peerName: peerName)
        do {
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
            panel.directoryURL = captureDirectory
        } catch {
            // The save panel still lets the user choose another writable folder.
            panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        }
        isSaving = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            defer { self.isSaving = false }
            guard response == .OK, let url = panel.url else { return }
            do {
                try Self.writePNG(image, to: url)
                self.lastCaptureURL = url
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func openCaptureFolder() {
        errorMessage = nil
        do {
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
            if let lastCaptureURL, FileManager.default.fileExists(atPath: lastCaptureURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([lastCaptureURL])
            } else if !NSWorkspace.shared.open(captureDirectory) {
                throw CaptureError.cannotOpenFolder
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveRegion(_ image: CGImage, peerName: String) {
        openEditor(image, peerName: peerName, selectRegion: true)
    }

    func annotateScreenshot(_ image: CGImage, peerName: String) {
        openEditor(image, peerName: peerName, selectRegion: false)
    }

    /// Start only in response to an explicit Capture-menu action. The native
    /// save panel completes before any video encoder or output file is created.
    func startRecording(_ image: CGImage, peerName: String) {
        guard !isPreparingRecording, !isRecording, !isFinishingRecording else { return }
        errorMessage = nil
        let request = UUID()
        recordingRequest = request
        let panel = NSSavePanel()
        panel.title = L("Record remote screen")
        panel.message = LF("Silent video from %@, up to 1920 × 1080 at 15 fps.", peerName)
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = (Self.captureName(peerName: peerName) as NSString)
            .deletingPathExtension + ".mov"
        panel.directoryURL = captureDirectory
        isPreparingRecording = true
        recordingSavePanel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, self.recordingRequest == request else { return }
            self.recordingSavePanel = nil
            guard response == .OK, let url = panel.url else {
                self.isPreparingRecording = false
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let recorder = try RemoteVideoRecorder(imageWidth: image.width, imageHeight: image.height)
                    do { try await recorder.append(RemoteRecordingImage(image: image), at: 0) }
                    catch { await recorder.cancel(); throw error }
                    guard self.recordingRequest == request else { await recorder.cancel(); return }
                    self.recorder = recorder
                    self.recordingURL = url
                    self.recordingStarted = ProcessInfo.processInfo.systemUptime
                    self.lastSubmitted = 0
                    self.recordingSeconds = 0
                    self.isPreparingRecording = false
                    self.isRecording = true
                    self.recordingClock = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled, let self, self.isRecording,
                                  self.recordingRequest == request else { return }
                            self.recordingSeconds = Int(ProcessInfo.processInfo.systemUptime - self.recordingStarted)
                        }
                    }
                } catch {
                    guard self.recordingRequest == request else { return }
                    self.isPreparingRecording = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }

    /// Feed received peer frames, never local capture. At most one frame is in
    /// flight; excess frames are dropped to keep the live viewer responsive.
    func recordFrame(_ image: CGImage) {
        guard isRecording, let recorder, pendingFrame == nil else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - recordingStarted
        recordingSeconds = Int(elapsed)
        guard elapsed - lastSubmitted >= 1.0 / 15.0 else { return }
        lastSubmitted = elapsed
        let request = recordingRequest
        let snapshot = RemoteRecordingImage(image: image)
        pendingFrame = Task { @MainActor [weak self] in
            do {
                try await recorder.append(snapshot, at: elapsed)
                guard let self, self.recordingRequest == request else { return }
                self.pendingFrame = nil
            } catch {
                guard let self, self.recordingRequest == request else { return }
                self.pendingFrame = nil
                self.errorMessage = error.localizedDescription
                Task { await self.stopRecording() }
            }
        }
    }

    func stopRecording() async {
        if let finishingTask { await finishingTask.value; return }
        if isPreparingRecording {
            recordingRequest = UUID()
            recordingSavePanel?.cancel(nil); recordingSavePanel = nil
            isPreparingRecording = false
        }
        guard let recorder, let destination = recordingURL else { return }
        self.recorder = nil
        isRecording = false
        isFinishingRecording = true
        recordingClock?.cancel()
        recordingClock = nil
        let elapsed = ProcessInfo.processInfo.systemUptime - recordingStarted
        let task = Task { @MainActor in
            await pendingFrame?.value
            pendingFrame = nil
            defer { isFinishingRecording = false; recordingURL = nil }
            do {
                let temporary = try await recorder.finish(at: elapsed)
                do {
                    let files = FileManager.default
                    if files.fileExists(atPath: destination.path) {
                        _ = try files.replaceItemAt(destination, withItemAt: temporary)
                    } else { try files.moveItem(at: temporary, to: destination) }
                    lastCaptureURL = destination
                } catch {
                    lastCaptureURL = temporary
                    errorMessage = "The video was saved to \(temporary.path). \(error.localizedDescription)"
                }
            } catch { errorMessage = error.localizedDescription }
        }
        finishingTask = task
        await task.value
        finishingTask = nil
    }

    /// Call on disconnection or remote-view dismissal. A prepared save panel is
    /// cancelled and an active movie is finalized without more peer frames.
    /// App termination must await stopRecording() before exiting the process.
    func endSession() {
        recordingRequest = UUID()
        recordingSavePanel?.cancel(nil)
        recordingSavePanel = nil
        isPreparingRecording = false
        Task { await stopRecording() }
    }

    func clearError() { errorMessage = nil }

    private func openEditor(_ image: CGImage, peerName: String, selectRegion: Bool) {
        let id = UUID()
        let editor = RemoteCaptureEditorController(image: image, peerName: peerName, selectRegion: selectRegion,
            onExport: { [weak self] image in self?.saveScreenshot(image, peerName: peerName) },
            onClose: { [weak self] in self?.editors[id] = nil })
        editors[id] = editor
        editor.show()
    }

    private static func captureName(peerName: String) -> String {
        let safeName = peerName.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? String(scalar) : "-"
        }.joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(String(safeName.prefix(60))) \(formatter.string(from: Date())).png"
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.cannotEncode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.cannotEncode }
        try (data as Data).write(to: url, options: .atomic)
    }

    private enum CaptureError: LocalizedError {
        case cannotEncode, cannotOpenFolder
        var errorDescription: String? {
            switch self {
            case .cannotEncode: "The remote image could not be encoded as PNG."
            case .cannotOpenFolder: "The capture folder could not be opened."
            }
        }
    }
}
