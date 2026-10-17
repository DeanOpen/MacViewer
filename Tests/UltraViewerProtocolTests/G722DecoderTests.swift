import Foundation
import Testing
@testable import UltraViewerProtocol

struct G722DecoderTests {
    @Test("NAudio compatibility wraps overflowing final QMF output rather than saturating it")
    func naudioOutputWrap() throws {
        // Original Windows fixture: encoded byte38 produces raw QMF37090 at
        // sample76. NAudio wraps to -28446; WebRTC's ordinary output is32767.
        let pcm = try G722Decoder().decode(Data((0...38).map(UInt8.init)))
        let bits = UInt16(pcm[152]) | UInt16(pcm[153]) << 8
        #expect(Int16(bitPattern: bits) == -28446)
    }

    @Test("Native G722 PCM matches the original Windows NAudio decoder one-shot and across arbitrary packet splits")
    func windowsCodecFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/g722-windows.json")
        let envelope = try JSONDecoder().decode(WindowsAudioFixtureEnvelope.self, from: Data(contentsOf: url))
        #expect(!envelope.fixtures.isEmpty)
        for fixture in envelope.fixtures {
            let encoded = try #require(Data(base64Encoded: fixture.encodedBase64))
            let expected = try #require(Data(base64Encoded: fixture.pcmBase64))
            #expect(try G722Decoder().decode(encoded) == expected)
            let streaming = try G722Decoder()
            var combined = Data()
            for chunk in fixture.splitChunks {
                let input = encoded.subdata(in: chunk.encodedOffset..<(chunk.encodedOffset + chunk.encodedLength))
                let actual = try streaming.decode(input)
                #expect(actual == Data(base64Encoded: chunk.pcmBase64))
                combined.append(actual)
            }
            #expect(combined == expected)
        }
    }

    @Test("Decoder state spans packet boundaries and empty packets do not advance it")
    func streamState() throws {
        let first = Data((0..<256).map(UInt8.init))
        let second = Data(first.reversed())
        let streaming = try G722Decoder()
        let firstPCM = try streaming.decode(first)
        #expect(firstPCM.count == first.count * 4)
        #expect(try streaming.decode(Data()).isEmpty)
        let secondPCM = try streaming.decode(second)
        let complete = try G722Decoder().decode(first + second)
        #expect(firstPCM + secondPCM == complete)
        #expect(try G722Decoder().decode(second) != secondPCM)
    }

    @Test("Oversized packets reject before changing decoder state")
    func packetBound() throws {
        let decoder = try G722Decoder()
        #expect(throws: G722Decoder.Error.packetTooLarge) {
            try decoder.decode(Data(repeating: 0, count: G722Decoder.maximumEncodedPacketBytes + 1))
        }
        let packet = Data(repeating: 0x3C, count: 128)
        #expect(try decoder.decode(packet) == G722Decoder().decode(packet))
    }

    @Test("Audio multipart distinguishes raw G722 from a signed zero-PCM count")
    func audioMessages() throws {
        let encoded = Data([0, 0xFF, 0x80, 42, 43])
        #expect(try ComputerAudioMessage.decode(parts: [Data([43]), encoded]) == .encoded(encoded))
        #expect(try ComputerAudioMessage.decode(parts: [Data([42]), Data([0x00, 0x4B, 0, 0])])
                == .silence(pcmByteCount: 19_200))
        #expect(throws: ComputerAudioMessage.Error.invalidSilenceLength) {
            try ComputerAudioMessage.decode(parts: [Data([42]), Data(repeating: 0xFF, count: 4)])
        }
        #expect(throws: ComputerAudioMessage.Error.malformedMessage) {
            try ComputerAudioMessage.decode(parts: [Data([42]), Data([0, 0, 0])])
        }
        #expect(throws: ComputerAudioMessage.Error.unsupportedCommand) {
            try ComputerAudioMessage.decode(parts: [Data([41]), Data()])
        }
    }
}

private struct WindowsAudioFixtureEnvelope: Decodable {
    let fixtures: [WindowsAudioFixture]
    enum CodingKeys: String, CodingKey { case fixtures = "Fixtures" }
}

private struct WindowsAudioFixture: Decodable {
    let encodedBase64: String
    let pcmBase64: String
    let splitChunks: [Chunk]
    enum CodingKeys: String, CodingKey {
        case encodedBase64 = "EncodedBase64", pcmBase64 = "PCMBase64", splitChunks = "SplitChunks"
    }
    struct Chunk: Decodable {
        let encodedOffset: Int
        let encodedLength: Int
        let pcmBase64: String
        enum CodingKeys: String, CodingKey {
            case encodedOffset = "EncodedOffset", encodedLength = "EncodedLength", pcmBase64 = "PCMBase64"
        }
    }
}
