import Foundation
import Network

func connectionErrorText(_ error: any Error) -> String {
    guard let network = error as? NWError else { return error.localizedDescription }
    switch network {
    case .dns: return "The UltraViewer relay could not be found. Check your internet connection and try again."
    case .tls: return "A secure connection to the UltraViewer relay could not be verified. Try again."
    case .posix: return "The network connection to UltraViewer ended. Check the connection and try again."
    default: return "The UltraViewer network connection could not be completed. Try again."
    }
}
