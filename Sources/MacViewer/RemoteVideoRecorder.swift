import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// CGImage's pixels are immutable; this wrapper transfers a retained snapshot
/// to the encoder actor without sharing mutable AppKit drawing objects.
struct RemoteRecordingImage: @unchecked Sendable {
    let image: CGImage
}

actor RemoteVideoRecorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: CGSize
    private let temporaryURL: URL
    private var lastImage: RemoteRecordingImage?
    private var lastTime = CMTime.invalid
    private var frameCount = 0
    private var isFinished = false

    init(imageWidth: Int, imageHeight: Int) throws {
        guard imageWidth > 0, imageHeight > 0, imageWidth <= 8192, imageHeight <= 8192 else {
            throw VideoError.invalidDimensions
        }
        let scale = min(1, 1920.0 / Double(imageWidth), 1080.0 / Double(imageHeight))
        let width = max(2, Int(Double(imageWidth) * scale) / 2 * 2)
        let height = max(2, Int(Double(imageHeight) * scale) / 2 * 2)
        size = CGSize(width: width, height: height)
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacViewer-\(UUID().uuidString).mov")
        writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(6_000_000, max(500_000, width * height * 3)),
                AVVideoExpectedSourceFrameRateKey: 15,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw VideoError.encoderUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw VideoError.encoding(writer.error?.localizedDescription) }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ snapshot: RemoteRecordingImage, at elapsed: TimeInterval) async throws {
        guard !isFinished else { return }
        guard writer.status == .writing else { throw VideoError.encoding(writer.error?.localizedDescription) }
        // Preserve a first frame even for a static desktop. Later busy frames
        // are dropped, so encoding cannot create an unbounded frame backlog.
        if frameCount == 0 {
            for _ in 0..<100 where !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
                guard writer.status == .writing else { throw VideoError.encoding(writer.error?.localizedDescription) }
            }
        }
        guard input.isReadyForMoreMediaData else { return }
        let requested = CMTime(seconds: max(0, elapsed), preferredTimescale: 600)
        let time = lastTime.isValid && requested <= lastTime
            ? CMTimeAdd(lastTime, CMTime(value: 1, timescale: 600)) : requested
        try appendReady(snapshot, at: time)
    }

    func finish(at elapsed: TimeInterval) async throws -> URL {
        guard !isFinished else { throw VideoError.alreadyFinished }
        guard writer.status == .writing else {
            let reason = writer.error?.localizedDescription
            cancel()
            throw VideoError.encoding(reason)
        }
        guard frameCount > 0 else { cancel(); throw VideoError.noFrames }
        do {
            if let lastImage {
                // Hold the final received screen until the user presses Stop,
                // including when the remote desktop has not changed for a while.
                let time = CMTime(seconds: max(0, elapsed), preferredTimescale: 600)
                for _ in 0..<100 where !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(10))
                }
                if input.isReadyForMoreMediaData, time > lastTime { try appendReady(lastImage, at: time) }
            }
        } catch { cancel(); throw error }
        guard writer.status == .writing else {
            let reason = writer.error?.localizedDescription
            cancel()
            throw VideoError.encoding(reason)
        }
        isFinished = true
        writer.endSession(atSourceTime: CMTime(seconds: max(0.05, elapsed), preferredTimescale: 600))
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw VideoError.encoding(writer.error?.localizedDescription)
        }
        return temporaryURL
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    private func appendReady(_ snapshot: RemoteRecordingImage, at time: CMTime) throws {
        guard let pool = adaptor.pixelBufferPool else { throw VideoError.encoderUnavailable }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw VideoError.cannotAllocateFrame }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: address, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                        | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw VideoError.cannotAllocateFrame
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = snapshot.image
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let fitted = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                                      width: fitted.width, height: fitted.height))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw VideoError.encoding(writer.error?.localizedDescription)
        }
        lastTime = time; lastImage = snapshot; frameCount += 1
    }

    private enum VideoError: LocalizedError {
        case invalidDimensions, encoderUnavailable, cannotAllocateFrame, alreadyFinished, noFrames
        case encoding(String?)
        var errorDescription: String? {
            switch self {
            case .invalidDimensions: "This remote image has unsupported recording dimensions."
            case .encoderUnavailable: "The H.264 video encoder is unavailable."
            case .cannotAllocateFrame: "A video frame could not be allocated."
            case .alreadyFinished: "This recording has already finished."
            case .noFrames: "No remote frames were available to record."
            case let .encoding(reason): reason ?? "The remote video could not be encoded."
            }
        }
    }
}
