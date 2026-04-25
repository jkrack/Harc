import Foundation

enum HardwareInfo {
    static let appleSiliconDisplayName: String = {
        if let brand = sysctlString("machdep.cpu.brand_string"),
           let name = parseAppleSiliconName(from: brand) {
            return name
        }
        return "Apple Silicon"
    }()

    private static func parseAppleSiliconName(from brand: String) -> String? {
        let pattern = #"Apple\s+(M\d(?:\s+(?:Pro|Max|Ultra))?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: brand,
                range: NSRange(brand.startIndex..<brand.endIndex, in: brand)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: brand) else {
            return nil
        }
        return String(brand[range])
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
