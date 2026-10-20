import Foundation
import Testing
@testable import UltraViewerProtocol

private func frame(width: Int, height: Int,
                   edits: [(x: Int, y: Int, value: UInt16)] = [],
                   layoutIdentifier: String? = "display",
                   monitors: [HostedScreenMonitor] = []) -> HostedScreenFrame {
    var bytes = [UInt8](repeating: 0, count: width * height * 2)
    for edit in edits {
        let bottomUpRow = height - 1 - edit.y
        let offset = (bottomUpRow * width + edit.x) * 2
        bytes[offset] = UInt8(truncatingIfNeeded: edit.value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: edit.value >> 8)
    }
    return HostedScreenFrame(width: width, height: height, rgb555BottomUp: Data(bytes),
                             monitors: monitors, layoutIdentifier: layoutIdentifier)
}

@Test func hostedFrameDiffReturnsNilForIdenticalFrames() {
    let first = frame(width: 64, height: 64, edits: [(3, 3, 0x7c00)])
    #expect(HostedScreenFrameDiff.changedRegion(previous: first, current: first) == nil)
    // Equal pixels but a different layout identity is not "identical": the host
    // must re-initialize, so the diff reports the full canvas.
    let moved = frame(width: 64, height: 64, edits: [(3, 3, 0x7c00)], layoutIdentifier: "other")
    #expect(HostedScreenFrameDiff.changedRegion(previous: first, current: moved)
        == .full(width: 64, height: 64))
}

@Test func hostedFrameDiffUsesTileAlignedBoundingBox() {
    let previous = frame(width: 64, height: 64)
    // One changed pixel in the first 32x32 tile.
    let small = frame(width: 64, height: 64, edits: [(1, 1, 0x001f)])
    #expect(HostedScreenFrameDiff.changedRegion(previous: previous, current: small)
        == HostedScreenRegion(x: 0, y: 0, width: 32, height: 32))

    // Changes in the top-left and bottom-right tiles produce their bounding box.
    let spread = frame(width: 128, height: 128, edits: [(1, 1, 1), (32, 32, 1)])
    let region = HostedScreenFrameDiff.changedRegion(previous: frame(width: 128, height: 128), current: spread)
    #expect(region == HostedScreenRegion(x: 0, y: 0, width: 64, height: 64))
    #expect(region?.isFull == false)

    // Right/bottom edges clamp to the canvas.
    let corner = frame(width: 128, height: 128, edits: [(127, 127, 1)])
    #expect(HostedScreenFrameDiff.changedRegion(previous: frame(width: 128, height: 128), current: corner)
        == HostedScreenRegion(x: 96, y: 96, width: 32, height: 32))
}

@Test func hostedFrameDiffFallsBackToFullFrameOnCoverageOrLayoutChange() {
    let previous = frame(width: 128, height: 128)
    // Four far-apart changed tiles: 96x96 bounding box = 56% of the canvas.
    let broad = frame(width: 128, height: 128, edits: [(0, 0, 1), (64, 0, 1), (0, 64, 1), (64, 64, 1)])
    let full = HostedScreenFrameDiff.changedRegion(previous: previous, current: broad,
                                                   fullFrameThreshold: 0.5)
    #expect(full == .full(width: 128, height: 128))
    #expect(full?.isFull == true)
    // A 1.0 threshold keeps the bounding box even for the same edit.
    let partial = HostedScreenFrameDiff.changedRegion(previous: previous, current: broad,
                                                      fullFrameThreshold: 1.0)
    #expect(partial == HostedScreenRegion(x: 0, y: 0, width: 96, height: 96))
    // A zero threshold makes any change full.
    let small = frame(width: 128, height: 128, edits: [(1, 1, 1)])
    #expect(HostedScreenFrameDiff.changedRegion(previous: previous, current: small, fullFrameThreshold: 0)
        == .full(width: 128, height: 128))
    // Layout changes are full even when the pixels are equal.
    let relayout = frame(width: 128, height: 128, layoutIdentifier: "external")
    #expect(HostedScreenFrameDiff.changedRegion(previous: previous, current: relayout)
        == .full(width: 128, height: 128))
    let monitors = [HostedScreenMonitor(left: 0, top: 0, right: 128, bottom: 128)]
    let monitorChange = frame(width: 128, height: 128, monitors: monitors)
    #expect(HostedScreenFrameDiff.changedRegion(previous: previous, current: monitorChange)
        == .full(width: 128, height: 128))
}

@Test func hostedFrameDiffHandlesSinglePixelCanvasAndTileSize() {
    let previous = frame(width: 1, height: 1)
    let changed = frame(width: 1, height: 1, edits: [(0, 0, 7)])
    // The only tile covers the whole canvas, so coverage is 100%.
    #expect(HostedScreenFrameDiff.changedRegion(previous: previous, current: changed)
        == .full(width: 1, height: 1))
    #expect(HostedScreenFrameDiff.changedRegion(previous: previous, current: previous) == nil)
    // Custom tile size.
    let sixteen = frame(width: 64, height: 64, edits: [(1, 1, 1)])
    #expect(HostedScreenFrameDiff.changedRegion(previous: frame(width: 64, height: 64),
                                                current: sixteen, tileSize: 16)
        == HostedScreenRegion(x: 0, y: 0, width: 16, height: 16))
}

@Test func hostedFrameRegionExposesAreaAndFullFlag() {
    let full = HostedScreenRegion.full(width: 100, height: 50)
    #expect(full.isFull)
    #expect(full.area == 5_000)
    #expect(full == HostedScreenRegion(x: 0, y: 0, width: 100, height: 50, isFull: true))
    let partial = HostedScreenRegion(x: 4, y: 6, width: 10, height: 8)
    #expect(!partial.isFull)
    #expect(partial.area == 80)
}
