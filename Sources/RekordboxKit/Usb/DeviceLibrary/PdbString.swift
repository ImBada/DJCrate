import DJCDomain
import Foundation

/// DeviceSQL 문자열 모양
public enum PdbStringKind: String, Sendable, Hashable, CaseIterable {
    /// 첫 바이트 홀수 `((n+1)<<1)+1` + ASCII n바이트(끝 표시 없음)
    case shortASCII
    /// `40`, u16 길이(머리 4 포함), `00`, ASCII
    case longASCII
    /// `90`, u16 길이(머리 4 포함), `00`, UTF-16LE
    case utf16LE
    /// `90`, u16 길이, `00`, `03`, ASCII, `00`(트랙 ISRC 칸에만)
    case isrc
}

public enum PdbStringDecoder {
    /// 행 시작 기준 offset에서 DeviceSQL 문자열 하나를 읽는다. `isrcAllowed`는 트랙 문자열 0(ISRC)에서만 참으로 준다
    /// (그 밖의 칸에서 `90 … 00 03`은 첫 글자 아래 바이트가 3인 UTF-16이다. 그래서 기본은 거짓).
    /// 모르는 첫 바이트·행 밖으로 나가는 길이·잘못된 글자는 `UsbError.readFailed`.
    public static func decode(_ row: Data, at offset: Int, isrcAllowed: Bool = false) throws -> (value: String, kind: PdbStringKind, byteLength: Int) {
        let bytes = [UInt8](row)
        guard offset >= 0, offset < bytes.count else { throw failure("offset \(offset) outside row \(bytes.count)") }
        let first = bytes[offset]
        if first & 1 == 1 {
            let length = Int(first >> 1) - 1
            guard length >= 0 else { throw failure("short ASCII header 0x01") }
            guard offset + 1 + length <= bytes.count else { throw failure("short ASCII past row end") }
            let body = bytes[(offset + 1)..<(offset + 1 + length)]
            guard body.allSatisfy({ $0 < 0x80 }) else { throw failure("short ASCII has non-ASCII byte") }
            return (String(decoding: body, as: UTF8.self), .shortASCII, 1 + length)
        }
        guard first == 0x40 || first == 0x90 else { throw failure(String(format: "unknown string byte 0x%02X", first)) }
        guard offset + 4 <= bytes.count else { throw failure("long string header past row end") }
        let length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
        guard length >= 4, offset + length <= bytes.count else { throw failure("long string length \(length) past row end") }
        let body = Array(bytes[(offset + 4)..<(offset + length)])
        if first == 0x40 {
            guard body.allSatisfy({ $0 < 0x80 }) else { throw failure("long ASCII has non-ASCII byte") }
            return (String(decoding: body, as: UTF8.self), .longASCII, length)
        }
        if isrcAllowed, body.first == 0x03 {
            guard body.count >= 2, body.last == 0x00 else { throw failure("ISRC string without terminator") }
            let text = body[1..<(body.count - 1)]
            guard text.allSatisfy({ $0 < 0x80 }) else { throw failure("ISRC has non-ASCII byte") }
            return (String(decoding: text, as: UTF8.self), .isrc, length)
        }
        guard body.count % 2 == 0 else { throw failure("UTF-16 string has odd length") }
        let units = stride(from: 0, to: body.count, by: 2).map { UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8 }
        guard let value = String(validating: units, as: UTF16.self) else { throw failure("invalid UTF-16") }
        return (value, .utf16LE, length)
    }

    static func failure(_ detail: String) -> UsbError {
        .readFailed(detail: "pdb string: \(detail)")
    }
}

/// DeviceSQL 문자열 만들기. UTF-16 문자열을 행 안 4바이트 경계에 두는 것은 행을 만드는 쪽 몫이다.
public enum PdbStringEncoder {
    /// 짧은 ASCII 최대 글자 수
    public static let shortASCIIMaxLength = 126

    /// 짧은 ASCII 첫 바이트 `((n+1)<<1)+1`
    public static func shortASCIIHeader(length: Int) -> UInt8 {
        precondition((0...shortASCIIMaxLength).contains(length), "짧은 ASCII는 126자까지")
        return UInt8(((length + 1) << 1) + 1)
    }

    /// 확인한 모양으로만 만든다.
    /// rekordbox 7.2.18 골든 관찰(2026-09-26 내보내기): 126자까지의 ASCII는 짧은 ASCII, ASCII가 아닌 글자가 있으면 UTF-16LE.
    /// 127자 이상 순수 ASCII의 모양은 확인 안 됨(`pdbLongAscii`)이라 nil을 돌려준다. 쓰는 쪽이 그 규칙을 허용할 때만
    /// `encodeUTF16` 등으로 명시해서 쓴다(긴 ASCII 0x40은 읽기만 한다).
    public static func encode(_ value: String) -> Data? {
        let ascii = Array(value.utf8)
        guard ascii.allSatisfy({ $0 < 0x80 }) else { return encodeUTF16(value) }
        guard ascii.count <= shortASCIIMaxLength else { return nil }
        return Data([shortASCIIHeader(length: ascii.count)] + ascii)
    }

    /// 늘 UTF-16LE(메뉴 이름처럼 ASCII여도 UTF-16인 칸)
    public static func encodeUTF16(_ value: String) -> Data {
        var data = Data([0x90])
        let length = 4 + value.utf16.count * 2
        data.append(contentsOf: [UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8), 0])
        for unit in value.utf16 { data.append(contentsOf: [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)]) }
        return data
    }

    /// 트랙 ISRC 특수형: `90`, u16 길이 = 4 + 1 + k + 1, `00`, `03`, ASCII k, `00`
    public static func encodeISRC(_ value: String) -> Data {
        let ascii = Array(value.utf8)
        let length = 4 + 1 + ascii.count + 1
        return Data([0x90, UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8), 0x00, 0x03] + ascii + [0x00])
    }
}
