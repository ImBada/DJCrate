# USB 라이브러리 형식과 쓰기 규칙

rekordbox 7이 USB에 내보내는 라이브러리(OneLibrary·Device Library)를 DJCrate가 읽고 쓰는 규칙이다. 로컬 rekordbox 라이브러리 쓰기는 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`의 "USB" 절을 본다.

## 0. 읽는 법·근거 표기

## 1. USB 파일 목록

## 2. OneLibrary(exportLibrary.db)

## 3. Device Library(export.pdb·exportExt.pdb)

## 4. ANLZ 변환

## 5. 경로·음원·아트워크

내보낼 곡을 USB 어디에·어떤 ID로·어떤 이름으로 둘지는 `UsbExportPlanner`(DJCDomain, 입출력 없음)가 정한다. 입력은 로컬 스냅샷 사본과 share에서 읽은 후보(`UsbExportCandidates`, share 파일은 lstat만)이고, USB에 이미 있는 것은 `UsbExistingState`로만 받는다. 실험 명령 `djc lab usb-plan`이 같은 계획을 수치로만 찍는다.

### 음원 경로

경로는 `/Contents/<아티스트>/<앨범>/<파일 이름>`(NFC)이다. 아티스트는 곡의 Artist(`djmdContent.ArtistID`)이고 앨범 아티스트가 아니다. 앨범은 `djmdAlbum.Name`.

폴더 성분(아티스트·앨범)은 이 순서로 짓는다.

1. NFC로 맞춘다. 비었거나 공백·점뿐이면 `UnknownArtist`·`UnknownAlbum`(`emptyArtistAlbum`).
2. `" * / : < > ? \ |`와 제어 문자(U+0000–U+001F, U+007F)를 `_`로 바꾼다. `:`·`/`만 확인했고, 나머지가 있었으면 `forbiddenCharacters`.
3. 끝이 `.`이면 마지막 `.` 하나를 `_`로 바꾼다.
4. 앞 48 유니코드 스칼라로 자른다(서로게이트를 가르지 않는다). 자른 성분에 보충 평면 글자가 있으면 `supplementaryCharacters`.
5. 끝의 공백과 `.`을 모두 지운다.
6. 비면 Unknown 이름.
7. 앞 공백은 그대로 두고 `leadingSpace`.

파일 이름은 `FileNameL`(NFC)에 같은 금지 글자 규칙을 쓴다. 48 스칼라 이하면 그대로 두고(줄기 끝의 공백·점도 그대로), 넘으면 확장자(마지막 `.` 뒤)를 남기고 줄기만 잘라 48에 맞춘 뒤 줄기 끝의 공백·점을 지운다(`fileNameTruncation`, 빈 줄기는 `_`). OneLibrary와 Device Library의 파일 이름은 최종 경로의 끝 성분이다.

### 같은 경로가 될 때

FAT는 대소문자와 NFC·NFD를 가리지 않으므로 이름은 `UsbLayout.collisionKey`로 비교한다.

- 폴더: 같은 부모 안에 키가 같은 폴더가 USB에 있거나 먼저 계획했으면 그 철자를 쓴다. 철자가 달랐으면 `pathCollision`.
- 파일: 같은 폴더에 키가 같은 파일이 있으면, USB의 그 파일이 같은 내용(크기·SHA-256)이면 다시 쓰지 않고(`reuse`) USB에 있는 철자로 가리킨다(철자가 다르면 `pathCollision`). 다르면 줄기에 ` (2)`, ` (3)` … ` (99)`를 붙인다(48 스칼라 안으로 줄기를 더 자름, `pathCollision`. 확장자가 길어 줄기를 남길 수 없으면 이름 전체를 줄기로 보고 자른다). 99까지 다 차면 그 곡을 막는다. 같은 음원 파일을 가리키는 두 곡은 한 파일을 함께 쓴다.
- Device Library 문자열 규칙(`pdbLongAscii`)은 번호를 붙인 뒤의 경로·파일 이름과 자르지 않은 아티스트·앨범 이름으로 판정한다.

### 분석 파일(ANLZ) 자리

