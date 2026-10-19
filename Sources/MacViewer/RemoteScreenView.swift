import AppKit
import QuartzCore
import SwiftUI

/// Carries remote frames and the remote cursor straight to the screen view,
/// outside SwiftUI, so a new frame redraws one layer instead of the window.
@MainActor
final class RemoteScreenFeed {
    private(set) var image: CGImage?
    private(set) var cursor: RemoteCursorPresenter.Snapshot?
    /// Called for every new frame, e.g. by the screen recorder.
    var onFrame: ((CGImage) -> Void)?
    fileprivate weak var view: RemoteScreenNSView?

    func show(_ image: CGImage?) {
        self.image = image
        view?.needsDisplay = true
        if let image { onFrame?(image) }
    }

    func showCursor(_ cursor: RemoteCursorPresenter.Snapshot?) {
        self.cursor = cursor
        view?.needsDisplay = true
    }
}

/// Displays only decoded peer frames; it never captures the local Mac screen.
struct RemoteScreenView: NSViewRepresentable {
    let feed: RemoteScreenFeed
    let smoothScaling: Bool
    let scrollSensitivity: Double
    let inputEnabled: Bool
    let onInput: (RemoteInput) -> Void

    func makeNSView(context: Context) -> RemoteScreenNSView {
        RemoteScreenNSView(frame: .zero)
    }

    func updateNSView(_ view: RemoteScreenNSView, context: Context) {
        view.feed = feed
        feed.view = view
        view.smoothScaling = smoothScaling
        view.scrollSensitivity = scrollSensitivity
        view.inputEnabled = inputEnabled
        view.onInput = onInput
        view.needsDisplay = true
    }
}

