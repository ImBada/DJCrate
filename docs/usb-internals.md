# USB 라이브러리 형식과 쓰기 규칙

rekordbox 7이 USB에 내보내는 라이브러리(OneLibrary·Device Library)를 DJCrate가 읽고 쓰는 규칙이다. 로컬 rekordbox 라이브러리 쓰기는 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`의 "USB" 절을 본다.

## 0. 읽는 법·근거 표기

- 경로는 USB 루트 기준 상대 경로(`UsbLayout`, NFC)다. 칸 이름은 두 형식을 합친 모델(`UsbLibrary`)의 이름이고, 파일 안 이름이 다르면 함께 적는다.
- **근거**: 규칙은 rekordbox 화면에서 만든 결과 파일을 칸 단위로 읽어 알아낸다. rekordbox 실행 파일은 분석하지 않는다. "근거: rekordbox 7.2.18 골든(2026-09-26 내보내기) 관찰"은 rekordbox 7.2.18이 빈 USB에 내보낸 결과를 읽어 본 것이다. 코드는 골든 바이트(쪽·표·파일 덩어리)를 넣지 않고, 칸 하나의 관찰값만 근거 주석을 단 이름 붙은 상수로 둔다. 외부 자료는 `THIRD_PARTY_NOTICES.md`에 적은 것만 쓴다.
- **[추정]**: 관찰에서 추정했고 rekordbox 실험으로 아직 가르지 못한 것이다.
- **확인 안 된 규칙**(`UsbProvisionalRule`, §9): 이름이 붙은 동작은 디스크 이미지에는 쓰고 실물 USB에는 막는다. 실험으로 확인한 뒤에만 푼다(§11).
- 시험 재료는 모두 합성이다(곡 제목·경로·ID는 지어낸 값). 골든·로컬 라이브러리의 수치는 문서·시험에 적지 않는다.

## 1. USB 파일 목록

경로는 USB 루트 기준(`UsbLayout`)이다.

| 경로 | 무엇 | DJCrate |
|---|---|---|
| `PIONEER/rekordbox/exportLibrary.db` | OneLibrary(§2) | 만든다·고친다 |
| `PIONEER/rekordbox/export.pdb`·`exportExt.pdb` | Device Library(§3) | 만든다·고친다 |
| `PIONEER/USBANLZ/P???/????????/ANLZ000N.DAT`·`.EXT`·`.2EX` | 곡마다 분석 파일 셋(§4) | 만든다. 폴더 이름은 §5 "분석 파일(ANLZ) 자리" |
| `PIONEER/Artwork/%05d/a{id}.jpg`·`a{id}_m.jpg`·`b{id}.jpg`·`b{id}_m.jpg` | 아트워크(a는 Device Library, b는 OneLibrary) | 만든다(§5) |
| `Contents/…` | 음원 | 복사한다(§5) |
| `PIONEER/MYSETTING.DAT`·`MYSETTING2.DAT`·`DJMMYSETTING.DAT` | 기기 설정(§6) | 첫 판 내보내기는 만들지 않는다(선택으로 켜는 옮기기만) |
| `PIONEER/DEVSETTING.DAT` | 기기 설정 | 만들지 않는다(rekordbox 내보내기도 만들지 않음) |
| `PIONEER/rekordbox/exportLibrary.db-wal`·`-shm`·`-journal` | SQLite 사이드카 | 만들지 않는다. 읽을 때는 사본에서만 정리한다(§2.3) |
| `.djc-part-*` | DJCrate가 쓰는 도중의 임시 파일 | 쓰기가 끝나면 남지 않는다(§7) |
| `.fseventsd`·`.Spotlight-V100`·`.Trashes`·`.TemporaryItems`, `._*` | macOS가 만드는 것 | 비교·지문에서 뺀다(`systemIgnored`, AppleDouble) |
| `PIONEER/extracted/`·`PIONEER/CDP/`·`PIONEER/djprofile.nxs` | 자격 증명·프로필 | **열지 않는다**: 열거·읽기·복사·해시하지 않고, 트리 순회는 이름만 보고 건너뛴다. "있음"도 알리지 않는다(`UsbLayout.neverRead`) |

기기(CDJ·OPUS-QUAD 등)가 만드는 것: 재생 기록(OneLibrary history·history_content, Device Library 표 11·12), OneLibrary cue·recommendedLike·hotCueBankList·hotCueBankList_cue 행, 곡의 기기 칸(rating·재생 횟수·hasModified), 기기가 연 뒤의 롤백 모드 머리와 `-wal`·`-journal`. DJCrate는 이 행을 지우거나 다시 만들지 않는다(§2.10, `carriedDeviceRows`).

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

- USB 원본은 열지 않는다. 늘 `UsbSnapshot.take`로 뜬 사본에서 읽는다. 사본 폴더는 USB 밖(뿌리와 같거나 그 아래가 아님 — 링크를 풀고 장치·inode로 견줌)이고 비어 있거나 없어야 한다. 남은 `-wal`·`-shm`이 있으면 SQLite가 사본과 함께 집어 가기 때문이다.
  1. `PIONEER/rekordbox/`의 `exportLibrary.db`·`-wal`·`-shm`·`-journal`·`export.pdb`·`exportExt.pdb` 중 있는 것만 복사한다(본 DB가 없으면 사이드카는 복사하지 않음). 파일마다 복사 전후 크기·mtime이 같아야 하고(다르면 `sourceChangedDuringCopy`), 원본 크기·mtime·SHA-256을 지문(`UsbFingerprint`)에 남긴다. 링크·일반 파일이 아닌 것은 복사하지 않고 `readFailed`. 열지 않는 경로(`PIONEER/extracted`·`PIONEER/CDP`·`djprofile.nxs`)는 건드리지 않는다.
  2. `-shm` 사본은 지운다(SQLite가 WAL에서 다시 만든다).
  3. `-wal`이나 `-journal`이 있었으면 사본을 쓰기 가능하게 한 번 열어(`sqlite_master`를 읽으며 hot journal 롤백) `PRAGMA wal_checkpoint(TRUNCATE)` 뒤 닫는다. 롤백·WAL 복구는 쓰기 가능한 연결에서만 된다.
  4. 읽기 전용으로 다시 열어 `PRAGMA integrity_check` = "ok", `PRAGMA cipher_integrity_check` = 0줄이어야 한다(아니면 `readFailed`).
  5. 머리 18·19바이트는 암호화돼 직접 읽을 수 없어 `PRAGMA journal_mode`로 WAL·롤백 모양을 기록한다.
  - 어느 단계에서 멈춰도 뜬 사본과, 사본을 연 SQLite가 만든 사이드카를 지운다.
- 쓰기 가능한 연결로 여는 정리(3)는 방금 만든 사본에만 한다. 파일 하나를 사본으로 떠야 하는 실험 명령(`djc lab onelib-sql`)은 `UsbSnapshot.copyDatabase`로 db·`-wal`·`-journal`을 새 파일로 복사한 뒤 그 사본만 정리한다.
- 정수 칸은 64비트로 읽는다(My Tag ID·masterDbId·myTagMasterDBID가 2³¹을 넘을 수 있다).
- 모델에 담지 않는 표(cue·hotCueBankList·hotCueBankList_cue·recommendedLike)에 행이 있으면 표 위치와 행 수만 `unknownRows`에 남긴다(쓸 때 조용히 지우지 않게).

### 2.4 호환 검사

`OneLibraryCompatibility.check`는 표 22·인덱스 4가 정확히 있고, 표마다 칸 이름·선언 자료형·순서·기본 키, 인덱스마다 표·칸이 같고, 뷰·트리거가 없고, property가 한 행이며 `dbVersion` = "1000"이어야 통과시킨다. 아니면 `UsbError.formatUnsupported`로 읽지도 고치지도 않는다. SQLite는 `PRAGMA table_info`에서 표준 자료형 이름(integer)을 대문자로 돌려주므로 자료형은 대소문자만 빼고 비교한다.

기본 키 말고 제약은 없어야 한다. `table_info`의 NOT NULL·기본값이 비어 있어야 하고, `table_info`에 드러나지 않는 제약(CHECK·AUTOINCREMENT 등)은 `sqlite_master.sql`을 스키마 문장과 견줘(대소문자·빈칸 차이만 뺌) 본다. `sqlite_sequence`(AUTOINCREMENT)·`sqlite_autoindex_…`(UNIQUE 등)는 모르는 표·인덱스로 거부하고, ANALYZE 통계 표(`sqlite_stat…`)만 넘긴다.

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
- 같은 id 목록의 이름·부모·종류가 형식마다 다르면(`playlistConflict`) 합친 모델에는 OneLibrary 목록만 남는다. 그대로 고쳐 쓰면 Device Library 쪽 목록과 항목을 잃으므로 이것도 편집을 막는다.
- artist·album·genre·key·label·color·image·My Tag·menuItem·category·sort 행에는 형식별 소속이 없어 투영이 거를 수 없다. 한 형식에만 있는 행은 합집합에 두되 `sharedRowDiffers`로 보고한다(편집은 막지 않음).
- `projected(to:)`: 그 형식에 있는 곡·목록·My Tag 연결과 그 형식 몫(기록·항목·기기 칸)만 남기고, 그 형식이 담지 않는 칸은 그 형식 리더의 기본값으로 바꾼다. 불일치 없는 USB(위 보고가 하나도 없음)에서는 `merge(ol, dl).projected(to: .oneLibrary) == ol`이다. 쓰기·검증은 늘 형식별 투영과 비교한다(`UsbLibraryDiff`의 `formats`).
- `UsbLibraryDiff`와 `djc lab usb-diff`는 칸 이름·ID·수만 출력한다(제목·이름·경로 값은 찍지 않음). ID를 무시하고 견줄 때 이름(경로)이 같은 행이 여럿이면 나온 순서대로 짝짓는다.

### 2.7 쓰기: 로컬 → 목표 모델(`UsbLibraryBuilder`)

로컬 스냅샷 사본(`UsbLocalSource`, 라이브 master.db를 연 연결이면 읽지 않음)과 내보내기 계획(§5)으로 목표 모델과 파일 작업 목록을 만든다. 파일은 옮기지 않는다(음원·아트워크 복사, 분석 파일 변환은 쓰기 단계 몫).

- 파일 작업: 새로 쓰는 음원(계획이 `create`인 것만 — 같은 음원을 함께 쓰는 곡과 USB에 이미 있는 음원은 빼고), 아트워크(`artwork_s.jpg` → `a{id}.jpg`·`b{id}.jpg`, `artwork_m.jpg` → `a{id}_m.jpg`·`b{id}_m.jpg`. Device Library를 쓸 때만 `a`, OneLibrary를 쓸 때만 `b`), 분석 파일(로컬 `.DAT`·`.EXT`·`.2EX` → 계획의 `.DAT` 경로). 목적지는 USB 루트 기준 상대 경로다.
- ID
  - content·image·재생 목록은 계획 값이다(§5 ID).
  - artist: 곡을 content ID 순서로 돌며 곡마다 곡 아티스트 → 앨범 아티스트 → 작곡가 → 리믹서 → 원곡자 순서로, 처음 나올 때 새 번호를 준다. 같은 로컬 아티스트 ID는 같은 USB 번호를 받는다([추정] 로컬 ID로만 합친다 — 이름이 같은 다른 로컬 행은 따로 둔다. 리믹서·원곡자의 순서는 값이 있는 곡을 보지 못했다).
  - album·genre·key·label: 곡 순서대로 처음 나올 때 새 번호(label은 [추정] genre와 같은 방식).
  - color·menuItem·category·sort·My Tag: 로컬 ID 그대로.
  - 로컬 ID가 비었거나 조인할 이름 행이 없으면 참조 칸은 NULL이다. 곡이 쓰지 않는 artist·album·genre·key·label 행은 넣지 않는다. color는 로컬 색을 모두 넣는다.
- 표별 행(새 USB)

| 표 | 행 | 값 |
|---|---|---|
| content | 곡마다 | §2.8 |
| genre·key·label | 쓰인 것 | name = djmdGenre.Name·djmdKey.ScaleName·djmdLabel.Name |
| artist | 쓰인 것 | name = djmdArtist.Name, nameForSearch NULL |
| album | 쓰인 것 | name, artist_id = AlbumArtistID의 USB 번호(NULL·빈 글자 → NULL), image_id NULL, isComplation = Compilation, nameForSearch NULL |
| color | 로컬 지우지 않은 색 모두 | color_id = ID, name = Commnt |
| image | 그림 있는 곡마다 | path = `/PIONEER/Artwork/%05d/b{id}.jpg` |
| playlist | 계획 목록·폴더 | sequenceNo = 계획의 형제 순번, image_id NULL, attribute 0 목록·1 폴더, playlist_id_parent(맨 위 0) |
| playlist_content | 목록 항목 | (playlist_id, content_id, sequenceNo 1..N). 목록 id 순, 순번 순으로 넣는다(PK 없는 표라 넣는 순서가 rowid) |
| myTag | 로컬 지우지 않은 행 모두 | myTag_id = ID(64비트), sequenceNo = Seq − 1, attribute 1 분류·0 태그, myTag_id_parent(root → 0). 곡에 안 쓰인 태그도 넣는다 |
| myTag_content | 0 | 쓰지 않는다(`myTagLinks`) |
| menuItem | 로컬 모두 | kind = Class + 256, name = U+FFFA + Name + U+FFFB |
| category | 로컬 지우지 않은 행 | sequenceNo = Seq, isVisible = Disable ≠ 1. InfoOrder·Disable은 Device Library 몫으로 모델에만 둔다 |
| sort | 로컬 지우지 않은 행 | sequenceNo = Seq, isVisible = Disable ≠ 1, isSelectedAsSubColumn = Disable = 2 |
| property | 1 | deviceName '', dbVersion '1000', numberOfContents = OneLibrary에 있는 곡 수(Device Library에만 있는 곡은 세지 않음), createdDate = 오늘(YYYY-MM-DD), backGroundColorType 0, myTagMasterDBID = 1 … 2³¹−1 난수(`myTagMasterDBID`) |
| cue·history·history_content·recommendedLike·hotCueBankList·hotCueBankList_cue | 0 | 로컬에 자료가 있어도 비운다(큐는 분석 파일에만) |

### 2.8 content 칸(로컬 `djmdContent` = c)

| 칸 | 값 |
|---|---|
| content_id | 계획 ID |
| title·subtitle·djComment(c.Commnt)·releaseDate·dateCreated·dateAdded(c.StockDate)·isrc·kuvoDeliveryComment(c.DeliveryComment) | 로컬 글자 그대로, NULL → '' |
| titleForSearch | NULL |
| bpmx100·length·trackNo·discNo·rating·releaseYear·fileSize·fileType·bitrate·bitDepth·samplingRate·djPlayCount·analysedBits | c.BPM(이미 ×100)·Length(초)·TrackNo·DiscNo·Rating·ReleaseYear·FileSize·FileType·BitRate·BitDepth·SampleRate·DJPlayCount·Analysed, NULL → 0 |
| artist_id_artist·_remixer·_originalArtist·_composer | 로컬 아티스트의 USB 번호, 없으면 NULL |
| artist_id_lyricist | 0(작사가는 로컬에 글자로만 있다. 값이 있으면 `metadataSeenEmptyOnly`) |
| album_id·genre_id·label_id·key_id | 로컬 행의 USB 번호, 없으면 NULL |
| color_id | CAST(c.ColorID AS INTEGER), NULL → 0 |
| image_id | 계획 image ID, 그림 없으면 NULL(`artworkMissing`) |
| path·fileName | 계획 경로(NFC)와 그 끝 성분 |
| isHotCueAutoLoadOn·isKuvoDeliverStatusOn | c.HotCueAutoLoad·c.DeliveryControl이 'on'(대소문자 무시)이면 1, 아니면 0 |
| masterDbId·masterContentId | CAST(c.MasterDBID·c.MasterSongID AS INTEGER) |
| analysisDataFilePath | 계획 분석 경로 |
| contentLink | 0x0C0700 \| (c.ContentLink & 0x100000). 0x100000은 로컬 `.2EX`에 PVDI가 있다는 뜻 |
| hasModified | 0 |
| cueUpdateCount·analysisDataUpdateCount·informationUpdateCount | c.CueUpdated·AnalysisUpdated·TrackInfoUpdated를 TEXT로 넣는다(NULL → ''). INTEGER 친화성 때문에 숫자 글자는 INTEGER, ''는 TEXT로 남는다 |

- 글자 칸은 늘 TEXT(빈 글자 포함)이고, 없을 수 있는 정수 칸(참조·image_id)만 NULL이 된다. NFC로 맞추는 것은 path·fileName뿐이다.
- 모델에는 Device Library용 칸도 채운다: `lyricist` = c.Lyricist, 형식별 기기 칸(rating·재생 횟수, OneLibrary만 hasModified 0).

### 2.9 새 파일 만들기(`OneLibraryWriter.create`)

Mac 준비 폴더에 새 `exportLibrary.db`를 만든다. 파일이나 사이드카가 이미 있으면 만들지 않는다. 모델의 OneLibrary 투영만 쓰고, 기기 기록이나 모델에 담지 않는 표의 행이 든 모델은 다시 만들 수 없어 막는다(`carriedDeviceRows`).

1. 문자열 키로 새 파일을 연다(다른 cipher PRAGMA 없음).
2. 표를 만들기 **전에** `PRAGMA journal_mode=WAL`(파일 머리가 WAL 모양이 된다).
3. `BEGIN` → 스키마 26문장(§2.2 순서) → 행 → `COMMIT`. `integer primary key` 표는 id 순서로 넣어 rowid = id가 된다.
4. `PRAGMA wal_checkpoint(TRUNCATE)` = (0, 0, 0), integrity ok, cipher_integrity_check 0줄 → 닫기 → `-wal`·`-shm`이 없어야 한다.
5. 다시 열어 확인(`verify`): 사이드카 없음, 호환 검사(§2.4), integrity, 다시 읽은 모델 = 모델의 OneLibrary 투영(OneLibrary 칸만 비교). 실패하면 만든 파일을 지운다. 사이드카가 있으면 DB를 열지 않고 그것만 보고한다(열면 닫을 때 SQLite가 남은 `-wal`을 본 파일에 합치고 지워, 확인할 파일과 증거가 바뀐다).

- 기기(SQLite 3.33)에 없는 기능(STRICT·생성 칸 등)을 쓰지 않는다. sqlite_master rowid·schema cookie·change counter·SQLite 버전 도장은 맞추지 않는다.
- 읽기 전용 연결은 WAL 모양 파일 옆에 `-wal`·`-shm`을 남긴다. 확인은 쓰기 가능하게 열고 `query_only`로 막아, 닫을 때 SQLite가 치우게 한다.

### 2.10 USB 사본 고치기(`OneLibraryWriter.apply`)

USB DB **사본**(`UsbSnapshot`으로 병합 끝난 것)에 편집 단계마다 차이만 SQL로 적용한다. 받는 모델은 두 형식을 합친 모델이어도 된다.

1. 쓰기 가능하게 열어 호환 검사 → `BEGIN IMMEDIATE`. 받아들인 모델 = 지금 모델.
2. 단계마다 `SAVEPOINT` → 편집을 적용한 모델을 다듬고(아래) → 받아들인 모델과의 OneLibrary 차이를 SQL로 → 성공하면 `RELEASE`하고 받아들인다. 모델 적용이나 SQL이 실패하면 `ROLLBACK TO`·`RELEASE`하고 그 편집만 건너뛴다(이유는 기술 정보로 남긴다). 다음 편집은 건너뛴 편집이 빠진 모델 위에 적용된다.
3. 같은 연결로 다시 읽어 **받아들인 모델의 OneLibrary 투영**과 OneLibrary 칸만 비교한다. 원래 목표(모든 편집)와 견주면 건너뛴 편집 때문에, 투영 없이 합친 모델과 견주면 Device Library 전용 칸·곡·목록 때문에 늘 어긋난다. 다르면 전체 `ROLLBACK`하고 `UsbError.writeRolledBack`(사본은 그대로).
4. `COMMIT` → `wal_checkpoint(TRUNCATE)` → 닫기 → 확인(§2.9의 5). 돌려주는 적용 모델은 투영하지 않은 합친 모델이다(Device Library를 같은 편집 집합으로 다시 만들 때 쓴다). COMMIT 뒤의 체크포인트·확인이 실패하면 사본에는 편집이 이미 들어가 있으므로 되돌렸다고 알리지 않는다(`OneLibraryCommittedCopyError`). 호출하는 쪽은 그 사본을 버리고 USB에서 다시 뜬다(같은 사본에 다시 적용하면 편집이 두 번 들어간다).

- 차이 SQL: 지우기를 먼저 한다. 곡 빼기는 content 행과 그 곡의 myTag_content 행을 지우고, 더하기는 INSERT, 바뀐 곡은 UPDATE(rating·djPlayCount·hasModified는 쓰지 않음). artist·album·genre·key·label·image는 id로 짝지어 지우기·더하기·고치기. 목록은 행을 고치고, 항목이 바뀐 목록만 playlist_content를 지운 뒤 1..N으로 다시 넣는다. property는 numberOfContents만 고친다(단계 모델 값을 믿지 않고 OneLibrary에 있는 곡 수로 센다).
- 모델 다듬기: 두 쪽에 다 있는 곡의 기기 칸, 색·메뉴·카테고리·정렬·My Tag·기록·모르는 표 행, property의 deviceName·dbVersion·createdDate·backGroundColorType·myTagMasterDBID는 USB 값을 지킨다. My Tag 연결은 더하지 않고 뺀 곡의 연결만 없앤다. 이 편집으로 아무도 가리키지 않게 된 album·artist·genre·key·label·image 행은 뺀다(원래 쓰이지 않던 행은 그대로).
- 건드리지 않는 것: history·history_content·cue·recommendedLike·hotCueBankList·hotCueBankList_cue(기기 행). 그 표를 바꿔야 하는 편집은 건너뛴다: 기기가 남긴 큐·추천·재생 기록(history_content)이 가리키는 곡을 빼는 편집, 핫큐 뱅크(hotCueBankList.image_id)가 가리키는 그림이 고아가 되는 편집.
- 목록 항목이 없는 곡을 가리키게 되는 편집도 건너뛴다. 이번 편집에서 뺀 곡은 항목을 고치지 않은 목록까지 모두 본다(USB에 원래 있던 어긋남 때문에 모든 편집이 막히지 않게 이번에 뺀 곡만 본다).
- 파일 머리 모양(WAL 2/2·롤백 1/1)은 바꾸지 않는다(`journal_mode`를 건드리지 않음).
- 만들기·고치기·확인 모두 Mac 준비 폴더나 USB DB 사본만 받는다. 파일이나 그 폴더의 realpath가 `/Volumes` 아래면 열기 전에 막는다(`libraryOnVolume`). USB에는 `UsbWriter`(백업·저널·실물 관문)로만 쓴다.

### 2.11 쓰기 실험 명령

- `djc lab onelib-rebuild <USB 폴더> <출력 폴더>`: USB OneLibrary를 사본으로 떠서 모델로 읽고, 그 모델로 `<출력>/PIONEER/rekordbox/exportLibrary.db`를 새로 만든 뒤 표마다 rowid·typeof·값과 sqlite_master.sql을 비교한다(수만 출력).
- `djc lab onelib-export --db <사본> --share <share> (--playlist <ID> | --tracks <ID,…>) --out <출력 폴더> [--snapshot-time <ISO 8601>]`: 로컬 사본의 곡·목록으로 계획 → 모델 → `exportLibrary.db`만 만든다(음원·분석 파일·Device Library는 쓰지 않음). 이어서 `djc lab usb-diff --onelibrary <골든> <출력>`으로 칸 단위로 견준다.
- 두 명령 모두 입력·출력은 임시 폴더 아래만 받는다(출력 폴더는 없거나 비어 있어야 함).

### 2.12 확인 안 된 것

- label 행의 번호·이름(값이 있는 곡을 보지 못함), 리믹서·원곡자 번호 순서, 작사가 글자가 있는 곡의 `artist_id_lyricist`(`metadataSeenEmptyOnly`).
- 검색 칸(titleForSearch·nameForSearch)은 NULL로만 봤다.
- My Tag 연결(`myTag_content`)은 쓰지 않는다(`myTagLinks`). myTagMasterDBID는 난수로 짓는다(`myTagMasterDBID`).
- 같은 이름의 다른 로컬 아티스트 행을 rekordbox가 합치는지(지금은 로컬 ID로만 합친다).
- 기기 행(큐·추천·재생 기록·핫큐 뱅크)이 가리키는 곡·그림을 USB에서 뺐을 때 기기·rekordbox가 어떻게 다루는지(그래서 그 편집은 막는다).

## 3. Device Library(export.pdb·exportExt.pdb)

근거: rekordbox 7.2.18 골든(2026-09-26 내보내기) 관찰. 먼 오프셋 행 모양(아래 "먼 모양")은 골든에서 보지 못해 읽기만 한다. 읽기 코드는 `Sources/RekordboxKit/Usb/DeviceLibrary/`(`PdbFile`·`PdbPage`·`PdbString`·`PdbRows`·`PdbReader`), 쓰기 코드는 `Sources/RekordboxKit/Usb/Write/Pdb*.swift`(§3.8), 시험 재료는 칸 값으로 쪽을 조립하는 `PdbBuilder`다.

### 3.1 파일 머리

파일은 4096바이트 쪽의 배열이다. 쪽 0이 파일 머리이고 쪽 `i`는 바이트 `i × 4096`에서 시작한다. 모든 정수는 little-endian이다.

| 오프셋 | 크기 | 칸 | 값 |
|---|---|---|---|
| 0x00 | u32 | | 0 |
| 0x04 | u32 | len_page | 4096 |
| 0x08 | u32 | num_tables | export 20, exportExt 9 |
| 0x0C | u32 | next_unused_page | 할당된 가장 큰 쪽 번호 + 1(파일 끝 너머 후보 포함) |
| 0x10 | u32 | (flag10) | 5 = rekordbox가 정상으로 닫음. 열린 채 뽑힌 USB에서는 다른 값 |
| 0x14 | u32 | sequence | 다음 쪽 순번(모든 쪽 순번보다 큼) |
| 0x18 | u32 | gap | 0 |
| 0x1C | 16 × num_tables | 표 포인터 | `{u32 type, u32 empty_candidate, u32 first_page, u32 last_page}`, type 0부터 오름차순 |

- first_page는 그 표의 인덱스 쪽이다. last_page는 사슬의 마지막 쪽(데이터가 없으면 인덱스 쪽)이고, 그 쪽 머리의 next_page가 empty_candidate다. empty_candidate는 0으로 채운 쪽이거나 파일 끝 너머다.
- 쪽 크기가 4096이 아니거나 표 수가 20·9가 아니면 `UsbError.readFailed`로 읽지 않는다. flag10은 보고서에 값만 남긴다(막을지는 쓰기 쪽이 정한다).

### 3.2 쪽 머리(0x00–0x27)

| 오프셋 | 크기 | 칸 | 데이터 쪽 | 인덱스 쪽 |
|---|---|---|---|---|
| 0x04 | u32 | page_index | 자기 쪽 번호 | 같음 |
| 0x08 | u32 | type | 표 번호 | 같음 |
| 0x0C | u32 | next_page | 다음 쪽(마지막이면 empty_candidate) | 첫 데이터 쪽(없으면 empty_candidate) |
| 0x10 | u32 | seq | 그 쪽을 마지막으로 고친 순번 | 새로 만든 파일에서 1(rekordbox가 고치면 그때 순번) |
| 0x14 | u32 | u2 | 0 | 0 |
| 0x18–0x1A | 24비트 | 행 수 묶음 | `nro + (nr << 13)`: 아래 13비트 nro = 할당한 행 자리 수, 위 11비트 nr = 산 행 수 | 0 |
| 0x1B | u8 | flags | 0x24(지운 행 없음) / 0x34(nr < nro) | 0x64 |
| 0x1C | u16 | free | `4096 − 0x28 − used − 2·nro − 4·⌈nro/16⌉` | 0 |
| 0x1E | u16 | used | 힙 할당 바이트 합(죽은 행 포함) | 0 |
| 0x20·0x22 | u16 | tx_row_count·tx_row_index | 마지막 트랜잭션이 건드린 자리 수·첫 자리 | 보통 0x1FFF |
| 0x24 | u16 | u6 | 0 | 0x03EC |
| 0x26 | u16 | u7 | 0 | 인덱스 항목 수 |

- 예: 7자리·6행 → `07 C0 00`, 284자리·284행 → `1C 81 23`. 0x18을 u8 행 수로 읽으면 255행 넘는 쪽(12바이트 행)에서 행을 잃는다.
- 인덱스 쪽 본문: 0x28 자기 쪽 번호, 0x2C 첫 데이터 쪽(없으면 0x03FFFFFF), 0x30 0x03FFFFFF, 0x34 0, 0x38 u16 항목 수, 0x3A 0x1FFF, 0x3C부터 u32 항목 1004개(빈 것 0x1FFFFFF8, 항목 = `(쪽 번호 << 3) | 아래 3비트` = 지운 행이 있는 데이터 쪽), 0xFEC–0xFFF 0. 읽기는 인덱스 항목을 쓰지 않는다.

### 3.3 행 인덱스

쪽 끝에서 거꾸로 16자리씩 묶는다. 자리 `k`는 묶음 `g = k / 16`, `j = k % 16`, `base = 4096 − g × 0x24`에서:

- `base − 2`: u16 tx 비트(j번 비트)
- `base − 4`: u16 presence 비트(산 행)
- `base − 6 − 2j`: u16 행 오프셋(힙 시작 0x28 기준)

마지막(덜 찬) 묶음도 같은 계산이다. 행 바이트는 그 오프셋부터 힙에서 다음 행 오프셋까지, 마지막 행은 used까지다. 행 해석은 표별 고정 칸과 문자열 오프셋으로 하고, 범위는 행 밖 읽기를 막는 데만 쓴다.

### 3.4 문자열(DeviceSQL)

| 첫 바이트 | 모양 | 구조 |
|---|---|---|
| 홀수 `((n+1)<<1)+1` | 짧은 ASCII | 첫 바이트 + ASCII n바이트(끝 표시 없음). 빈 문자열 `03`, n ≤ 126 |
| `0x40` | 긴 ASCII | `40`, u16 길이(머리 4 포함), `00`, ASCII |
| `0x90` | UTF-16LE | `90`, u16 길이(머리 4 포함), `00`, UTF-16LE |
| `0x90` + 다섯째 바이트 `03` | ISRC 특수형 | `90`, u16 길이 = 4 + 1 + k + 1, `00`, `03`, ASCII k, `00`(트랙 문자열 0에만) |

- 126자까지의 ASCII는 짧은 ASCII, ASCII가 아닌 글자가 든 문자열은 UTF-16LE다. 127자 이상 순수 ASCII를 rekordbox가 어떤 모양으로 쓰는지는 확인 안 됨(`pdbLongAscii`)이라 `PdbStringEncoder.encode`는 nil을 돌려준다. 작성기(`PdbStringEncoder.encoded`)는 그 문자열을 UTF-16LE로 두고 `pdbLongAscii`를 붙인다(§3.8). 긴 ASCII(0x40)는 읽기만 한다.
- ISRC 특수형은 트랙 문자열 0에서만 읽는다(`isrcAllowed`, 기본 거짓). 다른 칸의 `90 … 00 03 …`은 첫 글자 아래 바이트가 3인 UTF-16이다.
- UTF-16 문자열은 행 시작 기준 4바이트 경계에서 시작한다(앞 빈 바이트 0). 짧은 ASCII는 앞 문자열 바로 뒤에 붙는다.
- 모르는 첫 바이트, 행 밖으로 나가는 길이, 잘못된 UTF-16은 그 행만 문제로 남기고 계속 읽는다.

### 3.5 export.pdb 표

| 번호 | 표 | 행 |
|---|---|---|
| 0 | tracks | 아래 표 |
| 1·4 | genres·labels | u32 id, 문자열 @0x04 |
| 2 | artists | subtype 0x0060: 0x04 u32 id, 0x08 u8 0x03, 0x09 u8 이름 오프셋(ASCII 0x0A, UTF-16 0x0C). 먼 모양 0x0064: 0x0A u16 오프셋 |
| 3 | albums | subtype 0x0080: 0x08 u32 앨범 아티스트(0 없음), 0x0C u32 id, 0x14 u8 0x03, 0x15 u8 이름 오프셋(ASCII 0x16, UTF-16 0x18). 먼 모양 0x0084: 0x16 u16 오프셋 |
| 5 | keys | u32 id, u32 id(같은 값), 문자열 @0x08 |
| 6 | colors | u32 0, u8 id, u16 id, u8 0, 문자열 @0x08 |
| 7 | playlist_tree | u32 parent_id, u32 0, u32 sort_order, u32 id, u32 is_folder, 문자열 @0x14 |
| 8 | playlist_entries | u32 entry_index(1부터), u32 track_id, u32 playlist_id(12바이트). 항목은 entry_index 순 |
| 11·12 | history_playlists·history_entries | u32 id, 문자열 @0x04 / u32 track_id, u32 playlist_id, u32 entry_index. 해석되지 않으면 두 표 모두 행 수만 `unknownRows`로 |
| 13 | artwork | u32 id, 짧은 ASCII 경로 @0x04(`/PIONEER/Artwork/%05d/a%d.jpg`) |
| 16 | columns | u16 id, u16 code(= Class + 256), UTF-16 이름 @0x04(U+FFFA … U+FFFB로 감쌈) |
| 17 | category | u16 menuItemID, u16 id, u8 InfoOrder, u8 Disable, u16 Seq(8바이트). 보임 = Disable ≠ 1 |
| 18 | sort | u16 menuItemID, u16 id, u8 Disable, u8 Seq, u16 0(8바이트). 보임 = Disable ≠ 1, 보조 칸 = Disable = 2 |
| 19 | property | subtype 0x0280(40바이트): 0x04 u32 곡 수, 0x0C 짧은 ASCII 날짜(YYYY-MM-DD), 0x17 u8 버전 문자열("1000") 오프셋, 0x18 u8 두 번째 문자열 오프셋 |
| 9·10·14·15 | (모름) | 산 행 수만 `unknownRows` |

tracks(subtype 0x0024, 16비트 문자열 오프셋):

| 오프셋 | 크기 | 칸 | 모델(`UsbTrack`) |
|---|---|---|---|
| 0x00 | u16 | subtype 0x0024 | `trackRowExtras` |
| 0x02 | u16 | index_shift | 쓰지 않음 |
| 0x04 | u32 | bitmask | `trackRowExtras` |
| 0x08 | u32 | sample_rate | sampleRate |
| 0x0C | u32 | composer_id | composerID |
| 0x10 | u32 | file_size | fileSize |
| 0x14 | u32 | (로컬 MasterSongID) | masterContentId |
| 0x18 | u32 | master_db_id | masterDbId |
| 0x1C | u32 | artwork_id | imageID |
| 0x20·0x24·0x28·0x2C | u32 | key_id·original_artist_id·label_id·remixer_id | keyID·originalArtistID·labelID·remixerID |
| 0x30·0x34·0x38 | u32 | bitrate·track_number·tempo(BPM × 100) | bitrate·trackNo·bpmx100 |
| 0x3C·0x40·0x44·0x48 | u32 | genre_id·album_id·artist_id·id | genreID·albumID·artistID·id |
| 0x4C·0x4E·0x50·0x52·0x54 | u16 | disc_number·play_count·year·sample_depth·duration(초) | discNo·djPlayCount·releaseYear·bitDepth·lengthSeconds |
| 0x56 | u16 | u5 | `trackRowExtras` |
| 0x58·0x59 | u8 | color_id·rating | colorID·rating |
| 0x5A | u16 | file_type | fileType |
| 0x5C | u16 | u7 | `trackRowExtras` |
| 0x5E | u16 × 21 | 문자열 오프셋(행 시작 기준) | |

- id 칸 0은 "없음"(nil)이다. play_count·rating은 기기 칸(`deviceFields[.deviceLibrary]`)에도 넣는다.
- 문자열 21개: 0 ISRC(특수형) → isrc, 1 작사가 → lyricist, 2·3·4 정보·분석·큐 갱신 횟수 → informationUpdateCount·analysisDataUpdateCount·cueUpdateCount, 5 message, 6 kuvo_public("ON" → kuvoDeliver), 7 autoload_hotcues("ON" → hotCueAutoLoad), 8·9 모름, 10 dateCreated, 11 releaseDate, 12 mix_name → subtitle, 13 모름, 14 분석 파일 경로 → analysisDataPath, 15 dateAdded, 16 comment, 17 title, 18 모름, 19 파일 이름 → fileName, 20 파일 경로 → path.
- 뜻 모를 문자열(5·8·9·13·18)의 값, 참·거짓 문자열(6·7)의 원래 값, 문자열 21개의 모양은 `UsbPdbTrackExtras`에 남긴다(다시 쓸 때 비어 있지 않은 값이나 "ON"·''가 아닌 값을 잃지 않게).
- OneLibrary에만 있는 칸(titleForSearch, lyricistArtistID, kuvoDeliveryComment 등)은 Device Library 리더의 기본값으로 둔다(§2.6).

### 3.6 exportExt.pdb 표

| 번호 | 표 | 행 |
|---|---|---|
| 3 | tags | subtype 0x0680: 0x0C u32 부모(분류면 0), 0x10 u32 부모 안 순서(0부터), 0x14 u32 id, 0x1B u8 분류면 1, 0x1C u8 0x03, 0x1D u8 이름 오프셋(ASCII 0x1F, UTF-16 0x20), 0x1E u8 두 번째 문자열 오프셋. 먼 모양 0x0684는 칸 자리를 확인하지 못해 0x20·0x22 u16 오프셋으로 읽되(이름 < 두 번째, 둘 다 0x24 이상이 아니면 그 행을 버림), 읽은 행도 구조 문제(`unconfirmedRowShape`)로 남겨 rekordbox 실험으로 확인하기 전까지 Device Library 편집이 막히게 한다 |
| 4 | tag_tracks | u32 0, u32 track_id, u32 tag_id, u32 3 |
| 7 | (My Tag property) | subtype 0x0700(60바이트): 0x18 u32 myTagMasterDBID, 0x1C u8 0x03, 0x1D–0x21 빈 문자열 오프셋 다섯 |
| 0·1·2·5·6·8 | (모름) | 산 행 수만 `unknownRows` |

My Tag ID와 myTagMasterDBID는 u32라 Int32를 넘을 수 있어 64비트로 담는다.

### 3.7 읽기가 견뎌야 할 것

rekordbox는 Device Library를 제자리에서 고친다. 읽기는 아래를 견딘다(`PdbReader`).

- **죽은 행:** 산 행은 presence 비트가 켜진 자리만이다. 죽은 행이 멀쩡한 복제(같은 id 두 벌)일 수 있어 행 수를 짐작하지 않는다. 해석되는 죽은 행(tracks·artists·albums·genres·keys·labels·artwork·playlist_tree)의 id는 `deadIDs`에 모은다(지운 ID를 다시 쓰지 않게).
- **flags 0x34:** 지운 행이 있는 쪽. 인덱스 쪽의 항목 목록도 쓰지 않는다.
- **index_shift:** 행 0x02의 index_shift는 산 행 순번이 아니라 자리 × 0x20이라 해석에 쓰지 않는다.
- **패딩:** 행 사이 패딩 바이트는 보지 않는다.
- **파일 끝 너머 후보:** empty_candidate와 next_unused_page가 파일 끝 너머를 가리킬 수 있다. 사슬은 empty_candidate에서 끝난다.
- **flag10 ≠ 5:** 열린 채 뽑힌 USB. 읽기는 멈추지 않고 보고서에 값을 남긴다.
- **멈추지 않는 구조 문제:** 쪽 번호 ≠ 위치, 파일 밖 쪽, 순환 사슬, 다른 표의 쪽, last_page에서 끝나지 않는 사슬, 힙 밖 행 오프셋, 산 행끼리 같은 자리, 산 행 수 ≠ presence 비트 수, 해석되지 않는 산 행, 같은 id 산 행, 확인 안 된 행 모양(먼 모양 My Tag 행), 없는 목록을 가리키는 산 목록 항목(`orphanEntry`, rekordbox는 목록을 지울 때 그 항목도 함께 죽인다) → `PdbReadReport.issues`에 종류·표·쪽·자리만 넣고(값은 넣지 않음) 그 표는 읽은 데까지만 쓴다.
- **먼 오프셋 모양:** 아티스트·앨범·My Tag 행을 먼 모양(0x0064·0x0084·0x0684)으로 읽으면 `PdbReadReport.farShapeRows`에 표마다 수를 센다. 쓰는 쪽은 이 수로 `pdbFarOffsetRows`를 판단한다.
- `djc lab pdb-dump <파일> [--pages] [--rows <표>]`는 임시 폴더 아래 파일을 임시 사본으로 떠서 머리·표 포인터·표마다 산 행/자리·쪽 수, `far_shape_rows <수>`와 마지막 줄 `issues <수>`를 찍는다(0이 아니면 종류별 수와 쪽 번호). `--rows`는 자리·오프셋·산/죽음·index_shift와 문자열 모양·길이만 찍는다. `djc lab usb-diff`는 `--onelibrary`·`--device-library`로 한 형식만, 기본은 두 형식을 합친 모델끼리 비교하고 각 쪽의 형식 불일치 종류·수를 먼저 찍는다.

### 3.8 쓰기(`PdbWriter`)

근거: rekordbox 7.2.18 골든(2026-09-26 내보내기)에서 칸 값만 읽어 아래 규칙으로 다시 만든 쪽이 원본과 바이트가 같았다(`djc lab pdb-verify`, 제자리 수정 이력이 있는 쪽은 뺌: 지운 행이 있는 데이터 쪽, 0x20·0x22가 한 번에 씀·덧붙임 모양이 아닌 데이터 쪽, 지운 쪽 목록이 있는 인덱스 쪽). 코드는 `PdbWriter`(두 파일·쓴 모델·규칙), `PdbLayout`(쪽 배치·순번·쪽 바이트), `PdbRowEncoder`(행·`PdbRowSize`), `PdbRoundTrip`(왕복 검사), `PdbPageCheck`(쪽 다시 만들기 비교)다.

- 입력은 모델의 Device Library 투영(`projected(to: .deviceLibrary)`)이다. 두 형식을 합친 모델이어도 되고, OneLibrary에만 있는 칸·곡·목록은 쓰지 않는다.
- 쓰지 않고 막는 것(`UsbError.writeRefused`의 code): 곡 0개(`pdbNoTracks`), 기기 기록·모르는 표의 행(`carriedDeviceRows`), My Tag 연결(`myTagLinks`, v1의 tag_tracks는 0행), file_type과 파일 이름 확장자가 다른 곡(`pdbFileTypeMismatch`), 가까운 모양에 들어가지 않는 아티스트·앨범·태그 행(`pdbFarOffsetRows`, 할당 크기 255 초과), 빈 쪽에도 들어가지 않는 행(`pdbRowTooLarge`), 칸 크기를 넘는 값(`pdbValueOutOfRange.<칸>`), ASCII가 아닌 ISRC(`pdbISRCNotASCII`), 편집 모드에서 새 순번이 u32를 넘는 경우(`pdbSequenceOverflow`).
- 이 막힘들(규칙이 없는 것)의 문구는 일반 문구("USB에 쓰지 않았습니다. 조건을 확인한 뒤 다시 시도하세요")다. 쓰는 쪽(USB 내보내기·고치기)은 같은 조건을 계획 단계에서 먼저 막고(`PdbRowSize` 등) 할 일이 적힌 문구를 보여 준다. 작성기의 막힘은 마지막 안전장치다.

**쪽 배치**

```
next = 1
표마다(type 오름차순): 인덱스 쪽 = next, 빈 후보 = next + 1, next += 2     // 인덱스 2t+1, 후보 2t+2
넣는 순서의 표마다(행이 있을 때만):
    cur = 후보; 후보 = next; next += 1          // 후보를 데이터 쪽으로 쓰는 순간 새 후보
    행마다: 들어가지 않으면 cur를 닫고 cur = 후보; 후보 = next; next += 1
