import Foundation

enum IndexCJKSearchText {
    static func transform(_ text: String) -> String {
        var tokens: [String] = []
        var hanRun: [Character] = []
        var plain = ""

        func appendPlain() {
            tokens.append(
                contentsOf: plain.split(whereSeparator: { $0.isWhitespace }).map(String.init))
            plain = ""
        }

        func appendHanRun() {
            for index in hanRun.indices {
                tokens.append(String(hanRun[index]))
                let next = hanRun.index(after: index)
                if next < hanRun.endIndex {
                    tokens.append(String(hanRun[index]) + String(hanRun[next]))
                }
            }
            hanRun = []
        }

        for character in text {
            if isHan(character) {
                appendPlain()
                hanRun.append(character)
            } else {
                appendHanRun()
                plain.append(character)
            }
        }
        appendPlain()
        appendHanRun()
        return tokens.joined(separator: " ")
    }

    static func containsHan(_ text: String) -> Bool {
        text.contains(where: isHan)
    }

    static func isSingleHanRun(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy(isHan)
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                0x4E00...0x9FFF,
                0xF900...0xFAFF,
                0x20000...0x2FA1F,
                0x30000...0x323AF:
                true
            default:
                false
            }
        }
    }
}
