import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// USB 라이브러리 형식 작성 실험(임시 폴더에만 쓴다). 출력은 표 이름·칸 이름·수만 — 곡 제목·경로·값을 찍지 않는다.
enum UsbExportLab {
    static let all: [Command] = [
        Command("onelib-rebuild", "<USB 폴더> <출력 폴더>",
                "USB OneLibrary를 모델로 읽어 새로 만든 뒤 표마다 rowid·typeof·값과 sqlite_master.sql을 원본과 비교(값은 찍지 않음)",
                UsbExportLab.rebuild),
        Command("onelib-export",
                "--db <사본> --share <share> (--playlist <ID> | --tracks <ID,…>) --out <출력 폴더> [--snapshot-time <ISO 8601>]",
                "로컬 사본의 곡·목록으로 <출력>/PIONEER/rekordbox/exportLibrary.db만 만든다(음원·분석 파일·다른 형식은 쓰지 않음)",
                UsbExportLab.export),
    ]

    static let clusterSize = 32_768

    // MARK: - onelib-rebuild

    static func rebuild(_ args: [String]) async throws {
        guard args.count == 3 else { throw UsageError() }
        let input = try UsbScratchPath.check(args[1], as: .existingDirectory)
        let output = try UsbScratchPath.check(args[2], as: .outputDirectory)
        let work = FileManager.default.temporaryDirectory.appending(path: "djc-onelib-rebuild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let snapshot = try UsbSnapshot.take(root: UsbRoot(URL(filePath: input)), into: work)
        guard let source = snapshot.oneLibrary else {
            print("입력에 OneLibrary(exportLibrary.db)가 없다")
            return
        }
        let model = try OneLibraryReader.read(copyAt: source)
        let target = try database(in: output)
        try OneLibraryWriter.create(model, at: target)
        let sidecars = UsbLayout.oneLibrarySidecarSuffixes.filter { FileManager.default.fileExists(atPath: target.path + $0) }

        let left = try quietConnection(source), right = try quietConnection(target)
        defer {
            left.close()
            right.close()
        }
        var allSame = true
        for table in OneLibrarySchema.tables {
            let a = try dump(left, table), b = try dump(right, table)
            let result = compare(a, b, columns: table.columns.map(\.name))
            allSame = allSame && result.same
            print(result.line(table.name))
        }
        let sqlA = try schema(left), sqlB = try schema(right)
        let sqlSame = zip(sqlA, sqlB).filter { $0 == $1 }.count
        allSame = allSame && sqlA == sqlB
        print("sql \(sqlSame)/\(max(sqlA.count, sqlB.count)) 같음")
        print(sidecars.isEmpty ? "-wal·-shm 없음" : "남은 사이드카: \(sidecars.joined(separator: " "))")
        if allSame, sidecars.isEmpty {
            print("행·rowid·typeof·sql 골든과 같음(표 \(OneLibrarySchema.tables.count)), -wal·-shm 없음")
        } else {
            print("다름: 위 표·칸을 본다")
        }
    }

    /// 표 비교 결과(수만)
    struct TableComparison {
        var leftRows = 0, rightRows = 0, sameRows = 0
        /// "rowid"·"typeof(칸)"·칸 이름 → 다른 행 수
        var fields: [String: Int] = [:]
        var same: Bool { leftRows == rightRows && sameRows == leftRows }

        func line(_ table: String) -> String {
            let details = fields.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            return "\(table) \(sameRows)/\(max(leftRows, rightRows))행 같음"
                + (leftRows == rightRows ? "" : ", 행 수 \(leftRows) vs \(rightRows)")
                + (details.isEmpty ? "" : ", 다른 칸: " + details.joined(separator: ", "))
        }
    }

    /// rowid 순서대로 짝지어 rowid·칸마다 typeof·값을 비교한다
    static func compare(_ left: [[String]], _ right: [[String]], columns: [String]) -> TableComparison {
        var result = TableComparison(leftRows: left.count, rightRows: right.count)
        for (a, b) in zip(left, right) {
            if a == b { result.sameRows += 1; continue }
            if a.first != b.first { result.fields["rowid", default: 0] += 1 }
            for (index, column) in columns.enumerated() {
                let type = 1 + index * 2, value = type + 1
                if a[type] != b[type] { result.fields["typeof(\(column))", default: 0] += 1 }
                if a[value] != b[value] { result.fields[column, default: 0] += 1 }
            }
        }
        return result
    }

    /// (rowid, typeof(칸), quote(칸), …) rowid 순
    static func dump(_ db: CipherDatabase, _ table: OneLibrarySchema.Table) throws -> [[String]] {
        let select = (["rowid"] + table.columns.flatMap { ["typeof(\($0.name))", "quote(\($0.name))"] }).joined(separator: ", ")
        var rows: [[String]] = []
        try db.query("SELECT \(select) FROM \(table.name) ORDER BY rowid") { row in
            rows.append((0..<row.count).map { row.string(Int32($0)) ?? "NULL" })
        }
        return rows
    }

    /// sqlite_master의 (종류, 이름, 표, sql) 이름 순(rowid·rootpage는 맞추지 않는다)
    static func schema(_ db: CipherDatabase) throws -> [[String]] {
        var rows: [[String]] = []
        try db.query("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name") { row in
            rows.append((0..<4).map { row.string(Int32($0)) ?? "NULL" })
        }
        return rows
    }

    /// 읽기만 하는 연결. 쓰기 가능하게 열어야 닫을 때 SQLite가 -wal·-shm을 치운다(읽기 전용 연결은 WAL 파일 옆에 남긴다)
    static func quietConnection(_ url: URL) throws -> CipherDatabase {
        let db = try CipherDatabase(path: url.path, key: .passphrase(RekordboxKey.oneLibrary()), mode: .readWrite)
        try db.execute("PRAGMA query_only = ON")
        return db
    }

    /// <출력>/PIONEER/rekordbox/exportLibrary.db(폴더를 만든다)
    static func database(in output: String) throws -> URL {
        let target = URL(filePath: output).appending(path: UsbLayout.oneLibrary)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return target
    }

    // MARK: - onelib-export

    static func export(_ args: [String]) async throws {
        guard let dbArgument = value(after: "--db", in: args), let shareArgument = value(after: "--share", in: args),
              let outArgument = value(after: "--out", in: args) else { throw UsageError() }
        // 사본은 임시 폴더 아래만 연다(라이브 master.db·DJCrate 스냅샷 폴더는 거부된다). share는 읽기만 해 확인하지 않는다
        let databasePath = try UsbScratchPath.check(dbArgument, as: .existingFile)
        let output = try UsbScratchPath.check(outArgument, as: .outputDirectory)
        let snapshot = try UsbSnapshotTime.resolve(explicit: value(after: "--snapshot-time", in: args), database: URL(filePath: databasePath))
        print("스냅샷 시각: \(snapshot.source.rawValue)")

        let db = try CipherDatabase.diagnostic(path: databasePath, key: RekordboxKey.derive())
        defer { db.close() }
        var playlists: [UsbPlaylistInput] = []
        var ids: [String]
        if let playlist = value(after: "--playlist", in: args) {
            playlists = try UsbExportCandidates.playlistTree(database: db, rootIDs: [playlist])
            var seen: Set<String> = []
            ids = playlists.flatMap(\.trackLocalIDs).filter { seen.insert($0).inserted }
        } else if let tracks = value(after: "--tracks", in: args) {
            ids = tracks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            throw UsageError()
        }
        let share = URL(filePath: shareArgument)
        let candidates = try UsbExportCandidates.load(database: db, share: share, contentIDs: ids)
        let formats: Set<UsbFormat> = [.oneLibrary]
        let plan = UsbExportPlanner.plan(UsbExportRequest(
            candidates: candidates, playlists: playlists, existing: nil, formats: formats, naming: IdentifierAnalysisNaming(),
            snapshotTakenAt: snapshot.date, clusterSize: clusterSize))
        print("후보 \(ids.count) · 계획 \(plan.tracks.count)곡 · 목록 \(plan.playlists.count) · 막힘 \(plan.blocked.count)"
            + (plan.blocked.isEmpty ? "" : "(\(UsbPlanLab.counts(plan.blocked.map(\.code))))"))

        let model = try UsbLibraryBuilder.build(plan: plan, formats: formats, local: UsbLocalSource(database: db), share: share,
                                                myTagMasterDBID: UsbLibraryBuilder.randomMyTagMasterDBID(), createdDate: today())
        let target = try database(in: output)
        try OneLibraryWriter.create(model.library, at: target)
        let library = model.library
        print("exportLibrary.db: 곡 \(library.tracks.count) · artist \(library.artists.count) · album \(library.albums.count) · "
            + "genre \(library.genres.count) · key \(library.keys.count) · label \(library.labels.count) · color \(library.colors.count) · "
            + "image \(library.images.count) · 목록 \(library.playlists.count) · myTag \(library.myTags.count) · "
            + "menuItem \(library.menuItems.count) · category \(library.categories.count) · sort \(library.sorts.count)")
        let kinds = model.files.map { file -> String in
            switch file.kind {
            case .audio: "음원"
            case .artwork: "아트워크"
            case .analysis: "분석"
            }
        }
        print("파일 작업(옮기지 않음): \(UsbPlanLab.counts(kinds))")
        print("확인 문제 \(try OneLibraryWriter.verify(target, expected: library).count)")
    }

    /// 오늘(이 Mac의 시간대) "YYYY-MM-DD"
    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
