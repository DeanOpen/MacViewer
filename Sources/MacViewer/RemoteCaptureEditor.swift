import AppKit
import Combine
import SwiftUI

@MainActor
final class RemoteCaptureEditorController: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let onClose: () -> Void

    init(image: CGImage, peerName: String, selectRegion: Bool,
         onExport: @escaping (CGImage) -> Void, onClose: @escaping () -> Void) {
        let model = RemoteCaptureEditorModel(image: image, selectRegion: selectRegion)
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 570),
                         styleMask: [.titled, .closable, .resizable, .utilityWindow],
                         backing: .buffered, defer: false)
        self.onClose = onClose
        super.init()
        window.title = "\(selectRegion ? "Capture a region" : "Annotate capture") — \(peerName)"
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: RemoteCaptureEditorView(model: model, onExport: onExport).appLanguage())
        window.center()
    }

    func show() { window.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor
final class RemoteCaptureEditorModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case region, pen, rectangle
        var id: Self { self }
        var title: String {
            switch self { case .region: "Select region"; case .pen: "Draw"; case .rectangle: "Rectangle" }
        }
    }
    enum Ink: CaseIterable, Identifiable {
        case red, yellow, blue
        var id: Self { self }
        var color: NSColor {
            switch self { case .red: .systemRed; case .yellow: .systemYellow; case .blue: .systemBlue }
        }
    }
    struct Mark {
        let tool: Tool
        let ink: Ink
        var points: [CGPoint]
    }

    let image: CGImage
    @Published var tool: Tool
    @Published var ink: Ink = .red
    @Published var selection: CGRect?
    @Published var marks: [Mark] = []
    @Published var errorMessage: String?
    private var dragOrigin: CGPoint?
    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }
    var canExport: Bool { (selection?.width ?? 0) >= 2 && (selection?.height ?? 0) >= 2 }
    var strokeWidth: CGFloat { max(2, CGFloat(min(image.width, image.height)) / 350) }

    init(image: CGImage, selectRegion: Bool) {
        self.image = image
        tool = selectRegion ? .region : .pen
        selection = selectRegion ? nil : CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    func begin(at point: CGPoint) {
        dragOrigin = point
        if tool == .region { selection = CGRect(origin: point, size: .zero) }
        else {
            if marks.count >= 200 { marks.removeFirst() }
            marks.append(Mark(tool: tool, ink: ink, points: [point]))
        }
    }

    func drag(to point: CGPoint) {
        guard let dragOrigin else { return }
        if tool == .region {
            selection = CGRect(x: min(dragOrigin.x, point.x), y: min(dragOrigin.y, point.y),
                               width: abs(point.x - dragOrigin.x), height: abs(point.y - dragOrigin.y))
        } else if let last = marks.indices.last {
            if tool == .rectangle { marks[last].points = [dragOrigin, point] }
            else if marks[last].points.count < 50_000 { marks[last].points.append(point) }
        }
    }

    func end() { dragOrigin = nil }
    func useFullImage() { selection = imageBounds }
    func undo() { if !marks.isEmpty { marks.removeLast() } }

    func export() -> CGImage? {
        guard let region = selection?.integral.intersection(imageBounds), canExport,
              let cropped = image.cropping(to: region),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                      bitsPerComponent: 8, bytesPerRow: cropped.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            errorMessage = "Select a region at least 2 × 2 pixels."
            return nil
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        context.translateBy(x: 0, y: CGFloat(cropped.height))
        context.scaleBy(x: 1, y: -1)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            let points = mark.points.map { CGPoint(x: $0.x - region.minX, y: $0.y - region.minY) }
            guard let first = points.first else { continue }
            context.setStrokeColor(mark.ink.color.cgColor)
            context.setFillColor(mark.ink.color.cgColor)
            if mark.tool == .rectangle, let last = points.last {
                context.stroke(CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                      width: abs(last.x - first.x), height: abs(last.y - first.y)))
            } else if points.count == 1 {
                context.fillEllipse(in: CGRect(x: first.x - strokeWidth / 2, y: first.y - strokeWidth / 2,
                                                width: strokeWidth, height: strokeWidth))
            } else {
                context.beginPath(); context.move(to: first)
                points.dropFirst().forEach { context.addLine(to: $0) }
                context.strokePath()
            }
        }
        return context.makeImage()
    }
}

