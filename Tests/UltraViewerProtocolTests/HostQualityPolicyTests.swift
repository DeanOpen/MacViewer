import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func hostQualityPolicyTreatsMissingCommandAsDistinctLegacyState() {
    let legacy = HostQualityPolicy.legacy
    #expect(legacy.preset == .unspecified)
    #expect(legacy.quality == nil)
    #expect(HostQualityPolicy(quality: nil) == legacy)
    #expect(legacy != HostQualityPolicy(quality: 45))
    // Exactly the pre-quality defaults while no viewer preset is known.
    #expect(legacy.changedFrameDelay == HostQualityPolicy.minimumChangedFrameDelay)
    #expect(legacy.changedFrameDelay == 0.04)
    #expect(legacy.unchangedFrameDelay == 0.25)
    #expect(legacy.fullFrameThreshold == 0.5)
}

@Test func hostQualityPolicyMapsPresetBoundaries() {
    #expect(HostQualityPolicy(quality: nil).preset == .unspecified)
    #expect(HostQualityPolicy(quality: 0).preset == .speed)
    #expect(HostQualityPolicy(quality: 30).preset == .speed)
    #expect(HostQualityPolicy(quality: 31).preset == .automatic)
    #expect(HostQualityPolicy(quality: 55).preset == .automatic)
    #expect(HostQualityPolicy(quality: 56).preset == .quality)
    #expect(HostQualityPolicy(quality: 100).preset == .quality)
    // Out-of-range viewer values are clamped.
    #expect(HostQualityPolicy(quality: -5).quality == 0)
    #expect(HostQualityPolicy(quality: 500).quality == 100)
}

@Test func hostQualityPolicyPacingIsOrderedAndNeverFasterThanTheFloor() {
    let unspecified = HostQualityPolicy.legacy
    let speed = HostQualityPolicy(quality: 20)
    let automatic = HostQualityPolicy(quality: 45)
    let quality = HostQualityPolicy(quality: 80)
    // Only the speed preset deliberately slows down; the other presets keep the
    // pre-quality responsiveness and only differ in full-frame threshold.
    #expect(speed.changedFrameDelay > unspecified.changedFrameDelay)
    #expect(automatic.changedFrameDelay == unspecified.changedFrameDelay)
    #expect(quality.changedFrameDelay == unspecified.changedFrameDelay)
    #expect(unspecified.changedFrameDelay == HostQualityPolicy.minimumChangedFrameDelay)
    #expect(quality.changedFrameDelay >= HostQualityPolicy.minimumChangedFrameDelay)
    #expect(speed.unchangedFrameDelay > unspecified.unchangedFrameDelay)
    #expect(automatic.unchangedFrameDelay == unspecified.unchangedFrameDelay)
    #expect(quality.unchangedFrameDelay == unspecified.unchangedFrameDelay)
    for policy in [unspecified, speed, automatic, quality] {
        #expect(policy.unchangedFrameDelay >= policy.changedFrameDelay)
    }
    // Exact agreed values.
    #expect(abs(unspecified.changedFrameDelay - 0.04) < 0.000_1)
    #expect(abs(unspecified.unchangedFrameDelay - 0.25) < 0.000_1)
    #expect(abs(speed.changedFrameDelay - 0.2) < 0.000_1)
    #expect(abs(speed.unchangedFrameDelay - 1.0) < 0.000_1)
    #expect(abs(automatic.changedFrameDelay - 0.04) < 0.000_1)
    #expect(abs(automatic.unchangedFrameDelay - 0.25) < 0.000_1)
    #expect(abs(quality.changedFrameDelay - 0.04) < 0.000_1)
    #expect(abs(quality.unchangedFrameDelay - 0.25) < 0.000_1)
    #expect(HostQualityPolicy.minimumChangedFrameDelay == 0.04)
}

@Test func hostQualityPolicyFullFrameThresholdPrefersFullEarlierAtSpeed() {
    let unspecified = HostQualityPolicy.legacy
    let speed = HostQualityPolicy(quality: 20)
    let automatic = HostQualityPolicy(quality: 45)
    let quality = HostQualityPolicy(quality: 80)
    #expect(speed.fullFrameThreshold < unspecified.fullFrameThreshold)
    #expect(unspecified.fullFrameThreshold == automatic.fullFrameThreshold)
    #expect(automatic.fullFrameThreshold < quality.fullFrameThreshold)
    #expect((0...1).contains(speed.fullFrameThreshold))
    #expect((0...1).contains(unspecified.fullFrameThreshold))
    #expect((0...1).contains(automatic.fullFrameThreshold))
    #expect((0...1).contains(quality.fullFrameThreshold))
}

@Test func hostQualityPolicyParsesOnlyTheQualityCommand() {
    #expect(HostQualityPolicy.parse(Data("31|||45".utf8)) == 45)
    #expect(HostQualityPolicy.parse(Data("31|||0".utf8)) == 0)
    #expect(HostQualityPolicy.parse(Data("31|||100".utf8)) == 100)
    // Out-of-range values clamp; malformed commands are ignored (nil).
    #expect(HostQualityPolicy.parse(Data("31|||200".utf8)) == 100)
    #expect(HostQualityPolicy.parse(Data("31|||".utf8)) == nil)
    #expect(HostQualityPolicy.parse(Data("31|||-5".utf8)) == nil)
    #expect(HostQualityPolicy.parse(Data("31|||4x".utf8)) == nil)
    #expect(HostQualityPolicy.parse(Data("31|||12345".utf8)) == nil)
    #expect(HostQualityPolicy.parse(Data("32|||2".utf8)) == nil)
    #expect(HostQualityPolicy.parse(Data("8|||512|||1|||1".utf8)) == nil)
}
