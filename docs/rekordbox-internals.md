# rekordbox 7 내부 형식 — DJCrate가 알아낸 쓰기 규칙

rekordbox 7.2.18에서 사용자가 직접 편집한 결과를 스냅샷끼리 diff해서 뽑은 규칙이다. 각 규칙은 "실험 전 사본에 DJCrate로 같은 편집을 쓰고, rekordbox가 쓴 결과와 칸마다 비교"해서 확인했다. 확인하지 못한 규칙은 코드에서 막아 두었다(아래 "막아 둔 것").

코드: `Sources/RekordboxKit/` — `RekordboxWriter`(DB, 역할별 `+Cues`·`+Grid`·`+Gain`·`+Analysis`·`+Tags`·`+Playlist`·`+Verify`·`+Backup`), `RekordboxGridWriter`(ANLZ), `RekordboxCompatibility`(쓰기 전 버전·구조 확인), `CueJSON`, `AnlzFile`, `SeekInfo`, `MasterPlaylistsXML`, `CipherDatabase`.

## 파일과 열기

- 라이브러리: `~/Library/Pioneer/rekordbox/master.db` (SQLCipher 4). 키는 pyrekordbox와 같은 방식으로 푼다(`RekordboxKey.derive()`).
- 분석 파일: `~/Library/Pioneer/rekordbox/share/PIONEER/USBANLZ/<3자리>/<uuid 나머지>/ANLZ0000.{DAT,EXT,2EX,3EX}`. 경로는 `djmdContent.AnalysisDataPath`(`.DAT` 경로).
- 삭제 행이 절반쯤 있다(`rb_local_deleted=1`). 집계·쓰기는 항상 삭제되지 않은 행만.
- `agentRegistry`에는 클라우드 인증값이 들어 있다. 읽거나 출력하지 않는다(`djc lab sql`은 이 테이블 질의를 막는다). 예외: 쓰기 모듈이 `localUpdateCount`를 읽고 쓰고, `lastUpdateCount`의 정수 칸만 읽는다.

## 쓰기 전 확인 (`RekordboxCompatibility`)

쓰기 규칙은 rekordbox 7.2.18에서 확인했다. rekordbox가 업데이트로 DB 구조를 바꾸면 규칙이 맞지 않을 수 있어서, 쓰기 전에 다음을 보고 하나라도 다르면 **백업도 뜨지 않고** 막는다.

- 앱 버전: `/Applications/rekordbox N/rekordbox.app`의 `CFBundleShortVersionString` 주.부가 `7.2`(못 찾으면 아래 DB 검사에 맡김). 라이브 DB에만 적용.
- 새 행을 넣는 표(`djmdCue` 29칸, `contentCue` 13칸, 곡 넣기의 `djmdContent`·`djmdArtist`·`djmdAlbum`·`djmdGenre`, 곡 넣기·분석 붙이기의 `contentFile` 24칸·`djmdMixerParam` 15칸, 재생 목록의 `djmdPlaylist` 16칸·`djmdSongPlaylist` 13칸·`djmdCloudFilterPlaylist` 13칸)는 칸 이름이 정확히 같아야 한다. 칸이 늘면 rekordbox가 기대하는 값을 빠뜨리게 된다.
- 고치거나 읽는 칸(`agentRegistry`·`djmdProperty`·곡 삭제의 `djmdSongHistory`)은 모두 있어야 한다.
- `djmdProperty.DBVersion` = `6000`.
- `localUpdateCount` ≥ `lastUpdateCount`(클라우드 동기화가 본 가장 큰 번호). 로컬 번호가 더 작으면 동기화 때 변경이 되돌려졌다는 사례가 있다(2026-09-26 조사). 2026-09-26 실제 라이브러리: 로컬 1,002,950 · 클라우드 372,628.

`djc compat`으로 읽기 전용 확인을 할 수 있다. 새 rekordbox 버전을 허용하려면 "새 쓰기 경로를 여는 방법"처럼 실험으로 큐·그리드·게인 쓰기를 다시 확인한 뒤 `verifiedAppVersions`를 넓힌다.

## 공통: 변경 번호(usn)

- 바뀐 행마다 `rb_local_usn` = `agentRegistry`의 `localUpdateCount`를 1씩 올린 값. 마지막 값을 `localUpdateCount`에 적는다.
- `rb_data_status` 256 → 257 (이미 257이면 그대로). `updated_at`은 `YYYY-MM-DD HH:MM:SS.sss +00:00`.
- 한 곡의 큐를 바꾸면 `contentCue` 먼저, `djmdContent` 다음(연속 번호).

## 큐 (`djmdCue` + `contentCue`)

- 바꾼 큐는 행을 지우고 새로 넣는다. 새 `ID` = 겹치지 않는 임의 UInt32(문자열), `UUID` = 소문자 UUID.
- `InMsec` = ms, `InFrame` = ms × 150 / 1000(내림). 루프가 아니면 `OutMsec` −1, `OutFrame` 0.
- 루프가 아닌 새 큐: `Color` −1, `ColorTableIndex`·`ActiveLoop`·`BeatLoopSize`·`CueMicrosec` NULL, 코멘트 없으면 `Comment` NULL.
- `Kind`: 메모리 0, 핫큐 A·B·C = 1·2·3, D~H = 5~9. Kind 4는 뜻을 몰라 편집 대상에서 뺀다.
- 한도: 메모리 큐 곡당 10개(자동 큐 "1.1Bars" 포함). 핫큐 칸은 곡당 하나씩.
- `contentCue.Cues`는 곡의 모든 큐를 담은 JSON 배열이다.
  - 원래 객체는 **읽은 칸 순서 그대로** 다시 쓴다(옛 rekordbox가 쓴 순서가 다름).
  - 새 객체는 끝에 붙이고 칸 순서는 `ID, ContentID, ContentUUID, InMsec, InFrame, InMpegFrame, InMpegAbs, InPointSeekInfo, OutMsec, OutFrame, OutMpegFrame, OutMpegAbs, OutPointSeekInfo, Kind, Color, ColorTableIndex, ActiveLoop, Comment, BeatLoopSize, CueMicrosec, UUID, created_at, updated_at`.
  - NULL 칸과 빈 코멘트(`""`)는 적지 않는다(라이브러리 JSON에 `"Comment":""`는 0건). 시각은 `2026-09-25T20:20:39.744+00:00`.
  - `rb_cue_count` = 객체 수. `contentCue` 행이 없던 곡은 `ID` = 곡 UUID로 새로 만든다.
- `djmdContent.CueUpdated`(글자형) += 지운 수 + 넣은 수. NULL이면 0부터.

### 루프 (2026-09-26, Flip Flop·ときめき分類学 실험 + 기존 루프 105개)

- `OutMsec` = 끝 ms, `OutFrame` = 끝 ms × 150 / 1000(내림).
- `Color` 255, `ColorTableIndex` 0, `ActiveLoop` 0/1(활성 루프 = 곡을 불러오면 자동으로 반복), `CueMicrosec` 0, `Comment` `''`(JSON에는 안 적음).
- `BeatLoopSize` = 분자 << 16 | 분모. 8박 524289, 16박 1048577, ½박 65538, 박에 맞지 않는 루프 0.
- 새로 만든 루프는 JSON에도 `ActiveLoop`·`BeatLoopSize`가 있다(옛 루프 JSON엔 빠진 경우가 있음).
- 활성 루프는 곡당 하나(라이브러리에 둘 이상인 곡 없음). rekordbox는 활성 켜기를 행 제자리 UPDATE로 하고 `CueUpdated`를 안 올리지만, DJCrate는 지우고 새로 넣는다(결과 상태는 같음).

### 파일 형식별 탐색 위치

- MP3 CBR·M4A·WAV: `InMpegFrame`·`InMpegAbs` 0, SeekInfo NULL.
- FLAC: `InPointSeekInfo` = `"<큐 샘플이 든 FLAC 프레임 시작 샘플>,<그 프레임 바이트 위치 − 첫 오디오 프레임 위치>,<블록 크기>"`. 루프가 아니면 `OutPointSeekInfo` = `"0,0,0"`, 루프면 끝 지점을 같은 식으로. 기존 큐 1,818개·루프 끝 전부와 일치.
- VBR MP3(파일 머리가 Xing·VBRI거나 프레임 길이가 들쭉날쭉): `InMpegFrame` = InFrame / 2(1/75초 단위), `InMpegAbs` = rekordbox가 세는 프레임(LAME 정보 프레임은 세고 다른 인코더의 정보 프레임은 뺌) 중
  `floor(올림(InMpegFrame × 1000 / 75)ms × 샘플레이트 / 1000 / 1152) − 8`번째(음수면 0번째) 프레임의 바이트 위치(첫 센 프레임 기준). 루프 끝도 같은 식, 루프가 아니면 끝은 0·0. SeekInfo는 NULL.
  ms를 버림하면 1,099개, 올림하면 1,118개 전부 맞는다(기존 VBR 큐 1,118개·루프 끝 6개, `djc lab seekinfo-check`). 사본에서 VBR 200곡의 큐 886개를 지우고 다시 써도 885개가 칸까지 같다(`djc lab vbr-cue-repro`, 나머지 1개는 rekordbox가 옛날에 MPEG 칸을 비워 둔 큐).

## 비트그리드 (ANLZ)

- `.DAT`의 `PQTZ`: 박마다 `박 번호(u16 1~4) · BPM×100(u16) · 시각 ms(u32)`. 시각은 정밀 시각을 **내림**, 곡 앞 −1ms 안의 박은 0.
- `.EXT`의 `PQT2`: 머리에 첫 박·마지막 박·박 수·정체 모를 u32, 본문은 박마다 (ms 아래 소수 × 1024). rekordbox가 그리드를 손으로 고치면 PQT2를 빈 형태(머리 0·본문 없음)로 바꾼다 → DJCrate도 그렇게 쓴다.
- 이동만 하면 DB는 안 바뀐다(`contentFile` 해시도 그대로).
- BPM을 바꾸면:
  - `.DAT`의 `contentFile` 행: `Hash`(새 파일 MD5), `Size`, `rb_data_status`, `rb_local_usn`, `updated_at`.
  - `djmdContent`: `BPM`(×100), `AnalysisUpdated`+1·`TrackInfoUpdated`+1(글자형), 상태, usn.
  - 소수(PQT2)가 없으면 첫 박을 ms + 0.5로 보고 다시 계산한다(바이트까지 재현).
