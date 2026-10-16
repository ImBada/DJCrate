internal import DJLinkKit

/// 장치 알림 포트(UDP 50000)를 열어 알림을 받기만 한다(#272). 아무 패킷도 보내지 않아 네트워크에 참여하지 않는다.
public enum LinkAnnounceListener {
    /// 장치 알림을 하나씩 흘린다. 스트림이 끝나거나(취소) 소비자가 떠나면 소켓을 닫는다. 포트를 열지 못하면 오류로 끝난다.
    /// 시험 프로세스에서는 DJLinkKit이 소켓을 만들지 않고 바로 실패한다(`LiveSocketFactory`).
    public static func devices() -> AsyncThrowingStream<LinkDevice, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let box = AnnounceSocket()
            continuation.onTermination = { _ in Task { @DJLinkActor in await box.close() } }
            Task { @DJLinkActor in
                do {
                    try await box.open(
                        onDevice: { continuation.yield($0) },
                        onError: { continuation.finish(throwing: $0) })
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// 소켓 하나와 닫힘 여부. 열기를 기다리는 사이에 스트림이 끝나면 연 뒤 바로 닫는다(포트를 붙잡아 두지 않게).
@DJLinkActor
private final class AnnounceSocket {
    private var socket: (any UDPSocket)?
    private var closed = false

    nonisolated init() {}

    func open(onDevice: @escaping @Sendable (LinkDevice) -> Void, onError: @escaping @Sendable (any Error) -> Void) async throws {
        guard !closed else { return }
        let socket = try LiveSocketFactory.shared.createUDPSocket(reuseAddr: true)
        self.socket = socket
        do {
            try await udpBind(socket, ANNOUNCE_PORT, "0.0.0.0")
        } catch {
            await close()
            throw error
        }
        if closed {
            await close()
            return
        }
        // 알림 포트에는 다른 앱의 방송도 온다. Pro DJ Link 알림이 아니면 버린다
        socket.onMessage { bytes, _ in
            if let device = LinkDevice.fromAnnouncePacket(bytes) { onDevice(device) }
        }
        socket.onError { onError($0) }
    }

    func close() async {
        closed = true
        guard let socket else { return }
        self.socket = nil
        socket.removeAllListeners()
        try? await udpClose(socket)
    }
}
