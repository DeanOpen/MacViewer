import AppKit
import ImageIO
import Testing
import UltraViewerProtocol
@testable import MacViewer

@MainActor
struct RemoteCursorPresenterTests {
    @Test func missingSelectionRequestsAreSuppressedAndPositionRemainsVirtual() {
        let presenter = RemoteCursorPresenter()
        #expect(presenter.snapshot.isFallback)
        #expect(presenter.consume(.selection(hash: -17)) == -17)
        #expect(presenter.consume(.selection(hash: -17)) == nil)
        #expect(presenter.pendingRequestCount == 1)
        presenter.consume(.position(x: -1920, y: 32767))
        #expect(presenter.snapshot.position == CGPoint(x: -1920, y: 32767))
        presenter.consume(.selection(hash: CursorMessage.ignoredSelectionHash))
        #expect(presenter.selectedHash == -17)
        #expect(presenter.pendingRequestCount == 1)
    }

    @Test func PNGResourceDisplaysWithValidatedPixelHotspot() throws {
        let presenter = RemoteCursorPresenter()
        let cursor = try cursorFixture(resource: pngFixture(width: 2, height: 2),
                                       width: 2, height: 2, hotSpotX: 1, hotSpotY: 1)
        #expect(presenter.consume(.selection(hash: 5)) == 5)
        presenter.consume(.position(x: -20, y: 10))
        presenter.consume(.shape(hash: 5, cursor: cursor))
        #expect(!presenter.snapshot.isFallback)
        #expect(presenter.snapshot.image.width == 2 && presenter.snapshot.image.height == 2)
        #expect(presenter.snapshot.hotSpot == CGPoint(x: 1, y: 1))
        #expect(presenter.snapshot.position == CGPoint(x: -20, y: 10))
        #expect(presenter.cacheEntryCount == 1 && presenter.cacheByteCount == 16)
        #expect(presenter.pendingRequestCount == 0)
        #expect(presenter.consume(.selection(hash: 5)) == nil)
    }

    @Test func lateShapeRepliesDoNotReplaceTheNewSelectedCursor() throws {
        let presenter = RemoteCursorPresenter()
        let first = try cursorFixture(resource: pngFixture(width: 2, height: 2),
                                      width: 2, height: 2, hotSpotX: 0, hotSpotY: 0)
        let second = try cursorFixture(resource: first.resourceData, width: 2, height: 2, hotSpotX: 1, hotSpotY: 1)
        presenter.consume(.selection(hash: 1))
        presenter.consume(.selection(hash: 2))
        presenter.consume(.shape(hash: 1, cursor: first))
        #expect(presenter.snapshot.isFallback)
        #expect(presenter.selectedHash == 2)
        presenter.consume(.shape(hash: 2, cursor: second))
        #expect(!presenter.snapshot.isFallback && presenter.snapshot.hotSpot == CGPoint(x: 1, y: 1))
        #expect(presenter.consume(.selection(hash: 1)) == nil)
        #expect(presenter.snapshot.hotSpot == .zero)
    }

    @Test func shapeCountAndByteBudgetsEvictLeastRecentlySelectedEntries() throws {
        let presenter = RemoteCursorPresenter(maximumShapes: 2, maximumBytes: 32)
        let cursor = try cursorFixture(resource: pngFixture(width: 2, height: 2), width: 2, height: 2)
        presenter.consume(.shape(hash: 1, cursor: cursor))
        presenter.consume(.shape(hash: 2, cursor: cursor))
        presenter.consume(.selection(hash: 1))
        presenter.consume(.shape(hash: 3, cursor: cursor))
        #expect(presenter.cacheEntryCount == 2 && presenter.cacheByteCount == 32)
        #expect(presenter.consume(.selection(hash: 2)) == 2)
        #expect(presenter.consume(.selection(hash: 2)) == nil)
        let byteLimited = RemoteCursorPresenter(maximumBytes: 16)
        byteLimited.consume(.shape(hash: 1, cursor: cursor))
        byteLimited.consume(.shape(hash: 2, cursor: cursor))
        #expect(byteLimited.cacheEntryCount == 1 && byteLimited.cacheByteCount == 16)
        #expect(byteLimited.consume(.selection(hash: 1)) == 1)
    }