- 다른 태그는 바이트 그대로 둔다(`AnlzFile`이 태그 단위로 읽고 PMAI 전체 길이만 다시 적는다).
- **파형 파일(.EXT)이 없는 곡은 rekordbox 분석 전 곡이다**(BPM 0, PQTZ 0박). 그리드만 쓰면 파형 없는 채로 남으므로 막는다(2026-09-26 サラマンダー).
  분석 파일이 아예 없는 곡은 분석 붙이기로 쓰고(아래 "분석 붙이기"), `.DAT`만 있는 반쪽 곡은 "rekordbox에서 트랙 분석을 다시 한 뒤 쓰세요"로 막는다.

## 오토게인 (`djmdMixerParam`)

- `GainHigh`·`GainLow` = 선형 게인 float32의 상위·하위 16비트. `PeakHigh`·`PeakLow`는 샘플 피크.
- rekordbox 편집 시 삭제되지 않은 행 하나의 `GainHigh`·`GainLow`·상태·usn·`updated_at`만 바뀐다(같은 곡의 삭제된 옛 행이 따로 있을 수 있음).
- rekordbox는 약 −10 LUFS에 맞춘다: 게인 dB + 곡 LUFS = −9.97 ± 0.25.

## 태그 (곡 정보)

**실험 1**(2026-09-26 묶음 2, O-Ku-Ri-Mo-No Sunday!): 제목·아티스트(새 이름)·장르(새 이름)·코멘트·별점·키를 고쳤다. 같은 세션에 분석·Relocate·재생 목록 편집도 해서 카운터는 가를 수 없었다.
**실험 2**(2026-09-27, 합성 곡 "DJC 실험곡 1~5"): 정보 패널에서 한 칸씩 고쳤다. 세션 1은 값 넣기, 세션 2는 비우기였다. 각 세션 전후 스냅샷(S0·S1·S2)을 `djc lab db-diff`로 비교했다. 자동 분석은 끄고 했다.
**실험 3**(2026-09-27, 태그 2단계): 같은 합성 곡과 새 합성 AAC "DJC 실험 태그 날짜·중복 A/B"로 S0~S5를 비교했다. 새 앨범·기존 앨범 붙이기·공유 앨범 아티스트 넣기와 비우기·동명 앨범·아티스트 비우기·발매일이 있는 곡의 연도를 가렸다. 앱·Agent 종료 뒤에만 스냅샷을 보존했다. 마지막 자동 분석 설정 복원으로 새 AAC의 분석 칸이 바뀐 것은 태그 비교와 분리했다.

rekordbox 7.2.18이 하는 것:
- 정보 패널은 **칸마다 따로 저장**한다(한 줄 칸은 Enter, 코멘트는 다른 칸으로 옮길 때). 한꺼번에 저장하는 버튼은 없다. 앨범 아티스트 칸이 있다.
- `djmdContent` 행을 제자리에서 UPDATE한다. `TrackInfoUpdated`(글자)는 **저장 한 번에 +1**이다(제목·코멘트 '1'→'3', 장르·작곡가·연도·트랙 번호 '1'→'5', 그 넷을 비우면 '5'→'9'). `FileSize`와 다른 칸은 그대로였다(음원 파일 태그는 다시 쓴다).
- 제목 `Title`, 코멘트 `Commnt`(비우면 `''`), 연도 `ReleaseYear`·트랙 번호 `TrackNo`(정수, 빈칸은 받지 않아 0을 넣으면 0). 연도를 넣어도 `ReleaseDate`는 그대로였다. 실험 3의 발매일 있는 합성 곡에서도 연도 2012→2024→0이 발매일을 바꾸지 않았다.
- 이름 칸(`ArtistID`·`ComposerID`는 `djmdArtist`, `GenreID`는 `djmdGenre`, `AlbumID`는 `djmdAlbum`):
  - 있는 이름이면 그 행을 쓰고, 없으면 새 행을 만든다(ID 32비트 난수, UUID 소문자, `SearchStr` NULL, 상태 칸 0, `usn` NULL, `created_at` = `updated_at`, 곡 넣기와 같은 모양).
  - 비우면 아티스트·작곡가·앨범 `''`, 장르 `'0'`. 앨범을 비우면 앨범 아티스트도 함께 빈칸이 되고, 저장은 한 번이다.
  - 아무 곡도 안 쓰게 된 옛 이름 행은 **실제로 지운다**(삭제 표시가 아니다). 아티스트 A→B로 바꾼 A, 비운 장르·작곡가, 비운 앨범이 그랬다. 지운 앨범의 앨범 아티스트 행은 아무 곡도 안 쓰는데도 남았다. 다른 곡도 쓰는 이름은 그대로다.
- **아티스트를 고치면 그 곡의 앨범 행도 저장된다**: `AlbumArtistID`가 NULL이면 `''`, 값이 있으면 그대로이고, 변경 번호·`updated_at`를 받는다(실험곡 5, 묶음 2). 앨범에 곡을 붙일 때(있는 앨범 이름)도 그 앨범 행이 같은 식으로 저장됐다. 제목·코멘트·장르·작곡가·연도·트랙 번호를 고칠 때는 앨범 행이 그대로였다.
- 앨범 이름이 유일하면 앨범 아티스트를 **제자리에서** 고친다(새 이름이면 아티스트 행 추가). 빈 값은 `''`이고, 더 이상 참조하지 않는 이전 아티스트 행은 지운다. 다른 곡·앨범이 참조하면 남긴다.
- 공유 앨범도 같은 행을 고치므로 **선택하지 않은 곡의 앨범 아티스트까지 바뀐다**. 그 곡들의 `TrackInfoUpdated`는 그대로이고 화면 값은 다시 불러오기 전까지 낡을 수 있다.
- 새 앨범 행: `AlbumArtistID`는 기존 앨범 아티스트 ID를 이어받고 없으면 `''`(NULL 아님), `Compilation` 0, `ImagePath`·`SearchStr` NULL, 나머지 이름 행 공통 칸은 위와 같다. 이전 앨범은 미참조이면 삭제한다.
- 이름이 유일한 기존 앨범에 붙이면 그 앨범 행을 저장하고 곡의 이전 앨범 아티스트로 덮어쓴다. 다른 앨범 아티스트를 가진 앨범에 붙이는 것은 다른 곡까지 바꾸므로 DJCrate에서는 막는다.
- 같은 이름의 앨범이 여러 개면 단순한 `(이름, 앨범 아티스트)` 검색과 달랐다. 실험 3에서는 같은 짝의 행이 이미 있어도 새 행을 만들었다. 이 선택 규칙은 아직 열지 않는다.
- 변경 번호: 새 이름 행 → 앨범 행 → 곡 행. rekordbox는 저장 한 번에 곡 행을 두 번 고쳐 번호를 두 개 쓰는 것으로 보인다. DJCrate는 행마다 한 번이다(번호 값은 비교하지 않는다).

라이브러리 조사(2026-09-27, 스냅샷 사본 읽기 전용): 비어 있는 이름 칸은 NULL·`''`·`'0'`(장르)가 섞여 있다. NULL은 곡 넣기, `''`·`'0'`은 정보 편집에서 온 것으로 보인다. `ReleaseDate`(`YYYY-MM-DD`)가 든 곡은 앞 네 자가 `ReleaseYear`와 같다. 아무 곡도 쓰지 않는 이름 행은 삭제 표시(`rb_local_deleted` 1)된 것만 있다.

**사본 재현**(2026-09-27): S0 사본에 실험 2의 저장을 한 번씩 `djc lab tag-write-test`로 되풀이하고, S1·S2와 곡 행·이름 행을 칸마다(ID·UUID·변경 번호 값·시각 말고) 비교했다. 번호를 받은 행의 순서도 비교했다.
- 제목·코멘트·아티스트(새 이름·있는 이름, 버려진 A 삭제, 앨범 행 `''`)·장르·작곡가(넣기·비우기·삭제)·연도·트랙 번호·`TrackInfoUpdated`·번호 순서가 두 세션 모두 같다.
- 앨범 비우기(`''`, 앨범 행 삭제, 앨범 아티스트 행 남김)도 같다.
- 다른 것은 있는 앨범 이름을 붙일 때 rekordbox가 그 앨범 행을 저장(`AlbumArtistID` NULL → `''`)한 것 하나다.
- 묶음 2 실험 전 사본 재현에서도 제목·코멘트·새 아티스트·장르 행이 같았다(`TrackInfoUpdated`는 섞인 실험이라 비교하지 않음).

