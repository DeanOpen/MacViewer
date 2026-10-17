import Foundation
import Testing
@testable import UltraViewerProtocol

private func syntheticLoginContext() -> PartnerLoginMessage.Context {
    .init(screenPixelWidth: 1920, screenPixelHeight: 1080, desktopMetric: 7,
          screenTwipsPerPixelXText: "15", screenTwipsPerPixelYText: "15",
          formVerticalInset: 30, formHorizontalInset: 16,
          localID: "111222333", displayName: "Mac: Viewer!", controlMode: 1,
          clearControlMode: false, localUserSID: "S-1-5-21-1-2-3-1001",
          connectionHashKey: "connection-key", displayColors: 32, displayQuality: 7,
          remoteWallpaperDisabled: -1, hasDesktopToken: true,
          partnerSecretToken: "peer-secret", clientVersion: "6.0.0", desktopCounter: 42)
}

@Test func partnerLoginMatchesIndependentSyntheticFixture() throws {
    let message = PartnerLoginMessage(credential: .password(value: "test-pass", nonce: "12345678"),
                                     context: syntheticLoginContext())
    // MD5 values generated independently with Python hashlib from ASCII bytes:
    // b"12345678test-pass" and b" " * 32 + b"test-pass".
    let expected = "login:12345678:c10f3394b41ec5b86060e0285e0dd306:" +
        "1920:1080:7:15:15:30:16:111222333:Mac Viewer:1:" +
        "85347ba7a403ffed52d311b7c5b6b549:S-1-5-21-1-2-3-1001:connection-key:32:7:-1:1:" +
        "peer-secret:6.0.0:42"
    #expect(try message.text() == expected)
    #expect(try message.encode() == Data(expected.utf8))
    #expect(expected.split(separator: ":", omittingEmptySubsequences: false).count == 23)
}

@Test func alternativeCredentialPreservesRecoveredBranchAndEmptyFields() throws {
    var context = syntheticLoginContext()
    context.clearControlMode = true
    context.hasDesktopToken = false
    context.partnerSecretToken = ""
    context.displayName = String(repeating: "x", count: 30)
    let message = PartnerLoginMessage(credential: .verbatim(value: "opaque-proof"), context: context)
    let fields = try message.text().split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    #expect(fields.count == 23)
    #expect(fields[1] == String(repeating: " ", count: 32))
    #expect(fields[2] == "opaque-proof")
    #expect(fields[11] == String(repeating: "x", count: 20))
    #expect(fields[12] == "0")
    #expect(fields[13] == "opaque-proof")
    #expect(fields[19] == "0")
    #expect(fields[20].isEmpty)
}

@Test func partnerLoginRejectsAmbiguousEncodingAndFieldInjection() throws {
    for nonce in ["", "1234567", "123456789", "12:45678", "１２３４５６７８"] {
        let message = PartnerLoginMessage(credential: .password(value: "test", nonce: nonce),
                                         context: syntheticLoginContext())
        #expect(throws: PartnerLoginMessage.Error.invalidNonce) { try message.encode() }
    }
    let nonASCII = PartnerLoginMessage(credential: .password(value: "café", nonce: "12345678"),
                                      context: syntheticLoginContext())
    #expect(throws: PartnerLoginMessage.Error.unsupportedEncoding) { try nonASCII.encode() }
    var context = syntheticLoginContext()
    context.localID = "id:extra-field"
    let injected = PartnerLoginMessage(credential: .password(value: "test", nonce: "12345678"), context: context)
    #expect(throws: PartnerLoginMessage.Error.invalidField) { try injected.encode() }
    let raw = PartnerLoginMessage(credential: .verbatim(value: "proof\nextra"), context: syntheticLoginContext())
    #expect(throws: PartnerLoginMessage.Error.invalidField) { try raw.encode() }
}
