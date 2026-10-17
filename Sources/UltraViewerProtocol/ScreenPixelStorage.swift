import Accelerate
import Foundation

/// Internal pixel kernels. Callers validate complete source/destination regions
/// before passing pointers; strides may be negative for bottom-up converter rows.
enum ScreenPixelStorage {
    private static let rgb555ToBGRA: [UInt32] = (0..<32_768).map { value in
        let blue = UInt32((value & 31) << 3 | (value & 31) >> 2)
        let green5 = (value >> 5) & 31
        let red5 = (value >> 10) & 31
        let green = UInt32(green5 << 3 | green5 >> 2)
        let red = UInt32(red5 << 3 | red5 >> 2)
        return blue | green << 8 | red << 16 | 0xff00_0000
    }

    static func expandRGB555(source: UnsafeRawPointer, sourceRowBytes: Int,
                             destination: UnsafeMutableRawPointer, destinationRowBytes: Int,
                             width: Int, height: Int) {
        rgb555ToBGRA.withUnsafeBufferPointer { table in
            for row in 0..<height {
                let input = source.advanced(by: row * sourceRowBytes)
                let output = destination.advanced(by: row * destinationRowBytes)
                for x in 0..<width {
                    let value = UInt16(littleEndian: input.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self))
                    output.storeBytes(of: table[Int(value & 0x7fff)].littleEndian,
                                      toByteOffset: x * 4, as: UInt32.self)
                }
            }
        }
    }

    static func packRGB555(source: UnsafeRawPointer, sourceRowBytes: Int,
                           destination: UnsafeMutableRawPointer, destinationRowBytes: Int,
                           width: Int, height: Int) {
        for row in 0..<height {
            let input = source.advanced(by: row * sourceRowBytes).assumingMemoryBound(to: UInt8.self)
            let output = destination.advanced(by: row * destinationRowBytes)
            for x in 0..<width {
                let pixel = input.advanced(by: x * 4)
                let value = UInt16(pixel[0] >> 3)
                    | UInt16(pixel[1] >> 3) << 5 | UInt16(pixel[2] >> 3) << 10
                output.storeBytes(of: value.littleEndian, toByteOffset: x * 2, as: UInt16.self)
            }
        }
    }

    static func opaqueBlack(width: Int, height: Int) -> Data {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { storage in
            var buffer = vImage_Buffer(data: storage.baseAddress!, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
            let color: [UInt8] = [0, 0, 0, 255]
            _ = vImageBufferFill_ARGB8888(&buffer, color, vImage_Flags(kvImageNoFlags))
        }
        return pixels
    }

    /// Compatibility/export view only. Display uses the original BGRA storage.
    static func bgr24(fromBGRA pixels: Data, width: Int, height: Int) -> Data {
        var result = Data(count: width * height * 3)
        pixels.withUnsafeBytes { source in
            result.withUnsafeMutableBytes { target in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!),
                    height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var output = vImage_Buffer(data: target.baseAddress!, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 3)
                // This same SDK function is aliased as BGRA8888toBGR888: it
                // drops the last physical byte without changing the other three.
                _ = vImageConvert_RGBA8888toRGB888(&input, &output, vImage_Flags(kvImageNoFlags))
            }
        }
        return result
    }

    static func bgra32(fromBGR pixels: Data, width: Int, height: Int) -> Data {
        var result = Data(count: width * height * 4)
        pixels.withUnsafeBytes { source in
            result.withUnsafeMutableBytes { target in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!),
                    height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 3)
                var output = vImage_Buffer(data: target.baseAddress!, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 4)
                _ = vImageConvert_RGB888toRGBA8888(&input, nil, 255, &output, false,
                                                   vImage_Flags(kvImageNoFlags))
            }
        }
        return result
    }
}
