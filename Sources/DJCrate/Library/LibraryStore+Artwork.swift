import DJCDomain
import DJCStorage
import Foundation
import RekordboxKit

/// 곡 그림 초안(#66): 그림 넣기·바꾸기·지우기를 초안으로 쌓고 반영 때 rekordbox 라이브러리에 쓴다(음원 파일의 그림은 그대로).
/// 그림을 고르면 그 사본을 초안 폴더에 바로 둔다(원본 파일을 옮겨도 초안이 남게). 저장은 그 자리에서 끝나 실패하면 바로 알린다.
extension LibraryStore {
    var artworkDirectory: URL { (draftHome ?? DJCPaths.userData).appending(path: ArtworkDraftStore.folderName) }

    /// 그림을 고칠 수 있는 곡(이 라이브러리의 로컬 곡). 추가한 곡·USB 곡·스트리밍 곡은 뺀다.
    func canEditArtwork(_ row: TrackRow) -> Bool { !row.isStaged && !row.isUsb && !row.track.isStreaming }

    /// 초안 base: 스냅샷의 곡 행 `ImagePath`와 살아 있는 그림 파일 행
    func artworkBase(for row: TrackRow) -> ArtworkBase {
        ArtworkBase(imagePath: row.track.imagePath ?? "", files: artworkFileRows[row.track.id] ?? [])
    }

    /// 고른 그림 파일로 넣기·바꾸기 초안을 만든다. 읽지 못하거나 확인하지 않은 그림이면 초안을 만들지 않고 알린다.
    func setArtwork(fileAt url: URL, rows: [TrackRow]) {
        do {
            setArtwork(try Data(contentsOf: url), name: url.lastPathComponent, rows: rows)
        } catch {
            artworkMessage = AppMessage(kind: .warning, text: String(ui: "그림 파일을 읽지 못했으니 파일 위치와 접근 권한을 확인한 뒤 다시 고르세요"))
        }
    }

    func setArtwork(_ image: Data, name: String?, rows: [TrackRow]) {
        guard !isWritingRekordbox else { return }
        if let reason = TrackArtwork.unsupportedReason(image) {
            artworkMessage = AppMessage(kind: .warning, text: reason)
            return
        }
        let targets = rows.filter(canEditArtwork)
        finishArtworkChange(failed: saveArtworkDrafts(targets.map {
            ArtworkDraftStore.edit(trackUUID: $0.track.uuid, base: artworkBase(for: $0), image: image, imageName: name)
        }))
    }

    /// 그림 지우기 초안. 그림이 없는 곡은 남은 넣기 초안만 버린다. 실패는 한 번에 센다(뒤 단계가 앞 단계의 실패 안내를 지우지 않게).
    func deleteArtwork(rows: [TrackRow]) {
        guard !isWritingRekordbox else { return }
        let targets = rows.filter(canEditArtwork)
        let withArtwork = targets.filter { artworkBase(for: $0).hasArtwork }
        let saved = saveArtworkDrafts(withArtwork.map {
            ArtworkEdit(draft: ArtworkDraft(trackUUID: $0.track.uuid, change: .delete, base: artworkBase(for: $0)), image: nil)
        })
        let removed = removeArtworkDrafts(targets.filter { !artworkBase(for: $0).hasArtwork })
        finishArtworkChange(failed: saved + removed)
    }

    /// 초안 버리기(그림)
    func discardArtworkDrafts(rows: [TrackRow]) {
        guard !isWritingRekordbox else { return }
        finishArtworkChange(failed: removeArtworkDrafts(rows))
    }

    /// 초안과 사본을 지운다. 지우지 못한 곡 수를 돌려준다.
    private func removeArtworkDrafts(_ rows: [TrackRow]) -> Int {
        var failed = 0
        let stored = ArtworkDraftStore.uuids(directory: artworkDirectory)
        for row in rows where artworkDrafts[row.track.uuid] != nil || stored.contains(row.track.uuid) {
            do {
                try ArtworkDraftStore.remove(trackUUID: row.track.uuid, directory: artworkDirectory)
                artworkDrafts[row.track.uuid] = nil
                artworkChangeCount += 1
                updateEdited(row.track.uuid)
            } catch { failed += 1 }
        }
        return failed
    }

    /// 초안을 저장한다. 저장하지 못한 곡 수를 돌려준다.
    private func saveArtworkDrafts(_ edits: [ArtworkEdit]) -> Int {
        var failed = 0
        for edit in edits {
            do {
                try ArtworkDraftStore.save(edit, directory: artworkDirectory)
                artworkDrafts[edit.trackUUID] = edit.draft
                artworkChangeCount += 1
                updateEdited(edit.trackUUID)
            } catch { failed += 1 }
        }
        return failed
    }

