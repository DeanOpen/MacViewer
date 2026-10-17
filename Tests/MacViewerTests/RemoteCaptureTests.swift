import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import MacViewer

@MainActor
struct RemoteCaptureTests {
    @Test("Region capture normalizes a reverse drag and exports only selected pixels")
    func selectedRegion() throws {
        let model = RemoteCaptureEditorModel(image: try stripedImage(width: 128, height: 64), selectRegion: true)
        #expect(!model.canExport)
        model.begin(at: CGPoint(x: 128, y: 32))
        model.drag(to: .zero)
        model.end()
        let image = try #require(model.export())
        #expect(image.width == 128)
        #expect(image.height == 32)
        let pixel = try rgba(image, x: 64, y: 16)
        #expect(pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0)
    }

    @Test("Export keeps annotation coordinates at the top of the image and undo restores pixels")
    func annotationCoordinates() throws {
        let model = RemoteCaptureEditorModel(image: try stripedImage(width: 128, height: 64), selectRegion: false)
        model.ink = .yellow
        model.begin(at: CGPoint(x: 16, y: 8))
        model.drag(to: CGPoint(x: 112, y: 8))
        model.end()
        let annotated = try #require(model.export())
        let top = try rgba(annotated, x: 64, y: 8)
        let bottom = try rgba(annotated, x: 64, y: 56)
        #expect(top[0] > 180 && top[1] > 150 && top[2] < 100)
        #expect(bottom[0] == 0 && bottom[1] == 0 && bottom[2] == 255)
        model.undo()
        let restored = try #require(model.export())
        let original = try rgba(restored, x: 64, y: 8)
        #expect(original[0] == 255 && original[1] == 0 && original[2] == 0)
    }

    @Test("Video round trip preserves orientation, contains no audio, and holds a static frame until Stop")
    func videoRoundTrip() async throws {
        let recorder = try RemoteVideoRecorder(imageWidth: 128, imageHeight: 64)
        try await recorder.append(RemoteRecordingImage(image: try stripedImage(width: 128, height: 64)), at: 0)
        let url = try await recorder.finish(at: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) >= 0.95)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try generator.copyCGImage(at: .zero, actualTime: nil)
        #expect(image.width == 128 && image.height == 64)
        let top = try rgba(image, x: 64, y: 8)
        let bottom = try rgba(image, x: 64, y: 56)
        #expect(top[0] > 160 && top[2] < 80)
        #expect(bottom[2] > 160 && bottom[0] < 80)
    }

    private func stripedImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset + (y < height / 2 ? 0 : 2)] = 255
                bytes[offset + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                           bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let address = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: address + offset, count: 4))
    }
}
