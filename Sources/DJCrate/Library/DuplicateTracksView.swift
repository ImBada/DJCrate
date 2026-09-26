import DJCStorage
import SwiftUI

/// 기존 곡 표의 열·정렬 설정을 바꾸지 않고 후보끼리 비교한다.
struct DuplicateTracksView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("제목·아티스트 같음 · 길이 차이 2초 이내 · 버전 표기 구분")
                .font(.callout).padding(.horizontal, 12).padding(.top, 8)
            Text("스냅샷 기준 · 후보가 같은 음원인지는 직접 확인하세요 · 한 곡이 여러 묶음에 나올 수 있습니다")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            if store.displayDuplicateGroups.isEmpty {
                ContentUnavailableView("중복 후보가 없습니다", systemImage: "square.on.square",
                                       description: Text(store.search.isEmpty ? "현재 스냅샷에서 조건이 맞는 곡이 없습니다" : "검색어를 지우고 다시 확인하세요"))
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            columns(title: "곡 · 파일 경로", length: "길이", cues: "큐", playlists: "재생 목록",
                                    plays: "재생 횟수", format: "형식", bitrate: "비트레이트")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 6)
                            List(selection: $store.selection) {
                                ForEach(store.displayDuplicateGroups) { group in
                                    Section {
                                        ForEach(group.tracks) { member in
                                            candidate(member).tag(member.id)
                                        }
                                    } header: {
                                        Text("\(group.tracks.first?.track.title ?? "") · \(group.tracks.count)곡")
                                    }
                                }
                            }
                            .listStyle(.inset)
                        }
                        .frame(width: max(900, geometry.size.width), height: geometry.size.height)
                    }
                }
            }
        }
        .disabled(!store.writeLockPolicy.allowsLibraryInteraction)
        .navigationTitle(store.sidebarTitle)
        .navigationSubtitle("\(store.displayDuplicateGroups.count)묶음 · \(store.displayRows.count)곡")
    }

    private func candidate(_ member: LibraryRead.DuplicateMember) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            columns(title: member.track.title, length: "\(member.track.lengthSeconds)초", cues: "\(member.cueCount)",
                    playlists: "\(member.playlistCount)", plays: "\(member.playCount)", format: member.format,
                    bitrate: member.bitrateKbps.map { "\($0) kbps" } ?? "알 수 없음")
            HStack {
                Text(member.track.artist ?? "").lineLimit(1)
                Text("수동 큐 \(member.manualCueCount) · 자동 큐 \(member.cueCount - member.manualCueCount)")
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(member.track.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(member.track.path)
        }
        .padding(.vertical, 3)
    }

    private func columns(title: String, length: String, cues: String, playlists: String,
                         plays: String, format: String, bitrate: String) -> some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(length).frame(width: 60, alignment: .trailing)
            Text(cues).frame(width: 40, alignment: .trailing)
            Text(playlists).frame(width: 65, alignment: .trailing)
            Text(plays).frame(width: 65, alignment: .trailing)
            Text(format).frame(width: 60, alignment: .leading)
            Text(bitrate).frame(width: 100, alignment: .trailing)
        }
        .monospacedDigit()
    }
}
