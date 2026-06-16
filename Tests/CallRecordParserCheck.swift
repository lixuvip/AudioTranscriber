import Foundation

@main
struct CallRecordParserCheck {
    static func main() throws {
        let named = try require(
            CallRecordFilenameParser.parse(fileName: "章文@153 9711 1188_20240826172813.m4a"),
            "named call should parse"
        )
        assertEqual(named.contactName, "章文", "contact name")
        assertEqual(named.rawPhone, "153 9711 1188", "raw phone")
        assertEqual(named.normalizedPhone, "15397111188", "normalized phone")
        assertEqual(named.displayName, "章文", "display name")
        assertEqual(named.timestampText, "2024-08-26 17:28:13", "timestamp")
        assertEqual(named.directorySlug, "20240826_172813_章文_15397111188", "directory slug")

        let numberOnly = try require(
            CallRecordFilenameParser.parse(fileName: "131 0213 3750_20250813175323.wav"),
            "number-only call should parse"
        )
        assertEqual(numberOnly.contactName, nil, "missing contact")
        assertEqual(numberOnly.rawPhone, "131 0213 3750", "raw number-only phone")
        assertEqual(numberOnly.normalizedPhone, "13102133750", "normalized number-only phone")
        assertEqual(numberOnly.displayName, "131 0213 3750", "number-only display")
        assertEqual(numberOnly.timestampText, "2025-08-13 17:53:23", "number-only timestamp")
        assertEqual(numberOnly.directorySlug, "20250813_175323_13102133750", "number-only slug")

        assertEqual(
            CallRecordFilenameParser.parse(fileName: "not-a-call-file.m4a"),
            nil,
            "invalid file should not parse"
        )
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw CheckError(message)
        }
        return value
    }

    private static func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
        if lhs != rhs {
            fatalError("\(message): expected \(rhs), got \(lhs)")
        }
    }

    private struct CheckError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
