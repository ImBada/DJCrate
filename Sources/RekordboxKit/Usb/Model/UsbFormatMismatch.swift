import DJCDomain
import Foundation

/// 한 USB의 두 형식(OneLibrary·Device Library)이 서로 맞지 않는 곳
public enum UsbFormatMismatch: Sendable, Hashable {
    case trackOnlyIn(UsbFormat, id: Int)
    case trackPathDiffers(id: Int)
    case trackFieldDiffers(id: Int, field: String)
    case playlistConflict(id: Int)
    case playlistEntriesDiffer(id: Int)
    case playlistOnlyIn(UsbFormat, id: Int)
    case propertyDiffers(field: String)
    /// 같은 id 행의 두 형식 모두 칸이 다르거나, 공유 표(artist·album·menuItem 등) 행이 한 형식에만 있다
    case sharedRowDiffers(table: String, id: Int)

    /// 곡이 한 형식에만 있거나 같은 id가 다른 파일을 가리키면, 고쳐 쓸 때 한쪽 곡을 잃을 수 있어 편집을 막는다.
    /// 같은 id 목록이 형식마다 다르면(이름·부모·종류) 합친 모델에 OneLibrary 목록만 남아, 고쳐 쓰면 Device Library 목록과 항목을 잃는다.
    public var blocksEditing: Bool {
        switch self {
        case .trackOnlyIn, .trackPathDiffers, .playlistConflict: true
        default: false
        }
    }
}
