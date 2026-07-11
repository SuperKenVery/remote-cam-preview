import Foundation
import XCTest

enum TestSupport {
    static func vector(named name: String) throws -> [String: Any] {
        let bundle = Bundle(for: BundleSentinel.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("Missing shared vector resource \(name).json")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    static func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw HexError.invalid }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< end], radix: 16) else { throw HexError.invalid }
            result.append(byte)
            index = end
        }
        return result
    }

    enum HexError: Error { case invalid }
}

private final class BundleSentinel {}

