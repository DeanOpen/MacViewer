import CoreGraphics
import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func screenPixelExpansionMatchesEveryRGB555WordAndUnusedBit() {
    let count = 65_536
    var input = Data([0xa5])
    var expected = Data()
    var expectedPacked = Data([0xa5])
    for value in 0..<count {
        input.append(UInt8(truncatingIfNeeded: value))
        input.append(UInt8(value >> 8))
        expectedPacked.append(UInt8(truncatingIfNeeded: value))
        expectedPacked.append(UInt8((value >> 8) & 0x7f))
        for shift in [0, 5, 10] {
            let five = (value >> shift) & 31
            expected.append(UInt8((five << 3) | (five >> 2)))
        }
        expected.append(255)
    }
    input.append(0xa5)
    expectedPacked.append(0xa5)
    // Deliberately unaligned regions also verify that the kernels do not assume
    // alignment from a Data slice, nor overwrite its surrounding sentinel bytes.
    var output = Data(repeating: 0xa5, count: 3 + count * 4 + 5)
    input.withUnsafeBytes { source in
        output.withUnsafeMutableBytes { target in
            ScreenPixelStorage.expandRGB555(source: source.baseAddress!.advanced(by: 1), sourceRowBytes: 512,
                destination: target.baseAddress!.advanced(by: 3), destinationRowBytes: 1024,
                width: 256, height: 256)
        }
    }
    #expect(output == Data(repeating: 0xa5, count: 3) + expected + Data(repeating: 0xa5, count: 5))
    var packed = Data(repeating: 0xa5, count: input.count)
    output.withUnsafeBytes { source in
        packed.withUnsafeMutableBytes { target in
            ScreenPixelStorage.packRGB555(source: source.baseAddress!.advanced(by: 3), sourceRowBytes: 1024,
                destination: target.baseAddress!.advanced(by: 1), destinationRowBytes: 512,
                width: 256, height: 256)
        }
    }
    #expect(packed == expectedPacked)
}

@Test func screenPixelKernelsPreserveOddWidthPaddingAndReversedRows() {
    // Converter physical rows are bottom-up, three pixels plus DWORD padding.
    let bottom = Data([0xff, 0x7f, 0, 0, 0x10, 0x42])
    let top = Data([0, 0x7c, 0xe0, 3, 0x1f, 0])
    let padding = Data([0xa5, 0xa5])
    let input = Data([0xa5]) + bottom + padding + top + padding
    var output = Data(repeating: 0xa5, count: 3 + 32 + 5)
    input.withUnsafeBytes { source in
        output.withUnsafeMutableBytes { target in
            ScreenPixelStorage.expandRGB555(source: source.baseAddress!.advanced(by: 9), sourceRowBytes: -8,
                destination: target.baseAddress!.advanced(by: 3), destinationRowBytes: 16,
                width: 3, height: 2)
        }
    }
    let expectedTop = Data([0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255])
    let expectedBottom = Data([255, 255, 255, 255, 0, 0, 0, 255, 132, 132, 132, 255])
    let expected = Data(repeating: 0xa5, count: 3) + expectedTop + Data(repeating: 0xa5, count: 4)
        + expectedBottom + Data(repeating: 0xa5, count: 9)
    #expect(output == expected)
    var packed = Data(repeating: 0xa5, count: input.count)
    output.withUnsafeBytes { source in
        packed.withUnsafeMutableBytes { target in
            ScreenPixelStorage.packRGB555(source: source.baseAddress!.advanced(by: 3), sourceRowBytes: 16,
                destination: target.baseAddress!.advanced(by: 9), destinationRowBytes: -8,
                width: 3, height: 2)
        }
    }
    #expect(packed == input)
}