    @Test func mismatchedOversizeOrUnsupportedResourcesUseArrowWithoutCachingEncodedData() throws {
        let presenter = RemoteCursorPresenter()
        let oversizedPNG = try cursorFixture(resource: pngFixture(width: 257, height: 1), width: 256, height: 1)
        presenter.consume(.selection(hash: 1))
        presenter.consume(.shape(hash: 1, cursor: oversizedPNG))
        #expect(presenter.snapshot.isFallback && presenter.cacheByteCount == 0)
        var oversizedDIB = Data()
        for value in [UInt32(40), 4096, 4] { appendLong(value, to: &oversizedDIB) }
        oversizedDIB.append(contentsOf: [1, 0, 32, 0])
        oversizedDIB.append(Data(count: 24))
        let badDIB = try cursorFixture(resource: oversizedDIB, width: 2, height: 2)
        presenter.consume(.selection(hash: 2))
        presenter.consume(.shape(hash: 2, cursor: badDIB))
        #expect(presenter.snapshot.isFallback && presenter.cacheByteCount == 0)
        let unsupported = try cursorFixture(resource: Data([0xaa, 0xbb, 0xcc, 0xdd]), width: 2, height: 2)
        presenter.consume(.selection(hash: 3))
        presenter.consume(.shape(hash: 3, cursor: unsupported))
        #expect(presenter.snapshot.isFallback && presenter.cacheByteCount == 0)
        #expect(presenter.consume(.selection(hash: 3)) == nil)
    }

