# USB 라이브러리 형식과 쓰기 규칙

rekordbox 7이 USB에 내보내는 라이브러리(OneLibrary·Device Library)를 DJCrate가 읽고 쓰는 규칙이다. 로컬 rekordbox 라이브러리 쓰기는 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`의 "USB" 절을 본다.

## 0. 읽는 법·근거 표기

## 1. USB 파일 목록

## 2. OneLibrary(exportLibrary.db)

## 3. Device Library(export.pdb·exportExt.pdb)

## 4. ANLZ 변환

## 5. 경로·음원·아트워크

## 6. 설정 파일

USB `PIONEER/`의 `MYSETTING.DAT`·`MYSETTING2.DAT`·`DJMMYSETTING.DAT`는 기기(CDJ·DJM) 설정이다. rekordbox 내보내기는 로컬 rekordbox 설정 폴더의 같은 이름 파일을 옮겨 쓴다. 근거는 rekordbox 7.2.18 내보내기(2026-09-26) 관찰, 칸 뜻은 이슈 #45.

모양(리틀엔디언):

| 위치 | 칸 | MYSETTING·MYSETTING2 | DJMMYSETTING | DEVSETTING |
|---|---|---|---|---|
| 0x00 | 문자열 길이 u32 | 0x60 | 0x60 | 0x60 |
| 0x04 | 제조사 32바이트 | `PIONEER` | `PioneerDJ` | `PIONEER DJ` |
| 0x24 | 소프트웨어 32바이트 | `rekordbox` | `rekordbox` | `rekordbox` |
| 0x44 | 버전 32바이트 | `0.001` | `1.000` | 앱 버전 |
| 0x64 | 본문 길이 u32 | 40 | 52 | 32 |
| 0x68 | 본문 | MYSETTING은 `78 56 34 12 02 00 00 00`로 시작, MYSETTING2는 머리 표지 없음 | `78 56 34 12 01 00 00 00 20 00 00 00`로 시작 | `78 56 34 12 01 00 00 00`로 시작 |
| 끝−4 | CRC u16 | CRC-16/XMODEM(다항식 0x1021, 초깃값 0) | 같음 | 같음 |
| 끝−2 | u16 | 0 | 0 | 0 |
| CRC 범위 | | 본문(0x68 ~ 끝−4) | **파일 처음** ~ 끝−4 | 본문 |
| 크기 | | 148 | 160 | 140 |

뜻을 아는 칸(1바이트):

| 파일 | 위치 | 칸 |
|---|---|---|
| MYSETTING | 0x72 | quantize |
| MYSETTING | 0x80 | quantize beat value(0x80 1박 … 0x83 1/8박) |
| MYSETTING | 0x81 | hot cue auto load |
| MYSETTING2 | 0x74 | beat jump beat value |
| MYSETTING2 | 0x6D–0x6E | 뜻 모르는 새 칸. rekordbox 7.2.18 내보내기는 `80 80`, 옛 버전이 쓴 로컬 파일은 `00 00` |
| DJMMYSETTING | 0x78 | beat FX quantize |

규칙:

- 읽기 검증(`DeviceSettingFile`): 문자열 길이 = 0x60, 본문 길이 = 파일 크기 − 0x68 − 4, 크기가 종류별 값, 종류별 범위의 CRC 일치, 끝 2바이트 0. 하나라도 어긋나면 그 파일은 만들지 않는다.
- 고치기(`DeviceSettingPatch`): 구조체로 다시 만들지 않는다(모르는 칸이 0으로 지워진다). 읽은 바이트를 그대로 옮기고 아는 칸 바이트와 CRC만 덮은 뒤, 다시 읽어 검증한다.
- 내보내기용(`DeviceSettingPatch.forExport`): 머리 문자열·길이·본문은 그대로, MYSETTING2의 0x6D·0x6E가 둘 다 0이면 둘 다 0x80으로 채우고 CRC를 다시 계산한다(둘 다 0x80이면 그대로). 한쪽만 0이거나 다른 값이면 rekordbox가 쓴 적을 보지 못한 모양이라 그 파일을 만들지 않는다. 그 밖의 파일은 바이트가 바뀌지 않는다.
- 로컬 설정 폴더는 읽기만 하고, 세 파일 이름만 연다(폴더를 훑지 않는다).
- 첫 판 USB 내보내기는 설정 파일을 만들지 않는다. 이 코드는 선택으로 켜는 설정 옮기기용이다(기본 꺼짐). `DEVSETTING.DAT`(rekordbox 내보내기도 만들지 않음)·`djprofile.nxs`는 만들지 않는다.
- 실험: `djc lab setting-check <PIONEER 폴더>`(크기·길이·CRC 확인), `djc lab setting-export --local <로컬 설정 폴더> --out <빈 폴더>`(내보내기 모양으로 옮기기, 하나라도 만들지 못하면 실패로 끝남). USB 폴더와 출력 폴더는 임시 폴더 아래만 받는다.

## 7. 쓰기 절차

## 8. USB 안 수정

## 9. 확인 안 된 규칙

| 규칙 | 지금 값 | 표시 조건 |
|---|---|---|
| `physicalVolume` | 확인 안 됨(관문으로만 풂) | 대상이 디스크 이미지가 아닌 실물 USB |
| `analysisFolderNaming` | 확인 안 됨 | 분석 파일을 USB에 새로 쓸 때 |
| `analysisSlotCollision` | 확인 안 됨 | 새 분석 파일 폴더 이름이 이미 있는 폴더와 겹칠 때 |
| `playlistSiblingBase` | 확인 안 됨 | 재생 목록을 쓸 때(같은 폴더 안 순서 번호) |
| `playlistFolderRow` | 확인 안 됨 | 재생 목록 폴더를 쓸 때 |
| `myTagLinks` | 확인 안 됨 | My Tag가 붙은 곡을 쓸 때 |
| `myTagMasterDBID` | 확인 안 됨 | My Tag를 쓸 때 |
| `artworkFolderSplit` | 확인 안 됨 | 아트워크를 여러 폴더로 나눠야 할 때 |
| `artworkMissing` | 확인 안 됨 | 아트워크가 없는 곡을 쓸 때 |
| `fileNameTruncation` | 확인 안 됨 | 음원 파일 이름을 줄여야 할 때 |
| `forbiddenCharacters` | 확인 안 됨 | 이름에 FAT에서 쓸 수 없는 글자가 있을 때 |
| `pathCollision` | 확인 안 됨 | 두 곡이 USB에서 같은 경로(대소문자·NFC/NFD 무시)가 될 때 |
| `emptyArtistAlbum` | 확인 안 됨 | 아티스트나 앨범이 빈 곡 |
| `supplementaryCharacters` | 확인 안 됨 | 이름에 이모지 등 보충 평면 글자가 있을 때 |
| `leadingSpace` | 확인 안 됨 | 이름이 빈칸으로 시작할 때 |
| `cueSeekFields` | 확인 안 됨 | 큐가 있는 곡의 음원 형식이 MP3(MPEG 프레임 칸 0)·M4A·FLAC가 아닐 때 |
| `cueVariant` | 확인 안 됨 | 색 핫큐, 색 메모리 큐, 메모리 루프, 활성 루프, 박 루프가 아닌 루프, 8·16박이 아닌 박 루프, 핫큐 D·F·G·H |
| `fileTypeUnverified` | 확인 안 됨 | 확인하지 않은 음원 형식의 곡 |
| `metadataSeenEmptyOnly` | 확인 안 됨 | 빈 값으로만 본 곡 정보 칸에 값이 있을 때 |
| `pdbLongAscii` | 확인 안 됨 | Device Library에 긴 ASCII 문자열을 쓸 때 |
| `pdbFarOffsetRows` | 확인 안 됨 | Device Library 행의 문자열이 행 머리에서 먼 곳에 놓일 때 |
| `carriedDeviceRows` | 확인 안 됨(디스크 이미지에도 막음) | USB에 기기가 남긴 기록 행이 있을 때 |
| `settingFiles` | 확인 안 됨 | 기기 설정 파일을 쓸 때 |
| `pdbRegeneratedEdit` | 확인 안 됨 | USB를 고치며 Device Library를 다시 만들 때 |
| `trackRemovalFiles` | 확인 안 됨 | USB에서 곡을 빼며 그 곡의 파일을 지울 때 |
| `editRefreshTracks` | 확인 안 됨 | USB 안 곡 정보를 갱신할 때 |
| `editRemoveTracks` | 확인 안 됨 | USB에서 곡을 뺄 때 |
| `editAddTracks` | 확인 안 됨 | 이미 내보낸 USB에 곡을 더할 때 |
| `editPlaylists` | 확인 안 됨 | 이미 내보낸 USB의 재생 목록을 고칠 때 |

## 10. 막아 둔 것

## 11. 새 USB 쓰기 경로를 여는 방법

rekordbox 실험 → 사본 재현 → 칸 단위 일치 → 골든 테스트 → `UsbProvisionalRule.confirmed`에 더함. 더한 뒤 §9 표의 지금 값을 고친다.
