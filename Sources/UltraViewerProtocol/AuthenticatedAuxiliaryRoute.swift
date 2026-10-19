/// Auxiliary traffic may arrive on the peer's retained relay route after its
/// screen stream has moved to LAN. The Windows client selects Send or P2PSend
/// from its current socket state for chat and file traffic independently.
///
/// This is only a route gate. Callers must still validate the complete message
/// with its command-specific codec, enforce per-feature consent, and bind the
/// relay address and port to the authenticated peer. Screen initialization,
/// display updates, input permissions, and input acknowledgments stay on the
/// selected screen transport.
public enum AuthenticatedAuxiliaryRoute {
    public static func permitsRelay(command: UInt8, isActive: Bool, isKnownSource: Bool) -> Bool {
        guard isActive, isKnownSource else { return false }
        switch command {
        case 5, 33,             // Clipboard text.
             12, 29, 30,      // Chat message and typing state.
             13, 14, 15, 16, 21: // File transfer commands.
            return true
        default:
            return false
        }
    }
}