- 새 곡의 `PIONEER/USBANLZ/` 아래 폴더 이름은 DJCrate 고유 이름(시험용)이다: content ID로 `P%03X/%08X`(`analysisFolderNaming`). rekordbox의 폴더 이름 규칙을 따르지 않는다.
- 기존 곡은 USB DB에 적힌 분석 경로를 그대로 쓴다.
- 폴더 안 파일 번호(`ANLZ%04X`): 같은 곡 경로(PPTH)의 파일이 있으면 그 번호를 다시 쓰고, 다른 곡의 파일이 있으면 덮어쓰지 않고 가장 작은 빈 번호를 쓴다. 번호가 0이 아니면 `analysisSlotCollision`.

### 아트워크

- 원본: 로컬 `ImagePath`(share 기준 `…/artwork.jpg`)와 같은 폴더의 `artwork_s.jpg`(작은 그림) → `a{id}.jpg`·`b{id}.jpg`, `artwork_m.jpg`(중간) → `a{id}_m.jpg`·`b{id}_m.jpg`. 바이트를 그대로 복사하고 `artwork.jpg`는 쓰지 않는다. Device Library는 `a`, OneLibrary는 `b` 경로를 가리킨다.
- image ID는 그림 있는 곡마다 새로 준다(같은 그림도 합치지 않음). 그림 없는 곡은 `artworkMissing`, `ImagePath`는 있는데 그림 파일이 없으면 그림 없이 내보내며 경고(`artworkMissingFile`)를 낸다.
- 폴더는 `PIONEER/Artwork/%05d/`(1부터). 폴더 안 합(a·b·a_m·b_m)이 1,000,000바이트를 넘게 되면 다음 폴더로 간다. 빈 폴더에는 크기와 상관없이 넣는다. [추정] 나누는 기준은 관찰에서 추정했다 — 두 폴더 이상 쓰면 `artworkFolderSplit`.

### ID

- 새 USB: content는 내보낸 순서대로 1..N, image는 그림 있는 곡 순서, 재생 목록은 트리 순서(깊이 우선, Seq 순). 막힌 곡·목록은 ID를 받지 않는다.
- 기존 USB: 산 행·죽은 행·기기 기록이 가리키는 ID·저널 highWater 중 가장 큰 값 다음(`UsbIDAllocator`). 지운 ID는 다시 쓰지 않는다.
- 같은 부모 안 목록 순번은 기존 형제의 가장 큰 순번 다음, 형제가 없으면 0부터(`playlistSiblingBase`).

### 용량

새 파일 = 클러스터 크기로 올려 센 음원(새로 쓰는 것만)·분석 파일 셋·아트워크 넷·DB 어림(파일마다 곡당 4 KiB + 64 KiB). 임시 = 가장 큰 DB × 2(바꾸는 동안 옛 파일과 함께 있음). 여유 = max(64 MiB, 가용 용량의 1%).

### 막힘

곡 단위(`UsbBlock.scope = .track`)로 막힌 곡은 계획에서 빠지고, 그 곡이 든 목록에서도 빠진다.

| code | 조건 |
|---|---|
| `streaming` | 스트리밍 곡(`FolderPath`가 `/`로 시작하지 않음) |
| `audioMissing` | 음원 경로가 없거나 파일이 없음 |
| `fileTypeUnknown` | 음원 형식 번호를 모름 |
| `fileTooLarge` | 음원이 4 GiB 이상(FAT32 한계) |
| `audioSizeMismatch` | 음원 크기가 rekordbox가 적은 `FileSize`와 다름(분석 뒤 파일이 바뀜) |
| `analysisIncomplete` | 로컬 분석 파일 셋(`.DAT`·`.EXT`·`.2EX`)이 다 없음 |
| `analysisNewerThanSnapshot` | 로컬 분석 파일이 스냅샷 사본을 뜬 뒤에 바뀜 |
| `pathCollisionExhausted` | 같은 이름이 ` (99)`까지 다 참 |
| `namingUnavailable` | 분석 파일 폴더 이름을 지을 수 없음 |
| `smartPlaylist` | 스마트(인텔리전트) 재생 목록(목록 단위, 그 곡은 다른 목록·곡 선택대로 간다) |
| `directoryEntryLimit` | 한 폴더 항목 수 어림(짧은 이름 1 + 긴 이름 UTF-16 13단위마다 1)이 60,000을 넘음(볼륨 단위) |

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
