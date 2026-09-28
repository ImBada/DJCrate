import DJCDomain
import DJCStorage
import RekordboxKit
import SwiftUI

/// 사이드바 USB 재생 목록 줄
struct UsbPlaylistNode: Identifiable, Hashable {
    var id: Int
    var name: String
    var isFolder: Bool
    var isSmart: Bool
    /// 보일 항목 수(폴더는 0)
    var count: Int
    /// 두 형식을 함께 쓴 USB에서 한 형식에만 있는 목록("OneLibrary만"·"Device Library만")
    var marker: String?
    /// 두 형식의 항목(곡·순서)이 다르다
    var entriesDiffer: Bool
    /// 폴더면 하위 목록(비어 있어도 배열), 목록이면 nil
    var children: [UsbPlaylistNode]?
}

/// 합친 USB 라이브러리의 재생 목록 → 사이드바 트리
enum UsbPlaylistTree {
    static var mismatchHelp: String { String(ui: "두 형식의 재생 목록 내용이 다릅니다") }

    static func build(_ library: UsbLibrary) -> [UsbPlaylistNode] {
        let bothFormats = library.formats.isSuperset(of: UsbFormat.defaultSet)
        let byParent = Dictionary(grouping: library.playlists, by: \.parentID)
        var visited: Set<Int> = []
        func order(_ playlist: UsbPlaylist) -> Int { playlist.sortOrder[.oneLibrary] ?? playlist.sortOrder[.deviceLibrary] ?? .max }
        func nodes(under parent: Int) -> [UsbPlaylistNode] {
            (byParent[parent] ?? []).sorted { (order($0), $0.id) < (order($1), $1.id) }.compactMap { playlist in
                // 부모가 자기 자신을 가리키는 깨진 트리에서 끝없이 돌지 않게
                guard visited.insert(playlist.id).inserted else { return nil }
                let isFolder = playlist.attribute == 1
                var marker: String?
                if bothFormats, playlist.presentIn.count == 1 {
                    marker = playlist.presentIn.contains(.oneLibrary) ? String(ui: "OneLibrary만") : String(ui: "Device Library만")
                }
                let differ = bothFormats && !isFolder && playlist.presentIn.isSuperset(of: UsbFormat.defaultSet)
                    && playlist.entries[.oneLibrary] ?? [] != playlist.entries[.deviceLibrary] ?? []
                return UsbPlaylistNode(id: playlist.id, name: playlist.name, isFolder: isFolder, isSmart: playlist.attribute == 4,
                                       count: isFolder ? 0 : UsbLibraryRows.entries(of: playlist).count, marker: marker,
                                       entriesDiffer: differ, children: isFolder ? nodes(under: playlist.id) : nil)
            }
        }
        return nodes(under: 0)
    }
}

/// 사이드바 USB 절의 볼륨 하나(순수 모델, 화면은 이것만 그린다)
struct UsbSidebarVolume: Identifiable, Equatable {
    /// 볼륨키
    var id: String
    var name: String
    var symbol: String
    var isWarning: Bool
    /// 이름 아래 짧은 안내(읽는 중·막힌 이유 등)
    var status: String?
    var help: String
    /// "USB로 내보내기…"(빈 FAT32)
    var showsExport: Bool
    /// 내보내기를 누를 수 있는지(쓰는 중이 아닐 때)
    var canExport: Bool
    var collection: UsbSidebarTarget?
    var collectionCount: Int
    var playlists: [UsbPlaylistNode]
    /// 두 형식의 재생 목록이 다를 때의 경고
    var mismatchHelp: String?
    var canEject: Bool
}

@MainActor
enum UsbSidebarModel {
    static func volumes(_ store: UsbStore) -> [UsbSidebarVolume] {
        store.volumes.map { volume in
            let key = volume.usbKey
            let idle = !store.busyVolumes.contains(key) && store.activeWrite == nil
            var row = UsbSidebarVolume(id: key, name: volume.name, symbol: "externaldrive", isWarning: false, status: nil, help: volume.name,
                                       showsExport: false, canExport: false, collection: nil, collectionCount: 0, playlists: [], mismatchHelp: nil,
                                       canEject: !store.busyVolumes.contains(key) && !store.ejecting.contains(key))
            switch store.shapes[key] {
            case .emptyExportable:
                row.showsExport = true
                row.canExport = idle
                row.help = String(ui: "rekordbox 라이브러리가 없는 FAT32 USB입니다")
            case let .rekordbox(formats):
                row.symbol = "externaldrive.fill"
                row.help = UsbFormat.allCases.filter(formats.contains).map(\.displayName).joined(separator: " · ")
                if let library = store.libraries[key] {
                    row.collection = .collection(volumeKey: key)
                    row.collectionCount = library.tracks.count
                    row.playlists = UsbPlaylistTree.build(library)
                }
                if (store.infos[key]?.consistency.playlistMismatches ?? 0) > 0 { row.mismatchHelp = UsbPlaylistTree.mismatchHelp }
            case let .unsupported(reason):
                row.isWarning = true
                row.symbol = "exclamationmark.triangle"
                row.help = reason
                row.status = store.refusals[key] == "denylisted" ? String(ui: "쓰기 금지 볼륨") : reason
            case let .failed(message):
                row.isWarning = true
                row.symbol = "exclamationmark.triangle"
                row.help = message
                row.status = message
            case .reading, nil:
                row.status = String(ui: "읽는 중…")
                // 다시 읽는 중에는 앞서 읽은 목록을 그대로 둔다(고른 목록이 사라지지 않게)
                if let library = store.libraries[key] {
                    row.symbol = "externaldrive.fill"
                    row.collection = .collection(volumeKey: key)
                    row.collectionCount = library.tracks.count
                    row.playlists = UsbPlaylistTree.build(library)
                }
            }
            return row
        }
    }
}

