import DJCDomain
import Foundation

/// 파일 머리(쪽 0)
public struct PdbFileHeader: Sendable, Hashable {
    public var pageSize: UInt32
    public var numTables: UInt32
    /// 할당된 가장 큰 쪽 번호 + 1(파일 끝 너머 후보 포함)
    public var nextUnusedPage: UInt32
    /// 0x10. rekordbox가 정상으로 닫으면 5
    public var flag10: UInt32
    /// 다음 쪽 순번(모든 쪽 순번보다 큼)
    public var sequence: UInt32
    public var gap: UInt32
    public var tables: [PdbTablePointer]
}

/// 표 포인터 `{type, empty_candidate, first_page, last_page}`
public struct PdbTablePointer: Sendable, Hashable {
    public var type: UInt32
    /// 사슬 마지막 쪽의 다음 쪽. 0으로 채운 쪽이거나 파일 끝 너머
    public var emptyCandidate: UInt32
    /// 인덱스 쪽
    public var firstPage: UInt32
    /// 사슬 마지막 쪽(데이터가 없으면 인덱스 쪽)
    public var lastPage: UInt32
}

/// 멈추지 않고 모은 구조 문제. 값(이름·경로)은 넣지 않고 종류·표·쪽·자리만 둔다.
public struct PdbIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// 쪽 머리의 쪽 번호가 파일 안 위치와 다름
        case pageIndexMismatch
        /// 사슬이 파일 밖 쪽을 가리킴
        case pageOutsideFile
        /// 사슬이 이미 지난 쪽으로 돌아옴
        case cycle
        /// 사슬의 쪽이 다른 표의 쪽
        case pageTypeMismatch
        /// 사슬이 표 포인터의 last_page에서 끝나지 않음
        case lastPageMismatch
        /// 쪽 머리·행 인덱스를 읽을 수 없음
        case pageUnreadable
        /// 표 포인터가 type 0부터 오름차순이 아님
        case tableOrder
        /// 행 오프셋이 힙 밖
        case rowOutsideHeap
        /// 산 행끼리 같은 자리를 가리킴
        case rowOverlap
        /// 쪽 머리 산 행 수 ≠ presence 비트 수
        case liveCountMismatch
        /// 산 행을 해석할 수 없음(짧은 행·모르는 문자열 등)
        case rowUnreadable
        /// 같은 id 산 행이 둘 이상
        case duplicateID
        /// 한 행이어야 할 표에 산 행이 여럿
        case multipleRows
    }

    public var kind: Kind
    public var table: String
    public var page: Int?
    public var slot: Int?

    public init(kind: Kind, table: String, page: Int? = nil, slot: Int? = nil) {
        self.kind = kind
        self.table = table
        self.page = page
        self.slot = slot
    }

    public var description: String {
        "\(kind.rawValue) \(table)" + (page.map { " page \($0)" } ?? "") + (slot.map { " slot \($0)" } ?? "")
    }
}

/// 표 하나를 사슬로 따라간 결과
public struct PdbTableScan: Sendable {
    public var pointer: PdbTablePointer
    public var name: String
    /// 인덱스 쪽부터 사슬 순서. 문제가 나면 그 앞까지
    public var pages: [PdbPage]
    public var issues: [PdbIssue]

    /// 데이터 쪽의 (쪽, 자리). 인덱스 쪽은 자리가 없다
    public var slots: [(page: PdbPage, slot: PdbRowSlot)] {
        pages.flatMap { page in page.slots.map { (page, $0) } }
    }

    public var liveRows: Int { pages.reduce(0) { $0 + $1.slots.filter(\.isLive).count } }
    public var slotCount: Int { pages.reduce(0) { $0 + $1.slots.count } }
}

/// Device Library 파일 하나(4096바이트 쪽 배열, 쪽 0 = 파일 머리, 모든 정수 little-endian)
public struct PdbFile: Sendable {
    public let header: PdbFileHeader
    public let data: Data
    public let kind: PdbFileKind

    /// 머리만 검사한다: 쪽 크기 4096, 표 수 20(export)·9(exportExt), 표 포인터가 파일 안
    public init(data: Data) throws {
        let data = Data(data)
        guard data.count >= 0x1C else { throw UsbError.readFailed(detail: "pdb file too short (\(data.count) bytes)") }
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        let pageSize = u32(0x04), numTables = u32(0x08)
        guard pageSize == UInt32(PdbPage.size) else { throw UsbError.readFailed(detail: "pdb page size \(pageSize)") }
        guard let kind = PdbFileKind(tableCount: numTables) else { throw UsbError.readFailed(detail: "pdb table count \(numTables)") }
        guard data.count >= PdbPage.size, 0x1C + 16 * Int(numTables) <= PdbPage.size else {
            throw UsbError.readFailed(detail: "pdb file too short (\(data.count) bytes)")
        }
        let tables = (0..<Int(numTables)).map { index in
            let at = 0x1C + 16 * index
            return PdbTablePointer(type: u32(at), emptyCandidate: u32(at + 4), firstPage: u32(at + 8), lastPage: u32(at + 12))
        }
        header = PdbFileHeader(pageSize: pageSize, numTables: numTables, nextUnusedPage: u32(0x0C), flag10: u32(0x10),
                               sequence: u32(0x14), gap: u32(0x18), tables: tables)
        self.data = data
        self.kind = kind
    }

    /// 파일 안 쪽 수(끝의 모자란 쪽은 세지 않음)
    public var pageCount: Int { data.count / PdbPage.size }

    /// 쪽 `number`. 파일 밖이면 `UsbError.readFailed`
    public func page(_ number: UInt32) throws -> PdbPage {
        guard Int(number) < pageCount else { throw UsbError.readFailed(detail: "pdb page \(number) outside file") }
        let start = Int(number) * PdbPage.size
        return try PdbPage(data: data[start..<(start + PdbPage.size)])
    }

    /// 인덱스 쪽 → next … → empty_candidate 전까지. 구조 문제가 하나라도 있으면 `UsbError.readFailed`
    public func chain(of pointer: PdbTablePointer) throws -> [PdbPage] {
        let scan = walk(pointer)
        if let issue = scan.issues.first { throw UsbError.readFailed(detail: "pdb chain: \(issue)") }
        return scan.pages
    }

    /// 사슬을 따라가며 문제를 모은다(멈추지 않음). 문제가 난 쪽 앞까지를 돌려준다.
    public func walk(_ pointer: PdbTablePointer) -> PdbTableScan {
        let name = kind.tableName(pointer.type)
        var scan = PdbTableScan(pointer: pointer, name: name, pages: [], issues: [])
        var visited: Set<UInt32> = []
        var current = pointer.firstPage
        func issue(_ kind: PdbIssue.Kind, _ page: UInt32) {
            scan.issues.append(PdbIssue(kind: kind, table: name, page: Int(page)))
        }
        while current != pointer.emptyCandidate {
            guard visited.insert(current).inserted else { issue(.cycle, current); return scan }
            guard Int(current) < pageCount else { issue(.pageOutsideFile, current); return scan }
            let page: PdbPage
            do {
                page = try self.page(current)
            } catch {
                issue(.pageUnreadable, current)
                return scan
            }
            guard page.header.pageIndex == current else { issue(.pageIndexMismatch, current); return scan }
            guard page.header.type == pointer.type else { issue(.pageTypeMismatch, current); return scan }
            scan.pages.append(page)
            current = page.header.nextPage
        }
        if scan.pages.last?.header.pageIndex != pointer.lastPage {
            issue(.lastPageMismatch, scan.pages.last?.header.pageIndex ?? pointer.firstPage)
        }
        return scan
    }
}
