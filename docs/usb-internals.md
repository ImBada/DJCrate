# USB 라이브러리 형식과 쓰기 규칙

rekordbox 7이 USB에 내보내는 라이브러리(OneLibrary·Device Library)를 DJCrate가 읽고 쓰는 규칙이다. 로컬 rekordbox 라이브러리 쓰기는 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`의 "USB" 절을 본다.

## 0. 읽는 법·근거 표기

## 1. USB 파일 목록

## 2. OneLibrary(exportLibrary.db)

## 3. Device Library(export.pdb·exportExt.pdb)

## 4. ANLZ 변환

## 5. 경로·음원·아트워크

## 6. 설정 파일

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
