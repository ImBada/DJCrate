---
paths:
  - "Sources/DJCLink/**"
  - "Sources/DJCDomain/Link/**"
  - "Sources/DJCApplication/Link/**"
  - "Sources/DJCAdapters/Link/**"
  - "Sources/DJCrate/Link/**"
  - "Tests/DJCLinkTests/**"
---

# Pro DJ Link(LINK)를 고칠 때

CDJ·DJM 네트워크 코드를 고칠 때 지키는 규칙이다. 리뷰는 규칙을 ID로 가리킨다.

## 네트워크

- **LNK-1** 장치 찾기는 알림 포트(UDP 50000)를 받기만 한다. 아무 패킷도 보내지 않는다(#272).
- **LNK-2** 알림·상태·서버(Link Export)를 보내는 일은 사용자가 LINK 단추를 눌러 막대를 펼쳤을 때만 한다(#273). 접으면 서버를 내린다.
- **LNK-3** rekordbox·rekordboxAgent가 켜져 있으면 포트를 열지 않는다. 같은 포트(UDP 50000~50002 등)를 쓴다.
- **LNK-4** 시험과 에이전트는 실제 네트워크에 Pro DJ Link 패킷을 보내지 않는다. 공연·리허설 중인 네트워크에서는 듣지도 않는다.
- **LNK-5** 시험은 소켓을 열지 않는다. 가짜 포트를 쓴다. DJLinkKit `LiveSocketFactory`는 시험 프로세스에서 소켓을 만들지 않는다.
- **LNK-6** 화면 시험·자가 테스트·측정 실행의 조립은 장치 찾기를 붙이지 않는다(`AppComposition.link`가 nil).

## 내어 주기

- **LNK-10** 내어 주는 라이브러리는 저장소가 읽은 rekordbox 컬렉션이다. 이 Mac에 파일이 없는 곡은 내어 주지 않는다(`LinkLibrary.isShareable`).
- **LNK-11** 음원·분석 파일은 읽기만 한다. Link Export의 NFS는 쓰기 요청을 거절한다. CDJ의 큐·곡 정보 편집(`Source.edit`)은 받지 않는다.
- **LNK-13** CDJ가 보낸 재생 기록(`add_to_history`)은 DJCrate에 "LINK HISTORY yyyy-MM-dd" 보존본으로만 남긴다(`LinkHistory`). LINK 동안 rekordbox 라이브러리에 쓰지 않는다. rekordbox에는 USB 기록과 같은 쓰기 대기로 올려 rekordbox에 쓰기 때 넣는다.
- **LNK-12** 실기 확인은 시험용 네트워크에서 사용자가 한다. 에이전트는 LINK 단추를 누르지 않는다.

## 경계

- **LNK-7** DJLinkKit 제품은 `DJCLink`만 import한다. 공개 API에 DJLinkKit 타입을 내지 않는다(`internal import`).
- **LNK-8** 앱·핵심부는 `DJCDomain.LinkDevice`만 쓴다. `DJCLink.LinkDevice`는 어댑터(`DJCAdapters/Link`)에서 바꾼다.

## 시험 재료

- **LNK-9** 패킷 재료는 실기 캡처 바이트에서 MAC을 가려 쓴다. IP는 링크 로컬 주소만 둔다. 장비 일련번호·개인 정보는 넣지 않는다.