    /// 한 동작을 마친 뒤 한 번만 부른다. 실패가 있으면 안내를 남기고, 모두 되면 지난 안내를 지운다.
    private func finishArtworkChange(failed: Int) {
        artworkMessage = failed == 0 ? nil
            : AppMessage(kind: .warning, text: String(ui: "\(failed)곡의 그림 초안을 저장하지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 다시 하세요"))
        if let draftHome { applyMovedDrafts(DamagedDrafts.take(home: draftHome)) }
        if case .pending = sidebar { refreshBase() }
    }

    /// 초안의 그림 사본(넣기·바꾸기 초안만). 인스펙터가 보여 준다.
    func artworkDraftImage(trackUUID: String) -> Data? {
        guard artworkDrafts[trackUUID]?.change == .set else { return nil }
        return (try? ArtworkDraftStore.load(trackUUID: trackUUID, directory: artworkDirectory))?.image
    }

    /// 쓰기·미리 보기에 넘길 대상 곡의 그림 초안. 읽지 못한 초안은 옮겨 보관하고 쓰기를 막는다(`requireReadableDrafts`가 먼저 옮긴다).
    func artworkEdits(for rows: [TrackRow]) throws -> [ArtworkEdit] {
        try rows.compactMap { row in
            guard artworkDrafts[row.track.uuid] != nil else { return nil }
            do { return try ArtworkDraftStore.load(trackUUID: row.track.uuid, directory: artworkDirectory) }
            catch {
                throw DJCError.writeRefused(String(ui: "그림 초안을 읽지 못했으니 그 곡의 그림을 다시 고른 뒤 쓰기를 다시 시도하세요."))
            }
        }
    }

    /// 쓰기 뒤: 쓴 곡의 그림 초안을 지운다(백업에 남아 있다). 목록·덱이 그 곡의 그림을 새로 읽게 한다.
    func finishArtworkWrite(_ report: RekordboxWriter.Report) {
        let written = report.artworkWritten.map(\.trackUUID)
        guard !written.isEmpty else { return }
        var failed = 0
        for uuid in written {
            do { try ArtworkDraftStore.remove(trackUUID: uuid, directory: artworkDirectory) } catch { failed += 1 }
            artworkDrafts[uuid] = nil
            artworkChangeCount += 1
            updateEdited(uuid)
        }
        ArtworkRevisions.bump(written.compactMap { rowsByUUID[$0]?.track.id })
        if failed > 0 {
            writeFollowUp.append(String(ui: "rekordbox에는 썼지만 그림 초안 \(failed)곡을 정리하지 못했으니 쓰기 대기 목록에서 그림 초안 버리기로 버리세요."))
        }
    }

    /// 복원 뒤: 백업의 그림 초안을 되살린다(쓴 뒤 같은 곡에 새로 만든 초안은 `keeps`면 남긴다). 그 곡의 그림을 새로 읽게 한다.
    static func artworkRestoreFailureText(_ count: Int) -> String {
        String(ui: "rekordbox는 복원했지만 그림 초안 \(count)곡을 되살리지 못했으니 DJCrate 데이터 폴더의 쓰기 권한을 확인한 뒤 그 곡의 그림을 다시 고르세요.")
    }

    /// 복원 뒤: 백업의 그림 초안을 되살린다(쓴 뒤 같은 곡에 새로 만든 초안은 `keeps`면 남긴다). 그 곡의 그림을 새로 읽게 한다.
    /// - Returns: 덱이 다시 읽을 곡(되살린 초안·그 백업이 그림을 쓴 곡)과 되살리지 못한 초안 수(알린다)
    func restoreArtworkDrafts(from backup: RekordboxWriter.Backup, keeps: (String) -> Bool) -> (tracks: Set<String>, failed: Int) {
        var restored = Set<String>(), failed = 0
        for edit in RekordboxWriter.artworkDrafts(in: backup.url) where !keeps(edit.trackUUID) {
            do { try ArtworkDraftStore.save(edit, directory: artworkDirectory) } catch { failed += 1; continue }
            artworkDrafts[edit.trackUUID] = edit.draft
            artworkChangeCount += 1
            updateEdited(edit.trackUUID)
            restored.insert(edit.trackUUID)
        }
        let touched = (backup.report?.artworkWritten ?? []).map(\.trackUUID)
        ArtworkRevisions.bump(touched.compactMap { rowsByUUID[$0]?.track.id })
        return (restored.union(touched), failed)
    }
}
