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
    case sharedRowDiffers(table: String, id: Int)

    /// 곡이 한 형식에만 있거나 같은 id가 다른 파일을 가리키면, 고쳐 쓸 때 한쪽 곡을 잃을 수 있어 편집을 막는다.
    public var blocksEditing: Bool {
        switch self {
        case .trackOnlyIn, .trackPathDiffers: true
        default: false
        }
    }
}