extension UsbFormat {
    /// 형식 이름(고유 이름이라 번역하지 않는다)
    var displayName: String {
        switch self {
        case .oneLibrary: "OneLibrary"
        case .deviceLibrary: "Device Library"
        }
    }
}

/// 사이드바 "USB" 절: 볼륨마다 모양·꺼내기, 빈 FAT32는 내보내기, rekordbox USB는 컬렉션과 재생 목록(읽기 전용)
struct UsbSidebarSection: View {
    let usb: UsbStore
    @State private var isExpanded = true
    @State private var collapsed: Set<String> = []
    @State private var ejectMessage: String?

    var body: some View {
        Section(isExpanded: $isExpanded) {
            let volumes = UsbSidebarModel.volumes(usb)
            if volumes.isEmpty {
                Text(.ui("연결된 USB가 없습니다")).foregroundStyle(.secondary)
            }
            ForEach(volumes) { volume in
                DisclosureGroup(isExpanded: expanded(volume.id)) {
                    contents(of: volume)
                } label: {
                    header(of: volume)
                }
            }
            if let ejectMessage {
                Text(ejectMessage).font(.caption).foregroundStyle(UIColors.warning.color).lineLimit(3)
            }
        } header: {
            HStack {
                Text(verbatim: "USB")
                Spacer(minLength: 0)
                Button {
                    Task { await usb.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(.ui("USB 다시 읽기"))
                .accessibilityLabel(.ui("USB 다시 읽기"))
            }
        }
    }

    private func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(key) }, set: { open in
            if open { collapsed.remove(key) } else { collapsed.insert(key) }
        })
    }

    private func header(of volume: UsbSidebarVolume) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Label {
                    Text(verbatim: volume.name).lineLimit(1)
                } icon: {
                    Image(systemName: volume.symbol)
                        .foregroundStyle(volume.isWarning ? UIColors.warning.color : Color.secondary)
                }
                if let status = volume.status {
                    Text(verbatim: status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button {
                Task { ejectMessage = await usb.eject(volume.id) }
            } label: {
                Image(systemName: "eject")
            }
            .buttonStyle(.borderless)
            .disabled(!volume.canEject)
            .help(.ui("꺼내기"))
            .accessibilityLabel(.ui("\(volume.name) 꺼내기"))
        }
        .help(volume.help)
    }

    @ViewBuilder private func contents(of volume: UsbSidebarVolume) -> some View {
        if volume.showsExport {
            Button {
                usb.exportSheet = UsbExportSheetRequest(volumeKey: volume.id)
            } label: {
                Label(.ui("USB로 내보내기…"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(!volume.canExport)
            .help(.ui("로컬 재생 목록·곡을 이 USB에 OneLibrary·Device Library로 내보냅니다"))
        }
        if let collection = volume.collection {
            Label(.ui("컬렉션"), systemImage: "music.note.list")
                .badge(volume.collectionCount)
                .tag(SidebarItem.usb(collection))
            if let help = volume.mismatchHelp {
                Label(.ui("재생 목록이 형식마다 다릅니다"), systemImage: WarningMark.symbol)
                    .font(.caption)
                    .foregroundStyle(UIColors.warning.color)
                    .help(help)
            }
            OutlineGroup(volume.playlists, children: \.children) { node in
                UsbPlaylistRow(node: node)
                    .tag(SidebarItem.usb(.playlist(volumeKey: volume.id, id: node.id)))
            }
        }
    }
}

private struct UsbPlaylistRow: View {
    let node: UsbPlaylistNode

    var body: some View {
        HStack(spacing: 4) {
            Label {
                Text(verbatim: node.name).lineLimit(1)
            } icon: {
                Image(systemName: node.isFolder ? "folder" : node.isSmart ? "gearshape" : "music.note.list")
            }
            if let marker = node.marker {
                Text(verbatim: marker)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            if node.entriesDiffer {
                Image(systemName: WarningMark.symbol)
                    .foregroundStyle(UIColors.warning.color)
                    .help(UsbPlaylistTree.mismatchHelp)
                    .accessibilityLabel(UsbPlaylistTree.mismatchHelp)
            }
        }
        .badge(node.isFolder ? 0 : node.count)
        .help(node.name)
    }
}
