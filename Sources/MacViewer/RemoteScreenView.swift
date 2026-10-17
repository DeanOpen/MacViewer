import AppKit
import QuartzCore
import SwiftUI

/// Displays only decoded peer frames; it never captures the local Mac screen.
struct RemoteScreenView: NSViewRepresentable {
    let image: CGImage
    let smoothScaling: Bool
    let scrollSensitivity: Double
    let inputEnabled: Bool
    let onInput: (RemoteInput) -> Void
    var cursor: RemoteCursorPresenter.Snapshot? = nil

    func makeNSView(context: Context) -> RemoteScreenNSView {
        RemoteScreenNSView(frame: .zero)
    }

    func updateNSView(_ view: RemoteScreenNSView, context: Context) {
        view.image = image
        view.smoothScaling = smoothScaling
        view.scrollSensitivity = scrollSensitivity
        view.inputEnabled = inputEnabled
        view.onInput = onInput
        view.remoteCursor = cursor
        view.needsDisplay = true
    }
}

final class RemoteScreenNSView: NSView {
    var image: CGImage?
    var smoothScaling = true
    var scrollSensitivity = 1.0
    var inputEnabled = false {
        didSet {
            if oldValue && !inputEnabled { onInput?(.releaseAll) }
        }
    }
    var onInput: ((RemoteInput) -> Void)?
    var remoteCursor: RemoteCursorPresenter.Snapshot?
    private let cursorLayer = CALayer()
    private var pointerTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { inputEnabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        cursorLayer.contentsGravity = .resize
        layer?.addSublayer(cursorLayer)
        setAccessibilityLabel("Remote computer screen")
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Keep scaling/compositing on Core Animation instead of resampling a
        // full-resolution NSImage on the input/UI thread for every frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = smoothScaling ? .linear : .nearest
        layer?.magnificationFilter = smoothScaling ? .linear : .nearest
        layer?.contents = image
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
        if inputEnabled { onInput?(.releaseAll) }
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

    override func keyDown(with event: NSEvent) {
        guard inputEnabled else { return }
        onInput?(.key(keyCode: event.keyCode, characters: event.characters, pressed: true, modifiers: modifiers(event)))
    }

    override func keyUp(with event: NSEvent) {
        guard inputEnabled else { return }
        onInput?(.key(keyCode: event.keyCode, characters: event.characters, pressed: false, modifiers: modifiers(event)))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard inputEnabled, window?.firstResponder === self,
              event.type == .keyDown, event.modifierFlags.contains(.command) else {
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
        if event.modifierFlags.contains(.command) { result.insert(.command) }
        if event.modifierFlags.contains(.capsLock) { result.insert(.capsLock) }
        return result
    }
}