final class RemoteScreenNSView: NSView {
    static let forwardShortcutsKey = "MacViewer.forwardShortcuts"
    var feed: RemoteScreenFeed?
    var image: CGImage? { feed?.image }
    var smoothScaling = true
    var scrollSensitivity = 1.0
    var inputEnabled = false {
        didSet {
            if oldValue && !inputEnabled { discardComposition(); rawKeysDown.removeAll(); onInput?(.releaseAll) }
        }
    }
    var onInput: ((RemoteInput) -> Void)?
    var remoteCursor: RemoteCursorPresenter.Snapshot? { feed?.cursor }
    private let cursorLayer = CALayer()
    /// Shows the input method's uncommitted text (e.g. Telex "việ") locally;
    /// the peer receives it only once the input method commits it.
    private let compositionLayer = CATextLayer()
    private var markedText = "" { didSet { updateCompositionLayer() } }
    /// The key event currently being interpreted by the input method.
    private var keyEventInFlight: NSEvent?
    private var keyEventConsumed = false
    /// Keys sent on the physical VK path, so their key-up is sent too.
    private var rawKeysDown: Set<UInt16> = []
    private var pointerTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { inputEnabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        cursorLayer.contentsGravity = .resize
        layer?.addSublayer(cursorLayer)
        compositionLayer.fontSize = 15
        compositionLayer.foregroundColor = NSColor.white.cgColor
        compositionLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        compositionLayer.cornerRadius = 4
        compositionLayer.alignmentMode = .center
        compositionLayer.isHidden = true
        layer?.addSublayer(compositionLayer)
        setAccessibilityLabel("Remote computer screen")
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var wantsUpdateLayer: Bool { true }

    private var taggedSource: CGImage?
    private var taggedImage: CGImage?

    /// The frame tagged with the window's color space. A DeviceRGB image made
    /// Core Animation convert every pixel of every frame on the main thread
    /// before showing it; a matching color space shows the bytes directly.
    /// Windows does not color-manage the remote desktop either.
    private var displayImage: CGImage? {
        guard let image else { return nil }
        if image === taggedSource, let taggedImage { return taggedImage }
        let space = window?.colorSpace?.cgColorSpace ?? window?.screen?.colorSpace?.cgColorSpace
        let tagged = space.flatMap { image.copy(colorSpace: $0) } ?? image
        taggedSource = image
        taggedImage = tagged
        return tagged
    }

    override func updateLayer() {
        // Keep scaling/compositing on Core Animation instead of resampling a
        // full-resolution NSImage on the input/UI thread for every frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = smoothScaling ? .linear : .nearest
        layer?.magnificationFilter = smoothScaling ? .linear : .nearest
        layer?.contents = displayImage
        updateRemoteCursor()
        CATransaction.commit()
    }

    private func updateRemoteCursor() {
        guard let image, let cursor = remoteCursor, let position = cursor.position,
              position.x >= 0, position.y >= 0,
              position.x < CGFloat(image.width), position.y < CGFloat(image.height) else {
            cursorLayer.isHidden = true; return
        }
        let rect = imageRect
        let scale = rect.width / CGFloat(image.width)
        cursorLayer.contents = cursor.image
        cursorLayer.frame = CGRect(x: rect.minX + (position.x - cursor.hotSpot.x) * scale,
                                  y: rect.minY + (position.y - cursor.hotSpot.y) * scale,
                                  width: CGFloat(cursor.image.width) * scale,
                                  height: CGFloat(cursor.image.height) * scale)
        cursorLayer.isHidden = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func resignFirstResponder() -> Bool {
        if inputEnabled { discardComposition(); rawKeysDown.removeAll(); onInput?(.releaseAll) }
        return super.resignFirstResponder()
    }

    override func mouseMoved(with event: NSEvent) { sendMovement(event) }
    override func mouseDragged(with event: NSEvent) { sendMovement(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMovement(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMovement(event) }
    override func mouseDown(with event: NSEvent) { sendButton(event, pressed: true) }
    override func mouseUp(with event: NSEvent) { sendButton(event, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { sendButton(event, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { sendButton(event, pressed: false) }
    override func otherMouseDown(with event: NSEvent) { sendButton(event, pressed: true) }
    override func otherMouseUp(with event: NSEvent) { sendButton(event, pressed: false) }

    override func scrollWheel(with event: NSEvent) {
        guard inputEnabled, remotePoint(for: event) != nil else { super.scrollWheel(with: event); return }
        onInput?(.scroll(
            deltaX: RemoteScroll.detents(delta: event.scrollingDeltaX,
                precise: event.hasPreciseScrollingDeltas, sensitivity: scrollSensitivity),
            deltaY: RemoteScroll.detents(delta: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas, sensitivity: scrollSensitivity)))
    }

    /// When off, Command-key combinations stay on this Mac (menus, app
    /// switching, copy/paste) instead of going to the other computer.
    private var forwardsShortcuts: Bool {
        UserDefaults.standard.object(forKey: Self.forwardShortcutsKey) as? Bool ?? true
    }

    private func keepsLocally(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) && (!forwardsShortcuts || Self.isReservedShortcut(event))
    }

    /// The View menu's ⌃⌥⌘ shortcuts and ⌃⌘F always stay on this Mac so the
    /// session can be controlled while other ⌘ shortcuts go to the peer.
    static func isReservedShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == [.command, .control, .option] { return true }
        return flags == [.command, .control] && event.charactersIgnoringModifiers?.lowercased() == "f"
    }

    override func keyDown(with event: NSEvent) {
        guard inputEnabled else { return }
        guard !keepsLocally(event) else { super.keyDown(with: event); return }
        // Shortcuts keep the physical-key path. Other keys go through the input
        // method first so Vietnamese (Telex/VNI) and other IMEs can compose text.
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let context = inputContext {
            keyEventInFlight = event
            keyEventConsumed = false
            _ = context.handleEvent(event)
            keyEventInFlight = nil
            if keyEventConsumed { return }
        }
        sendRawKey(event, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        guard inputEnabled, rawKeysDown.contains(event.keyCode) else { return }
        sendRawKey(event, pressed: false)
    }

    private func sendRawKey(_ event: NSEvent, pressed: Bool) {
        if pressed { rawKeysDown.insert(event.keyCode) } else { rawKeysDown.remove(event.keyCode) }
        onInput?(.key(keyCode: event.keyCode, characters: event.characters, pressed: pressed, modifiers: modifiers(event)))
    }

    private func discardComposition() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        inputContext?.discardMarkedText()
    }

    private func updateCompositionLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        compositionLayer.string = markedText
        compositionLayer.isHidden = markedText.isEmpty
        if !markedText.isEmpty {
            compositionLayer.contentsScale = window?.backingScaleFactor ?? 2
            let width = min(bounds.width - 16, compositionLayer.preferredFrameSize().width + 16)
            compositionLayer.frame = CGRect(x: bounds.midX - width / 2, y: bounds.maxY - 40, width: width, height: 22)
        }
        CATransaction.commit()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard inputEnabled, window?.firstResponder === self,
              event.type == .keyDown, event.modifierFlags.contains(.command), !keepsLocally(event) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard inputEnabled else { return }
        onInput?(.modifiers(modifiers(event)))
    }

    private var imageRect: NSRect {
        guard let image, image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func remotePoint(for event: NSEvent) -> (x: Int, y: Int)? {
        guard let image else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return (
            min(image.width - 1, max(0, Int((point.x - rect.minX) / rect.width * CGFloat(image.width)))),
            min(image.height - 1, max(0, Int((point.y - rect.minY) / rect.height * CGFloat(image.height))))
        )
    }

    private func sendMovement(_ event: NSEvent) {
        guard inputEnabled, let point = remotePoint(for: event) else { return }
        onInput?(.pointerMoved(x: point.x, y: point.y))
    }

    private func sendButton(_ event: NSEvent, pressed: Bool) {
        guard inputEnabled else { return }
        if pressed { window?.makeFirstResponder(self) }
        guard let point = remotePoint(for: event) else {
            if !pressed { onInput?(.releaseAll) }
            return
        }
        onInput?(.pointerButton(button: event.buttonNumber, pressed: pressed, x: point.x, y: point.y))
    }

    private func modifiers(_ event: NSEvent) -> RemoteModifiers {
        var result: RemoteModifiers = []
        if event.modifierFlags.contains(.shift) { result.insert(.shift) }
        if event.modifierFlags.contains(.control) { result.insert(.control) }
        if event.modifierFlags.contains(.option) { result.insert(.option) }
        if event.modifierFlags.contains(.command), forwardsShortcuts { result.insert(.command) }
        if event.modifierFlags.contains(.capsLock) { result.insert(.capsLock) }
        return result
    }
}

extension RemoteScreenNSView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        keyEventConsumed = true
        // A key that produced its own ASCII character keeps the VK/scan path, so
        // plain typing behaves exactly as before; anything else is sent as text.
        if let event = keyEventInFlight, text == event.characters,
           text.unicodeScalars.count == 1, text.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) {
            sendRawKey(event, pressed: true)
        } else if !text.isEmpty {
            onInput?(.text(text))
        }
    }

    override func doCommand(by selector: Selector) {
        // Return, Backspace, arrows, Tab, Escape…: forward the physical key.
        keyEventConsumed = true
        if let event = keyEventInFlight { sendRawKey(event, pressed: true) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        keyEventConsumed = true
    }

    func unmarkText() {
        // The input method commits its composition as-is (e.g. focus change).
        let text = markedText
        markedText = ""
        if !text.isEmpty { onInput?(.text(text)) }
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Place candidate windows at the composition preview.
        guard let window else { return .zero }
        return window.convertToScreen(convert(compositionLayer.frame, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
