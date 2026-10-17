import CoreGraphics
import Foundation
import Testing
@testable import UltraViewerProtocol

/// Opt-in release benchmark; disabled during ordinary correctness tests.
/// MACVIEWER_PIXEL_BENCHMARK=1 swift test -c release --filter rendererPixelPipelineReleaseBenchmark
/// No captured screen content, target execution or network access is involved.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACVIEWER_PIXEL_BENCHMARK"] == "1"))
func rendererPixelPipelineReleaseBenchmark() throws {
    let width = 1024, height = 1024, iterations = 50
    var source = Data(count: width * height * 2)
    source.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for index in 0..<(width * height) {
            let value = UInt16(truncatingIfNeeded: index * 73 ^ (index >> 5))
            bytes[index * 2] = UInt8(truncatingIfNeeded: value)
            bytes[index * 2 + 1] = UInt8(value >> 8)
        }
    }
    // Initialize the lookup table and both graphics paths before timing.
    _ = try #require(oldPixelPipelineImage(source, width: width, height: height))
    _ = try #require(nativePixelPipelineImage(source, width: width, height: height))
    let clock = ContinuousClock()
    var checksum = 0
    let baselineStart = clock.now
    for _ in 0..<iterations {
        let image = try #require(oldPixelPipelineImage(source, width: width, height: height))
        checksum &+= image.bytesPerRow
    }
    let baselineTime = baselineStart.duration(to: clock.now)
    let optimizedStart = clock.now
    for _ in 0..<iterations {
        let image = try #require(nativePixelPipelineImage(source, width: width, height: height))
        checksum &+= image.bytesPerRow
    }
    let optimizedTime = optimizedStart.duration(to: clock.now)
    func milliseconds(_ time: Duration) -> Double {
        Double(time.components.seconds) * 1000 + Double(time.components.attoseconds) / 1e15
    }
    let old = milliseconds(baselineTime) / Double(iterations)
    let new = milliseconds(optimizedTime) / Double(iterations)
    let report: [String: Any] = ["benchmark": "RGB555 expansion plus CGImage creation",
        "pixels": width * height, "iterations": iterations,
        "oldMillisecondsPerIteration": old, "nativeMillisecondsPerIteration": new,
        "speedup": old / new, "checksum": checksum,
        "excludes": "network, Zstd, converter staging, cache and JPEG decode"]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    #expect(checksum == iterations * width * 4 * 2)
}

/// Exact former copyTemporaryToMain RGB555 expansion and makeCGImage loops.
@inline(never)
private func oldPixelPipelineImage(_ source: Data, width: Int, height: Int) -> CGImage? {
    var bgr = Data(count: width * height * 3)
    source.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
        bgr.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let index = ((height - 1 - y) * width + x) * 2
                    let value = UInt16(input[index]) | UInt16(input[index + 1]) << 8
                    let destination = (y * width + x) * 3
                    for channel in 0..<3 {
                        let five = UInt8((value >> (channel * 5)) & 31)
                        output[destination + channel] = (five << 3) | (five >> 2)
                    }
                }
            }
        }
    }
    var rgba = Data(count: width * height * 4)
    bgr.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
        rgba.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            for pixel in 0..<(width * height) {
                output[pixel * 4] = input[pixel * 3 + 2]
                output[pixel * 4 + 1] = input[pixel * 3 + 1]
                output[pixel * 4 + 2] = input[pixel * 3]
                output[pixel * 4 + 3] = 255
            }
        }
    }
    guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

@inline(never)
private func nativePixelPipelineImage(_ source: Data, width: Int, height: Int) -> CGImage? {
    var bgra = Data(count: width * height * 4)
    source.withUnsafeBytes { input in
        bgra.withUnsafeMutableBytes { output in
            ScreenPixelStorage.expandRGB555(
                source: input.baseAddress!.advanced(by: (height - 1) * width * 2), sourceRowBytes: -width * 2,
                destination: output.baseAddress!, destinationRowBytes: width * 4, width: width, height: height)
        }
    }
    return ModernScreenBitmap(width: width, height: height, bgraPixels: bgra).makeCGImage()
}
