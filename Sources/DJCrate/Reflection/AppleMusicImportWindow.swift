import AppKit
import AVFoundation
import DJCDomain
import DJCStorage
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppleMusicImportWindow: NSObject, NSWindowDelegate {
    static let shared = AppleMusicImportWindow()
    private var window: NSWindow?
    private var model: AppleMusicImportModel?

    func open(store: LibraryStore) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let model = AppleMusicImportModel(store: store)
        let window = NSWindow(contentViewController: NSHostingController(rootView: AppleMusicImportView(model: model)))
        window.title = String(localized: "Apple Music XML 가져오기")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 820, height: 600))
        window.contentMinSize = NSSize(width: 680, height: 480)
        window.center()
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.isBusy != true }
}

@MainActor
@Observable
final class AppleMusicImportModel {
    let store: LibraryStore
    var library: AppleMusicLibrary?
    var selected = Set<Int>()
    var playlistID = ""
    var isBusy = false
    var message: String?

    init(store: LibraryStore) { self.store = store }

    var visibleTracks: [AppleMusicLibrary.Track] {
        guard let library else { return [] }
        guard let playlist = library.playlists.first(where: { $0.id == playlistID }) else { return library.tracks }
        let byID = Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0) })
        // 같은 곡이 여러 번 들어 있어도 선택 줄은 한 번만 보여 준다. 출처에는 원래 순서를 모두 보관한다.
        var seen = Set<Int>()
        return playlist.trackIDs.compactMap { seen.insert($0).inserted ? byID[$0] : nil }
    }

    var selectedTracks: [AppleMusicLibrary.Track] { library?.selectedTracks(trackIDs: selected) ?? [] }

    func chooseXML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.prompt = String(localized: "보관함 열기")
        panel.message = String(localized: "Music 또는 iTunes에서 내보낸 보관함·재생 목록 XML을 고르세요.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    func load(_ url: URL) async {
        isBusy = true
        message = nil
        library = nil
        selected = []
        playlistID = ""
        defer { isBusy = false }
        do {
            let library = try await Task.detached(priority: .userInitiated) {
                try AppleMusicLibrary.parse(Data(contentsOf: url))
            }.value
            self.library = library
        } catch {
            message = String(localized: "XML을 열지 못했습니다. Music에서 보관함을 XML로 다시 내보내고 파일 접근 권한을 확인하세요.")
        }
    }

    func selectVisible(_ select: Bool) {
        let ids = Set(visibleTracks.filter { $0.exclusion == nil }.map(\.id))
        if select { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    func addSelected() async {
        guard !isBusy, store.writeLockPolicy.allowsLibraryInteraction, let library else { return }
        let candidates = selectedTracks
        guard !candidates.isEmpty else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        var urls: [URL] = []
        var origins: [String: [AppleMusicOrigin]] = [:]
        var rejected = 0
        for track in candidates {
            guard let url = track.fileURL else { continue }
            var reason: AppleMusicLibrary.Exclusion?
            // XML을 내보낸 뒤 파일이 바뀌었거나 보호 표시가 빠진 경우도 실제 파일에서 막는다.
            if !AppleMusicLibrary.isReadableFile(url) {
                reason = .unavailableFile
            } else {
                do {
                    if try await AVURLAsset(url: url).load(.hasProtectedContent) { reason = .protectedContent }
                } catch { reason = .unavailableFile }
            }
            if let reason {
                if let index = self.library?.tracks.firstIndex(where: { $0.id == track.id }) {
                    self.library?.tracks[index].exclusion = reason
                }
                selected.remove(track.id)
                rejected += 1
                continue
            }
            urls.append(url)
            origins[url.path.precomposedStringWithCanonicalMapping, default: []].append(library.origin(for: track.id))
        }
        // 파일 검사 중 시작된 반영과 곡 추가가 겹치지 않게 다시 확인한다.
        guard store.writeLockPolicy.allowsLibraryInteraction else {
            message = String(localized: "rekordbox 반영이 끝난 뒤 선택한 곡을 다시 추가하세요.")
            return
        }
        if !urls.isEmpty {
            await store.addFiles(urls, appleMusicOrigins: origins)
            message = store.stagingMessage?.text
        }
        if rejected > 0 {
            let warning = String(localized: "\(rejected)곡은 파일을 확인하지 못해 제외했습니다. 각 곡의 안내를 확인하세요.")
            message = [message, warning].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

private struct AppleMusicImportView: View {
    @Bindable var model: AppleMusicImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Music의 파일 › 보관함 › 보관함 내보내기에서 XML을 저장하세요. 재생 목록 내보내기에서 XML을 골라도 됩니다."))
            Text(String(localized: "로컬 음원만 ‘추가한 곡’에 넣습니다. 재생 목록은 원래 소속과 순서만 기억하며 rekordbox에 만들지는 않습니다."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "XML 파일 선택…")) { model.chooseXML() }
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Text(String(localized: "선택한 곡 \(model.selectedTracks.count)개"))
            }
            if let library = model.library {
                Picker(String(localized: "재생 목록"), selection: $model.playlistID) {
                    Text(String(localized: "보관함 전체")).tag("")
                    ForEach(library.playlists) { playlist in
                        Text(playlist.name).tag(playlist.id)
                    }
                }
                HStack {
                    Button(String(localized: "표시한 곡 선택")) { model.selectVisible(true) }
                    Button(String(localized: "표시한 곡 해제")) { model.selectVisible(false) }
                    Spacer()
                    Text(String(localized: "제외된 곡 \(model.visibleTracks.filter { $0.exclusion != nil }.count)개"))
                        .foregroundStyle(.secondary)
                }
                List(model.visibleTracks) { track in
                    Toggle(isOn: Binding(get: { model.selected.contains(track.id) }, set: {
                        if $0 { model.selected.insert(track.id) } else { model.selected.remove(track.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                            if !track.artist.isEmpty { Text(track.artist).font(.caption).foregroundStyle(.secondary) }
                            if let reason = track.exclusion {
                                Text(reason.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(track.exclusion != nil)
                }
            } else {
                Spacer()
                Text(String(localized: "XML을 열면 곡과 재생 목록을 고를 수 있습니다."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
            if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(String(localized: "선택한 곡 추가")) { Task { await model.addSelected() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedTracks.isEmpty || !model.store.writeLockPolicy.allowsLibraryInteraction)
            }
        }
        .padding(20)
        .disabled(model.isBusy)
    }
}
