import DJCDomain
import SwiftUI

/// 목록과 태그 시트에서 곡·종류를 명시한 뒤 같은 복구 흐름으로 들어간다.
struct DraftRecoveryBar: View {
    let store: LibraryStore
    let deck: DeckModel

    var body: some View {
        let rows = store.selectedRows.filter { !store.recoveryKinds(for: $0).isEmpty }
        let deckRow = deck.row.flatMap { store.rowsByUUID[$0.track.uuid] }
        if !rows.isEmpty || deckRow.map({ !store.recoveryKinds(for: $0).isEmpty }) == true {
            HStack(spacing: 12) {
                if rows.count == 1, let row = rows.first {
                    ForEach(store.recoveryKinds(for: row), id: \.self) { kind in
                        Button(kind.recoveryButtonTitle) {
                            DraftRecoveryPanels.recover(store: store, row: row, kind: kind)
                        }
                        .accessibilityLabel(kind.recoveryButtonTitle)
                    }
                } else if !rows.isEmpty {
                    Menu(.ui("선택한 곡 현재값 가져오기…")) {
                        ForEach(rows) { row in
                            Menu(row.title) {
                                ForEach(store.recoveryKinds(for: row), id: \.self) { kind in
                                    Button(kind.label) { DraftRecoveryPanels.recover(store: store, row: row, kind: kind) }
                                }
                            }
                        }
                    }
                }
                if let row = deckRow, !rows.contains(where: { $0.track.uuid == row.track.uuid }) {
                    Menu(.ui("덱 곡 현재값 가져오기…")) {
                        ForEach(store.recoveryKinds(for: row), id: \.self) { kind in
                            Button(kind.label) { DraftRecoveryPanels.recover(store: store, row: row, kind: kind) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .disabled(store.isRecoveringDraft || store.isWritingRekordbox || !(store.allowsLibrarySync?() ?? true))
        }
    }
}
