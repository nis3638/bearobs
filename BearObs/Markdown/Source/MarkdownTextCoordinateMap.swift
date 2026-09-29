import Foundation

/// Maps valid Unicode scalar boundaries between Markdown's UTF-8 byte offsets
/// and AppKit's UTF-16 offsets. Invalid interior offsets fail closed.
public struct MarkdownTextCoordinateMap: Equatable, Sendable {
    private let utf8ToUTF16: [Int: Int]
    private let utf16ToUTF8: [Int: Int]

    public init(text: String) {
        var utf8ToUTF16: [Int: Int] = [0: 0]
        var utf16ToUTF8: [Int: Int] = [0: 0]
        var utf8Offset = 0
        var utf16Offset = 0

        for scalar in text.unicodeScalars {
            utf8Offset += scalar.utf8.count
            utf16Offset += scalar.utf16.count
            utf8ToUTF16[utf8Offset] = utf16Offset
            utf16ToUTF8[utf16Offset] = utf8Offset
        }

        self.utf8ToUTF16 = utf8ToUTF16
        self.utf16ToUTF8 = utf16ToUTF8
    }

    /// Returns the equivalent AppKit coordinate only when both endpoints are
    /// valid Unicode scalar boundaries.
    public func utf16Range(forUTF8 range: Range<Int>) -> Range<Int>? {
        guard
            range.lowerBound >= 0,
            range.upperBound >= range.lowerBound,
            let lowerBound = utf8ToUTF16[range.lowerBound],
            let upperBound = utf8ToUTF16[range.upperBound]
        else {
            return nil
        }
        return lowerBound..<upperBound
    }

    /// Returns the source byte offset only at a valid Unicode scalar boundary.
    public func utf8Offset(forUTF16 offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        return utf16ToUTF8[offset]
    }
}
