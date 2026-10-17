import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func recoveredRectangleCopyPreservesPixelBytesAndBottomUpPadding() throws {
    // A 2×2, three-byte-per-pixel top-down fixture. Channel order remains opaque.
    let source = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    var canvas = try ScreenRectangleBuffer(width: 2, height: 2, bytesPerPixel: 3,
                                           rowStride: 8, pixels: Data(repeating: 99, count: 16))
    try canvas.copyRectangle(source, width: 2, height: 2, atX: 0, atY: 0)
    #expect(canvas.pixels == Data([7, 8, 9, 10, 11, 12, 99, 99,
                                 1, 2, 3, 4, 5, 6, 99, 99]))
}

@Test func recoveredRectangleClippingUsesCorrespondingSourcePixels() throws {
    var canvas = try ScreenRectangleBuffer(width: 3, height: 2, bytesPerPixel: 1,
                                           rowStride: 5, pixels: Data(repeating: 99, count: 10))
    let source = Data([1, 2, 3, 4, 5, 6])
    try canvas.copyRectangle(source, width: 3, height: 2, atX: -1, atY: 0)
    #expect(canvas.pixels == Data([5, 6, 99, 99, 99, 2, 3, 99, 99, 99]))
    // The first source row lies above the destination and must be skipped.
    try canvas.copyRectangle(source, width: 3, height: 2, atX: 0, atY: -1)
    #expect(canvas.pixels == Data([5, 6, 99, 99, 99, 4, 5, 6, 99, 99]))
    // Only the top-left source pixel intersects the destination's bottom-right.
    try canvas.copyRectangle(source, width: 3, height: 2, atX: 2, atY: 1)
    #expect(canvas.pixels == Data([5, 6, 1, 99, 99, 4, 5, 6, 99, 99]))
}

@Test func rectangleOffscreenPlacementAndSlicedDataAreSafe() throws {
    var canvas = try ScreenRectangleBuffer(width: 2, height: 2, bytesPerPixel: 1,
                                           rowStride: 2, pixels: Data([99, 0, 0, 0, 0]).dropFirst())
    let source = Data([99, 1, 2, 3, 4]).dropFirst()
    for (x, y) in [(2, 0), (0, 2), (-2, 0), (0, -2), (Int.min, Int.max)] {
        try canvas.copyRectangle(source, width: 2, height: 2, atX: x, atY: y)
        #expect(canvas.pixels == Data([0, 0, 0, 0]))
    }
    try canvas.copyRectangle(source, width: 2, height: 2, atX: 0, atY: 0)
    #expect(canvas.pixels == Data([3, 4, 1, 2]))
}

@Test func rectangleRejectsMalformedSizesBeforeModifyingPixels() throws {
    #expect(throws: ScreenRectangleBuffer.Error.invalidGeometry) {
        try ScreenRectangleBuffer(width: 0, height: 1, bytesPerPixel: 1, rowStride: 1, pixels: Data([0]))
    }
    #expect(throws: ScreenRectangleBuffer.Error.invalidStride) {
        try ScreenRectangleBuffer(width: 2, height: 1, bytesPerPixel: 3, rowStride: 5, pixels: Data(count: 5))
    }
    #expect(throws: ScreenRectangleBuffer.Error.invalidDestinationLength) {
        try ScreenRectangleBuffer(width: 2, height: 1, bytesPerPixel: 3, rowStride: 6, pixels: Data(count: 5))
    }
    #expect(throws: ScreenRectangleBuffer.Error.sizeOverflow) {
        try ScreenRectangleBuffer(width: .max, height: 1, bytesPerPixel: 2, rowStride: .max, pixels: Data())
    }
    var canvas = try ScreenRectangleBuffer(width: 1, height: 1, bytesPerPixel: 3,
                                           rowStride: 3, pixels: Data([7, 8, 9]))
    #expect(throws: ScreenRectangleBuffer.Error.truncatedSource) {
        try canvas.copyRectangle(Data([1, 2]), width: 1, height: 1, atX: 0, atY: 0)
    }
    #expect(throws: ScreenRectangleBuffer.Error.sizeOverflow) {
        try canvas.copyRectangle(Data(), width: .max, height: 1, atX: 0, atY: 0)
    }
    #expect(canvas.pixels == Data([7, 8, 9]))
}
