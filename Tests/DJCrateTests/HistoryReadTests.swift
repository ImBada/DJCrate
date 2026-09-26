@testable import DJCrate
import DJCStorage
import DJCTestSupport
import Foundation
import Testing

@Suite("재생 기록 화면과 CLI")
struct HistoryReadTests {
    @Test func CLI는_기록목록과_순번과_오류를_JSON으로_출력한다() throws {
        let fixture = try historyFixture()
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([".build/debug/djc", ".build/out/Products/Debug/djc"].map {
            root.appending(path: $0)
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        for (arguments, status) in [(["histories"], 0), (["history", "new-a"], 0),
                                     (["history", "unknown"], 1), (["history"], 1)] {
            let process = Process(), out = Pipe(), err = Pipe()
            process.executableURL = executable
            process.arguments = arguments + ["--db", fixture.database.path, "--json"]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "DJC_HOME": fixture.root.appending(path: "home").path,
                "DJC_REKORDBOX_DIR": fixture.root.path,
            ]) { _, new in new }
            process.standardOutput = out; process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == status)
            #expect(status == 0 ? stderr.isEmpty : stdout.isEmpty)
            let envelope = try #require(JSONSerialization.jsonObject(with: status == 0 ? stdout : stderr) as? [String: Any])
            #expect(envelope["schemaVersion"] as? Int == 1)
            #expect(envelope["command"] as? String == arguments[0])
            if status == 0 {
                let data = try #require(envelope["data"] as? [String: Any])
                if arguments[0] == "histories" {
                    #expect((data["histories"] as? [[String: Any]])?.map { $0["id"] as? String } == ["new-a", "new-b", "old", "undated"])
                } else {
                    #expect((data["entries"] as? [[String: Any]])?.map { $0["trackNumber"] as? Int } == [1, 2, 3])
                }
            } else {
                #expect((envelope["error"] as? [String: String])?["code"] == (arguments.count == 1 ? "invalid_arguments" : "not_found"))
            }
        }
    }

    @Test func JSON은_날짜와_재생순번을_보존하고_없는곡은_뺀다() throws {
        let fixture = try historyFixture()
        let read = try LibraryRead(snapshot: fixture.database, home: fixture.root.appending(path: "home"))
        #expect(read.histories().histories.map(\.id) == ["new-a", "new-b", "old", "undated"])
        #expect(read.histories().histories.first?.trackCount == 3)
        let result = try read.history(id: "new-a")
        #expect(result.entries.map(\.track.id) == ["102", "101", "101"])
        #expect(result.entries.map(\.trackNumber) == [1, 2, 3])
        let data = try LibraryReadTests().json("history", result)
        #expect(Set(data.keys) == ["history", "entries"])
        let history = try #require(data["history"] as? [String: Any])
        #expect(Set(history.keys) == ["id", "name", "dateCreated", "trackCount"])
        let entry = try #require((data["entries"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["id", "trackNumber", "track"])
        #expect(try read.history(id: "old").entries.isEmpty)
        #expect(throws: ReadFailure.self) { try read.history(id: "deleted") }
        #expect(throws: ReadFailure.self) { try read.history(id: "unknown") }
    }

    @Test @MainActor func 기록선택은_순번과_반복행을_보존하고_선택한곡은_한번만_편집한다() async throws {
        let fixture = try historyFixture()
        let store = LibraryStore(resultHistory: WriteResultHistory(url: fixture.root.appending(path: "result.json")), saveTagDrafts: { _ in })
        await store.load(snapshot: fixture.database)
        #expect(store.histories.map(\.id) == ["new-a", "new-b", "old", "undated"])
        store.sidebar = .history("new-a")
        #expect(store.sortOrder.isEmpty)
        #expect(store.sidebarTitle.contains("2025-02-03"))
        #expect(store.displayRows.map(\.track.id) == ["102", "101", "101"])
        #expect(store.displayRows.map(\.historyTrackNumber) == [1, 2, 3])
        #expect(Set(store.displayRows.map(\.id)).count == 3)
        store.selection = [store.displayRows[2].id]
        #expect(store.primaryRow?.id == "101")
        store.selection = Set(store.displayRows.map(\.id))
        #expect(store.selectedRows.map(\.id) == ["102", "101"])
        store.search = "Alpha"
        #expect(store.displayRows.map(\.historyTrackNumber) == [2, 3])
        store.search = ""
        store.sortOrder = [KeyPathComparator(\TrackRow.title)]
        #expect(store.displayRows.map(\.track.id) == ["101", "101", "102"])
        store.sortOrder = []
        #expect(store.displayRows.map(\.track.id) == ["102", "101", "101"])
        store.selection = [store.displayRows[2].id]
        await store.load(snapshot: fixture.database, quiet: true)
        #expect(store.selection == ["history:entry-3"])
        #expect(store.primaryRow?.id == "101")
        store.sidebar = .history("old")
        #expect(store.displayRows.isEmpty)
        store.sidebar = .filter(.all)
        #expect(!store.sortOrder.isEmpty)
        #expect(store.displayRows.allSatisfy { $0.historyTrackNumber == nil })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DJC_HISTORY_FIXTURE"] != nil))
    func 화면확인용_합성_사본() throws {
        guard let path = ProcessInfo.processInfo.environment["DJC_HISTORY_FIXTURE"] else { return }
        let fixture = try historyFixture()
        try FileManager.default.copyItem(at: fixture.root, to: URL(filePath: path))
    }
}
