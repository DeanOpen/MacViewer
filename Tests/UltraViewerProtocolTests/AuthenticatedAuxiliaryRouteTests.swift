import Testing
@testable import UltraViewerProtocol

@Test func retainedRelayAcceptsOnlyAuthenticatedAuxiliaryCommands() {
    let auxiliary: Set<UInt8> = [5, 33, 12, 29, 30, 13, 14, 15, 16, 21]
    for command in UInt8.min...UInt8.max {
        #expect(AuthenticatedAuxiliaryRoute.permitsRelay(command: command, isActive: true,
            isKnownSource: true) == auxiliary.contains(command))
        #expect(!AuthenticatedAuxiliaryRoute.permitsRelay(command: command, isActive: false,
            isKnownSource: true))
        #expect(!AuthenticatedAuxiliaryRoute.permitsRelay(command: command, isActive: true,
            isKnownSource: false))
    }
}

@Test func retainedRelayCannotChangeSelectedScreenState() {
    // Init/frame, cursor, input ACK, rejection, direct acceptance, permissions,
    // screen settings and side switch are not auxiliary traffic.
    for command in [UInt8(0), 1, 3, 4, 8, 18, 22, 26, 27, 28, 32, 39, 41, 48, 49, 54] {
        #expect(!AuthenticatedAuxiliaryRoute.permitsRelay(command: command, isActive: true,
            isKnownSource: true))
    }
}
