import CryptoKit
import Foundation

/// The supplied desktop loads this trained Zstandard dictionary at startup.
/// It is data, not Windows executable code. Native Zstandard consumes its bytes.
public enum UltraViewerScreenDictionary {
    public enum Error: Swift.Error { case missingResource, unexpectedResource }

    public static func load() throws -> Data {
        let url: URL?
        if Bundle.main.bundleURL.pathExtension == "app" {
            url = Bundle.main.url(forResource: "8bit", withExtension: "dat")
        } else {
            url = Bundle.module.url(forResource: "8bit", withExtension: "dat")
        }
        guard let url else { throw Error.missingResource }
        let data = try Data(contentsOf: url)
        guard data.count == 112_640,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() ==
              "9aa45789d9ff9d329a623a685d57b67e33c777019de9ce1f273f21860e4bfe6b" else {
            throw Error.unexpectedResource
        }
        return data
    }
}
