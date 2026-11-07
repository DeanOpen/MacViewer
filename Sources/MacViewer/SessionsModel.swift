import Combine
import SwiftUI

/// Every remote session has its own model and tab, so several computers stay
/// connected at once. The dashboard's `form` model only holds the inputs and
/// history; it never connects itself.
@MainActor
final class SessionsModel: ObservableObject {
    @Published private(set) var sessions: [ConnectionModel] = []
    /// The shown tab, or nil for Home. Menu commands and AI agents act on it.
    @Published private(set) var selected: ConnectionModel?
    /// Why the last Connect from the dashboard did not start a session.
    @Published var formError: String?
    let form: ConnectionModel
    private let makeModel: () -> ConnectionModel
    private var observers: [ObjectIdentifier: [AnyCancellable]] = [:]
    private var captures: [ObjectIdentifier: RemoteCaptureController] = [:]

    init(form: ConnectionModel, makeModel: @escaping () -> ConnectionModel) {
        self.form = form
        self.makeModel = makeModel
    }

    var activeSessions: [ConnectionModel] { sessions.filter(\.isSessionActive) }
    var hasActiveSession: Bool { sessions.contains(where: \.isSessionActive) }

    /// The session menus and agents act on: the shown one, else the newest.
    var current: ConnectionModel { selected ?? sessions.last ?? form }

    func capture(for model: ConnectionModel) -> RemoteCaptureController? { captures[ObjectIdentifier(model)] }
    var allCaptures: [RemoteCaptureController] { Array(captures.values) }

    func activeSession(for identifier: String) -> ConnectionModel? {
        let target = identifier.filter { !$0.isWhitespace && $0 != "-" }
        return sessions.first { $0.isSessionActive && $0.normalizedTarget == target }
    }

    /// Starts a session in a new tab, or shows the tab already open for
    /// this ID. An empty password uses the one saved in Keychain.
    @discardableResult
    func connect(partnerID: String, password: String) -> ConnectionModel? {
        formError = nil
        if let existing = activeSession(for: partnerID) {
            select(existing)
            return existing
        }
        let model = makeModel()
        model.partnerID = partnerID
        if !password.isEmpty { model.password = password }
        model.connect()
        guard model.isSessionActive else {
            formError = model.errorMessage ?? NativeSessionError.missingPassword.localizedDescription
            return nil
        }
        add(model)
        select(model)
        return model
    }

    func connectFromForm() {
        guard connect(partnerID: form.partnerID, password: form.password) != nil else { return }
        form.password = ""
    }

    /// Shows a session's tab, or Home for nil. Other sessions stay connected.
    func select(_ model: ConnectionModel?) {
        guard selected !== model else { return }
        // Never leave keys or buttons held on a computer that is not shown.
        selected?.releaseRemoteInput()
        selected = model
    }

    /// Disconnects a session and closes its tab.
    func close(_ model: ConnectionModel) {
        guard let index = sessions.firstIndex(where: { $0 === model }) else { return }
        model.disconnect()
        if let capture = captures.removeValue(forKey: ObjectIdentifier(model)) {
            Task { @MainActor in
                if capture.isRecording || capture.isPreparingRecording { await capture.stopRecording() }
                capture.endSession()
            }
        }
        sessions.remove(at: index)
        observers[ObjectIdentifier(model)] = nil
        if selected === model {
            selected = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)]
        }
    }

    func selectNextTab(_ offset: Int) {
        let tabs: [ConnectionModel?] = [nil] + sessions.map { $0 }
        let index = tabs.firstIndex { $0 === selected } ?? 0
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Disconnects every session and closes all tabs.
    func closeAll() {
        for model in sessions { close(model) }
    }

    func disconnectAll() {
        for model in sessions { model.disconnect() }
    }

    func shutdown() async {
        await withTaskGroup(of: Void.self) { group in
            for model in sessions { group.addTask { await model.shutdown() } }
        }
    }

    private func add(_ model: ConnectionModel) {
        sessions.append(model)
        let capture = RemoteCaptureController()
        captures[ObjectIdentifier(model)] = capture
        model.screenFeed.onFrame = { capture.recordFrame($0) }
        observers[ObjectIdentifier(model)] = [
            // The dashboard lists every session's status, and the menus follow
            // the current one, so forward each session's changes.
            model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            model.$phase.sink { [weak self] phase in
                guard phase == .connected else { return }
                // History is saved after the phase changes.
                Task { @MainActor in self?.form.reloadHistory() }
            },
        ]
    }
}

extension SessionsModel {
    static func formattedID(_ id: String) -> String {
        stride(from: 0, to: id.count, by: 3).map { offset in
            let start = id.index(id.startIndex, offsetBy: offset)
            return String(id[start..<id.index(start, offsetBy: min(3, id.count - offset))])
        }.joined(separator: " ")
    }
}