@MainActor
private struct RemoteCaptureEditorView: View {
    @ObservedObject var model: RemoteCaptureEditorModel
    let onExport: (CGImage) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Tool", selection: $model.tool) {
                    ForEach(RemoteCaptureEditorModel.Tool.allCases) { tool in Text(LocalizedStringKey(tool.title)).tag(tool) }
                }.pickerStyle(.segmented).frame(maxWidth: 320)
                ForEach(RemoteCaptureEditorModel.Ink.allCases) { ink in
                    Button { model.ink = ink } label: {
                        Circle().fill(Color(nsColor: ink.color)).frame(width: 16, height: 16)
                            .padding(3).overlay(Circle().stroke(model.ink == ink ? Color.primary : .clear))
                    }.buttonStyle(.plain).help("Drawing color: \(String(describing: ink))")
                }
                Spacer(minLength: 0)
            }.padding(10).background(.bar)
            Divider()
            CaptureCanvas(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Button("Full image", action: model.useFullImage)
                Button("Undo drawing", action: model.undo).disabled(model.marks.isEmpty)
                Spacer()
                if let selection = model.selection, model.canExport {
                    Text("\(Int(selection.width)) × \(Int(selection.height))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Drag over the image to select a region.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Save PNG…") { if let image = model.export() { onExport(image) } }
                    .buttonStyle(.borderedProminent).disabled(!model.canExport)
            }.padding(10).background(.bar)
        }
        .alert("Couldn’t create capture", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
}

@MainActor
private struct CaptureCanvas: NSViewRepresentable {
    @ObservedObject var model: RemoteCaptureEditorModel
    func makeNSView(context: Context) -> CaptureCanvasNSView { CaptureCanvasNSView(model: model) }
    func updateNSView(_ view: CaptureCanvasNSView, context: Context) { view.needsDisplay = true }
}

@MainActor
private final class CaptureCanvasNSView: NSView {
    let model: RemoteCaptureEditorModel
    private var dragging = false
    override var isFlipped: Bool { true }
    init(model: RemoteCaptureEditorModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var imageRect: CGRect {
        let scale = min(max(0, bounds.width - 24) / CGFloat(model.image.width),
                        max(0, bounds.height - 24) / CGFloat(model.image.height))
        let size = CGSize(width: CGFloat(model.image.width) * scale, height: CGFloat(model.image.height) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let rect = imageRect
        guard rect.width > 0 else { return }
        NSImage(cgImage: model.image, size: NSSize(width: model.image.width, height: model.image.height))
            .draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                  hints: [.interpolation: NSImageInterpolation.high])
        let scale = rect.width / CGFloat(model.image.width)
        func viewPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        for mark in model.marks {
            guard let first = mark.points.first.map(viewPoint) else { continue }
            let path = NSBezierPath()
            path.lineWidth = max(1, model.strokeWidth * scale)
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            mark.ink.color.setStroke(); mark.ink.color.setFill()
            if mark.tool == .rectangle, let last = mark.points.last.map(viewPoint) {
                NSBezierPath(rect: CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                         width: abs(last.x - first.x), height: abs(last.y - first.y)))
                    .withLineWidth(path.lineWidth).stroke()
            } else if mark.points.count == 1 {
                NSBezierPath(ovalIn: CGRect(x: first.x - path.lineWidth / 2, y: first.y - path.lineWidth / 2,
                                            width: path.lineWidth, height: path.lineWidth)).fill()
            } else {
                path.move(to: first)
                mark.points.dropFirst().forEach { path.line(to: viewPoint($0)) }
                path.stroke()
            }
        }
        if let selection = model.selection {
            let selected = CGRect(origin: viewPoint(selection.origin),
                                  size: CGSize(width: selection.width * scale, height: selection.height * scale))
            let shade = NSBezierPath(rect: rect)
            shade.append(NSBezierPath(rect: selected)); shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.36).setFill(); shade.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selected); border.lineWidth = 1
            border.setLineDash([4, 3], count: 2, phase: 0); border.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        dragging = true; model.begin(at: sourcePoint(point))
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        model.drag(to: sourcePoint(convert(event.locationInWindow, from: nil)))
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        model.drag(to: sourcePoint(convert(event.locationInWindow, from: nil)))
        dragging = false; model.end()
    }
    private func sourcePoint(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: min(CGFloat(model.image.width), max(0, (point.x - rect.minX) / rect.width * CGFloat(model.image.width))),
                       y: min(CGFloat(model.image.height), max(0, (point.y - rect.minY) / rect.height * CGFloat(model.image.height))))
    }
}

private extension NSBezierPath {
    func withLineWidth(_ width: CGFloat) -> NSBezierPath { lineWidth = width; return self }
}