**DJCrate가 쓰는 것**(`RekordboxWriter+Tags`, 반영 ⌘⇧E, #1):
- rekordbox 라이브러리만 쓰고 음원 파일 태그는 건드리지 않는다(2026-09-26 결정). 확인 창에 "음원 파일의 태그는 그대로"라고 알린다.
- 여러 칸을 한 번에 쓰되 **칸마다 한 번 저장한 것과 같은 결과**를 낸다.
  - `TrackInfoUpdated` += 바꾼 칸 수. 앨범을 비우며 앨범 아티스트도 비우면 하나로 센다.
  - 비운 값은 위와 같고, 버려진 이름 행을 지운다(참조: 곡 행의 아티스트·작곡가·원곡 아티스트·리믹서, 앨범의 앨범 아티스트. 지운 곡 행이 가리켜도 남긴다).
  - 아티스트를 고치면 곡의 앨범 행을 저장한다.
  - 변경 번호는 정보 패널 칸 순서다: 아티스트(→ 앨범 행) → 앨범 → 장르 → 작곡가 새 행 → 곡 행. 실험한 상태 0만 허용한다. 상태 256→257은 태그에서 확인하지 못했으므로 곡·관련 앨범의 상태가 0이 아니면 막는다.
- 초안의 base(초안을 만들 때 rekordbox 값)와 지금 곡 정보가 한 칸이라도 다르면 그 곡은 쓰지 않는다. 빈 제목, 숫자가 아니거나 음수인 연도·트랙 번호, 비운 앨범에 새 앨범 아티스트도 막는다.
- 앨범과 앨범 아티스트를 동시에 바꾸는 조합은 비우기를 제외하고 한 칸씩 반영하도록 막는다. 공유 앨범 아티스트·동명 앨범 선택도 막힌 이유와 rekordbox에서 할 일을 알린다.
- 같은 쓰기에서 큐·그리드·분석도 쓰는 곡은 태그를 마지막에 써서 곡 행이 가장 큰 번호를 받는다.
- 다시 읽어 검증한다: 곡 정보(라이브러리 읽기와 같은 조인)·`TrackInfoUpdated`(글자형)·곡 행과 앨범 행의 번호·지운 이름 행. 쓴 곡의 태그 초안은 지운다(반영한 값이 새 base). 되돌리면 백업의 `tag-drafts/`로 초안을 살린다.

| 칸 | 곡 행 칸 | 쓰기 | 근거 |
|---|---|---|---|
| 제목 | `Title` | 연다 | 실험 1·2, 사본 재현 |
| 아티스트 | `ArtistID` → `djmdArtist`, 곡의 앨범 행 저장 | 연다(비우면 `''`) | 실험 1·2·3, 사본 재현 |
| 장르 | `GenreID` → `djmdGenre`(비우면 `'0'`) | 연다 | 실험 1·2, 사본 재현 |
| 작곡가 | `ComposerID` → `djmdArtist`(비우면 `''`) | 연다 | 실험 2, 사본 재현 |
| 연도 | `ReleaseYear`(비우면 0) | 연다(발매일 보존) | 실험 2·3, 사본 재현 |
| 트랙 번호 | `TrackNo`(비우면 0) | 연다 | 실험 2, 사본 재현 |
| 코멘트 | `Commnt`(비우면 `''`) | 연다 | 실험 1·2, 사본 재현 |
| 앨범 | `AlbumID` → `djmdAlbum`(비우면 `''`) | 조건부 | 새 앨범·같은 아티스트의 유일한 기존 앨범·비우기, 실험 2·3과 사본 재현 |
| 앨범 아티스트 | `djmdAlbum.AlbumArtistID` | 조건부 | 단독·유일한 이름의 앨범에서 넣기·바꾸기·비우기, 실험 2·3과 골든 테스트 |

`RekordboxWriter.writableTagKeys`가 연 칸이고 `checkTags`가 위 조건을 거른다. 막힌 곡은 반영 미리 보기에 이유와 할 일이 함께 보인다. 전부 막힌 태그만 있으면 백업도 만들지 않는다.

**실험 3 사본 재현**: `djc lab tag-write-test`로 다섯 전후 사본 쌍에 10번 편집을 적용했다. 새 앨범(빈 아티스트·아티스트 있음), 기존 앨범 붙이기, 아티스트 비우기, 발매일 보존 연도 변경·0, 단독 앨범 아티스트 비우기의 곡·앨범 칸과 옛 이름 행 삭제 여부가 모두 일치했다. 난수 ID·UUID·시각·변경 번호 값은 제외하고 외래 키는 가리키는 이름으로 비교한다. 골든 테스트는 `RekordboxTagWriterTests`·`RekordboxTagAlbumTests`에 둔다.

**남겨 둔 조건**(#1): 공유 앨범 아티스트를 안전하게 미리 보여 주고 일괄 반영하는 흐름, 다른 아티스트를 가진 기존 앨범 붙이기, 동명 앨범 선택, 앨범·앨범 아티스트 동시 변경, 상태 256→257. 추가 화면 실험과 사본 재현 전에는 열지 않는다.

## 시간축

- rekordbox는 압축 음원 앞 지연을 잘라 내지 않는다 → rekordbox 시각 = AVFoundation 시각 + 인코더 지연.
- AAC 2112샘플, LAME MP3 +51.2ms(576+529+1152), ffmpeg MP3 = 프라이밍+529, 태그 없는 MP3 529샘플, 무손실 0.
- 계산: `RekordboxTimeline.predictedOffset(url:)`. 덱·초안의 모든 시각은 rekordbox 시간축이다.

## 쓰기 절차 (`RekordboxWriter.write`)

1. rekordbox·rekordboxAgent가 실행 중이면 거부. `-wal`이 남아 있어도 거부.
2. master.db(+wal/shm) 전체와 바꿀 분석 파일을 `rekordbox-backups/<시각>-write/`에 복사(복사 중 원본이 바뀌면 실패).
3. `BEGIN IMMEDIATE` 한 트랜잭션에서 쓰고, 같은 연결로 다시 읽어 초안과 칸마다 비교. 비교 기준은 초안의 변경(`CueDraft.changes`, 1ms 미만 차이는 변경 아님)만 base에 반영한 큐 목록(`expectedCues(after:)`)이다. 그리드 따라가기로 1ms 미만 움직인 큐는 rekordbox 값 그대로 둔다(#73).
4. 커밋 뒤 다시 열어 한 번 더 검증 + `PRAGMA quick_check` + `cipher_integrity_check`. 그 뒤 분석 파일·`masterPlaylists6.xml`을 쓴다(백업에 원본을 함께 둔다).
5. 어느 단계든 실패하면 백업으로 되돌린다. 초안을 만든 뒤 rekordbox에서 그 곡이 바뀌었으면(base 불일치) 그 곡은 쓰지 않는다.

## 곡 추가·삭제 (`RekordboxTrackWriter`, 2026-09-26 묶음 1·2 실험)

**추가(분석 전)**: rekordbox가 자동 분석을 끈 채 파일을 넣으면 `djmdContent` 행 하나만 생긴다(78칸, 형식까지 `RekordboxTrackWriter.contentRow`).
- 곡 ID는 1~2^28 난수(라이브러리 14,155행 전부 이 범위), 아티스트·앨범·장르 ID는 32비트 난수. UUID는 소문자 v4.
- 태그(ID3·iTunes·Vorbis)에서 제목·아티스트·앨범·앨범 아티스트·장르·작곡가(`djmdArtist`)·코멘트·연도·트랙·디스크·ISRC. 제목이 없으면 확장자를 뺀 파일 이름. 설명이 붙은 ID3 코멘트(iTunNORM 등)는 쓰지 않는다. 이름이 없으면 새 행.
- 분석 칸은 0·빈 값, `Analysed` 0, `ContentLink` 14, `AnalysisUpdated`·`TrackInfoUpdated`·`CueUpdated` NULL, 길이는 초 반올림.
- `rb_file_id` = 음원 파일 inode, `DateCreated` = 파일 만든 날, `StockDate` = 넣은 날, `MasterDBID`·`DeviceID`는 라이브러리 공통값. 경로·파일 이름은 NFC.
- 변경 번호는 관련 행(아티스트·앨범·장르)이 먼저, 곡 행이 마지막.

**추가(분석 포함)**: 위 행에 분석 칸을 채우고 분석 파일·파일 행·오토게인 행을 더한다.
- 분석 경로 `/PIONEER/USBANLZ/<UUID 앞 3자>/<나머지>/ANLZ0000.DAT`, `Analysed` 105, 길이는 초 버림, `AnalysisUpdated` "1"·`TrackInfoUpdated` "1"(글자, 첫 BPM/Grid 분석만 만든다).
- 비트레이트: CBR MP3는 프레임 비트레이트, LAME VBR MP3는 0, AAC는 esds 평균 비트레이트(없으면 0, streamType 바이트 0x14도 있음), WAV는 샘플레이트×비트×채널, FLAC 0.
- `.DAT`: `PPTH`(`?/파일 이름` UTF-16BE + NULL) · `PVBR`(머리 0, 탐색표 400칸, 끝값 = MP3는 rekordbox가 세는 프레임 수×1152, AAC·WAV는 0) · `PQTZ` · `PWAV` · `PWV2` · `PCOB`(핫, 빈) · `PCOB`(메모리, 빈). 같은 그리드로 다시 만들면 머리·PPTH·PVBR·PQTZ·PCOB가 바이트까지 같다.
- `.EXT`·`.2EX`는 파형 생성기(`RekordboxWaveforms`, baken MIT 규칙 이식). 흑백 파형 높이는 99.5% 바이트 일치, 색·3밴드·미리 보기는 근사. rekordbox 7.2.18은 우리 파일을 그대로 표시했다(サラマンダー 복사본).
- `contentFile` 행은 파일마다(ID `<곡 UUID>_<경로, /는 %2F>`, MD5, 크기, `rb_local_path`, `rb_priority` 50). 없어도 표시는 되지만 rekordbox처럼 넣는다.
- 변경 번호: 관련 행 → (아트워크 파일 행) → 오토게인 행 → 곡 행 → .2EX → .DAT → .EXT. rekordbox는 곡 행을 먼저 넣고 분석이 끝나면 다시 고쳐 새 번호를 받고, 곡 행 뒤·.2EX 앞에 .3EX 행도 넣는다(2026-09-26 아트워크 실험 세션: 자동 분석을 켜고 넣은 합성 WAV 3곡, 분석 전 곡을 분석한 "DJC 실험 아트"). DJCrate는 곡 행을 한 번만 넣으므로 rekordbox의 마지막 번호 순서를 따른다.
- 카운터는 분석 항목·횟수에 따라 다르다. 조성·Phrase 없이 첫 BPM/Grid만 만드는 두 경로는 '1'·'1'이다(아래 "분석 카운터", 2026-09-27 #95).
- `ContentLink`는 분석 구성 비트: `0x3C060E` 보통(6,409곡), `0x2C060E` 보컬 분석 없음, +`0x10000` 프레이즈 있음. 우리는 프레이즈·보컬이 없으므로 `0x2C060E`.
- 만들 수 없는 것: `PSSI`(프레이즈), `PVDI`(보컬), `.3EX`(MessagePack `embedding`, rekordbox AI 특징값). rekordbox에서 Phrase만 분석하면 우리 태그를 바이트 그대로 두고 `PSSI`만 덧붙인다.
- MP3 프레임 세기: LAME 정보 프레임(첫 프레임 안에 LAME 태그)은 소리로 세고, 다른 인코더(ffmpeg Lavc 등)의 정보 프레임은 세지 않는다. 다음 오디오 프레임에 "LAME3.99U"가 찍힌 ffmpeg 파일이 있어 LAME은 첫 프레임 안에서만 찾는다.
- VBR MP3 탐색표: 칸 k = 센 프레임 중 `floor((k+1)·n/400) − 8`번째 프레임의 바이트 위치(첫 센 프레임 기준, 음수면 0번째). 라이브러리 LAME VBR 451곡 400칸 전부 일치(CBR은 전부 0, 2291/2294곡). 8프레임 앞은 디코더 비트 저장소 몫으로 보인다.
- FLAC: 비트레이트 0, 비트는 STREAMINFO, `PVBR`은 탐색표·끝값 모두 0. 대신 `.EXT` 끝(`PWV4` 뒤)에 `PVB2`를 붙인다.
  머리 0x20(`u32 0` · `u64 전체 샘플` · `u32 400` · `u32 20`), 칸 400개 × 20바이트 = (`u64 프레임 시작 샘플` · `u64 첫 프레임 기준 바이트 위치` · `u32 블록 크기`).
  칸 k = 샘플 `k · floor(전체 샘플 / 400)`이 든 FLAC 프레임(나눗셈을 먼저 버리므로 뒤 칸일수록 조금 앞을 가리킨다). 라이브러리 1,083곡 중 1,081곡 바이트까지 일치(`djc lab pvb2-check`). 나머지 2곡은 시작 샘플은 같고 바이트 위치만 달라 분석 뒤 파일이 바뀐 것으로 본다.
- 막음: 미확인 ALAC 조건(16/24비트·44.1/48kHz·스테레오 밖), 44.1kHz가 아닌 ffmpeg VBR(곡 행 BPM과 정밀 그리드 규칙 미확인), 그 밖의 비LAME VBR(L3.99r1 포함), 프레임이 중간에 끊긴 MP3·FLAC(STREAMINFO 전체 샘플과 프레임 합이 다름).

**아트워크**(#4): rekordbox는 곡을 **분석할 때** 음원 내장 그림(ID3 APIC·iTunes covr·FLAC PICTURE)으로 파일 셋을 만든다. 자동 분석을 끄고 넣을 때는 만들지 않는다. XML로 들어온 곡(`Analysed` 41)에도 없었다.
- 실험(2026-09-26, rekordbox 7.2.18): 1200×900 JPEG 앞표지(APIC)가 든 MP3 "DJC 실험 아트"(라이브러리에 없던 아티스트·앨범)를 자동 분석을 끄고 넣고 종료했다. 다음 세션에서 자동 분석을 켜자 rekordbox가 이 곡을 분석했다. 넣기 전·넣은 직후·분석 뒤 스냅샷을 `djc lab db-diff`로 비교했다(넣기 전 스냅샷은 rekordbox 자동 백업과 같은 상태).
  - 넣을 때: `djmdArtist` → `djmdAlbum` → `djmdContent` 행만 생기고 변경 번호도 이 순서다(`localUpdateCount` +3). `ImagePath` 빈 값, 파일 행·아트워크 파일 없음, `djmdAlbum.ImagePath` NULL, `imageFile` 표 그대로(0행). 곡 행은 `djc lab track-add-repro`로 19칸 모두 같았다.
  - 분석할 때(#87에서 넣은 직후 스냅샷 → 분석 뒤 스냅샷을 곡 ID로 갈라 다시 정리): `artwork.jpg` 파일 행이 먼저 번호를 받고(분석 결과를 쓰기 2초 전) → 오토게인 행 → 곡 행(`ImagePath`와 분석 칸) → 파일 행 .3EX → .2EX → .DAT → .EXT. 아트워크 행과 오토게인 행 사이 빈 번호에는 다른 곡 한 행만 있고 나머지는 어느 표에도 없다. 오토게인 행 N·곡 행 N+2이고 N+1이 어느 표에도 없는 모양은 같은 세션에서 자동 분석으로 넣은 합성 WAV 3곡도 같아, 곡 행이 번호를 두 번 받는 것으로 보인다(DJCrate는 한 번). `djmdAlbum.ImagePath`·`imageFile`은 그대로.
  - 곡 행에서 바뀐 칸: `BitRate`·`BitDepth`·`SampleRate`·`ImagePath`·`AnalysisDataPath`·`Analysed` 0→105·`ContentLink` 14→0x2C060E·`AnalysisUpdated`·`TrackInfoUpdated` NULL→'1'·'1'·변경 번호·`updated_at`. `rb_data_status`는 0 그대로(동기화한 적 없는 곡), `Length`(40)도 그대로. 이 합성 MP3에서는 박을 찾지 못해 BPM 0·`PQTZ` 0박이었지만 `.EXT`·`.2EX`·`.3EX`까지 만들었다(파일이 모두 있으므로 아래 "반쪽 분석"과 다르다).
  - 이미 분석한 곡은 다시 뽑지 않는다: 아트워크를 넣기 전의 DJCrate로 분석까지 붙여 넣은 곡 중 음원에 그림이 있는 곡(3곡)은 그 뒤 rekordbox를 켜도(위 자동 분석 세션 포함) `ImagePath`가 빈 값이었다.
- 폴더는 곡 UUID로 정한다: `/PIONEER/Artwork/<UUID 앞 3자>/<나머지>/`(분석 폴더와 같은 규칙, 아트워크 있는 곡 전부 일치). `djmdContent.ImagePath` = 그 안의 `artwork.jpg`, 없으면 빈 값 `''`. `djmdAlbum.ImagePath`는 전부 NULL(건드리지 않는다).
- 파일 셋(라이브러리 조사: 스냅샷 사본과 share 읽기 전용, 아트워크 있는 곡 전부·파일 19,914개): `artwork.jpg`는 원본 크기 그대로, 긴 변이 800을 넘으면 800으로 줄인다(비율 유지, 짧은 변 반올림: 900×784 → 800×697, 3311×3001 → 800×725, 실험 곡 1200×900 → 800×600). `artwork_m.jpg` 240×240·`artwork_s.jpg` 80×80은 정사각에 맞게 키우거나 줄이고 남는 곳은 검은 여백으로 가운데 맞춘다(200×200 원본도 240으로 키움).
- 셋 다 원본이 JPEG여도 다시 인코딩한 기준선 JPEG다(PNG도 JPEG로): 머리는 SOI · APP0(JFIF 1.01, 비율 1:1, 썸네일 없음) · DQT 둘(libjpeg 품질 85 휘도·색차 표) · SOF0(Y 2x2, Cb·Cr 1x1) · DHT 넷(DC0·AC0·DC1·AC1, 최적화라 그림마다 다름) · SOS. EXIF·ICC 없음. 19,914개 전부 같은 머리.
- 파일 행(`contentFile`)은 `artwork.jpg` 하나만(`_m`·`_s`는 행 없음, 6,637행). 칸은 분석 파일 행과 같다(ID `<곡 UUID>_<경로, /는 %2F>`, MD5, 크기, `rb_local_path`, `rb_priority` 50). 실험 곡 행도 전 칸이 이 모양이다(`rb_insync_hash`·`rb_insync_local_usn`·`rb_temp_path`·`usn` NULL, 나머지 상태 칸 0, `UUID` 소문자 v4, `created_at` = `updated_at`).
- 빼면 파일 셋을 지우고 폴더는 남긴다(サラマンダー 복사본 삭제 실험).
- DJCrate(`TrackArtwork`·`ArtworkJPEG`): **분석까지 붙여 넣는 곡과 분석을 붙이는 분석 전 곡에** 넣는다(`RekordboxTrackWriter.writesArtwork`, 위 실험으로 2026-09-26 열었다). 분석 없이 넣는 곡은 rekordbox처럼 넣지 않고, rekordbox에서 분석하면 생긴다고 확인 창에 알린다. 변경 번호는 위 "추가(분석 포함)"·아래 "분석 붙이기" 순서에서 오토게인 행 앞이다(`RekordboxTrackArtworkTests`·`RekordboxAnalysisArtworkTests`).
  같은 크기·여백·머리로 만들고 바이트는 다르다(허프만 표가 그림마다 다르고, 축소 방식·DCT가 다름). `djc lab artwork-check`로 라이브러리 곡의 음원 그림을 다시 만들어 비교하면(21곡) `artwork.jpg`는 머리 같음·화소 차이(0~255) 중앙 0.1·최대 1.1·크기 비 0.997~1.009로 거의 같고, `_m`·`_s`는 축소 필터 차이로 중앙 4.4·8.1(시험한 필터 중 CoreGraphics 고품질이 가장 가까움). 실험 곡은 머리 같음·화소 차이 0.1·2.5·4.9·크기 비 1.001·0.95·0.99.
- 확인하지 않은 것: 투명한 PNG(검은 바탕에 그림), EXIF 회전(무시), 그림이 여럿일 때 고르는 그림(AVFoundation이 주는 첫 그림), 분석 말고 다른 때(곡 선택·덱에 올리기·태그 다시 읽기 등) 아트워크를 뽑는지. 라이브러리의 분석하지 않은 곡(`Analysed` 0)에도 아트워크가 있는데, 넣을 때는 뽑지 않으므로 그런 다른 길이나 옛 버전에서 온 것으로 보인다.
- 분석 붙이기(`RekordboxWriter+Analysis`, #87): 위 실험의 "분석할 때"가 바로 그 경우라 같은 파일 셋·`ImagePath`·파일 행을 넣는다(아래 "분석 붙이기"). 이미 아트워크가 있는 분석 전 곡(`ImagePath`나 아트워크 파일 행이 있거나, 곡 UUID 아트워크 폴더에 파일이 있는 곡)은 rekordbox가 분석할 때 다시 뽑는지 확인하지 않아 아트워크를 건드리지 않고 분석만 붙인다.
- 라이브러리에는 음원에 그림이 없는데 `ImagePath`가 있는 m4a가 있다(파일에 `covr`가 없음). rekordbox에서 직접 붙였거나 넣은 뒤 태그가 바뀐 곡으로 보고, DJCrate는 음원에 그림이 없으면 아트워크를 만들지 않는다.

**삭제**: 삭제 표시가 아니라 행을 실제로 지운다.
- 곡 행, 큐(`djmdCue`·`contentCue`), 파일 행, 오토게인 행, 재생 목록·재생 이력 항목. 같은 이력의 뒤 순번을 하나씩 당기고 그 행들은 한 변경 번호로 몰아 받는다(재생 목록도 같다고 보고 당긴다: 추정). 화면의 "플레이리스트에서 제거"는 남은 곡을 모두 다시 매긴다(아래 "재생 목록"). 컬렉션에서 지울 때 재생 목록 항목이 어떻게 되는지는 아직 실험하지 않았다.
- 그 곡만 쓰던 아티스트·앨범 행도 지운다. 분석 폴더는 통째로, 아트워크는 파일만 지운다(폴더는 남김).
- MyTag·핫큐 뱅크·샘플러·관련 곡·신청곡·검열 구간·클라우드 내보내기에 걸린 곡은 아직 지우지 않는다.

## 분석 붙이기 (분석 전 곡, `RekordboxWriter+Analysis`, #6)

라이브러리에 이미 있는데 분석 파일이 없는 곡에, 반영할 때 그 곡의 그리드 초안으로 분석 파일을 만들어 붙인다. 곡 넣기(분석 포함) 레시피(`RekordboxTrackWriter.prepare`·`fileRow`·`mixerRow`)를 쓰고, 쓰기는 `RekordboxWriter.write`의 안전 절차(사전 확인 → 백업 → 한 트랜잭션 → 다시 읽어 검증 → 무결성 검사 → 실패 시 복원)를 따른다.

**분석 전 곡은 두 가지다**(2026-09-26 라이브러리 조사, 읽기 전용):
- 분석 파일 없음: `AnalysisDataPath` 빈 값. 자동 분석을 끄고 넣은 곡(`Analysed` 0, `ContentLink` 14)과 XML로 들어온 곡(`Analysed` 41, `ContentLink` 14, BPM·비트레이트·샘플레이트는 XML 값, `AnalysisUpdated`·`TrackInfoUpdated` NULL). 파일 행·오토게인 행이 없다. → 분석을 붙인다.
- 반쪽 분석: `.DAT`(PQTZ 0박, PWAV·PWV2 전부 0)와 `.3EX`, 그 파일 행(`.DAT`·`.3EX`, 아트워크), 오토게인 행은 있고 `.EXT`·`.2EX`가 없다(`Analysed` 105, BPM 0이거나 태그 BPM, `AnalysisUpdated`·`TrackInfoUpdated` "1"). rekordbox 분석이 실패한 흔적으로 보인다. → 막는다(아래). 그리드가 든 채 `.EXT`만 없는 곡은 라이브러리에 없었다.

**실험**(2026-09-26, rekordbox 7.2.18, 자동 분석 끔, '트랙 분석' 보통 모드·BPM/그리드·키만, 프레이즈·보컬 끔): XML로 들어온 분석 전 곡 The Asterisk War (edit)(WAV)와 반쪽 곡 ヴァンパイア(M4A). 전후 스냅샷을 `djc lab db-diff`로 비교하고, 실험 전 사본에 같은 곡을 `djc lab analysis-attach-test --grid-from <rekordbox .DAT>`로 써서 칸마다 맞췄다.

**rekordbox가 분석 전 곡을 분석하면**(The Asterisk War (edit)):
- `djmdContent`: `AnalysisDataPath`(곡 UUID 폴더), `Analysed` 41→105, `ContentLink` 14→0x2C060E, `AnalysisUpdated` NULL→'2', `TrackInfoUpdated` NULL→'1'(글자), 변경 번호, `updated_at`. BPM·Length·BitRate·BitDepth·SampleRate는 XML 값이 분석 값과 같아 그대로였다(분석 전 추가 곡은 채운다: 2026-09-26 O-Ku-Ri-Mo-No Sunday! 241→240초 버림). 키 분석을 켰는데도 `KeyID`는 0 그대로였다(#5 참고).
- `contentFile` 행 4개(.3EX·.2EX·.DAT·.EXT, 곡 넣기와 같은 칸), `djmdMixerParam` 행 1개(피크 1.0).
- 변경 번호: 오토게인 행 → .3EX 행 → 곡 행 → .2EX → .DAT → .EXT. rekordbox는 두 번에 나눠 쓴다(오토게인·.3EX·.DAT 행을 먼저 만들고 몇 분 뒤 곡 행·나머지 파일 행, .DAT 행은 그때 다시 고침). 파일 행 순서 .2EX → .DAT → .EXT는 O-Ku-Ri-Mo-No Sunday!·ヴァンパイア에서도 같았다.

**DJCrate가 쓰는 것**(골든 테스트 `RekordboxAnalysisAttachTests`: 같은 음원·그리드·음량이면 곡 넣기 결과와 칸·바이트까지 같고, 다른 것은 위 실험의 카운터·순서뿐):
- 분석 파일 `.DAT`·`.EXT`·`.2EX`를 곡 UUID 폴더(`/PIONEER/USBANLZ/<UUID 앞 3자>/<나머지>`)에 새로 만든다. PPTH의 파일 이름은 `FileNameL`.
- `djmdContent`: BPM(첫 구간 ×100)·Length(AVFoundation 길이 버림)·BitRate·BitDepth·SampleRate·AnalysisDataPath·`Analysed` 105·`ContentLink` 0x2C060E·`AnalysisUpdated` '1'·`TrackInfoUpdated` '1'(첫 BPM/Grid), 상태 256→257, 변경 번호, `updated_at`. `KeyID`는 건드리지 않는다.
- `contentFile` 행 3개와 `djmdMixerParam` 행(오토게인, −10 LUFS 목표). 변경 번호는 오토게인 행 → 곡 행 → .2EX → .DAT → .EXT(.3EX는 만들지 못한다).
- 음원에 그림이 있으면 아트워크(#87): 파일 셋 3개·`ImagePath`·`artwork.jpg` 파일 행(곡 넣기와 같은 레시피, 바이트까지 같음). 변경 번호는 `artwork.jpg` 행 → 오토게인 행 → 곡 행 → .2EX → .DAT → .EXT(골든 테스트 `RekordboxAnalysisArtworkTests`, "DJC 실험 아트" 순서). 파일은 분석 파일 다음에 쓰고 `createdFiles`에 넣어 되돌릴 때 지운다. 앱은 반영 때 음원 태그를 읽어 그림을 넘기고(`AnalysisInput.artwork`), 확인 창에 "아트워크"를 붙여 알린다.
- 같은 쓰기의 큐·게인 초안은 분석을 붙인 뒤에 쓴다(분석한 곡을 고치는 순서).
- 파일은 DB를 커밋하고 다시 읽어 확인한 뒤 쓴다. 파일 쓰기가 실패하면 만든 파일·빈 폴더를 지우고 DB를 백업으로 되돌린다.
- 되돌리기: 백업 보고서(`report.json`)의 `createdFiles`로 만든 파일과 빈 분석 폴더를 지우고, 백업에 둔 그리드 초안을 살린다.

**사본 재현 결과**(실험 전 사본, rekordbox 그리드를 PQT2 소수까지 가져와서): 곡 행은 바뀐 칸·값이 rekordbox와 같다(변경 번호 값·시각 말고). 파일 행 3개는 ID까지 같고 나머지 칸도 같다. `.DAT`는 머리·PPTH·PVBR·PCOB가 바이트까지 같고, PQTZ는 227박 중 9박만 1ms 다르다(rekordbox 박 간격이 419.49~419.60ms로 흔들려 소수가 ms 경계에 붙은 박). `.2EX`·`.DAT` 크기는 같고 `.EXT`는 PQT2 빈 형태만큼(박당 2바이트) 작다. 파형 태그는 곡 넣기와 같은 근사. 오토게인은 0.09dB 차이(음량 측정 차, 위 ±0.25dB 안).

**사본 재현 결과(#87, 아트워크)**: "DJC 실험 아트"를 넣은 직후 스냅샷 사본에 `djc lab analysis-attach-test`(추정 그리드)로 붙이고 `djc lab db-diff`로 rekordbox가 분석한 스냅샷과 비교했다.
- 곡 행: 바뀐 칸이 rekordbox와 같고 `ImagePath`·`AnalysisDataPath`·`BitRate` 192·`BitDepth` 16·`SampleRate`·`Analysed`·`ContentLink`·`TrackInfoUpdated` '1'이 값까지 같다. 다른 것은 `AnalysisUpdated`('2' vs '1', 아래 "분석 카운터")와 BPM(rekordbox는 박을 찾지 못해 0, DJCrate는 초안 그리드), 변경 번호 값·시각. `localUpdateCount`만 바뀐다(+6: 아트워크 행·오토게인·곡 행·파일 행 3개).
- 파일 행: `artwork.jpg`·.2EX·.DAT·.EXT 행의 ID·경로·`rb_local_path`·상태 칸이 같고 해시·크기만 다르다(`artwork.jpg` 31,258 vs 31,223바이트, `.DAT`는 그리드 86박 × 8바이트만큼 큼). rekordbox의 .3EX 행은 없다.
- 오토게인 행: 상태 칸·피크가 같고 게인은 음량 측정 차만큼 다르다. 파일 셋은 800×600·240×240·80×80.

**분석 카운터**(`AnalysisUpdated`·`TrackInfoUpdated`, 글자, #95): 2026-09-27 rekordbox 7.2.18에서 같은 PCM의 합성 곡 "DJC 실험 카운터 auto/manual-grid/manual-key/manual-phrase/manual-keyphrase/repeat"를 조건별로 분석하고 정상 종료 사본 S0~S9를 비교했다.

| 조건 | 분석 전 | 분석 뒤 |
|---|---|---|
| 자동 분석 가져오기, BPM/Grid만 | 행 없음 | '1'·'1' |
| 자동 분석 Off로 가져온 뒤 수동 BPM/Grid만 | NULL·NULL | '1'·'1' |
| BPM/Grid + 조성 | NULL·NULL | '1'·'2' |
| BPM/Grid + Phrase | NULL·NULL | '2'·'1' |
| BPM/Grid + 조성 + Phrase | NULL·NULL | '2'·'2' |
| BPM/Grid만 반복 분석 | '1'·'1' | '2'·'2' → '3'·'3' |

- **[확인]** 위 조건에서는 BPM/Grid 분석마다 두 칸이 1씩 늘고, 조성은 `TrackInfoUpdated`, Phrase는 `AnalysisUpdated`를 1 더 올렸다. 재시작 뒤에도 값과 `text` 자료형을 유지했다. 조성·Phrase만 단독/반복 분석한 경우까지 일반화하지 않는다.
- **[확인]** DJCrate가 만드는 것은 파형·BPM/Grid·오토게인뿐이므로 곡 넣기와 분석 붙이기 모두 첫 분석의 '1'·'1'을 쓴다. 보존된 가져오기 전/분석 전 사본에 두 경로를 각각 실행해 자동·수동 기준의 카운터와 음원 칸을 대조했다. 이미 어느 카운터든 있는 곡은 계속 막는다.
- **[확인]** 옛 #6 표본은 보존된 분석 전 사본에서 `Analysed=41`, 카운터 NULL·NULL, `KeyID=0`, 분석 경로 없음이고, 분석 뒤 사본에서 `Analysed=105`, '2'·'1', `KeyID=0`이었다. 조성을 켰다는 기록만으로 조성 분석 성공이나 카운터 증가를 주장할 수 없다. 이 표본의 '2'·'1'은 새 실험의 BPM/Grid+Phrase 결과와 같지만, 당시 Phrase 설정·중간 분석 사본이 없어 원인을 확정하지 못했다.
- **[추정]** 묶음 2의 '3'·'2'는 여러 분석/추가 항목의 이력이 섞인 값일 수 있다. 당시에는 분석·태그·Relocate를 함께 했으며, 남은 사본으로 '3'·'2'에 이른 각 작업을 복원하지 못했다. 반복 BPM/Grid만으로는 두 카운터가 같이 오르므로 이 비대칭을 설명할 수 없다. 옛 관측값은 이력 자료로 남기되 첫 BPM/Grid 쓰기의 고정값으로 쓰지 않는다.
- **검증 범위**: `RekordboxTrackWriterTests`·`RekordboxAnalysisAttachTests`·`RekordboxAnalysisArtworkTests`가 글자형 '1'·'1', 기존 카운터 차단, XML에서 온 분석 전 상태의 보존을 고정한다. XML `Analysed=41`에 BPM/Grid만 분석하는 새 rekordbox 화면 실험은 하지 않았으므로, 그 조건의 독립 재현까지 확인했다고 주장하지 않는다.
- **기존 차이**는 아래와 같으며 이번 카운터 수정의 범위 밖이다. 전체 파일 바이트 일치를 보장하지 않는다.

| 비교 항목 | rekordbox | DJCrate | 확인·추정 범위 |
|---|---|---|---|
| #95 합성 WAV `Length` | 63 | 64 | [확인] 입력은 44.1kHz·2,822,400프레임(64초), DJCrate는 AVFoundation 길이를 버린다. [추정] rekordbox가 마지막 샘플 시각 `(N−1)/rate=63.999977…`을 버리면 63이다. 부동소수점 오차나 분석 종료 위치 기준도 배제하지 못해 일반식으로 적용하지 않는다. |
| 그리드 | 기준 박 목록 | 시작 쪽 선행 박 추가·대응 박의 약 ±1ms 차이 | `GridDraft.segments`는 첫~끝 박 간격으로 BPM을 복원하고 생성기는 시작까지 늘린다. 저장 BPM과 복원 BPM이 항상 같지는 않다. |
| 파형·오토게인 | rekordbox 분석 | 기존 생성기·음량 측정 근사 | 파형 태그 길이·파일 행 형식은 대조했지만 파형 값·게인/피크 하위 칸까지 동일하지 않다. |


**막는 것**:
- 반쪽 분석 곡(.DAT만): "rekordbox에서 트랙 분석을 다시 한 뒤 쓰세요". rekordbox가 다시 분석하면(ヴァンパイア) 곡 행은 BPM·`AnalysisUpdated`+1·`TrackInfoUpdated`+1·변경 번호만 바뀌고(`ContentLink`는 그대로), `.DAT`를 새로 써서 그 파일 행 해시·크기를 고치고, `.3EX` 해시를 고치고, `.2EX`·`.EXT` 파일 행을 넣는다(곡 행 → .3EX → .2EX → .DAT → .EXT). 오토게인 행은 그대로였다. 이 경로는 아직 쓰지 않는다.
- 카운터(`AnalysisUpdated`·`TrackInfoUpdated`)가 이미 있는 분석 전 곡(rekordbox에서 곡 정보를 고친 곡): 분석하면 얼마나 느는지 확인하지 않았다.
- 오토게인 행·USBANLZ 파일 기록·분석 폴더 파일이 이미 있는 곡, 음원 파일이 없는 곡, 음원 길이를 재지 못한 곡, base가 있는 초안(초안을 만든 뒤 rekordbox 쪽이 바뀜), 곡 넣기에서 막는 형식(ALAC·LAME이 아닌 VBR MP3·프레임이 끊긴 MP3·FLAC).

`RekordboxWriter.attachesAnalysis`로 경로 전체를 닫을 수 있다(규칙이 어긋나는 것이 드러나면 닫는다).

**rekordbox가 음원 파일도 고친다**: 태그를 고치면 파일 태그를 다시 쓰고(m4a 확인), 분석하면 키 태그(TKEY 등)를 써 넣는다(파일 크기가 커짐). 자동 분석을 켜면 라이브러리의 분석 안 된 곡까지 한꺼번에 분석한다. DJCrate는 태그를 쓸 때도 음원 파일은 건드리지 않는다(위 "태그 (곡 정보)").

## 재생 목록 (`RekordboxWriter+Playlist`, #38)

**실험**(2026-09-26 23:36 ~ 09-27 00:07 KST, rekordbox 7.2.18, 합성 곡 "DJC 실험곡 1~5"): 맨 위에 폴더 "DJC 실험"을 만들고 그 안에서 목록 만들기, 곡 넣기(세 곡 한꺼번에·한 곡 따로), 빼기(다섯 곡 중 2·4번째), 순서 바꾸기(5번째 → 1·2번째 사이), 같은 곡 두 번 넣기, 이름 바꾸기, 다른 폴더로 옮기기, 폴더 안 순서 바꾸기(맨 아래 → 맨 위), 목록 지우기(곡 2개 든 가운데 목록), 폴더째 지우기(폴더 > 폴더 > 목록), 가운데 넣기 시도를 차례로 했다. rekordbox는 조작마다 곧바로 DB와 XML에 쓴다. 그래서 켜 둔 채 `djc lab playlist-watch`로 2초마다 라이브 DB·XML을 읽기용으로 복사해 단계마다 비교했다.
**사본 재현**: 실험 전 사본에 같은 조작 42개를 `djc lab playlist-repro`로 쓰면 목록 행 133개(맨 위 형제 112 + 새 21)·곡 항목 19개·거울 행 21개가 번호(`rb_local_usn`)까지 칸마다 같고, 변경 카운터(1,004,075 → 1,004,366)와 XML NODE 672줄도 같다. 골든 테스트는 `RekordboxPlaylistWriterTests`.

**행 모양**
- 목록(`djmdPlaylist`): `ID`는 32비트 난수(문자열), `UUID`는 소문자 v4. 폴더 `Attribute` 1·목록 0(인텔리전트 목록은 4·`SmartList`). 맨 위는 `ParentID` `"root"`. 새 행은 `ImagePath`·`SmartList` NULL, 상태 0, `usn` NULL, `created_at` = `updated_at`.
- 곡 항목(`djmdSongPlaylist`): `ID`·`UUID` 둘 다 소문자 v4(서로 다름). `TrackNo`는 1부터 이어진다. 새 행은 상태 0, `usn` NULL.
- 클라우드 거울(`djmdCloudFilterPlaylist`): 목록·폴더마다 하나. `ID` 32비트 난수, `PlaylistUUID` = 목록 UUID, `Seq` 0, `ParentID` NULL, 상태 0, `usn` NULL. 고치지 않고, 목록을 지우면 같이 지운다.
- 고친 행: 바뀐 칸 + `rb_local_usn`·`updated_at`, 상태 256 → 257(0은 그대로). 클라우드 `usn`은 그대로.
- 지우기는 삭제 표시가 아니라 행을 실제로 지운다(목록·곡 항목·거울). 삭제 표시(`rb_local_deleted` 1)가 남은 옛 행은 건드리지 않고 Seq 계산에서도 뺀다(맨 위 삭제 표시 행 30개는 실험 뒤에도 그대로).
- 실험 전 라이브러리(읽기 전용 조사): 부모 48곳 모두 Seq가 1부터 이어지고, 목록 404개 모두 TrackNo가 1부터 이어졌다.

**조작별 규칙**. "번호" = 변경 카운터를 하나씩 올려 받는 값. "비움" = rekordbox가 카운터만 올리고 어느 행에도 쓰지 않는 번호다.

| 조작 | 행 | 번호 |
|---|---|---|
| 만들기 | 부모의 맨 위(Seq 1), 형제는 Seq +1 | 형제가 있으면 비움 → 새 행 → 형제마다 하나씩(Seq 순서) → 거울 행 → 새 행 한 번 더(rekordbox는 "무제 리스트"로 만든 뒤 이름을 바꾼다) |
| 이름 바꾸기 | `Name` | 하나 |
| 곡 넣기 | 끝에 붙인다(보조 브라우저로 가운데에 놓아도 끝) | 한 번에 넣은 곡이 하나를 같이 |
| 같은 곡 다시 넣기 | 확인 창("사본을 추가하시겠습니까 아니면 스킵하시겠습니까?")에서 "추가"면 새 항목 | 곡 넣기와 같다 |
| 곡 빼기 | 행을 지우고 남은 곡을 1부터 다시 매긴다 | 비움 → 남은 곡 모두(자리가 그대로인 곡도) 하나를 같이 |
| 곡 순서 | 옮긴 곡을 끼우고 다시 매긴다 | 자리가 바뀐 곡만 하나를 같이 |
| 다른 폴더로 옮기기 | 새 폴더의 맨 끝(가장 큰 Seq + 1). 옛 폴더의 형제는 그대로라 Seq에 빈칸이 남는다(가3=1·가1=3) | 옮긴 행 하나 |
| 폴더 안 순서 | 부모 안을 1부터 다시 매긴다 | 자리가 바뀐 행마다 하나씩(새 순서대로) |
| 지우기 | 폴더면 안에 든 목록·곡 항목·거울까지. 뒤 형제만 Seq −1 | 비움 → 당긴 형제 모두 하나를 같이 |

**masterPlaylists6.xml**(rekordbox 폴더, CRLF): NODE 한 줄마다 `Id`(목록 ID 16진수 대문자) · `ParentId`(맨 위 `0`) · `Attribute` · `Timestamp`(ms) · `Lib_Type` 0 · `CheckType` 0.
- 만들기: 끝에 NODE를 붙인다(Timestamp 0, 이름을 붙이면 그 시각). 부모 폴더 Timestamp도 그 시각.
- 이름 바꾸기·곡 넣기·빼기·순서: 그 목록의 Timestamp.
- 옮기기: `ParentId`와 Timestamp, 새 부모 Timestamp(옛 부모는 그대로). 폴더 안 순서: 옮긴 목록과 부모 Timestamp.
- 지우기: 바꾸지 않는다(NODE가 남는다). 그래서 새 ID는 남은 NODE와도 겹치지 않게 고른다.

**DJCrate가 쓰는 것**: `RekordboxWriter.write(playlists:)`가 편집(`PlaylistEdit`)을 적힌 순서대로 한 트랜잭션에서 쓴다. 번호를 받는 순서와 비우는 번호까지 위 표와 같게 한다. 만들기는 이름을 붙인 뒤 모양으로 한 번에 쓰고(XML Timestamp = 쓴 시각), 가운데 넣기는 넣은 뒤 옮기기(`moveTracks`)다. 막힌 편집은 그 편집만 되돌린다(번호도). 다 쓴 뒤 재생 목록 표 전체를 다시 읽어 계획과 같은지, 거울 행이 있는지 트랜잭션 안과 커밋 뒤에 본다. XML은 커밋·확인 뒤 적는다. 적지 못하면 DB·XML 모두 되돌린다. 백업에 XML을 함께 두어 되돌리기 때 같이 살린다. DB 옆에 XML이 없는 사본은 DB만 쓴다. 사본 시험은 `djc playlist-write --db <사본.db> <편집.json>`.

**앱의 재생 목록 초안**(#39·#40): 앱은 편집을 바로 쓰지 않고 `PlaylistDraft`(편집 순서 + 편집마다 기대는 rekordbox 목록의 처음 상태 `base`)로 쌓았다가 반영 때 `write(playlistDraft:)`로 넘긴다. 쓰기 모듈은 트랜잭션 안에서 쓰기 전 재생 목록 표를 `PlaylistLayout`으로 읽어 base와 비교하고, 달라진 목록에 기대는 편집은 "초안을 만든 뒤 rekordbox에서 이 목록이 바뀌었습니다"로 막는다(나머지는 위 규칙대로). 비교하는 것: 곡 넣기·빼기·옮기기·이름·옮기기는 그 목록의 이름·부모·곡 항목(TrackNo까지), 순서 바꾸기는 부모 안 순서도, 폴더 지우기는 그 아래 모든 목록과 자식 순서. 만들기·옮겨 넣을 폴더는 폴더가 있기만 하면 된다. 초안을 얹은 모양과 쓴 뒤 다시 읽은 모양이 같은지는 `RekordboxPlaylistWriterTests`의 초안 시험이 본다.

**막는 것**: 인텔리전트 재생 목록, 폴더에 곡 넣기·빼기, 목록 아래에 만들기, 폴더를 제 안으로 옮기기, 컬렉션에 없는 곡, 빈 이름. 곡 빼기·순서는 `(TrackNo, ContentID)`로 자리를 가리켜 편집을 만든 뒤 rekordbox에서 목록이 바뀌었으면 막는다.

**확인하지 않은 것**(규칙을 넓혀 둔 곳): 여러 곡을 한꺼번에 끌어 순서 바꾸기(한 곡만 봤다. 자리가 바뀐 곡만 하나를 같이), Seq에 빈칸이 있는 폴더 안 순서 바꾸기(1부터 다시 매긴다), 뒤 형제가 없는 목록 지우기(비움 하나만), 인텔리전트 목록.

## ALAC 분석 파일 조사 (#8, 2026-09-26)

**결론: ALAC 기준 표본을 확인하지 못해 규칙을 확정하지 못했다. 분석 붙이기 차단을 유지한다.** 아래는 기존 스냅샷을 읽은 결과이며, rekordbox에서 새로 분석한 전후 비교가 아니다.

- **[확인]** 조사 당시 최신 스냅샷(2026-09-26 10:17:23 UTC)의 삭제되지 않은 곡 중 `FileType IN (3, 4)` 또는 확장자가 `.m4a`인 후보를 전부 조회했다. 음원이 있는 후보는 `AudioFileOpenURL(.readPermission)`로 열어 `kAudioFilePropertyDataFormat`을 읽고, `ffprobe -select_streams a:0 -show_entries stream=codec_name`으로 교차 확인했다. 파일은 읽기만 했고 식별값·경로·곡 수는 기록하지 않았다.
- **[확인]** AudioToolbox에서 확인한 형식은 `aac `·`paac`, ffprobe에서는 `aac`였다. `alac`는 확인되지 않았다. 음원이 없는 후보도 있으므로 라이브러리에 ALAC이 없다는 결론은 낼 수 없다.
- **[확인]** `.m4a` 확장자나 `djmdContent.BitDepth`만으로 ALAC을 고를 수 없다. `BitDepth = 32`인 후보도 실제 코덱을 읽으면 ALAC이 아니었다.
- **미확인**: ALAC으로 확인된 음원과 연결된 `.DAT`·`.EXT` 기준 표본을 얻지 못했다. 따라서 태그 순서·`PVBR`·`PVB2` 유무/내용, `BitRate`·`BitDepth`·`SampleRate`, 큐의 MPEG·SeekInfo 칸은 모두 ALAC 규칙으로 확정할 수 없다. 대조 대상이 없으므로 "전수 대조 어긋남 0"으로 세지 않는다. `AudioFacts`·`TrackAnalysisFiles`와 쓰기 조건은 바꾸지 않았다.

**조사 1 당시 제안한 rekordbox 실험**:

1. 개인 음원 대신 합성 ALAC M4A(16/24비트, 44.1/48kHz, 스테레오)를 준비하고, 실제 코덱이 `alac`인지 먼저 확인한다. 자동 분석을 끈 rekordbox 7.2.18에 넣은 뒤 종료해 분석 전 스냅샷을 보관한다.
2. 사용자가 그 합성 곡만 "트랙 분석"(보통 모드, BPM/그리드·키, 프레이즈·보컬 끔)하고 종료한다. 분석 뒤 스냅샷과 실제 복사한 share에서 `.DAT`·`.EXT` 태그, 곡 행의 음원 칸·분석 카운터·파일 행을 비교한다. 탐색 칸은 별도 단계로 메모리 큐·핫큐·루프를 넣은 전후 스냅샷에서 확인한다.
3. 규칙이 보이면 합성 테스트를 먼저 실패시킨 뒤 구현하고, 읽기 전용 `djc lab` 전수 대조에서 코덱 확인 실패·음원/분석 파일 누락을 일치와 구분한다. 사본 재현으로 칸 단위 일치를 확인하기 전에는 쓰기 경로를 열지 않는다.

## ALAC·비LAME VBR 분석 파일 조사 2 (#8·#9, 2026-09-27)

**현재 결론(2026-09-27 #95 후속): ALAC 16/24비트·44.1/48kHz 스테레오와 44.1kHz ffmpeg Xing(Lavc/Lavf) VBR은 첫 BPM/Grid 카운터 사본 재현을 확인해 분석 쓰기를 연다.** 아래 조사 2 당시에는 카운터가 달라 닫았으며, 후속 재현은 다음 절에 기록한다. `TrackAddPlan`은 ALAC을 코덱으로 판별해 `FileType=6`으로 넣는다.

**[확인] 실험 조건**: rekordbox 7.2.18에 합성 7곡만 기본 자동 분석으로 가져왔다. ALAC은 afconvert로 만든 스테레오 16/24비트 × 44.1/48kHz이며, ffmpeg VBR은 44.1kHz q2/q8·48kHz q5다. VBR 압축기는 ffmpeg 기본 libmp3lame이지만 첫 Xing 프레임의 인코더 문자열은 `Lavc62.28`이고 `LAME`은 없다. 여기서 비LAME은 첫 정보 프레임 문자열에 따른 분류이며 압축 라이브러리의 출처를 뜻하지 않는다. 가져오기 직후 분석 전·분석 완료·앱 종료 후 스냅샷을 보존하고, 분석 파일은 실제 복사본으로 비교했다. 업데이트·OneLibrary 변환·기존 곡 편집은 하지 않았다.

| 시험 곡 제목 | FileType | BitRate(kbps) | BitDepth | SampleRate | Length | 상세 파형 칸 수 |
|---|---:|---:|---:|---:|---:|---:|
| DJC 실험 ALAC 16bit 44100Hz | 6 | 195 | 16 | 44100 | 33 | 5007 |
| DJC 실험 ALAC 16bit 48000Hz | 6 | 234 | 16 | 48000 | 33 | 5007 |
| DJC 실험 ALAC 24bit 44100Hz | 6 | 901 | 24 | 44100 | 33 | 5007 |
| DJC 실험 ALAC 24bit 48000Hz | 6 | 984 | 24 | 48000 | 33 | 5007 |
| DJC 실험 VBR ffmpeg 44100Hz q2 | 1 | 256 | 16 | 44100 | 33 | 5012 |
| DJC 실험 VBR ffmpeg 44100Hz q8 | 1 | 192 | 16 | 44100 | 33 | 5012 |
| DJC 실험 VBR ffmpeg 48000Hz q5 | 1 | 224 | 16 | 48000 | 33 | 5012 |

**[확인] ALAC**:
- `BitRate`는 `kAudioFilePropertyBitRate`의 bps를 1000으로 나눈 버림이다(195046·234701·901640·984708 → 표의 값). `mBitsPerChannel`은 0이고 비트 깊이는 `mFormatFlags`의 원본 16/24비트 플래그로 판별한다. 확장자만으로 AAC와 구분할 수 없다.
- `.DAT` 태그 순서는 `PPTH PVBR PQTZ PWAV PWV2 PCOB PCOB`, `.EXT`는 `PPTH PWV3 PCOB PCOB PCO2 PCO2 PQT2 PWV5 PWV4`, `.2EX`는 `PPTH PWV7 PWV6 PWVC`다. `PVBR` 머리·400칸·끝값이 모두 0이며 `PVB2`는 없다. `PPTH`는 `?/파일 이름`이다.
- 33.375초 표본의 `PWV3·PWV5·PWV7`은 5007칸이다. 유효 샘플만 센 `ceil(길이×150)`과 일치하며, 프라이밍은 0이고 끝 패딩을 더하지 않는다. `Length`는 초 버림이다. 이번 확인 범위는 스테레오 16/24비트·44.1/48kHz다.

**[확인] 비LAME VBR**:
- 기존 스냅샷의 `Xing Lavc/Lavf` 표본과 새 합성 3곡에서 `BitRate`는 정보 프레임을 뺀 **첫 음성 프레임**의 비트레이트였다. 정보 프레임 비트레이트·Xing 평균 비트레이트와는 달랐다.
- `PVBR`은 정보 프레임을 제외한 `n`개 프레임으로 기존 `max(0, floor((k+1)×n/400)−8)` 식을 쓰면 400칸과 끝값이 바이트까지 같다. 새 44.1kHz 표본의 끝값은 1473408샘플, 48kHz는 1603584샘플이다. 상세 파형 5012칸은 `ceil(센 MPEG 샘플×150/sampleRate)`와 같다.
- `Xing L3.99r1`은 같은 후보식에서 PVBR이 다르고 파형이 4칸 길었다. 이 인코더·알 수 없는 인코더·Xing이 아닌 머리는 새 규칙으로 인정하지 않는다. 음원 누락은 일치와 구분해 제외했다.
- 읽기 전용 재현: `djc lab nonlame-vbr-check --db <스냅샷>`. 인코더·비트레이트 후보·PVBR 일치 여부·파형 길이 차이의 중복 없는 익명 수치만 출력하며 곡 이름·경로·곡 수는 출력하지 않는다.

**[확인] 사본 재현과 남은 불일치**:
- 시험용 후보 구현으로 사본에 7곡을 분석 포함 추가하고, 별도 분석 전 사본의 7곡에 분석을 붙였다. 각 경로가 분석 파일 21개를 만들었다. 음원 칸과 `PPTH·PVBR·빈 PCOB`는 일치했고, 같은 그리드를 넣어 만든 `.DAT`는 `PQTZ`까지 일치했다. 파형 길이는 맞지만 파형 값은 기존 근사이며 전체 파일 바이트 일치를 주장하지 않는다.
- 카운터는 rekordbox 자동 분석이 `AnalysisUpdated='1'·TrackInfoUpdated='1'`, 곡 추가 사본이 `'3'·'2'`, 분석 붙이기 사본이 `'2'·'1'`로 달랐다. 기존 공통 카운터 규칙은 바꾸지 않았고 **후보 쓰기 허용을 제거했다**. 골든 테스트는 두 쓰기 경로가 막히고 기존 행·분석 파일을 남겨 두는 것까지 확인한다.
- 48kHz VBR q5는 곡 행 `BPM=12000`인데 첫 정밀 그리드는 `119.96 BPM`이다. 정밀 그리드를 가져온 분석 붙이기 사본은 `BPM=11996`이므로 카운터 외에도 이 차이가 남는다. #95 후속 실험에서 행 BPM과 정밀 그리드 BPM을 함께 기록해야 한다.
- 골든 테스트: `AnalysisFormatGoldenTests`(실험 날짜·시험 제목 명시). 저장소에는 음원·DB·분석 파일 사본을 넣지 않으며, ALAC은 런타임 합성하고 MP3는 정보·음성 프레임을 칸 단위로 만든다. ALAC 큐의 MPEG·SeekInfo와 미확인 ALAC 비트 깊이·샘플레이트·채널 수는 이번 실험으로 열지 않는다.

### #95 후속 사본 재현 (2026-09-27)

- 보존된 #8·#9 가져오기 전/분석 전 사본에서 ALAC 4조건·44.1kHz ffmpeg VBR 2조건을 두 경로로 재현했다. `FileType·BPM·Length·BitRate·BitDepth·SampleRate·Analysed·ContentLink·AnalysisUpdated·TrackInfoUpdated`가 기준과 일치했다. 분석 붙이기의 나머지 곡 행도 신원·경로·변경 번호·시각을 제외하면 일치했다. 새 곡의 아티스트 ID는 새 난수이므로 동일 문자열을 기대하지 않는다.
- `PPTH·PVBR·빈 PCOB/PCO2·PVB2 유무`, 파일 행의 신원·경로·해시·크기·변경 번호·시각을 제외한 칸, 파형 태그 길이를 대조했다. PVBR 400칸과 끝값은 같다. 파형·게인·박 재생성의 기존 차이는 위 검증 범위대로 남기며, 해시와 크기는 각 생성 파일 자체를 다시 읽어 검증한다. `.3EX`는 만들지 않는다.
- **48kHz ffmpeg VBR은 계속 막는다**: q5 표본은 곡 행과 `PQTZ`에 12000을 기록했지만 정밀 박 간격으로 복원한 첫 구간은 119.96 BPM이다. 다른 표본의 행/PQTZ는 ALAC 11995, ffmpeg 11997도 있어 정수 BPM 반올림을 공통 규칙으로 쓰면 틀린다. 시간 간격으로 복원한 BPM과 저장된 표시 BPM을 분리하는 규칙은 미확인이다. 확인된 44.1kHz만 열고 다른 샘플레이트·L3.99r1·알 수 없는 인코더는 막는다(#9 후속).
- `AnalysisFormatGoldenTests`는 ALAC 4조건과 44.1kHz ffmpeg의 두 쓰기 경로·글자형 '1'·'1', 48kHz ffmpeg의 두 경로 차단과 행·파일 미생성을 검증한다. ALAC 큐의 MPEG·SeekInfo와 그 밖의 ALAC 형식은 이번에 열지 않는다.

## 막아 둔 것 (규칙 미확인)

- **템포 구간이 여러 개인 곡의 BPM 변경**: 구간 이동은 되지만 BPM 변경은 막는다.
- **미확인 ALAC·VBR 형식의 분석 쓰기**: ALAC 16/24비트·44.1/48kHz·스테레오 밖, 44.1kHz가 아닌 ffmpeg VBR, L3.99r1·알 수 없는 비LAME VBR은 계속 막는다.
- **반쪽 분석 곡(.DAT만 있고 .EXT 없음)의 그리드·분석 붙이기**: rekordbox가 다시 분석한 모양은 한 곡 보았지만(위 "분석 붙이기") 사본 재현으로 확인하지 않았다.
- **카운터가 이미 있는 분석 전 곡에 분석 붙이기**: `AnalysisUpdated`·`TrackInfoUpdated`가 NULL인 곡만 확인했다.
- **태그의 공유 앨범 값 변경·동명 앨범 선택·앨범과 앨범 아티스트 동시 변경·상태 256**: 위 "태그 (곡 정보)"의 조건표. 새 앨범·단독 앨범 아티스트·아티스트 비우기·발매일 보존 연도는 연다.

## 새 쓰기 경로를 여는 방법

1. 사용자에게 rekordbox에서 그 편집을 직접 해 달라고 한다(곡 이름 받기, 끝나면 rekordbox 종료).
2. 편집 전 스냅샷과 새 스냅샷(`djc snapshot --force`)을 `djc lab sql <사본> "…"`·`djc lab db-diff`로 비교: 바뀐 테이블·칸·usn 순서. rekordbox가 조작마다 바로 쓰는 표면 켜 둔 채 단계마다 떠서 비교할 수 있다(`djc lab playlist-watch --out <폴더>`, 읽기 전용 복사만).
3. 실험 전 사본에 DJCrate로 같은 편집을 써서 칸마다 비교(예: `djc lab loop-repro --old … --new … --ids … --work <폴더>`).
4. 일치하면 `Tests/RekordboxKitTests`에 골든 테스트를 먼저 쓰고, 막아 둔 조건을 풀고, 이 문서에 규칙을 적는다.