    @Test func classicDIBCursorCanBeDecodedThroughSingleImageICO() throws {
        var dib = Data()
        for value in [UInt32(40), 2, 4] { appendLong(value, to: &dib) }
        dib.append(contentsOf: [1, 0, 32, 0])
        for value in [UInt32(0), 16, 0, 0, 0, 0] { appendLong(value, to: &dib) }
        // Bottom-up BGRA color rows, followed by DWORD-aligned AND-mask rows.
        dib.append(contentsOf: [255, 0, 0, 255, 255, 255, 255, 255,
                                0, 0, 255, 255, 0, 255, 0, 255])
        dib.append(Data(count: 8))
        let cursor = try cursorFixture(resource: dib, width: 2, height: 2, hotSpotX: 1)
        let presenter = RemoteCursorPresenter()
        presenter.consume(.selection(hash: 9))
        presenter.consume(.shape(hash: 9, cursor: cursor))
        #expect(!presenter.snapshot.isFallback)
        #expect(presenter.snapshot.image.width == 2 && presenter.snapshot.image.height == 2)
        #expect(presenter.snapshot.hotSpot == CGPoint(x: 1, y: 0))
        let pixels = try imageBytes(presenter.snapshot.image)
        #expect(pixels == Data([0, 0, 255, 255, 0, 255, 0, 255,
                               255, 0, 0, 255, 255, 255, 255, 255]))
    }

    @Test func DIBAlphaOverridesANDMaskAndZeroAlphaUsesLegacyMask() throws {
        let alphaDIB = dibFixture(width: 2, height: 1, bits: 32,
            pixelRows: Data([0, 0, 255, 128, 0, 255, 0, 0]), maskRows: Data([0xc0, 0, 0, 0]))
        let presenter = RemoteCursorPresenter()
        presenter.consume(.selection(hash: 1))
        presenter.consume(.shape(hash: 1, cursor: try cursorFixture(resource: alphaDIB, width: 2, height: 1)))
        #expect(!presenter.snapshot.isFallback)
        let alphaPixels = try imageBytes(presenter.snapshot.image)
        #expect(alphaPixels == Data([0, 0, 255, 128, 0, 0, 0, 0]))

        let legacyDIB = dibFixture(width: 2, height: 1, bits: 32,
            pixelRows: Data([0, 0, 0, 0, 0, 0, 255, 0]), maskRows: Data([0x80, 0, 0, 0]))
        presenter.consume(.selection(hash: 2))
        presenter.consume(.shape(hash: 2, cursor: try cursorFixture(resource: legacyDIB, width: 2, height: 1)))
        #expect(!presenter.snapshot.isFallback)
        let legacyPixels = try imageBytes(presenter.snapshot.image)
        #expect(legacyPixels == Data([0, 0, 0, 0, 0, 0, 255, 255]))
    }

    @Test func topDown24BitDIBHonorsDWORDRowPadding() throws {
        // Three24bpp pixels require nine data bytes and three padding bytes.
        let dib = dibFixture(width: 3, height: 2, bits: 24, topDown: true,
            pixelRows: Data([0, 255, 255, 255, 0, 255, 255, 255, 0, 0xaa, 0xbb, 0xcc,
                             0, 0, 255, 0, 255, 0, 255, 0, 0, 0xdd, 0xee, 0xff]),
            maskRows: Data(count: 8))
        let presenter = RemoteCursorPresenter()
        presenter.consume(.selection(hash: 1))
        presenter.consume(.shape(hash: 1, cursor: try cursorFixture(resource: dib, width: 3, height: 2)))
        #expect(!presenter.snapshot.isFallback)
        let pixels = try imageBytes(presenter.snapshot.image)
        #expect(pixels == Data([0, 255, 255, 255, 255, 0, 255, 255, 255, 255, 0, 255,
                               0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255]))
    }

    @Test func monochromeDIBUsesPaletteMSBFirstBitsAndBottomUpMasks() throws {
        let dib = dibFixture(width: 3, height: 2, bits: 1,
            colors: Data([0, 0, 0, 0, 255, 255, 255, 0]), colorsUsed: 2,
            pixelRows: Data([0x40, 0, 0, 0, 0xa0, 0, 0, 0]),
            maskRows: Data([0, 0, 0, 0, 0x40, 0, 0, 0]))
        let presenter = RemoteCursorPresenter()
        presenter.consume(.selection(hash: 1))
        presenter.consume(.shape(hash: 1, cursor: try cursorFixture(resource: dib, width: 3, height: 2)))
        #expect(!presenter.snapshot.isFallback)
        let pixels = try imageBytes(presenter.snapshot.image)
        #expect(pixels == Data([255, 255, 255, 255, 0, 0, 0, 0, 255, 255, 255, 255,
                               0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255]))
    }

    @Test func malformedDIBTablesMasksAndUnrepresentableInversionStayBoundedFallbacks() throws {
        let valid = dibFixture(width: 2, height: 1, bits: 32,
            pixelRows: Data([0, 0, 255, 255, 0, 255, 0, 255]), maskRows: Data(count: 4))
        let invalidPalette = dibFixture(width: 2, height: 1, bits: 8,
            colors: Data([0, 0, 0, 0]), colorsUsed: 1,
            pixelRows: Data([0, 1, 0, 0]), maskRows: Data(count: 4))
        let inversion = dibFixture(width: 2, height: 1, bits: 1,
            colors: Data([0, 0, 0, 0, 255, 255, 255, 0]), colorsUsed: 2,
            pixelRows: Data([0x80, 0, 0, 0]), maskRows: Data([0x80, 0, 0, 0]))
        for (index, dib) in [Data(valid.dropLast()), Data(valid.prefix(43)), invalidPalette, inversion].enumerated() {
            let presenter = RemoteCursorPresenter()
            let hash = Int32(index)
            presenter.consume(.selection(hash: hash))
            presenter.consume(.shape(hash: hash, cursor: try cursorFixture(resource: dib, width: 2, height: 1)))
            #expect(presenter.snapshot.isFallback)
            #expect(presenter.cacheByteCount == 0)
        }
    }

    @Test func pendingHashesAndResetAreBoundedAcrossSessions() throws {
        let presenter = RemoteCursorPresenter()
        for hash in 0..<100 { #expect(presenter.consume(.selection(hash: Int32(hash))) == Int32(hash)) }
        #expect(presenter.pendingRequestCount == 64)
        let cursor = try cursorFixture(resource: pngFixture(width: 2, height: 2), width: 2, height: 2)
        presenter.consume(.shape(hash: 99, cursor: cursor))
        presenter.consume(.position(x: 100, y: -100))
        presenter.reset()
        #expect(presenter.cacheEntryCount == 0 && presenter.cacheByteCount == 0)
        #expect(presenter.pendingRequestCount == 0 && presenter.selectedHash == nil)
        #expect(presenter.snapshot.isFallback && presenter.snapshot.position == nil)
        #expect(presenter.consume(.selection(hash: 99)) == 99)
    }

    private func cursorFixture(resource: Data, width: Int, height: Int,
                               hotSpotX: UInt16 = 0, hotSpotY: UInt16 = 0) throws -> CursorFile {
        var data = Data([0, 0, 2, 0, 1, 0, UInt8(truncatingIfNeeded: width), UInt8(truncatingIfNeeded: height), 0, 0,
                         UInt8(truncatingIfNeeded: hotSpotX), UInt8(hotSpotX >> 8),
                         UInt8(truncatingIfNeeded: hotSpotY), UInt8(hotSpotY >> 8)])
        appendLong(UInt32(resource.count), to: &data)
        appendLong(22, to: &data)
        data.append(resource)
        return try CursorFile.decode(data)
    }

    private func pngFixture(width: Int, height: Int) throws -> Data {
        let rgba = Data(repeating: 255, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: rgba as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func appendLong(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func imageBytes(_ image: CGImage) throws -> Data {
        let provider = try #require(image.dataProvider)
        let bytes = try #require(provider.data)
        return bytes as Data
    }

    private func dibFixture(width: Int, height: Int, bits: UInt16, topDown: Bool = false,
                            colors: Data = Data(), colorsUsed: UInt32 = 0,
                            pixelRows: Data, maskRows: Data) -> Data {
        var dib = Data()
        appendLong(40, to: &dib)
        appendLong(UInt32(width), to: &dib)
        appendLong(UInt32(bitPattern: Int32((topDown ? -2 : 2) * height)), to: &dib)
        dib.append(contentsOf: [1, 0, UInt8(truncatingIfNeeded: bits), UInt8(bits >> 8)])
        for value in [UInt32(0), UInt32(pixelRows.count), 0, 0, colorsUsed, 0] { appendLong(value, to: &dib) }
        dib.append(colors); dib.append(pixelRows); dib.append(maskRows)
        return dib
    }
}