@Test func screenBitmapNativeStoragePreservesBGRViewAndCGImageChannels() throws {
    let bgr = Data([1, 2, 3, 255, 0, 0, 0, 255, 0,
                    0, 0, 255, 33, 66, 99, 255, 255, 255])
    let bgra = ScreenPixelStorage.bgra32(fromBGR: bgr, width: 3, height: 2)
    let bitmap = ModernScreenBitmap(width: 3, height: 2, bgraPixels: bgra)
    #expect(bitmap.bgrPixels == bgr)
    #expect(bitmap == ModernScreenBitmap(width: 3, height: 2, bgrPixels: bgr))
    let image = try #require(bitmap.makeCGImage())
    #expect(image.width == 3 && image.height == 2 && image.bytesPerRow == 12)
    #expect(image.bitmapInfo.contains(.byteOrder32Little))
    let providerBytes = try #require(image.dataProvider?.data)
    #expect((providerBytes as Data) == bgra)
    // Independent old RGBA image layout verifies CoreGraphics interpretation,
    // rather than relying only on the compatibility conversion's channel order.
    var rgba = Data()
    for index in stride(from: 0, to: bgr.count, by: 3) {
        rgba.append(contentsOf: [bgr[index + 2], bgr[index + 1], bgr[index], 255])
    }
    let oldProvider = try #require(CGDataProvider(data: rgba as CFData))
    let oldImage = try #require(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: oldProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    #expect(renderRGBA(image) == renderRGBA(oldImage))
}

@Test func screenBitmapAndCGImageSnapshotsSurviveLaterRendererWrites() throws {
    let renderer = try ModernScreenRenderer(width: 2, height: 1, displayColors: 2, lastFrameNumber: 0)
    let initial = renderer.bitmap
    #expect(initial.bgrPixels == Data(count: 6))
    let firstMessage = try pixelTestMessage(sequence: 1, rectangles: [0, 0, 2, 1],
                                           pixels: [0x7c00, 0x03e0])
    let first = try renderer.apply(firstMessage)
    let image = try #require(first.makeCGImage())
    let second = try renderer.apply(pixelTestMessage(sequence: 2, rectangles: [0, 0, 2, 1],
                                                     pixels: [0x001f, 0x7fff]))
    #expect(first.bgrPixels == Data([0, 0, 255, 0, 255, 0]))
    #expect(initial.bgrPixels == Data(count: 6))
    #expect(second.bgrPixels == Data([255, 0, 0, 255, 255, 255]))
    let providerBytes = try #require(image.dataProvider?.data)
    #expect((providerBytes as Data) == Data([0, 0, 255, 255, 0, 255, 0, 255]))
}

@Test func screenRawRectangleSlicesPreserveOffsetsAndConverterStaging() throws {
    let renderer = try ModernScreenRenderer(width: 3, height: 2, displayColors: 2, lastFrameNumber: 0)
    let message = try pixelTestMessage(sequence: 1,
        rectangles: [0, 0, 2, 1, 2, 0, 1, 2], pixels: [0x7c00, 0x7c00, 0x03e0, 0x03e0])
    let bitmap = try renderer.apply(message)
    #expect(bitmap.bgrPixels == Data([0, 0, 255, 0, 0, 255, 0, 255, 0,
                                     0, 0, 0, 0, 0, 0, 0, 255, 0]))
}

private func renderRGBA(_ image: CGImage) -> Data {
    var result = Data(count: image.width * image.height * 4)
    result.withUnsafeMutableBytes { target in
        let context = CGContext(data: target.baseAddress!, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return result
}

private func pixelTestMessage(sequence: Int32, rectangles: [UInt16], pixels: [UInt16]) throws -> ModernScreenFrameMessage {
    func words(_ values: [UInt16]) -> Data {
        values.reduce(into: Data()) { bytes, value in
            bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(value >> 8))
        }
    }
    let raw = words(pixels)
    var zstd = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
    zstd.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: raw.count >> ($0 * 8)) })
    let block = (raw.count << 3) | 1
    zstd.append(contentsOf: (0..<3).map { UInt8(truncatingIfNeeded: block >> ($0 * 8)) })
    zstd.append(raw)
    let sequenceBytes = Data((0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: sequence) >> ($0 * 8)) })
    return try ModernScreenFrameMessage.decode(parts: [Data([1]), words(rectangles), zstd, Data(),
        sequenceBytes, Data(), Data(), Data(), Data(), Data(), Data()])
}
