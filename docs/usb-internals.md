# USB 라이브러리 형식과 쓰기 규칙

rekordbox 7이 USB에 내보내는 라이브러리(OneLibrary·Device Library)를 DJCrate가 읽고 쓰는 규칙이다. 로컬 rekordbox 라이브러리 쓰기는 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`의 "USB" 절을 본다.

## 0. 읽는 법·근거 표기

## 1. USB 파일 목록

## 2. OneLibrary(exportLibrary.db)

근거: rekordbox 7.2.18 골든(2026-09-26 내보내기) 관찰.

### 2.1 파일·암호

- 위치 `PIONEER/rekordbox/exportLibrary.db`. SQLCipher 4 기본값 그대로다(cipher_page_size·page_size 4096, kdf_iter 256000, PBKDF2_HMAC_SHA512, HMAC_SHA512, 평문 머리 0 — 파일 첫 16바이트가 salt, 쪽마다 예약 80바이트). 따로 cipher PRAGMA를 주지 않는다.
- 키는 64자 영숫자 **문자열 키**다(`master.db`의 16진수 키와 다르다). `RekordboxKey.oneLibrary()`가 pyrekordbox(MIT)의 상수를 `master.db` 키와 같은 방법(base85 → XOR → zlib)으로 풀고, `CipherDatabase(path:key: .passphrase(…), mode:)`가 `PRAGMA key = '<키>'`로 넣는다. 키 글자는 `[A-Za-z0-9]`만 받는다. 키는 로그·출력·시험에 쓰지 않는다.
- rekordbox가 만든 파일은 journal_mode wal(머리 18·19바이트 = 2/2), user_version 0, application_id 0, auto_vacuum 0, UTF-8이고 트리거·뷰·AUTOINCREMENT, PK 말고 제약이 없다. 기기(OPUS-QUAD)가 연 뒤에는 롤백 모드(1/1)이고 SQLite 3.33.0 도장이 찍힌다. 두 모양 모두 읽는다.

### 2.2 스키마

표 22·인덱스 4를 아래 순서로 만든다. DDL 전체는 `Tests/Support/Resources/onelibrary-7.2.18-schema.sql`(rekordbox가 만든 `sqlite_master.sql`과 글자까지 같음), 코드는 `OneLibrarySchema`(칸 표 → DDL)다. 자료형은 소문자 `integer`·`varchar`이고 `integer primary key`만 rowid 별칭이다. 철자도 그대로 둔다: album `isComplation`, cue `OutFileOffsetInBlock`.

| 표 | 칸 수 | 표 | 칸 수 |
|---|---|---|---|
| content | 46 | hotCueBankList_cue | 3 |
| genre | 2 | history | 5 |
| artist | 3 | history_content | 3 |
| album | 6 | image | 2 |
| label | 2 | cue | 22 |
| key | 2 | menuItem | 3 |
| color | 2 | category | 4 |
| playlist | 6 | sort | 5 |
| playlist_content | 3 | property | 6 |
| hotCueBankList | 6 | recommendedLike | 4 |
| myTag | 5 | myTag_content | 2 |

인덱스: `playlist_content(playlist_id)`, `myTag_content(myTag_id)`, `myTag_content(content_id)`, `hotCueBankList_cue(hotCueBankList_id)`.

### 2.3 읽기 규칙

- USB 원본은 열지 않는다. 늘 `UsbSnapshot.take`로 뜬 사본에서 읽는다.
  1. `PIONEER/rekordbox/`의 `exportLibrary.db`·`-wal`·`-shm`·`-journal`·`export.pdb`·`exportExt.pdb` 중 있는 것만 복사한다(본 DB가 없으면 사이드카는 복사하지 않음). 파일마다 복사 전후 크기·mtime이 같아야 하고(다르면 `sourceChangedDuringCopy`), 원본 크기·mtime·SHA-256을 지문(`UsbFingerprint`)에 남긴다. 링크·일반 파일이 아닌 것은 복사하지 않고 `readFailed`. 열지 않는 경로(`PIONEER/extracted`·`PIONEER/CDP`·`djprofile.nxs`)는 건드리지 않는다.
  2. `-shm` 사본은 지운다(SQLite가 WAL에서 다시 만든다).
  3. `-wal`이나 `-journal`이 있었으면 사본을 쓰기 가능하게 한 번 열어(`sqlite_master`를 읽으며 hot journal 롤백) `PRAGMA wal_checkpoint(TRUNCATE)` 뒤 닫는다. 롤백·WAL 복구는 쓰기 가능한 연결에서만 된다.
  4. 읽기 전용으로 다시 열어 `PRAGMA integrity_check` = "ok", `PRAGMA cipher_integrity_check` = 0줄이어야 한다(아니면 `readFailed`).
  5. 머리 18·19바이트는 암호화돼 직접 읽을 수 없어 `PRAGMA journal_mode`로 WAL·롤백 모양을 기록한다.
- 정수 칸은 64비트로 읽는다(My Tag ID·masterDbId·myTagMasterDBID가 2³¹을 넘을 수 있다).
- 모델에 담지 않는 표(cue·hotCueBankList·hotCueBankList_cue·recommendedLike)에 행이 있으면 표 위치와 행 수만 `unknownRows`에 남긴다(쓸 때 조용히 지우지 않게).

### 2.4 호환 검사

`OneLibraryCompatibility.check`는 표 22·인덱스 4가 정확히 있고, 표마다 칸 이름·선언 자료형·순서·기본 키, 인덱스마다 표·칸이 같고, 뷰·트리거가 없고, property가 한 행이며 `dbVersion` = "1000"이어야 통과시킨다. 아니면 `UsbError.formatUnsupported`로 읽지도 고치지도 않는다. SQLite는 `PRAGMA table_info`에서 표준 자료형 이름(integer)을 대문자로 돌려주므로 자료형은 대소문자만 빼고 비교한다.

### 2.5 칸 대응(모델 ← OneLibrary)

| 모델(`UsbTrack`) | content 칸 | 읽는 법 |
|---|---|---|
| id | content_id | |
| title / titleForSearch / subtitle | 같은 이름 | NULL → ""(titleForSearch는 nil 그대로) |
| bpmx100 / lengthSeconds / trackNo / discNo | bpmx100 / length(초) / trackNo / discNo | |
| artistID·remixerID·originalArtistID·composerID | artist_id_artist·_remixer·_originalArtist·_composer | NULL → nil |
| lyricistArtistID | artist_id_lyricist | 작사가 글자(`lyricist`)는 OneLibrary에 없어 "" |
| albumID·genreID·labelID·keyID / imageID | album_id·genre_id·label_id·key_id / image_id | NULL → nil |
| colorID | color_id | NULL → 0 |
| comment / rating / releaseYear / releaseDate / dateCreated / dateAdded | djComment / 같은 이름 | 날짜는 글자 그대로 |
| path / fileName / fileSize / fileType / bitrate / bitDepth / sampleRate / isrc | 같은 이름(sampleRate ← samplingRate) | |
| djPlayCount / hotCueAutoLoad / kuvoDeliver / kuvoDeliveryComment | djPlayCount / isHotCueAutoLoadOn(≠0) / isKuvoDeliverStatusOn(≠0) / kuvoDeliveryComment | |
| masterDbId / masterContentId | 같은 이름 | 64비트 |
| analysisDataPath / analysedBits / contentLink / hasModified | analysisDataFilePath / 같은 이름 | |
| 갱신 횟수 셋 | cueUpdateCount·analysisDataUpdateCount·informationUpdateCount | INTEGER → 10진 글자, TEXT '' → "", NULL → "" |
| deviceFields[.oneLibrary] | rating·djPlayCount·hasModified | 기기가 바꿀 수 있는 칸 |

그 밖: artist(name·nameForSearch), album(name·artist_id·image_id·isComplation·nameForSearch), genre·key·label·color(name), image(path → `oneLibraryPath`), playlist(sequenceNo → 형식별 순서, attribute, playlist_id_parent → parentID, image_id), playlist_content(sequenceNo 순 → 형식별 항목), myTag(attribute 1 = 분류, myTag_id_parent → parentID), myTag_content, menuItem(name을 감싼 U+FFFA·U+FFFB를 뗌), category·sort, property 한 행, history·history_content(sequenceNo 순).

### 2.6 두 형식 합치기·투영

- 모델(`UsbLibrary`)은 두 형식의 칸을 모두 담는다. 칸마다 그 값을 실제로 담는 형식과, 그 칸이 없는 형식의 리더가 넣는 기본값을 `UsbFieldFormats` 한 표에 둔다(예: `lyricist`·category `infoOrder`·`pdbDate`는 Device Library만, `titleForSearch`·album `imageID`·`createdDate`는 OneLibrary만).
- `UsbLibrary.merge`: 한 형식에만 있는 칸은 그 형식 값을 그대로 지킨다(다른 형식 리더의 빈 값으로 덮지 않고 비교도 하지 않음). 두 형식 모두의 칸은 OneLibrary 값이 앞서고 다르면 불일치로 보고한다. 같은 id인데 경로(NFC)가 다른 곡과 한 형식에만 있는 곡은 편집을 막는 불일치다.
- `projected(to:)`: 그 형식에 있는 곡·목록·My Tag 연결과 그 형식 몫(기록·항목·기기 칸)만 남기고, 그 형식이 담지 않는 칸은 그 형식 리더의 기본값으로 바꾼다. 불일치 없는 USB에서는 `merge(ol, dl).projected(to: .oneLibrary) == ol`이다. 쓰기·검증은 늘 형식별 투영과 비교한다(`UsbLibraryDiff`의 `formats`).
- `UsbLibraryDiff`와 `djc lab usb-diff`는 칸 이름·ID·수만 출력한다(제목·이름·경로 값은 찍지 않음).

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