next_unused = next
표 포인터 = (type, 후보, 인덱스 쪽, 마지막 데이터 쪽 또는 인덱스 쪽)
파일 길이 = 후보가 아닌 쪽 중 가장 큰 번호 + 1쪽. 그 안의 후보는 0으로 채운 쪽, 그보다 큰 후보는 파일 끝 너머
```

- 들어가는지: `used + L + dir(nro + 1) ≤ 4056`, `dir(n) = 2n + 4⌈n/16⌉`(12바이트 행은 쪽당 284개).
- 넣는 순서: export 19, 6, 16, 17, 18, 7, 2, 1, 3, 4, 5, 0, 13, 8, 11, 12(9·10·14·15는 늘 빈 표), exportExt 7, 3, 4.
- 사슬: 인덱스 쪽 next = 첫 데이터 쪽(없으면 후보), 데이터 쪽 next = 다음 데이터 쪽, 마지막 쪽 next = 후보. 빈 표도 인덱스 쪽과 후보가 있다(인덱스 쪽 본문 0x2C = 0x03FFFFFF).
- 쪽 안 행 순서는 id 순이다. category·sort는 (순서, id), columns는 id, My Tag는 분류를 순서대로 놓고 분류마다 그 태그를 순서대로. 목록 항목은 목록 id 순, 목록 안 순서대로 entry_index 1부터.
- rekordbox가 곡마다 표를 번갈아 넣어 생기는 뒤쪽 쪽 번호는 맞추지 않는다(기기는 사슬을 따라간다고 본다, 추정).

**순번과 쪽 머리**

| 쪽 | 순번 | 모양 |
|---|---|---|
| 모든 인덱스 쪽 | 1 | 인덱스(§3.2, 지운 쪽 목록 없음) |
| export 6·16·17·18 데이터 | 2부터 | 한 번에 씀 |
| 그 밖의 export 데이터 | 이어서 쪽을 닫는 순서대로 | 한 행씩 덧붙임 |
| export 19 데이터 | 마지막 | 행 하나 |
| exportExt 7 / 3 / 4 데이터 | 1 / 2부터 / 그 뒤 | 7·3 한 번에 씀, 4 덧붙임 |
| 파일 머리 0x14 | 가장 큰 쪽 순번 + 1 | 0x10 = 5 |

- 한 번에 씀: 0x20 = 자리 수, 0x22 = 0, tx 비트 = presence 비트. 덧붙임: 0x20 = 1, 0x22 = 마지막 자리, tx 비트는 마지막 자리만. 행 하나인 쪽은 둘이 같다.
- 데이터 쪽: flags 0x24, 0x24·0x26 = 0(0x1FFF를 쓰지 않는다), free = `4096 − 0x28 − used − dir(nro)`, used = 행 할당 크기의 합. 힙과 행 인덱스 사이는 0. 행 0x02 index_shift = 자리 × 0x20(subtype이 있는 행).
- **편집 모드**(`PdbWriteMode.edit`): 모든 쪽 순번 = 옛 파일 머리 순번 + 위 상대 순번(인덱스 쪽도). 머리는 늘 옛 머리보다 크다. 옛 머리 순번은 USB에서 읽은 값이라, 새 머리 순번이 u32를 넘으면 쓰지 않고 막는다(`pdbSequenceOverflow`, 왕복 검사에서는 문제로 남는다).

**행**

- 할당 크기 L(`PdbRowSize`): 단순 행(genre·label·key·color·artwork·columns·playlist_tree) = align4(마지막 문자열 끝), 고정 행 playlist_entries 12·category 8·sort 8·표 19 40, 오프셋 문자열 행 = align4(고정 칸) + Σ align4(문자열 길이) + 4(고정 칸: 트랙 0x88, 아티스트 0x0A, 앨범 0x16, 태그 0x1F, exportExt 표 7 0x22). 트랙 행은 224바이트 이상. 문자열 뒤 할당 끝까지는 0.
- 트랙 행 상수: 0x04 bitmask 0x000C0700, 0x56 0x0029, 0x5C 3. 평점·재생 수는 `deviceFields[.deviceLibrary]` 값(없으면 모델 칸). 뜻 모를 문자열 5·8·9·13·18은 빈 값, 6·7은 켜짐이면 "ON" 아니면 빈 값(빈 값은 추정).
- 아티스트 0x08·앨범 0x14·태그 0x1C는 0x03, 앨범 0x04·0x10은 0, 분류 태그는 0x0C(부모) = 0·0x18 = 0x01000000, 태그의 두 번째 문자열은 빈 값(오프셋 = 이름 끝).
- keys는 모델 키만 모델 id로 쓴다(고정 24개 표를 쓰지 않는다). colors는 모델 색. category Disable이 없으면 보임 0·숨김 1, sort Disable이 없으면 보조 칸 2·숨김 1·보임 0.
- 표 19: 곡 수 = 산 트랙 행 수, 날짜 = 모델 `pdbDate`(고칠 때 보존) → 없으면 OneLibrary `createdDate`(내보낸 날) → 없으면 오늘, 버전 "1000", 두 번째 문자열 빈 값. 늘 한 행.
- exportExt 표 7: myTagMasterDBID와 빈 문자열 다섯(오프셋 0x22–0x26).
- 문자열 경계: 126자까지 순수 ASCII는 짧은 ASCII, 127자 이상 순수 ASCII는 UTF-16LE + `pdbLongAscii`(판정은 `UsbTrackRules.pdbStringRules`와 같다). UTF-16은 행 기준 4바이트 경계로 앞을 0으로 채우고, 짧은 ASCII는 앞 문자열 바로 뒤에 붙인다. 트랙 행 문자열에서 나온 규칙은 `PdbFiles.rulesByTrack`(content id별)에도, 모든 규칙은 `PdbFiles.rules`에 모은다. 쓰는 쪽은 `rules`를 변경 묶음 `requiredRules`에 합친다.

**쓴 모델과 확인**: `PdbFiles.written`은 입력 투영에 작성기가 정하는 칸(트랙 행 관찰값, 표 19 곡 수·날짜·버전·두 번째 문자열, 기기 칸의 평점·재생 수, Disable, 폴더 여부, 0인 참조 → nil, Device Library 경로가 없는 아트워크는 뺌)을 채운 모델이다. 쓴 두 파일을 다시 읽은 모델은 이것과 `UsbLibraryDiff`(formats: [.deviceLibrary]) 차이가 0이어야 한다. Device Library에서 읽은 모델을 쓰면 입력의 투영과 같다.

**왕복 검사**(`PdbRoundTrip.check`): 고쳐 쓰기 전에 읽기 → 모델 → 쓰기(편집 모드) → 다시 읽기를 해, 알려진 표의 칸이 모두 같고 트랙 상수 칸이 관찰값이어야 통과한다(빈 배열). 원본의 구조 문제·먼 모양 행, 작성기가 막는 행, 쓰지 않는 문자열 모양(긴 ASCII 0x40 등)도 문제로 남긴다. 트랙 문자열 6·7(kuvo 공개·핫큐 자동 불러오기)은 "ON"만 참으로 읽고 작성기는 "ON"·''만 쓰므로, 읽기가 원래 값을 `UsbPdbTrackExtras.flagStrings`에 남기고 둘 중 어느 것도 아닌 값이 든 곡을 문제로 남긴다(모델은 같아도 다시 쓰면 바뀐다). 지운 행 id는 다시 쓰면 사라지는 것이 정상이라 비교하지 않는다(지운 ID를 다시 쓰지 않게 지키는 것은 편집 쪽 몫).

**v1에 없는 것**: 먼 오프셋 모양 행(0x0064·0x0084·0x0684), 긴 ASCII(0x40), 기기 기록 표(11·12)의 행, My Tag 연결(tag_tracks), 모르는 표의 행, 제자리 수정(지운 행·지운 쪽 목록).

**실험 명령**

- `djc lab pdb-verify <USB 폴더>`: 두 pdb를 사본으로 떠서 쪽마다 칸 값만으로 다시 만들어 바이트를 비교한다(쪽 번호·next·순번·행 자리 순서는 원본 값). 제자리 수정 이력이 있는 쪽은 뺀다: 지운 행이 있는 데이터 쪽, 지운 쪽 목록이 있는 인덱스 쪽, 지운 행은 없지만 0x20·0x22가 그 표의 쓰기 모양(한 번에 씀 = (자리 수, 0), 덧붙임 = (1, 마지막 자리), 행 하나면 (1, 0))과 다른 데이터 쪽(rekordbox가 제자리에서 고친 행은 할당 크기가 이 규칙보다 클 수 있다. 읽기는 문제없다). 다른 쪽은 쪽 번호·처음 다른 오프셋과 행마다 할당 크기만 찍는다. 행을 해석하지 못하거나 다시 만든 행이 원본보다 커서 한 쪽에 들어가지 않으면(긴 ASCII 0x40 → UTF-16 등) 쪽을 만들지 않고 "행을 다시 만들지 못함"과 이유를 찍는다(들어가지 않을 때는 행마다 크기도).
- `djc lab pdb-export --db <사본> --share <share> (--playlist <ID> | --tracks <ID,…>) --out <폴더> [--snapshot-time <ISO 8601>]`: 로컬 사본으로 두 형식 모델을 만들어 `<폴더>/PIONEER/rekordbox/export.pdb`·`exportExt.pdb`만 쓰고, 다시 읽기 차이·왕복 문제 수를 찍는다. 골든과는 `djc lab usb-diff --device-library`로 비교한다.

## 4. ANLZ 변환

로컬 분석 파일(`share` + `djmdContent.AnalysisDataPath`에서 확장자만 바꾼 `.DAT`·`.EXT`·`.2EX`)과 `djmdCue`로 USB 분석 파일 세 개를 만든다(`UsbAnlzTransform`). 로컬 파일 이름은 `ANLZ0000`이 아닐 수 있어 가정하지 않는다. 근거는 모두 rekordbox 7.2.18 골든 관찰이다. 골든의 곡을 로컬 곡과 짝지어 다시 만들면, 스냅샷을 뜬 뒤 로컬 분석 파일이 바뀐 곡을 빼고 세 파일이 바이트까지 같았다(§4.10). 모든 칸은 빅엔디언이다.

### 4.1 파일 머리

`PMAI` · len_header 28 · len_file(파일 전체 길이, 태그를 바꾼 뒤 다시 적는다) · 나머지 16바이트는 로컬 그대로.

### 4.2 태그 처리

태그 순서는 로컬 순서 그대로 두고, 태그 목록을 돌며 새 목록을 만든다. 같은 이름 태그(PCOB 둘, PCO2 둘)는 태그 0x0C의 목록 종류(1 핫큐, 0 메모리 큐)로 가린다. 골든에서 본 순서는 `.DAT` `PPTH PVBR PQTZ PWAV PWV2 PCOB(핫) PCOB(메모리)`, `.EXT` `PPTH PWV3 PCOB(핫) PCOB(메모리) PCO2(핫) PCO2(메모리) PQT2 PWV5 PWV4 [PVB2] [PSSI]`, `.2EX` `PPTH PWV7 PWV6 PWVC PVDI`다.

| 태그 | USB |
|---|---|
| 모든 파일 `PPTH` | `/Contents/…` 경로로 새로(§4.3) |
| `PVBR` `PQTZ` `PWAV` `PWV2` `PWV3` `PWV4` `PWV5` `PWV6` `PWV7` `PWVC` `PVB2`, 비지 않은 `PQT2`, 모르는 태그 | 바이트 그대로 |
| `.DAT` `PCOB` 둘, `.EXT` `PCOB` 둘·`PCO2` 둘 | `djmdCue`로 새로(§4.4–4.6). 로컬 share의 큐 태그는 비어 있다 |
| `.EXT` `PSSI` | 평문(mood 1–3)이면 마스크(§4.7). 이미 마스크된 모양이면 빼고 경고 `maskedLocalPSSIDropped` |
| `.2EX` `PVDI` | 평문이면 마스크(§4.8). 이미 마스크된 모양이면 그대로 두고 경고, 모르는 모양이면 그 자리에 빈 `PVDI`를 두고 경고. 없으면 빈 `PVDI`를 파일 끝에 붙인다 |
| `.EXT` 빈 `PQT2` | 뺀다(§4.9) |
| `.3EX` | 만들지 않는다 |

로컬 `.2EX`가 없으면 USB `.2EX`도 만들지 않는다(막는 것은 계획 몫). 경고는 `UsbAnlzWarning`의 코드로 남기고 계획 보고에서 문구로 바꾼다.

### 4.3 경로 태그(PPTH)

| 오프셋 | 칸 | 값 |
|---|---|---|
| 0x00 | `PPTH` | |
| 0x04 | len_header u32 | 0x10 |
| 0x08 | len_tag u32 | 0x10 + len_path |
| 0x0C | len_path u32 | 경로 바이트 수(UTF-16BE, 끝 NUL 2바이트 포함) |
| 0x10 | 경로 | `/Contents/{Artist}/{Album}/{File}` UTF-16BE + `00 00` |

로컬은 `?/{파일 이름}`이다. USB에서는 세 파일에 같은 경로를 쓰고, Device Library `file_path`·OneLibrary `path`와 글자까지 같다(NFC). 코드는 `AnlzPathTag`.

### 4.4 큐 배치·순서

입력은 `djmdCue`에서 그 곡의 `rb_local_deleted = 0`인 행이다(`UsbCueSource`, 배치는 `UsbCuePlacement`).

| 태그 | 넣는 큐 |
|---|---|
| `.DAT` PCOB(핫, 종류 1) | 핫큐 A–C(Kind 1·2·3) |
| `.DAT` PCOB(메모리, 종류 0) | 메모리 큐 전부(Kind 0) |
| `.EXT` PCOB(핫) | 핫큐 D–H(Kind 5–9) |
| `.EXT` PCOB(메모리) | 늘 비움 |
| `.EXT` PCO2(핫) | 핫큐 A–H 전부 |
| `.EXT` PCO2(메모리) | 메모리 큐 전부 |

- 핫큐 번호는 Kind < 4면 Kind, 5–9면 Kind − 1(A=1 … H=8). Kind 4는 어느 태그에도 넣지 않고 경고 `cueKindDropped`.
- 목록마다 `created_at` 내림차순, 같으면 `InMsec` 내림차순. `created_at`은 시각으로 풀어 비교한다(`YYYY-MM-DD HH:MM:SS.fff +00:00`, 밀리초·시간대를 뺀 형식도). 하나라도 풀지 못하면 그 목록은 글자로 비교하고 경고 `cueCreatedAtUnparsed`. 골든 전 곡의 큐 태그에서 맞았고, 행 순서(rowid) 내림차순 규칙과는 골든으로 가를 수 없었다.

### 4.5 PCOB·PCPT

PCOB 머리 24바이트: `PCOB` · len_header 0x18 · len_tag(24 + 56n) · 목록 종류 u32 · u16 0 · 항목 수 n u16 · u32(핫 `0xFFFFFFFF`, 메모리 n − 1, n = 0이면 `0xFFFFFFFF`). 빈 PCOB는 로컬 새 곡의 빈 태그와 같다.

| 오프셋 | 칸 | 값 |
|---|---|---|
| 0x00 | `PCPT` | |
| 0x04 | len_header u32 | 0x1C |
| 0x08 | len_entry u32 | 0x38 |
| 0x0C | hot_cue u32 | 메모리 0, 핫 1–8 |
| 0x10 | status u32 | 0(활성 루프도 0으로 쓴다 — 확인 안 된 모양은 `cueVariant`) |
| 0x14 | u32 | `0x00010000` |
| 0x18 | 앞 항목 u16 | 메모리 i − 1(첫 항목 `0xFFFF`), 핫 `0xFFFF` |
| 0x1A | 뒤 항목 u16 | 메모리 i + 1(끝 항목 `0xFFFF`), 핫 `0xFFFF` |
| 0x1C | type u8 | 1 큐, 2 루프(OutMsec > InMsec) |
| 0x1D | u8 | 0 |
| 0x1E | u16 | `0x03E8` |
| 0x20 | u32 | InMsec |
| 0x24 | u32 | 루프면 OutMsec, 아니면 `0xFFFFFFFF` |
| 0x28–0x37 | 16바이트 | 0 |

### 4.6 PCO2·PCP2

PCO2 머리 20바이트: `PCO2` · len_header 0x14 · len_tag · 목록 종류 u32 · 항목 수 u16 · u16 0.

| 오프셋 | 칸 | 값 |
|---|---|---|
| 0x00 | `PCP2` | |
| 0x04 | len_header u32 | 0x10 |
| 0x08 | len_entry u32 | 0x58 + len_comment |
| 0x0C | hot_cue u32 | 메모리 0, 핫 1–8 |
| 0x10 | type u8 | 1 큐, 2 루프 |
| 0x11 | u8 | 0 |
| 0x12 | u16 | `0x03E8` |
| 0x14 | u32 | InMsec |
| 0x18 | u32 | 루프면 OutMsec, 아니면 `0xFFFFFFFF` |
| 0x1C | 색 id u8 | 골든은 모두 0. 색 큐는 핫 `ColorTableIndex`, 메모리 `Color`(1–8, 그 밖 0)로 쓰되 확인 안 된 모양(`cueVariant`) |
| 0x1D | u8 | 1 |
| 0x1E | u16 | 0 |
| 0x20 | u32 | 0 |
| 0x24 | u16 | 박 루프 분자 = `BeatLoopSize >> 16`(NULL은 0) |
| 0x26 | u16 | 박 루프 분모 = `BeatLoopSize & 0xFFFF` |
| 0x28 | len_comment u32 | 주석 UTF-16BE 바이트 + NUL 2. 주석이 NULL·빈 글자면 0 |
| 0x2C | 주석 | UTF-16BE + `00 00`(패딩 없음) |
| C = 0x2C + len_comment | 색 4바이트 | 핫큐 `00 1A FF 00`, 핫 루프 `00 FF 8C 00`, 메모리 `00 00 00 00` |
| C + 0x04 | u64 | In 프레임 시작(FLAC만, `InPointSeekInfo` 첫 값) |
| C + 0x0C | u64 | Out 프레임 시작(FLAC 루프만, `OutPointSeekInfo` 첫 값) |
| C + 0x14 | u64 | In 바이트 위치(FLAC만, 둘째 값) |
| C + 0x1C | u64 | Out 바이트 위치(FLAC 루프만, 둘째 값) |
| C + 0x24 | u32 | In 블록 크기(FLAC만, 셋째 값) |
| C + 0x28 | u32 | Out 블록 크기(FLAC 루프만, 셋째 값) |

SeekInfo는 `"a,b,c"` 글자이고 `"0,0,0"`·NULL·빈 글자는 0으로 쓴다. 탐색 칸은 FLAC(`FileType` 5)만 채우고, M4A·MP3 CBR(`InMpegFrame` 0)은 모두 0으로 확인했다. 그 밖의 형식(VBR MP3, WAV, AIFF, ALAC 등)은 0으로 쓰되 `cueSeekFields`로 표시한다.

### 4.7 PSSI 마스크

로컬 평문 PSSI의 바이트 18부터 끝까지 `b[i] ^= (마스크[(i − 18) % 19] + 항목 수) & 0xFF`(항목 수 = u16 @0x10). 바이트 0–17은 그대로다. 마스크 상수는 `AnlzMasks.pssiMask`(pyrekordbox MIT의 XOR 규칙, 골든으로 다시 확인). 평문인지는 mood(u16 @0x12)가 1–3인지로 가린다. 로컬에 이미 마스크된 PSSI가 있으면 USB에서 빼고 경고한다.

### 4.8 PVDI 마스크

로컬 PVDI 머리 24바이트는 `PVDI` · len_header 0x18 · len_tag · `00 00 04 00` · `56 22 00 01` · 본문 길이 u32(= len_tag − 24)다. USB에서는 바이트 12를 `0x00` → `0x80`으로 바꾸고, 바이트 24부터 끝까지 `b[i] ^= 키[(i − 24) % 19]`를 한다. 키는 `AnlzMasks.pvdiKey`(골든과 로컬의 같은 곡 PVDI를 XOR해 얻은 관찰값, 길이와 관계없이 같다). 로컬에 PVDI가 없으면 `.2EX` 끝에 빈 PVDI(`AnlzMasks.emptyPVDI`: `PVDI` · 0x18 · 0x18 · `00 00 04 00` · `56 22 00 01` · 0, 플래그 0)를 붙인다. 로컬 PVDI의 바이트 12가 이미 `0x80`이면 그대로 옮기고 경고 `maskedLocalPVDIKept`(로컬에서 본 적 없는 모양). 24바이트보다 짧거나 바이트 12가 `0x00`·`0x80`이 아닌 PVDI는 마스크를 씌울 수도 그대로 옮길 수도 없어, 로컬에 PVDI가 없는 곡처럼 빈 PVDI를 두되 태그 순서를 지키려고 그 자리에 두고 경고 `unknownLocalPVDIDropped`.

### 4.9 빈 PQT2

len_tag 56이고 0x0C부터 `00 00 00 00 01 00 00 02`, 나머지가 0인 `PQT2`는 USB에서 뺀다. 비지 않은 `PQT2`는 그대로 둔다.

### 4.10 확인 안 된 규칙

변환 결과의 규칙 표시(`UsbAnlzResult.rules`)는 곡 큐 모양 분류(`UsbCueRules.rules`) 그대로다(§9 `cueVariant`·`cueSeekFields`). 실험 명령 `djc lab usb-anlz-check`는 USB 폴더의 분석 파일을 로컬 분석 파일·큐로 다시 만들어 바이트를 비교한다(모두 읽기만). 곡은 USB `PPTH` 경로의 음원 파일 이름·크기를 로컬 `djmdContent`의 (`FileNameL`, `FileSize`)와 맞춰 짝짓고, 맞는 로컬 곡이 하나가 아니면 짝 없음으로 센다. 라이브러리에 이름·크기가 같은 곡이 여럿이면 `--playlist <재생 목록 ID>`로 내보낸 재생 목록의 곡만 후보로 둔다. 스냅샷을 뜬 뒤 로컬 분석 파일이 바뀐 곡은 따로 센다.

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

USB에 쓰는 길은 `UsbWriter.write` 하나다. 되돌리기(`restore`, `djc usb-restore`)와 회복(`recover`, `djc usb-recover`)도 같은 확인을 먼저 거친다. 쓰기는 형식(OneLibrary·Device Library)을 모른 채 변경 묶음(`UsbChangeSet`: DB 교체·음원 복사·준비 파일 쓰기·지우기·목표 지문)을 파일 단위로 쓴다. 형식별 막힘과 검증은 주입한다(`UsbWriteInspector`·`UsbWriteVerifier`).

### 7.1 단계

| 단계 | 하는 일 | 실패하면 |
|---|---|---|
| A 막힘 확인 | 부작용 없음(7.2) | `writeRefused`. USB·백업·저널 그대로 |
| B 준비 | 준비 폴더 파일의 크기·해시가 계획과 같은지, 저널 `staged`. 드라이 런은 저널을 `dryRun`으로 닫고 끝 | 〃 |
| C 백업(Mac) | `usb-backups/<볼륨 UUID>/<시각>-<이름>/`에 DB·사이드카·`export.pdb.bak`, 덮어쓸 파일, 지울 파일(음원 빼고), 그 파일들의 원래 있던 `._`와 `manifest.json`. 파일마다 복사 전후 크기·mtime이 같아야 함. 저널 `backedUp`이 디스크에 내려간 뒤에만 D | 백업 폴더를 지우고 막음 |
| D 파일(취소 가능) | 음원 → 분석 파일 → 아트워크 → 그 밖. 없는 폴더는 위에서부터 한 단계씩 만들고 저널에 적음 | H |
| E DB 교체(커밋 지점) | exportLibrary.db → export.pdb → exportExt.pdb. DB 항목을 저널에 먼저 적고 임시 이름에 쓴 뒤 rename. OneLibrary는 rename 전에 USB의 `-wal`·`-shm`·`-journal`을 지움(백업에 있음) | H |
| F 지우기 | 지우기 허용 목록 + 크기·SHA-256 + 분석 파일은 PPTH가 계획과 같을 때만. 맞지 않으면 건너뛰고 알림(실패가 아님). 비게 된 우리 폴더만 지움 | H |
| G 검증 | 목표 지문(매체에서 다시 읽음)·없어야 할 경로·우리 폴더의 임시 파일 0개·이번에 바꾼 경로의 `._` 0개 + 주입한 검증 | H |
| H 되돌리기 | 7.6 | `restoreFailed`(백업 폴더와 `djc usb-restore` 안내) |
| I 끝 | 백업 폴더에 `report.json`(결과 DB SHA-256)·`journal.json`(닫는 저널 사본) → 백업 정리(7.9) → 저널 `verified` | — |

rekordbox·rekordboxAgent는 A, D 전, DB마다, F 전에 다시 본다. 켜져 있으면 멈추고 H로 간다.

### 7.2 A 막힘 확인 순서

1. **가드와 무관한 확인이 맨 처음이다.** 실물 쓰기가 닫혀 있는 동안(`UsbPhysicalWriteGate.buildEnabled == false`) 루트의 realpath(3)가 임시 폴더 뿌리 아래가 아니면 `physicalDisabled`로 끝낸다. 잠금 파일도 만들지 않고 USB 파일 연산도 하지 않는다. 주입한 가드가 "디스크 이미지"라고 해도 같다: 가드 값 하나가 거짓이면 관문과 가드 값 확인이 함께 뚫리기 때문이다. 디스크 이미지는 lab 도구·앱 자가 테스트가 늘 임시 폴더 아래에 붙이고, 실물은 `/Volumes` 아래에 붙는다. 이어서 루트가 정말 마운트 지점인지(statfs `f_mntonname` = realpath) 본다. 아니면 `notMountPoint`. 이 값을 기준 마운트 지점으로 기억한다(7.5).
2. 가드로 볼륨 정보를 읽는다(읽기만). 볼륨 UUID가 없으면 `noVolumeUUID`(잠금 전이라 잠금 파일이 생기지 않는다).
3. 잠금: `usb-sessions/<볼륨 UUID>.lock`에 `flock(LOCK_EX | LOCK_NB)`. 못 잡으면 `volumeBusy`. 쓰기·되돌리기·회복이 끝날 때까지 쥔다.
4. rekordbox 실행(`rekordboxRunning`), 볼륨 정책(`UsbVolumePolicy`)과 보호 경로(`protectedPath`), 실물 관문(`UsbRuleCheck`)과 가드 값이 실물이면 `physicalDisabled`.
5. 닫히지 않은 저널이 있으면 `recoveryNeeded`. 닫힌 상태는 `UsbJournal.closedStates` = verified·rolledBack·restored·recovered·dryRun·needsReplan 한 곳에 둔다. 드라이 런은 USB에 아무것도 쓰지 않으므로, needsReplan은 회복이 우리 임시 파일을 이미 지웠으므로 다음 쓰기를 막지 않는다. 저널 파일을 읽지 못하면 쓰기·되돌리기·회복 모두 `journalUnreadable`로 막는다(회복도 거부하므로 회복하라고 안내하지 않는다). 앱은 `UsbWriter.journalStatus`로 없음·열림·닫힘·깨짐을 가른다.
6. 우리 폴더(`PIONEER/rekordbox`, `PIONEER/USBANLZ`, `PIONEER/Artwork`, `Contents`)에 `.djc-part-*`가 있으면 `tempFilesPresent`(다른 Mac·다른 `DJC_HOME`의 쓰기 흔적). 이름만 본다.
7. 수정: 지금 DB 지문(크기·SHA-256, 사이드카 포함 — mtime은 FAT 2초 단위·복원 때 바뀌어 비교하지 않는다)이 계획 때 base와 같아야 한다. 아니면 `usbChanged`. 내보내기: `PIONEER/` 바로 아래에 `.`으로 시작하지 않는 이름이 없어야 한다(`notEmpty`). 개수는 바로 아래 이름만 세고 열지 않는 경로로 내려가지 않는다.
8. 형식 검사기(`UsbWriteInspector`)의 막힘. 10의 경로 막힘이 있으면 부르지 않는다(받을 수 없는 경로를 검사기가 읽지 않게).
9. 용량: 새로 쓸 크기(클러스터 단위 올림) + 가장 큰 DB × 2 + max(64 MiB, 가용 1%) − 지울 크기 ≤ 가용.
10. 대상 경로: 상대 경로, `..` 없음, 열지 않는 경로 아님, 부모 경로에 심볼릭 링크 없음. 모양 규칙(`UsbWriter.isSafeRelativePath`: 첫 성분 PIONEER·Contents, ""·"."·".." 성분 없음)은 되돌리기·회복이 기록을 읽을 때도 같이 쓴다. 세션 번호는 임시 이름이 되므로 영문·숫자·`-`·`_`만 받는다.
11. **만들 대상 충돌(`destinationExists`):** rename(2)은 대상이 있으면 조용히 바꿔치고, FAT(macOS msdos)는 대소문자·NFC/NFD만 다른 이름을 같은 이름으로 본다. 만들 파일·내보내기의 DB·새 폴더마다 부모 폴더 목록에 같은 `UsbLayout.collisionKey`의 이름이 있으면 막는다. 받을 수 없는 경로는 stat·열거하지 않고 건너뛴다(10이 막는다). 폴더는 NFC까지 같은 철자면 있는 폴더로 쓰고, 철자만 다르면 막는다. D 단계의 rename 직전에 한 번 더 본다. 그 사이 생긴 이름은 우리 것이 아니므로 H도 건드리지 않는다. 백업에도 없는 사용자 파일(예: `Contents/`에 직접 넣은 음원)을 잃지 않게 하는 규칙이다.

### 7.3 파일 하나 쓰기

- 임시 이름은 `UsbLayout.tempName(session:sequence:)`(같은 폴더, `.djc-part-…`)다. 대상 이름과 무관해 `._`·`_`로 시작하는 이름과 겹치지 않는다.
- 저널 항목(pending)을 먼저 적는다 → 데이터만 복사(`O_EXCL`, 확장 속성·ACL 없음) 또는 준비 파일 쓰기 → 음원·아트워크는 원본 mtime → `F_FULLFSYNC` → 덮어쓰기면 대상의 지금 SHA-256(분석 파일은 PPTH도)이 계획과 같은지, 만들기면 충돌 재확인 → rename → 정확한 이름 `._<대상>`·`._<임시>`만 지움 → 폴더 fsync → 저널 done.
- `._` 파일은 패턴으로 쓸지 않는다. 사용자의 `._` 파일은 남는다.
- `RENAME_SWAP`·`renamex_np`를 쓰지 않는다. FAT에서는 맞바꾸지 않고 덮어쓴다.
- 재사용은 쓰지 않고 크기와 내용 해시만 확인한다. 분석 파일·아트워크는 계획 SHA-256, 음원은 목표 지문의 SHA-256, 없으면 로컬 원본의 SHA-1과 비교한다. 음원에 둘 다 없을 때만 크기만 본다. 음원은 덮어쓰지 않는다.

### 7.4 Mac 쪽 내구 쓰기와 저널

- 저널·manifest·보고서는 같은 폴더 임시 파일 → write → `F_FULLFSYNC` → rename → 폴더 fsync로 쓴다(`UsbDurableFile`).
- 저널(`usb-sessions/<볼륨 UUID>.json`)은 파일·DB 항목(created·reused·overwritten, pending·done), 만든 폴더, 지운 사이드카, 지우기 상태(removed·skipped와 이유), 백업 폴더를 담는다. 상태 값은 `committing`·`committed` 하나씩이고, 형식별 진행은 DB 항목에서 읽는다(`committedFormats`·`committingFormat`).
- 저널 파일은 볼륨마다 하나라 새 세션(드라이 런 포함)이 닫힌 옛 저널을 덮는다. 그래서 되돌리기와 백업 정리는 백업 폴더의 `journal.json`·`report.json`을 읽는다.

### 7.5 마운트 확인과 볼륨이 사라질 때

- C 시작, D의 파일마다 쓰기 전과 rename 직전, E의 DB마다, F·G 전, H 시작과 H의 파일마다, 회복·되돌리기의 파일 연산 전에 루트가 아직 기준 마운트 지점에 붙어 있는지 본다.
- 실물은 뽑히면 마운트 폴더가 사라지지만, 디스크 이미지를 강제로 떼면 임시 폴더의 마운트 지점은 빈 폴더로 남는다. 확인 없이 이어 가면 USB가 아니라 Mac 폴더에 쓴다.
- 사라졌으면 그 자리에서 멈추고 되돌리지 않는다(`volumeLost`). 저널은 마지막 내구 상태 그대로 두고, 같은 볼륨이 다시 붙으면 회복이 이어 판정한다.

### 7.6 H 되돌리기

- 마운트 확인(사라졌으면 멈춤) → rekordbox 재확인(켜져 있으면 저널 `restorePending`) → pending 항목은 임시 이름만 지운다(대상 이름의 파일은 우리 것이 아닐 수 있다) → 만든 파일을 지운다(+ 정확한 `._`) → 덮어쓴 파일은 백업에서 임시 이름 → rename.
- DB는 저널의 DB 항목대로 한다. 쓰기 전에 없던 DB(내보내기)는 그 DB·`-wal`·`-shm`·`-journal`과 정확한 이름의 `._`만 지운다. 덮어쓴 DB(수정)는 USB 사이드카를 지우고 백업의 DB·사이드카·원래 있던 `._<DB>`를 되살린다.
- 지운 파일은 백업에서 되살린다. 지운 음원은 로컬 원본의 SHA-1이 같을 때만 다시 복사하고, 원본이 없거나 바뀌었으면 알림만 남기고 지문 비교에서 뺀다(되돌릴 수 없는 것을 실패로 세면 회복이 끝나지 않는다). 쓰기 전에 이미 없던 파일은 되살릴 것이 없다.
- 만든 폴더는 거꾸로 비었으면 지운다. 우리 경로 지문이 쓰기 전과 같으면 `rolledBack`, 아니면 `restoreFailed`.

### 7.7 회복(`djc usb-recover`) — 대상 먼저

- 쓰기와 같은 확인(7.2의 1–4, 관문 포함)을 먼저 거친다. 회복도 USB 파일을 지우고 이름을 바꾸는 쓰기다. 앱의 회복도 같다.
- 저널의 경로·임시 이름·세션이 7.2-10의 모양 규칙을 어기거나 백업 폴더가 이 볼륨의 `usb-backups/<볼륨>/` 밖이면 파일 연산 없이 `journalUnreadable`로 막는다. 없어진 백업 폴더는 없는 것으로 보고 기록을 새로 만들지 않는다.
- `usb-restore`가 연 저널(끊긴 되돌리기)은 되돌리기로 마저 하고 `restored`로 닫는다. 그 쓰기의 백업 기록은 바꾸지 않는다.
- DB마다 옛 해시·새 해시·없음·그 밖으로 나눈다. "그 밖"(기기가 바꿈)이 하나라도 있으면 저널에 적힌 우리 임시 파일만 지우고 `needsReplan`으로 닫는다. 다음 쓰기는 지금 USB를 다시 읽어 만든 새 계획이어야 한다(옛 계획은 `usbChanged`로 막힌다).
- 대상이 없고 임시 파일이 새 해시와 같으면 rename을 마친다(만들기는 충돌 재확인 뒤). 모든 DB가 새것이면 F·G를 다시 해 `recovered`. 일부만 바뀌었으면 준비 폴더가 온전하고 남은 DB가 옛것일 때 마저 쓰고, 아니면 H로 `rolledBack`.
- 저널에 적힌 임시 파일은 판정이 끝난 뒤 지운다. 저널이 없으면 USB의 `.djc-part-*`를 보고만 하고 `--discard-temp`일 때만 지운다.
- 닫을 때 그 쓰기의 백업 폴더에 `journal.json`·`report.json`(회복 뒤 지금 DB 해시)을 남긴다. 끊긴 쓰기도 백업 정리와 되돌리기가 알아보게 하려는 것이다. 백업 전에 끊겼으면(USB에 쓴 것 없음) 알림만 남긴다.

### 7.8 되돌리기(`djc usb-restore`)

- 같은 확인을 먼저 거친다. 무엇을 되돌릴지는 그 백업 폴더의 `journal.json`에서 읽는다. 백업 폴더는 realpath가 이 볼륨의 `usb-backups/<볼륨>/` 바로 아래여야 하고(`backupOutside`), `journal.json`·`manifest.json`의 경로가 7.2-10의 모양 규칙을 어기면 파일 연산 없이 `backupUnreadable`로 막는다.
- 되돌리기를 마치면 백업 폴더에 `restored.json`을 남긴다. 같은 백업으로 다시 되돌리면 "이미 되돌렸습니다"로 끝낸다(그 뒤 USB를 바꾼 것은 기기가 아니라 이 되돌리기다). `--backup`을 빼도 가장 최근 백업을 고르므로 두 번 돌려 더 옛 쓰기까지 되돌리지는 않는다.
- 지금 DB 해시가 `report.json`의 결과 해시와 같고 USB에 `-wal`·`-journal`이 없을 때만 진행한다. 아니면(기기가 쓴 기록 등) 막고, `--discard-device-changes`를 줘야 기기 변경을 버리고 되돌린다. 회복이 needsReplan으로 닫은 쓰기는 해시가 같아도 이 인자를 요구한다.
- 만든 파일·폴더·DB는 지우고, 덮어쓴 것은 백업에서 되살리고, 재사용한 것은 그대로 둔다. 지웠던 음원은 로컬 원본의 SHA-1이 manifest와 같을 때만 다시 복사한다. 그래서 내보내기 직후 되돌리면 빈 USB로 돌아간다.

### 7.9 백업 정리

볼륨마다 최근 다섯 개만 남긴다. 닫히지 않은 저널이 가리키는 백업, 마지막 verified 쓰기의 백업, 마지막 needsReplan 백업(다음 verified 전까지)은 남긴다. 판정은 백업 폴더의 `journal.json` 상태로 한다.

### 7.10 디스크 이미지(`djc lab usb-image`)

- 모든 경로 인자는 임시 폴더 아래만 받는다(`UsbScratchPath`). 경로 비교는 realpath(3)끼리 한다: `hdiutil info`의 image-path는 attach 때 준 철자 그대로라 `/tmp`와 `/private/tmp`가 섞인다.
- 만들기: sparse raw 파일 → MBR(파티션 하나, 2048섹터부터, 형식 0x0B 또는 0x0C) → `hdiutil attach -nomount` → 장치는 그 attach plist의 `content-hint`로 고른다(전체 `FDisk_partition_scheme`, 파티션 `DOS_FAT_32`·`Windows_FAT_32`, 배열 순서에 기대지 않는다) → 파괴 명령 직전 image-path·`BusProtocol == "Disk Image"`·`Internal == false`를 다시 확인 → `newfs_msdos -F 32` → 파티션 표 값만 확인(포맷 직후의 파일 시스템 이름은 비어 있거나 "MS-DOS"라 보지 않는다) → 떼고 BPB로 FAT32 판정(클러스터 수 ≥ 65,525).
- 클러스터: 파티션 8 GiB 이하는 4 KiB부터, 클러스터 수가 FAT32 최소에 모자라면 반으로 줄인다. 64 MiB보다 작은 이미지는 받지 않는다.
- hdiutil은 성공해도 stderr에 경고를 찍는다. 성공·실패는 rc와 stdout plist로만 판정한다.
- 붙이기는 `diskutil mount -mountOptions nobrowse -mountPoint`로 하고, 파일 시스템 이름이 "MS-DOS FAT32"로 보일 때까지 기다린다.
- 장치 번호는 인자로 받지 않는다. 늘 이미지 경로에서 `hdiutil info`로 찾는다. rekordbox가 켜져 있으면 만들기·붙이기·채우기·쓰기 시험을 거부한다.
- 볼륨이 디스크 이미지인지는 DiskArbitration `DADeviceModel == "Disk Image"`, `hdiutil info`의 짝, image-path가 일반 파일, 셋이 모두 맞을 때만 참이다. 모르면 실물로 본다. FAT32는 볼륨 종류·볼륨 형식("MS-DOS (FAT32)")·파티션 형식이 모두 맞을 때만이다(0x0B 파티션 안의 FAT16은 FAT16).

### 7.11 근거

디스크 이미지 강제 분리 시험(`djc lab usb-commit-crash`): 빈 FAT32 틀의 복제본에 합성 묶음을 쓰는 도중 무작위 시점에 강제로 떼고, 다시 붙여 원시 상태를 본 뒤 회복한다. 반복 시험에서 파일마다 옛것 또는 새것이었고, 회복 뒤 트리는 쓰기 전 또는 목표와 같았으며 분리 뒤 Mac 폴더에 쓴 흔적은 없었다.

### 7.12 빈 USB 내보내기(`UsbExportSession`, `djc usb-export`)

로컬 스냅샷 사본의 곡·재생 목록을 빈 FAT32·MBR USB에 두 형식으로 내보낸다. 흐름은 후보 → 계획 → 빌더 → 준비 → 쓰기 → 검증이고, 세션(`UsbExportSession`, DJCStorage)이 순서대로 부른다. 미리 보기(`preview`)와 드라이 런은 준비까지 같고 USB에 쓰지 않는다.

1. **원본**: 받은 사본이 라이브 master.db(`~/Library/Pioneer/rekordbox/master.db`·rekordbox 폴더의 master.db, 실경로·같은 inode)면 열지 않고 `liveDatabase`. 스냅샷 시각을 이때 원본에서 푼다(`UsbSnapshotTime`: `--snapshot-time` → 사본 이름 → 수정 시각). 세션이 다시 뜨는 사본은 이름·시각이 달라지기 때문이다.
2. **볼륨 단위 막힘**(여기서 막히면 로컬 사본도 뜨지 않는다): 이 Mac의 rekordbox가 확인한 버전이 아님(`localVersionUnverified`), 볼륨 정책(`UsbVolumePolicy`, 내보내기), 실물 관문(`UsbRuleCheck`, 실물이면 `physicalDisabled`), `PIONEER/rekordbox/`에 DB 이름이 있음(`libraryExists` — USB 수정으로 안내), DB는 없지만 `PIONEER/` 바로 아래에 `.`으로 시작하지 않는 이름이 있음(`leftoverPioneer`, 이름만 세고 열지 않는 경로로 내려가지 않는다). rekordbox 실행은 쓰기 절차가 본다(켜진 채 미리 보기는 된다).
3. **세션 사본**: 받은 사본을 `usb-snapshots/local-<세션>/`에 한 번 더 뜬다(원본 = 받은 사본, `force: true` — 우리 사본이라 실행 중 확인·WAL 거부 없이 곁의 `-wal`을 사본 안에서 합친다. 원본과 그 `-wal`은 읽기만). 사용자 스냅샷 폴더는 목적지·원본으로 쓰지 않고 읽지도 않는다. 세션이 끝나면(성공·실패·취소) 이 폴더를 지운다(클라우드 토큰이 든 DB 사본을 남기지 않게).
4. **계획**: 이미 `Contents/`가 있으면 그 아래 이름·철자를 모아(`UsbTree.walk`, 파일은 열지 않음) `UsbExistingState.contentsOnly`로 넘긴다. 같은 충돌 키의 파일이 같은 내용(크기·SHA-256)이면 그 파일을 가리키고(쓰지 않음), 다르면 ` (2)`처럼 번호를 붙이며 폴더는 USB 철자를 쓴다(§5). 클러스터 크기는 볼륨 값.
5. **빌더와 행 크기**: `UsbLibraryBuilder.build`(myTagMasterDBID는 난수, createdDate는 오늘). Device Library를 쓰면 행 크기를 먼저 본다(`PdbRowSize`): 트랙 행이 빈 쪽에도 안 들어가면 그 곡(`trackRowTooLarge`), 아티스트·앨범 행이 가까운 모양(255바이트)에 안 들어가면 그 이름을 쓰는 곡(`nameTooLongForDeviceLibrary`, `pdbFarOffsetRows`), My Tag 행이면 볼륨(`myTagNameTooLongForDeviceLibrary` — My Tag 정의는 곡과 무관하게 모두 들어가므로 곡을 빼서 풀 수 없다). 막힌 곡을 빼고 다시 계획해 ID가 빈틈없게 한다.
6. **준비**(`UsbExportAssembly`): Mac의 `usb-staging/<세션>/`에 USB와 같은 자리로 만든다.
   - 곡마다 분석 파일 셋(§4, 경고 `analysisPSSIMasked`·`kind4CueDropped` 등), 아트워크(`artwork_s.jpg` → a·b, `artwork_m.jpg` → a_m·b_m, 바이트 복사·원본 수정 시각, a는 Device Library·b는 OneLibrary를 쓸 때만).
   - OneLibrary: `OneLibraryWriter.create` → `verify`(준비한 DB를 읽기 전용으로 열지 않는다 — WAL 모양 파일 곁에 사이드카가 남는다). Device Library: `PdbWriter.files(.fresh)` → `PdbRoundTrip.check`가 빈 배열이어야 한다.
   - 음원은 복사 목록만(원본 → 계획 경로, 크기 = `FileSize`, 원본 수정 시각). `--settings`면 로컬 설정 파일 셋(§6).
   - 목표 지문: DB 셋·분석 파일·아트워크는 크기·SHA-256, 음원은 크기(해시는 복사하며 잰다).
   - 확인 안 된 규칙 = 계획 규칙(경로·파일 이름·아티스트·앨범·목록 이름의 `pdbLongAscii` 포함) ∪ 분석 파일 규칙 ∪ Device Library 작성기가 실제로 UTF-16으로 쓴 긴 ASCII(장르·레이블·키·My Tag·메뉴 이름까지) ∪ `settingFiles`(켰을 때). 규칙별 곡 수는 계획 곡 규칙에 작성기의 곡별 규칙을 더해 센다(같은 곡은 한 번).
7. **막힘 모음**: 곡·목록 단위 막힘은 그 곡·목록만 빼고 쓴다. 볼륨 단위(2·5·확인 안 된 규칙·용량 `insufficientSpace`·곡이 없음 `noTracks`)가 하나라도 있으면 쓰지 않는다.
8. **쓰기**: `UsbWriter.write`(§7.1) — 검사기 `UsbEmptyVolumeInspector`(A 단계에서 한 번 더: `PIONEER/` 바로 아래 이름 0개, 만들 대상과 충돌 키가 같은 이름 없음), 검증기 `UsbFingerprintVerifier`·`OneLibraryVerifier`·`PdbVerifier`·`UsbInvariantVerifier`, `ppthReader`는 분석 파일의 PPTH 태그.
9. **정리**: 준비 폴더를 지운다. 끝나지 않은 쓰기(볼륨이 사라짐·되돌리기 실패·되돌리기 미룸)는 회복이 쓸 수 있게 남긴다.

진행 이벤트: 세션이 `planning` → `staging`(곡 n/N, 취소 가능)을 내고, 이어서 쓰기 절차가 `backup` → `files` → `commit`(취소 불가) → `cleanup` → `verify`를 낸다. 준비 중 취소하면 저널도 만들지 않는다.

**검증기**(G 단계, USB에서 다시 사본을 떠서 연다. 문제는 표·칸 이름·곡 id·수만 적는다):

- `OneLibraryVerifier`: 사이드카(`-wal`·`-shm`·`-journal`)가 없고, 사본의 무결성·암호 검사가 통과하고, 다시 읽은 모델 = 기대 모델의 OneLibrary 투영(`UsbLibraryDiff`, formats: [.oneLibrary]).
- `PdbVerifier`: 두 파일의 칸 = 작성기가 쓴 모델(`PdbFiles.written`)의 Device Library 투영, 머리 0x10 = 5, 머리 순번 > 모든 쪽 순번, 구조 문제·먼 모양 행 0, 표마다 사슬 마지막 쪽 = 포인터 last_page이고 그 쪽 next = 빈 후보, 빈 후보는 0으로 채운 쪽이거나 파일 끝 너머.
- `UsbInvariantVerifier`: ① 곡마다 pdb 분석 경로 = OneLibrary 분석 경로(NFC) ② `.DAT` PPTH = 두 DB의 곡 경로 ③ 파일 이름 = 경로 끝 성분 ④ DB가 가리키는 파일(음원·분석 파일 셋·아트워크)이 모두 있고 음원 크기 = 파일 크기 칸 ⑤ 분석 파일 폴더 안 같은 번호를 두 곡이 쓰지 않음 ⑥ 곡 수 칸(OneLibrary property·pdb 표 19)과 두 형식의 곡 수가 같음 ⑦ `._*`·`.djc-part-*` 0개.

디스크 이미지에서 확인하는 법: `docs/cli.md`의 "USB 내보내기". 골든과는 `djc lab usb-diff <골든> <이미지> --ignore-anlz-folder --files --anlz --mtime`(재생 목록 표는 rekordbox가 항목을 한 번 더 넣는 모양이 있어 `--skip`으로 뺀다), 다시 만들기는 `djc lab usb-rebuild`로 본다(§8.2). 골든과 달라야 정상인 것: 설정 파일 셋(기본 끔), DB 세 파일의 바이트(칸 비교로 판정), property의 createdDate·myTagMasterDBID(Device Library 날짜 포함), 지운 행 id(새 파일에는 없다), 분석 파일의 수정 시각(쓴 시각).

## 8. USB 안 수정

### 8.1 읽기 점검(`UsbRead`, `djc usb-info`)

고치기 전, 그리고 앱 사이드바가 USB를 보여 줄 때 USB를 읽기만 해서 무엇이 있는지·건강한지 본다. USB에는 아무것도 쓰지 않는다. 명령과 JSON 모양은 `docs/cli.md`의 "USB 읽기".

1. 볼륨 판정: 대상 경로의 `statfs` 마운트 지점이 Mac 시동 볼륨(`/`·`/System/Volumes/Data`)이 아니면 — 볼륨 맨 위가 아닌 하위 폴더여도 — 그 볼륨(`UsbVolumes.info`)으로 보고 `UsbRead.readRefusal`로 먼저 판정한다. 막히면 사본도 뜨지 않는다.
   1. 볼륨 UUID가 쓰기 금지 목록에 있음 → `denylisted`(디스크 이미지여도)
   2. 디스크 이미지 → 읽는다
   3. 목록 파일이 깨짐(고정 위치·`DJC_HOME` 어느 쪽이든) → `denyListUnreadable`
   4. 고정 위치 목록이 없거나 항목이 0 → `denyListNotRegistered`. 증거용 USB를 가려낼 수단이 거부 목록뿐이라, 등록 전에는 실물 USB를 읽지 않는다
   5. 볼륨 UUID를 읽지 못함 → `noVolumeUUID`. 목록과 맞춰 볼 수 없으므로 읽지 않는다(쓰기 관문과 같다)
   6. 그 밖 → 읽는다. 볼륨 정책 문제(`UsbVolumePolicy`, 내보내기·고치기 각각)를 함께 적는다

   부르는 쪽이 볼륨 없이(폴더 대상으로) 넘겨도 `UsbRead.info`가 마운트 지점을 다시 보고, Mac 시동 볼륨이 아니면 읽지 않는다. 사본 폴더는 없거나 비어 있어야 하며(아니면 거부), 끝나면 그 호출이 뜬 사본만 지운다.
2. 형식: `PIONEER/rekordbox/` 바로 아래 파일 이름만 본다(`exportLibrary.db` → OneLibrary, `export.pdb` → Device Library).
3. DB: `UsbSnapshot.take`로 Mac 쪽 사본을 떠서(§2.3) 읽고 끝나면 지운다.
   - OneLibrary: 사이드카(`-wal`·`-journal`) 유무, 머리 모양(wal·rollback), `integrity_check`·`cipher_integrity_check`, 호환 검사(§2.4), 곡·재생 목록·My Tag·기록 수. 사본이 온전하지 않으면 OneLibrary는 읽지 못한 것으로 적고 pdb 둘만 따로 떠서 읽는다.
   - Device Library: 머리 0x10(두 파일, 5가 아니면 rekordbox가 정상으로 닫지 않은 것), 기록 표 산 행, 모르는 표 산 행, 구조 문제 수(§3.7), 왕복 검사(`PdbRoundTrip.check`, §3.8: 읽기 → 모델 → 다시 쓰기 → 다시 읽기). 왕복 검사가 통과하지 못하면(My Tag 연결·모르는 표 행 등 작성기가 다시 만들 수 없는 것이 있음) 경고 `pdbRoundTripFailed`를 문제 수만 적어 낸다.
4. 두 형식 일치(`UsbLibrary.merge`, §2.6): 곡 ID·경로가 같은지, 다른 재생 목록 수, 고치기를 막는 불일치(`blocksEditing`)가 있는지, 모든 곡의 masterDbId가 한 값인지, 두 형식의 myTagMasterDBID가 같은지. 식별값 자체는 내지 않는다.
5. 분석 파일: 곡마다 두 DB가 가리키는 경로(같으면 한 번)의 `.DAT`·`.EXT`·`.2EX`가 일반 파일로 있는지, `.DAT` PPTH = 곡 경로(NFC)인지(§4.3), 파일 번호가 0이 아닌지(§5). DB 경로가 열지 않는 경로·링크를 거치면 열지 않고 없는 파일로 센다.
6. 이 Mac의 rekordbox 버전이 확인한 버전인지(`RekordboxCompatibility.verifiedAppVersions`).

경고 code: `pdbOpenFlag`, `unknownTableRows`, `pdbStructure`, `pdbRoundTripFailed`, `deviceLibraryUnreadable`, `oneLibrarySidecar`, `oneLibraryUnsupported`, `oneLibraryUnreadable`, `formatMismatch`, `analysisMissing`, `analysisPathMismatch`. 곡마다 파일 번호가 0이 아닌 것, 두 형식의 항목만 다른 재생 목록(rekordbox도 만드는 모양)은 수로만 적고 경고하지 않는다.

### 8.2 실험 도구

- `djc lab usb-diff <A> <B> --files --anlz`: 모델 비교(§2.6)에 더해 파일 트리(NFC 경로·크기·SHA-256, macOS 파일·`._*`·열지 않는 경로 제외)와 분석 파일(PPTH·확장자로 짝지어 태그 목록·태그 바이트)을 비교한다. 경로 대신 묶음 이름(DB·설정·USBANLZ·Artwork·Contents)·곡 id·태그 이름·수만 찍는다. `--ignore-anlz-folder`면 파일 트리에서도 USBANLZ 파일을 (PPTH, 확장자)로 짝짓는다. 한쪽에 같은 (PPTH, 확장자) 파일이 여럿이면(같은 곡의 분석 파일을 다른 폴더에 한 벌 더 둔 사본 등) 버리지 않고 모두 비교하고 "PPTH 겹침"으로 따로 센다. "n/N 바이트 같음"의 N은 한쪽의 모든 분석 파일 수(큰 쪽)다. `--mtime`이면 내용이 같은 파일의 수정 시각도 FAT 단위(2초로 내림)로 비교해 묶음별로 센다.
- `djc lab usb-rebuild <USB 폴더> <출력 폴더>`: USB의 두 형식을 사본으로 떠서 읽어 합친 모델로 DB 셋만 새 내보내기 모양(`OneLibraryWriter.create`, `PdbWriter` fresh)으로 다시 만든다(음원·분석 파일은 복사하지 않는다). `djc lab usb-diff <USB> <출력> --ignore-ids`가 "차이 0"이면 읽기 → 쓰기가 모델을 잃지 않는다. 입력·출력은 임시 폴더 아래만, 출력은 없거나 빈 폴더.
- `djc lab usb-anlz-relocate <USB 사본> --track <id> --folder <P???/????????> [--db-only|--files-only|--decoy-slot0|--cue-variant]`: 기기가 분석 파일을 DB 경로로 찾는지 확인하려고 한 곡을 일부러 어긋나게 만든다. Mac 데이터 볼륨의 임시 폴더 아래 **사본 폴더**에만 쓴다(마운트된 볼륨의 맨 위나 그 안 폴더·링크·임시 폴더 밖·rekordbox 실행 중이면 거부). pdb 분석 경로는 같은 길이 문자열로 제자리 교체하고(길이가 다르면 거부), OneLibrary는 `UPDATE` 뒤 `wal_checkpoint(TRUNCATE)`로 사이드카를 남기지 않는다. 모든 확인을 먼저 하고 하나라도 걸리면 아무것도 바꾸지 않는다.
  - 기본·`--db-only`: 파일을 새 폴더로 옮기고 두 DB 경로도 옮긴다.
  - `--files-only`: 파일은 그대로, 두 DB 경로만 같은 길이의 없는 폴더로.
  - `--cue-variant`: 새 폴더에 파일을 복사하고 그쪽 `.DAT`의 핫큐 A 위치만 바꾼다(인코더로 원래 핫큐 목록을 다시 만든 바이트가 원본과 같을 때만). DB는 새 폴더.
  - `--decoy-slot0`(`--folder` 없음): 원래 폴더의 `ANLZ0000`은 PPTH만 바꾼 가짜, 진짜는 `ANLZ0001`, DB는 `ANLZ0001.DAT`.

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

첫 판에서 코드가 막는 것과 쓰지 않는 것이다. 막힘은 이유와 할 일을 한 문장으로 알린다.

| 무엇 | 지금 | 규칙·code |
|---|---|---|
| 실물 USB에 쓰기 | 코드 상수로 닫힘. 디스크 이미지(임시 폴더 아래)에만 쓴다. `--confirm`·`--allow-provisional`로도 풀리지 않는다 | `physicalVolume`, `physicalDisabled` |
| 분석 파일 폴더 이름 | rekordbox 규칙을 따르지 않고 DJCrate 고유 이름(content ID)으로 짓는다 | `analysisFolderNaming` |
| Device Library 먼 오프셋 행 | 쓰지 않는다. 아티스트·앨범 행이 가까운 모양에 안 들어가면 그 곡을, My Tag 행이면 내보내기 전체를 막는다. 트랙 행이 빈 쪽에도 안 들어가면 그 곡을 막는다 | `pdbFarOffsetRows`, `nameTooLongForDeviceLibrary`, `myTagNameTooLongForDeviceLibrary`, `trackRowTooLarge` |
| 긴 ASCII(127자 이상 순수 ASCII) | rekordbox의 0x40 모양 대신 UTF-16으로 쓴다 | `pdbLongAscii` |
| 재생 기록 표 | 쓰지 않는다. 기기 기록 행이 있는 USB를 다시 만드는 쓰기는 디스크 이미지에서도 막는다 | `carriedDeviceRows` |
| My Tag 연결 | 두 형식 모두 쓰지 않는다. Device Library에 연결이 있는 USB는 다시 쓸 수 없는 모양으로 본다(왕복 검사 실패) | `myTagLinks`, `pdbRoundTripFailed` |
| 기기 설정 파일 | 기본 끔. `--settings <로컬 설정 폴더>`로 켤 때만 셋을 옮긴다. `DEVSETTING.DAT`·`djprofile.nxs`는 만들지 않는다 | `settingFiles` |
| 스마트(인텔리전트) 재생 목록 | 내보내지 않는다(그 곡은 다른 선택대로 간다) | `smartPlaylist` |
| 이미 라이브러리가 있는 USB에 내보내기 | 막고 USB 수정으로 안내한다. DB가 없어도 `PIONEER/`에 무엇이 남아 있으면 막는다 | `libraryExists`, `leftoverPioneer` |
| 확인하지 않은 로컬 rekordbox 버전 | 내보내기를 막는다(확인: 7.2.x) | `localVersionUnverified` |
| 스냅샷 뒤에 바뀐 곡 | 음원 크기가 `FileSize`와 다른 곡, 스냅샷 뒤 분석 파일이 바뀐 곡은 그 곡만 막는다(§5 막힘) | `audioSizeMismatch`, `analysisNewerThanSnapshot` |
| 볼륨 모양 | FAT32·MBR 첫 파티션·512바이트 섹터만. GPT·exFAT·HFS+·APFS·내장·네트워크·읽기 전용은 막는다 | `UsbVolumePolicy` |

## 11. 새 USB 쓰기 경로를 여는 방법

rekordbox 실험 → 사본 재현 → 칸 단위 일치 → 골든 테스트 → `UsbProvisionalRule.confirmed`에 더함. 더한 뒤 §9 표의 지금 값을 고친다.

1. **rekordbox 실험**: 사용자에게 rekordbox 7.2.x에서 그 동작을 직접 해 달라고 부탁한다(빈 USB에 내보내기·USB 수정 등, 곡 이름을 받고 끝나면 rekordbox 종료). 결과 USB는 폴더 사본이나 디스크 이미지로 떠서 본다(`PIONEER/extracted`·`CDP`·`djprofile.nxs`는 빼고, 실물은 읽기만).
2. **사본 재현**: 같은 입력을 DJCrate로 디스크 이미지에 쓴다(`djc usb-export`, 필요하면 `--allow-provisional`로 그 규칙만 푼 계획).
3. **칸 단위 일치**: `djc lab usb-diff <rekordbox 결과> <재현> --files --anlz [--mtime]`로 표·칸·태그·파일 단위 차이가 0이거나, 남은 차이마다 이유(쓴 시각·난수 ID 등)를 설명할 수 있어야 한다. 쪽 바이트는 `djc lab pdb-verify`, 분석 파일은 `djc lab usb-anlz-check`로 본다.
4. **골든 테스트**: 합성 재료로 그 규칙을 고정하는 시험을 남긴다. 근거 주석은 `// rekordbox 7.2.18 골든 관찰(<날짜> 내보내기)` 한 줄이고, 골든 바이트를 통째로 넣지 않는다.
5. **확인 목록**: `UsbProvisionalRule.confirmed`에 더하고 §9 표를 고친다. 한 번에 한 규칙씩 연다.
6. rekordbox가 업데이트되면 `djc compat`·`djc usb-info`로 먼저 보고, 실험으로 다시 확인하기 전에는 확인한 버전·규칙 목록을 넓히지 않는다. 실물 쓰기 관문(`buildEnabled`)을 여는 것은 따로 정한다.
