import DJCDomain
import Foundation

/// USB 쓰기 진행 기록. USB가 아니라 맥(`usb-sessions/<볼륨키>.json`)에 두어 USB가 뽑혀도 회복할 근거가 남는다.
/// 바꿀 때마다 내구 쓰기(`UsbDurableFile`)로 디스크에 내린 뒤 다음 USB 연산을 한다.
public struct UsbJournal: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case planned, staged, backedUp, filesWritten, committing, committed, cleaned, verified
        case rolledBack, restoreFailed, restorePending, needsReplan, dryRun, recovered, restored
    }

    /// 닫힌 상태. 닫힌 저널은 다음 쓰기를 막지 않는다(드라이 런·다시 계획 포함). 앱·회복·백업 정리도 이것만 본다
    public static let closedStates: Set<State> = [.verified, .rolledBack, .restored, .recovered, .dryRun, .needsReplan]

    public var isClosed: Bool { Self.closedStates.contains(state) }

    public enum FileDisposition: String, Codable, Sendable { case created, reused, overwritten }
    public enum EntryState: String, Codable, Sendable { case pending, done }
    public enum RemovalState: String, Codable, Sendable { case pending, removed, skipped }
    public enum SkipReason: String, Codable, Sendable { case ppthDiffers, hashDiffers, notAllowed }

    /// 음원·분석 파일·아트워크 하나
    public struct FileEntry: Codable, Sendable, Equatable {
        public var destination: String
        /// 재사용이면 nil
        public var tempName: String?
        public var disposition: FileDisposition
        public var oldSHA256: String?
        /// 음원은 복사한 뒤에 채운다(그 전에 끊기면 임시 파일을 불완전으로 본다)
        public var newSHA256: String?
        public var size: Int64
        public var appleDoublePreexisted: Bool
        public var state: EntryState

        public init(destination: String, tempName: String?, disposition: FileDisposition, oldSHA256: String?, newSHA256: String?,
                    size: Int64, appleDoublePreexisted: Bool, state: EntryState) {
            self.destination = destination
            self.tempName = tempName
            self.disposition = disposition
            self.oldSHA256 = oldSHA256
            self.newSHA256 = newSHA256
            self.size = size
            self.appleDoublePreexisted = appleDoublePreexisted
            self.state = state
        }
    }

    /// DB 하나. 임시 파일을 쓰기 전에 pending으로 적고 rename 뒤 done
    public struct DatabaseEntry: Codable, Sendable, Equatable {
        public var destination: String
        public var format: UsbFormat
        public var tempName: String
        /// created = 쓰기 전에 없던 DB(내보내기, 백업에 없음), overwritten = 있던 DB(백업에 있음)
        public var disposition: FileDisposition
        public var oldSHA256: String?
        public var newSHA256: String
        public var appleDoublePreexisted: Bool
        /// 쓰기 전 USB에 있던 그 DB의 -wal·-shm·-journal(백업에 있음)
        public var sidecarsPreexisted: [String]
        public var state: EntryState

        public init(destination: String, format: UsbFormat, tempName: String, disposition: FileDisposition, oldSHA256: String?,
                    newSHA256: String, appleDoublePreexisted: Bool, sidecarsPreexisted: [String], state: EntryState) {
            self.destination = destination
            self.format = format
            self.tempName = tempName
            self.disposition = disposition
            self.oldSHA256 = oldSHA256
            self.newSHA256 = newSHA256
            self.appleDoublePreexisted = appleDoublePreexisted
            self.sidecarsPreexisted = sidecarsPreexisted
            self.state = state
        }
    }

    /// 쓰기 전 확인에서 정한 DB별 처리(회복이 옛 해시·새 해시로 분류하는 근거)
    public struct PlannedDatabase: Codable, Sendable, Equatable {
        public var destination: String
        public var disposition: FileDisposition
        public var oldSHA256: String?

        public init(destination: String, disposition: FileDisposition, oldSHA256: String?) {
            self.destination = destination
            self.disposition = disposition
            self.oldSHA256 = oldSHA256
        }
    }

    public struct RemovalEntry: Codable, Sendable, Equatable {
        public var path: String
        public var state: RemovalState
        public var reason: SkipReason?

        public init(path: String, state: RemovalState, reason: SkipReason? = nil) {
            self.path = path
            self.state = state
            self.reason = reason
        }
    }

    public var formatVersion = 1
    /// 계획 전체(base·target·준비 폴더·ID 상한 포함). 회복이 이어 쓰거나 검증할 때 쓴다
    public var changes: UsbChangeSet
    public var volumeUUID: String
    public var volumeName: String
    public var state: State
    public var plannedDatabases: [PlannedDatabase] = []
    public var entries: [FileEntry] = []
    public var databases: [DatabaseEntry] = []
    public var createdDirs: [String] = []
    public var deletedSidecars: [String] = []
    public var removals: [RemovalEntry] = []
    public var backupDirectory: String?
    public var reportPath: String?
    /// `usb-restore`가 연 저널. 끊겨도 회복이 같은 방식(되돌리기)으로 마저 하고, 그 쓰기의 백업 기록은 건드리지 않는다
    public var restoringBackup = false
    /// 다음 임시 이름 번호
    public var nextSequence = 1
    public var updatedAt: Date

    public init(changes: UsbChangeSet, volumeUUID: String, volumeName: String, now: Date) {
        self.changes = changes
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        state = .planned
        updatedAt = now
    }

    public var session: String { changes.session }
    public var base: UsbFingerprint? { changes.base }
    public var target: UsbTargetFingerprint { changes.target }
    public var stagingDirectory: String { changes.stagingDirectory }
    public var idHighWater: [String: Int] { changes.idHighWater }

    /// DB 교체를 모두 마친 형식(Device Library는 export.pdb·exportExt.pdb 둘 다). 앱이 형식별 진행을 여기서 읽는다
    public var committedFormats: Set<UsbFormat> {
        Set(changes.databases.map(\.format)).filter { format in
            changes.databases.filter { $0.format == format }.allSatisfy { planned in
                databases.contains { $0.destination == planned.destination && $0.state == .done }
            }
        }
    }

    /// 지금 교체 중인(저널에 적었으나 rename 전인) DB의 형식
    public var committingFormat: UsbFormat? { databases.last { $0.state == .pending }?.format }

    /// 상태는 앞으로만 간다. 닫힌 저널은 움직이지 않는다(새 세션은 새 저널을 쓴다)
    public func canMove(to next: State) -> Bool {
        if isClosed { return false }
        switch next {
        case .planned: return false
        case .staged: return state == .planned
        case .dryRun, .backedUp: return state == .staged
        case .filesWritten: return state == .backedUp
        case .committing, .committed: return [.filesWritten, .committing].contains(state)
        case .cleaned: return state == .committed
        case .verified: return state == .cleaned
        // 되돌리기·회복은 어느 열린 상태에서든 닫는다
        case .rolledBack, .restoreFailed, .restorePending, .recovered: return true
        // 기기가 DB를 바꿨다는 판정은 USB에 쓰기 시작한 뒤에만 나온다
        case .needsReplan: return ![.planned, .staged].contains(state)
        case .restored: return [.restorePending, .restoreFailed].contains(state)
        }
    }

    public mutating func move(to next: State) throws {
        guard canMove(to: next) else {
            throw UsbError.readFailed(detail: "journal state \(state.rawValue) -> \(next.rawValue) not allowed")
        }
        state = next
    }

    /// 저널·manifest·보고서 JSON. 날짜는 기본(초 단위 실수)으로 둔다 — ISO 8601은 1초 아래를 버려 mtime이 어긋난다
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }
}
