import AnicueCore
import SwiftUI

struct TrackTable: View {
    @Bindable var store: LibraryStore

    var body: some View {
        Table(store.displayRows, selection: $store.selection, sortOrder: $store.sortOrder) {
            leadingColumns
            trailingColumns
        }
        .navigationTitle(store.sidebarTitle)
        .navigationSubtitle("\(store.displayRows.count)곡" + (store.selection.count > 1 ? " · \(store.selection.count)곡 선택" : ""))
    }

    @TableColumnBuilder<TrackRow, KeyPathComparator<TrackRow>>
    private var leadingColumns: some TableColumnContent<TrackRow, KeyPathComparator<TrackRow>> {
            TableColumn("") { row in
                ThumbnailView(track: row.track)
            }
            .width(26)
            TableColumn("✎") { row in
                if store.editedUUIDs.contains(row.track.uuid) {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(Palette.mid)
                        .help("anicue 초안이 있습니다 (rekordbox·파일에는 아직 반영 안 됨)")
                }
            }
            .width(18)
            TableColumn("제목", value: \.title) { row in
                Text(row.title).lineLimit(1)
            }
            .width(min: 140, ideal: 200)
            TableColumn("아티스트", value: \.artist) { row in
                Text(row.artist).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 130)
            TableColumn("장르", value: \.genre) { row in
                Text(row.genre).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)
            TableColumn("코멘트", value: \.comment) { row in
                CommentCell(row: row)
            }
            .width(min: 140, ideal: 230)
    }

    @TableColumnBuilder<TrackRow, KeyPathComparator<TrackRow>>
    private var trailingColumns: some TableColumnContent<TrackRow, KeyPathComparator<TrackRow>> {
            TableColumn("분류", value: \.commentClassName) { row in
                Text(row.commentClassName).foregroundStyle(row.commentClass.tint)
            }
            .width(52)
            TableColumn("BPM", value: \.bpmValue) { row in
                Text(row.bpmValue > 0 ? String(format: "%.0f", row.bpmValue) : "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(40)
            TableColumn("키", value: \.keyName) { row in
                Text(row.keyName).foregroundStyle(.secondary)
            }
            .width(34)
            TableColumn("임포트", value: \.importedOn) { row in
                Text(row.importedOn).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(86)
            TableColumn("재생", value: \.playCount) { row in
                Text(row.playCount > 0 ? "\(row.playCount)" : "").monospacedDigit()
            }
            .width(40)
            TableColumn("큐", value: \.cueStateName) { row in
                Text(row.cueState == .manual ? "수동 \(row.manualCueCount)" : row.cueStateName)
                    .foregroundStyle(row.cueState == .none ? .orange : .secondary)
            }
            .width(58)
    }
}

/// 썸네일은 백그라운드에서 디코딩해 받아 온다. 스크롤 중 메인 스레드를 막지 않는다.
private struct ThumbnailView: View {
    let track: Track
    @State private var image: NSImage?

    var body: some View {
        CoverView(image: image, size: 22)
            .task(id: track.id) {
                let box = await Thumbnails.shared.image(imagePath: track.imagePath, key: track.id)
                image = box.map { NSImage(cgImage: $0.image, size: NSSize(width: 22, height: 22)) }
            }
    }
}

private struct CommentCell: View {
    let row: TrackRow

    var body: some View {
        if row.comment.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else {
            Text(row.comment)
                .lineLimit(1)
                .foregroundStyle(row.commentClass == .convention ? .primary : .secondary)
        }
    }
}

extension CommentClass {
    var tint: Color {
        switch self {
        case .convention: .green
        case .empty: .orange
        case .legacy, .credit: .blue
        case .residue: .red
        case .other: .secondary
        }
    }
}
