# rekordbox 7 내부 형식 — DJCrate가 알아낸 쓰기 규칙

rekordbox 7.2.18에서 사용자가 직접 편집한 결과를 스냅샷끼리 diff해서 뽑은 규칙이다. 각 규칙은 "실험 전 사본에 DJCrate로 같은 편집을 쓰고, rekordbox가 쓴 결과와 칸마다 비교"해서 확인했다. 확인하지 못한 규칙은 코드에서 막아 두었다(아래 "막아 둔 것").

코드: `Sources/RekordboxKit/` — `RekordboxWriter`(DB, 역할별 `+Cues`·`+Grid`·`+Gain`·`+Analysis`·`+Tags`·`+Playlist`·`+Verify`·`+Backup`), `RekordboxGridWriter`(ANLZ), `RekordboxCompatibility`(쓰기 전 버전·구조 확인), `CueJSON`, `AnlzFile`, `SeekInfo`, `MasterPlaylistsXML`, `CipherDatabase`.

## 파일과 열기

- 라이브러리: `~/Library/Pioneer/rekordbox/master.db` (SQLCipher 4). 키는 pyrekordbox와 같은 방식으로 푼다(`RekordboxKey.derive()`).
- 분석 파일: `~/Library/Pioneer/rekordbox/share/PIONEER/USBANLZ/<3자리>/<uuid 나머지>/ANLZ0000.{DAT,EXT,2EX,3EX}`. 경로는 `djmdContent.AnalysisDataPath`(`.DAT` 경로).
- 삭제 행이 절반쯤 있다(`rb_local_deleted=1`). 집계·쓰기는 항상 삭제되지 않은 행만.
- `agentRegistry`에는 클라우드 인증값이 들어 있다. 읽거나 출력하지 않는다(`djc lab sql`은 이 테이블 질의를 막는다). 예외: 쓰기 모듈이 `localUpdateCount`를 읽고 쓰고, `lastUpdateCount`의 정수 칸만 읽는다.

### iTunes 동기화 목록 읽기 (2026-09-27, #100)

- iTunes 아래의 동기화 목록은 일반 `djmdPlaylist` 목록과 구분한다. 목록 구성·순서는 읽기 전용이며, 컬렉션에 등록된 곡의 큐·태그는 기존 rekordbox 곡에 연결해야 한다.
- rekordbox 폴더의 `playlists3.sync`는 `SYNC_ITUNES_PLAYLIST/PLAYLISTS/NODE` XML이다. `Lib_Type="1"` 노드에 iTunes 영구 ID(`Id`), 부모 ID(`ParentId`), 폴더 여부(`Attribute`: 1 폴더·0 목록), 동기화 선택(`CheckType="1"`)이 있다. 이름·곡 목록은 없다. ID는 앞의 0을 생략한 UInt64 16진수다.
- `rekordbox6/rekordbox3.settings`의 `showAllItunesPlaylist="0"`과 rekordbox 화면의 동기화 목록만 표시하는 상태가 일치했다. `MusicAppLoadingType="1"`인 환경에서 동기화 ID를 Apple `ITLibrary` API와 대조해 목록과 곡 순서를 확인했다. 일반 DB에서 해당 목록 이름은 발견되지 않았다.
- 공식 개발진은 Framework 방식이 Apple의 `ITLibrary`에서 Music 보관함 정보를 읽고, XML 방식과 선택할 수 있다고 설명한다([공식 답변](https://forums.pioneerdj.com/hc/en-us/community/posts/900001887506-What-does-Framework-in-iTunes-load-method-mean-and-imply-for-the-sync-manage), [Apple API](https://developer.apple.com/documentation/ituneslibrary/itlibrary)). 동기화 선택 정보가 존재한다는 것만으로 마지막 동기화 당시 이름·곡 순서까지 별도 DB에 보존된다고 가정하지 않는다.
- DJCrate는 동기화 ID로 표시할 대상을 고르고, 선택 창에서 바꿀 수 있도록 전체 목록 본문도 사본에 보관한다. 읽기는 rekordbox의 설정을 따른다(`RekordboxITunesReader`). Framework는 `ITLibrary`, XML은 설정의 `itunesLibraryFile`이다. 실제 화면에서 Framework가 선택된 상태와 설정값 1, 동기화 파일과 API의 목록 순서·화면에 표시된 목록의 기존 컬렉션 연결을 확인했다. XML 방식(값 0)은 합성 설정·XML로 검증했다.
- 앱 시작·새 스냅샷·iTunes 목록 새로고침 때 읽고 `<DB 스냅샷>.itunes.json`에 사본을 보관한다. 읽기에 실패하면 마지막 정상 사본을 덮어쓰지 않고, 현재 화면과 새 DB 스냅샷에는 이전 목록을 오래된 자료로 표시한다. 직전 사본이 손상됐으면 같은 스냅샷 폴더에서 더 이른 정상 사본을 찾는다. 새 DB를 뜨기 전에 이전 목록을 메모리에 보관해 같은 초에 파일 이름을 재사용해도 복구할 수 있게 한다. 같은 DB의 갱신은 요청 순서로 채택하며 sidecar 확인·저장을 한 잠금 안에서 끝내고, 겹친 DB 스냅샷 생성은 순서대로 처리한다. 명시한 `--db`·`DJC_DB` 모드의 iTunes 새로고침 버튼은 현재 DB와 그 옆 목록 사본·동기화 파일만 다시 읽으며, 별도의 새 스냅샷 메뉴는 원래 동작을 따른다. 비어 있지 않은 `DJC_REKORDBOX_DIR` 사본도 그 폴더의 DB와 목록만 읽어 실제 Music 보관함과 섞지 않는다. 오래된 DB를 정리할 때 목록 사본도 지운다.
- `SyncedITunesLibrary`는 정규화한 파일 경로가 유일하게 일치하는 기존 컬렉션 곡만 연결한다(삭제 행 제외). 없는 곡·모호한 경로는 개수를 알리고, 같은 곡의 반복과 원래 순번을 유지한다. 행 ID는 목록 ID·기존 곡 ID·곡별 등장 순번으로 만들고 편집은 기존 곡 ID로 연결한다. 별도 사이드바 항목·`itunes:` ID를 써서 재생 목록 초안에 섞지 않는다. 목록 구성·순서·삭제는 막고, 기존 곡의 큐·태그 초안과 반영 경로를 그대로 사용한다.

### iTunes 동기화 선택 쓰기 (2026-09-27, rekordbox 7.2.14.0323)

- 실제 설치 버전 `7.2.14.0323`에서 사용자가 선택된 플레이리스트 하나를 해제하고 SYNC 후 종료한 전후 사본을 비교했다. `playlists3.sync`의 해당 NODE는 없어졌고, 상위 폴더는 `CheckType` 1→2가 됐다. 남은 iTunes 노드의 `Timestamp`는 동기화 시점의 Unix 밀리초로 갱신됐고 루트(ID 0)는 시각 0을 유지했다.
- 루트·PRODUCT 메타데이터, 남은 노드의 순서, `masterPlaylists6.xml`, iTunes 읽기·표시 설정은 같았다. 인증 표를 제외한 DB의 표·행·칸에도 변화가 없었다. Music API의 폴더별 선행 순회가 파일의 노드 순서와 같았다.
- `ITunesSyncExperimentRepro`는 전후 파일의 모든 NODE 속성과 순서를 사본에서 재현한다. 실행 시각은 전후 대조용으로 주입하고, 실제 `RekordboxWriter.write` 경로도 사본에서 실행해 시각 외 모든 칸·순서 일치와 DB 바이트 불변을 확인한다. 실제 파일은 저장소에 넣지 않는다.
- 같은 목록을 다시 체크해 SYNC한 결과, 목록 NODE는 제자리로 돌아왔지만 부모의 `CheckType`은 **2를 유지**했다. 하위를 모두 고른 상태와 폴더 자체를 고른 상태는 다르다. DJCrate도 부모를 직접 고를 때만 1로 쓰고, 하위 선택만 있으면 2로 쓴다. ID 0은 `All Playlist`의 명시적인 선택으로 별도 보존한다.
- 추가·해제 두 방향 모두 모든 속성·순서 재현을 통과해 `RekordboxWriter.write(iTunesSync:)`를 열었다. 실행·버전·DB 구조·카운터 검사 → 전체 DB와 동기화 파일 백업 → 선택 원문(base) 재확인 → 동기화 파일 원자적 교체 → 다시 읽기·무결성 검사 순서다. DB와 Music 보관함에는 쓰지 않는다. 실패 시 동기화 파일을 복원하고, 이후 외부에서 선택을 바꾸면 되돌리기도 덮어쓰지 않는다.
- DJCrate 전용 선택 파일은 더 이상 읽지 않는다. 선택은 `playlists3.sync`를 기준으로 하며, DB가 그대로인 동기화 변경도 창으로 돌아올 때 감지한다. 명시한 DB 사본에서는 그 옆 동기화 파일만 쓴다.
- 읽기 요청 순서는 스냅샷 URL별로, 동기화 쓰기 세대는 출처 DB별로 관리한다. 쓰기가 완료되면 같은 출처의 오래된 캡처와 화면 로드를 무효화한다. 서로 다른 URL의 정상 캡처는 각각 보존해 뒤의 갱신 실패 때 복구 자료로 쓸 수 있게 한다.
- `DJC_REKORDBOX_DIR`만 지정한 모드는 사본 루트의 현재 동기화 파일을 적용한다. 새 스냅샷을 뜰 때 같은 출처의 현재 목록도 메모리에 보관해 같은 초 파일명 재사용, 없는 루트 캐시, 오래된 루트 캐시 때문에 선택·전체 목록이 돌아가지 않게 한다. 명시한 `--db`·`DJC_DB`는 기본 스냅샷 폴더 안에 있어도 자동으로 다른 DB를 열지 않는다.
- 선택 창은 `ITunesSyncOutline`으로 이름·계층만 구성한다. 곡 경로 정규화와 컬렉션 곡 연결은 실제 라이브러리 목록을 읽을 때만 수행하며, 선택 창의 화면 계산에서는 트리·미리보기를 한 번씩 만든다.

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

### 자동 큐 (#145)

- rekordbox가 분석 때 넣는 메모리 큐다: `Kind` 0, `Comment` `CUE(Auto)` 또는 `1.1Bars`, `Color` 255, `ColorTableIndex` 0, `ActiveLoop`·`BeatLoopSize`·`CueMicrosec` 0. rekordbox 화면에서는 메모리 큐로 보이고 한도(10개)에 든다.
- DJCrate는 **이름으로만** 자동 큐를 가린다(`Color` 255는 이름 없는 일반 큐에도 많다). 덱 큐 목록에 '자동' 표시를 붙인 메모리 큐로 보이고, 일반 메모리 큐처럼 옮기기·지우기·이름·루프·종류를 고친다. 지우기 말고 한 번이라도 고치면 자동 이름을 비워(이름을 넣었으면 그 이름) 일반 큐가 된다.
- 쓰기에 자동 큐 전용 규칙은 없다. 건드리지 않은 자동 큐의 행·JSON 객체는 바이트 그대로 두고, 지우면 그 행을 지운다. 고친 자동 큐는 같은 칸 값을 가진 직접 찍은 큐를 옮길 때와 같은 규칙으로 새로 넣는다(`Comment` NULL 또는 넣은 이름, 색을 지정하지 않은 큐로 보아 `Color` −1·`ColorTableIndex` NULL). 골든 테스트 `RekordboxWriterGoldenTests`의 자동 큐 묶음이 칸 단위로 고정한다. **[미확인]** rekordbox에서 자동 큐를 옮겼을 때도 같은 모양인지는 실험하지 않았다.
- #145 이전 초안(자동 큐를 빼고 만든 `base`)과 중복 합치기 초안은 불러올 때와 쓸 때 곡의 자동 큐를 `base`·`cues`에 채운다(`CueDraft.includingAutoCues`). 변경으로 치지 않으므로 예전처럼 그 행은 그대로 남고, 한도는 자동 큐까지 센다.

### 루프 (2026-09-26, Flip Flop·ときめき分類学 실험 + 기존 루프 105개)

- `OutMsec` = 끝 ms, `OutFrame` = 끝 ms × 150 / 1000(내림).
- `Color` 255, `ColorTableIndex` 0, `ActiveLoop` 0/1(활성 루프 = 곡을 불러오면 자동으로 반복), `CueMicrosec` 0, `Comment` `''`(JSON에는 안 적음).
- `BeatLoopSize` = 분자 << 16 | 분모. 8박 524289, 16박 1048577, ½박 65538, 박에 맞지 않는 루프 0.
- 새로 만든 루프는 JSON에도 `ActiveLoop`·`BeatLoopSize`가 있다(옛 루프 JSON엔 빠진 경우가 있음).
- 활성 루프는 곡당 하나(라이브러리에 둘 이상인 곡 없음). rekordbox는 활성 켜기를 행 제자리 UPDATE로 하고 `CueUpdated`를 안 올리지만, DJCrate는 지우고 새로 넣는다(결과 상태는 같음).

### 파일 형식별 탐색 위치

- MP3 CBR·M4A·WAV: `InMpegFrame`·`InMpegAbs` 0, SeekInfo NULL.
- FLAC: `InPointSeekInfo` = `"<큐 샘플이 든 FLAC 프레임 시작 샘플>,<그 프레임 바이트 위치 − 첫 오디오 프레임 위치>,<블록 크기>"`. 루프가 아니면 `OutPointSeekInfo` = `"0,0,0"`, 루프면 끝 지점을 같은 식으로. 기존 큐 1,818개·루프 끝 전부와 일치. 본문이 잘려 CRC-16이 맞지 않는 프레임이 있어도 프레임 머리의 번호를 따른다(2026-10-03 #14 곡 D의 원래 곡 큐 13개, 손상 뒤 큐 포함). PVB2는 이때 규칙이 달라진다(아래 "곡 추가").
- VBR MP3(파일 머리가 Xing·VBRI거나 프레임 길이가 들쭉날쭉): `InMpegFrame` = InFrame / 2(1/75초 단위), `InMpegAbs` = rekordbox가 세는 프레임(LAME·`L3.99r1` 정보 프레임은 세고 다른 인코더의 정보 프레임은 뺌) 중
  `floor(올림(InMpegFrame × 1000 / 75)ms × 샘플레이트 / 1000 / 1152) − 8`번째(음수면 0번째) 프레임의 바이트 위치(첫 센 프레임 기준). 루프 끝도 같은 식, 루프가 아니면 끝은 0·0. SeekInfo는 NULL.
  ms를 버림하면 1,099개, 올림하면 1,118개 전부 맞는다(기존 VBR 큐 1,118개·루프 끝 6개, `djc lab seekinfo-check`). 사본에서 VBR 200곡의 큐 886개를 지우고 다시 써도 885개가 칸까지 같다(`djc lab vbr-cue-repro`, 나머지 1개는 rekordbox가 옛날에 MPEG 칸을 비워 둔 큐).
  `L3.99r1` 정보 프레임을 빼고 세던 때는 그 인코더 곡의 큐 1개가 한 프레임(313바이트) 어긋났다. 2026-10-03 같은 곡의 복제본에 rekordbox 7.2.18로 새로 찍은 큐도 같은 값이라 옛 상태가 아니라 세는 규칙 차이였다. 정보 프레임을 세도록 고친 뒤 `seekinfo-check`의 VBR 큐 어긋남은 0이다(#14).

## 비트그리드 (ANLZ)

- `.DAT`의 `PQTZ`: 박마다 `박 번호(u16 1~4) · BPM×100(u16) · 시각 ms(u32)`. 시각은 정밀 시각을 **내림**, 곡 앞 −1ms 안의 박은 0.
- `.EXT`의 `PQT2`: 머리에 첫 박·마지막 박·박 수·정체 모를 u32, 본문은 박마다 (ms 아래 소수 × 1024). rekordbox가 그리드를 손으로 고치면 PQT2를 빈 형태(머리 0·본문 없음)로 바꾼다 → DJCrate도 그렇게 쓴다.
- 이동만 하면 DB는 안 바뀐다(`contentFile` 해시도 그대로).
- 전체를 단일 템포로 바꾸면:
  - `.DAT`의 `contentFile` 행: `Hash`(새 파일 MD5), `Size`, `rb_data_status`, `rb_local_usn`, `updated_at`.
  - `djmdContent`: `BPM`(×100), `AnalysisUpdated`+1·`TrackInfoUpdated`+1(글자형), 상태, usn.
  - 소수(PQT2)가 없으면 첫 박을 ms + 0.5로 보고 다시 계산한다(바이트까지 재현).
- 다른 태그는 바이트 그대로 둔다(`AnlzFile`이 태그 단위로 읽고 PMAI 전체 길이만 다시 적는다).
- **파형 파일(.EXT)이 없는 곡은 rekordbox 분석 전 곡이다**(BPM 0, PQTZ 0박). 그리드만 쓰면 파형 없는 채로 남으므로 막는다(2026-09-26 サラマンダー).
  분석 파일이 아예 없는 곡은 분석 붙이기로 쓰고(아래 "분석 붙이기"), `.DAT`만 있는 반쪽 곡은 "rekordbox에서 트랙 분석을 다시 한 뒤 쓰세요"로 막는다.

### 여러 템포 구간의 BPM 편집 (#11, 2026-09-28)

**[확인] rekordbox 7.2.18의 두 입력 경로는 다르다.** 합성 WAV 「DJC 다구간 BPM 실험 A 첫 구간」과 「DJC 다구간 BPM 실험 B 중간 구간」에서 사용자가 직접 편집하고, 종료 후 DB 스냅샷과 분석 파일 실제 복사본을 보존했다.

- 평소 GRID BPM 칸에 입력하면 전체를 단일 템포로 바꾼다. A의 120→150→100을 121로 바꾸면 121 BPM 99박이 된다. 파일 행·분석 카운터·곡 정보 카운터는 기존 단일 템포 규칙대로 바뀐다.
- 「현재 위치로부터 조정」 버튼의 **별도 BPM 입력창**으로 구간을 편집하면 `PQTZ`를 바꾸고 `PQT2`는 빈 형태로 둔다. 다른 분석 태그와 `.2EX`·`.3EX`는 그대로다.
- B의 120→151→100을 별도 입력창으로 121→152→101로 바꾼 종료 후 결과: `djmdContent.BPM` 12000→12100, `TrackInfoUpdated` '4'→'5', `rb_local_usn`·`updated_at`만 바뀌었다. **`AnalysisUpdated` '7'과 `contentFile`의 해시·크기·번호를 포함한 모든 칸은 그대로**다. 파일 행 해시가 실제 `.DAT`와 다를 수 있으며 임의로 새 해시로 맞추지 않는다.
- 첫 구간의 BPM이 그대로인 부분 편집은 대표 BPM을 바꾸지 않는다. DJCrate도 다구간 초안의 첫 BPM이 달라졌을 때만 대표 BPM·곡 정보 카운터를 갱신한다. 단일 구간으로 합치는 초안은 전체 BPM 편집 경로를 쓴다.
- 구간 경계는 이전 구간에서 가장 가까운 박을 대체한다. B의 151 BPM 구간을 29.305초에서 끝낼 때 29.209초 박을 따로 넣지 않아 총 97박이다. 각 구간 시작은 정밀 소수가 없으면 ms + 0.5로 계산한다. 121→152→101의 구간 시작 0.494·16.362·28.994초로 생성하면 98박의 번호·BPM·시각이 모두 일치한다.
- 고치지 않은 구간은 경계 직전의 원래 박까지 보존한다. ms 간격에서 역산한 BPM으로 다시 만들면 일부 박이 1ms 바뀔 수 있다. 경계를 늦춰 새로 늘인 박에는 위의 반 박 대체 규칙을 적용한다. 전체 이동·박 번호 변경도 기존 박의 시각을 보존한다.
- 안전 차단: 음원 안에서 시작하는 구간의 박이 경계 대체로 모두 사라지면 쓰지 않는다. 첫 구간이 없어지면 대표 BPM과 실제 첫 박의 BPM이 달라질 수 있다. 새 곡 분석과 기존 곡 쓰기에 같은 검사를 적용한다.

**사본 재현**: `GridTempoExperimentRepro`는 A 전체 변경과 B 다구간 변경을 각각 실험 전 사본에 `RekordboxWriter.write`로 쓰고, `.DAT`·`.EXT`·`.2EX`·`.3EX` 전체 바이트와 곡·파일·큐·게인 표의 모든 대상 칸을 대조한다. 실행 시각과 변경 번호 값은 변경 여부로 비교하고 나머지 칸은 값까지 일치한다. 실행은 `DJC_GRID_EXPERIMENT=<전후 사본과 edits.json 폴더> swift test --filter GridTempoExperimentRepro`이며, 사본·입력 JSON은 저장소 밖에 둔다. 합성 골든 테스트는 `MultiTempoGridWriterTests`로 유지한다.

## 오토게인 (`djmdMixerParam`)

- `GainHigh`·`GainLow` = 선형 게인 float32의 상위·하위 16비트. `PeakHigh`·`PeakLow`는 샘플 피크.
- rekordbox 편집 시 삭제되지 않은 행 하나의 `GainHigh`·`GainLow`·상태·usn·`updated_at`만 바뀐다(같은 곡의 삭제된 옛 행이 따로 있을 수 있음).
- rekordbox는 약 −10 LUFS에 맞춘다: 게인 dB + 곡 LUFS = −9.97 ± 0.25.

## 태그 (곡 정보)

**실험 1**(2026-09-26 묶음 2, O-Ku-Ri-Mo-No Sunday!): 제목·아티스트(새 이름)·장르(새 이름)·코멘트·별점·키를 고쳤다. 같은 세션에 분석·Relocate·재생 목록 편집도 해서 카운터는 가를 수 없었다.
**실험 2**(2026-09-27, 합성 곡 "DJC 실험곡 1~5"): 정보 패널에서 한 칸씩 고쳤다. 세션 1은 값 넣기, 세션 2는 비우기였다. 각 세션 전후 스냅샷(S0·S1·S2)을 `djc lab db-diff`로 비교했다. 자동 분석은 끄고 했다.
**실험 3**(2026-09-27, 태그 2단계): 같은 합성 곡과 새 합성 AAC "DJC 실험 태그 날짜·중복 A/B"로 S0~S5를 비교했다. 새 앨범·기존 앨범 붙이기·공유 앨범 아티스트 넣기와 비우기·동명 앨범·아티스트 비우기·발매일이 있는 곡의 연도를 가렸다. 앱·Agent 종료 뒤에만 스냅샷을 보존했다. 마지막 자동 분석 설정 복원으로 새 AAC의 분석 칸이 바뀐 것은 태그 비교와 분리했다.
**실험 4**(2026-10-01, #171): 클라우드 동기화 상태(`rb_data_status` 256)인 곡 "カクシタワタシ"의 코멘트를 곡 정보에서 고쳐 저장하고 종료한 전후 사본, 같은 곡의 코멘트를 다시 저장하고 종료한 사본을 `djc lab db-diff`로 비교했다. 아래 "동기화 상태(256·257)인 곡".
**#173 세션 S1·S2·S3**(2026-10-04, rekordbox 7.2.18, 자동 분석 끔): 실제 동기화 곡과 상태 0 곡(S1 T01~T16·X1~X3, S2 U01~U14·X4, S3 V01~V07, 역할 이름만 적는다)의 정보 패널에서 한 칸씩 저장했다. 세 세션은 같은 기준점에서 따로 했고, 끝날 때마다 라이브러리를 기준점으로 되돌렸다. 아래 "동기화 상태(256·257)인 곡".

rekordbox 7.2.18이 하는 것:
- 정보 패널은 **칸마다 따로 저장**한다(한 줄 칸은 Enter, 코멘트는 다른 칸으로 옮길 때). 한꺼번에 저장하는 버튼은 없다. 앨범 아티스트 칸이 있다.
- `djmdContent` 행을 제자리에서 UPDATE한다. `TrackInfoUpdated`(글자)는 **저장 한 번에 +1**이다(제목·코멘트 '1'→'3', 장르·작곡가·연도·트랙 번호 '1'→'5', 그 넷을 비우면 '5'→'9'). 값이 같아도 저장하면 +1이다(#173 S2 X4). `FileSize`와 다른 칸은 그대로였다(음원 파일 태그는 다시 쓴다).
- 제목 `Title`, 코멘트 `Commnt`(비우면 `''`), 연도 `ReleaseYear`·트랙 번호 `TrackNo`(정수, 빈칸은 받지 않아 0을 넣으면 0). 연도를 넣어도 `ReleaseDate`는 그대로였다. 실험 3의 발매일 있는 합성 곡에서도 연도 2012→2024→0이 발매일을 바꾸지 않았다.
- 이름 칸(`ArtistID`·`ComposerID`는 `djmdArtist`, `GenreID`는 `djmdGenre`, `AlbumID`는 `djmdAlbum`):
  - 있는 이름이면 그 행을 쓰고, 없으면 새 행을 만든다(ID 32비트 난수, UUID 소문자, `SearchStr` NULL, 상태 칸 0, `usn` NULL, 곡 넣기와 같은 모양). 아티스트·장르 새 행은 `created_at` = `updated_at`이고, 새 앨범 행은 2~3ms 다르다(#173 S1 T04·S3 V02, 상태 0 실험도 같았다. DJCrate는 같은 값을 쓰고 시각은 비교하지 않는다).
  - 이름은 대소문자까지 정확히 찾는다. 대소문자만 다른 행만 있으면 새 행을 만든다[확인](#173 S1 T03·S2 U13·S3 V05). DJCrate의 `Name = ?`와 같다.
  - 비우면 아티스트·작곡가·앨범 `''`, 장르 `'0'`. 앨범을 비우면 앨범 아티스트도 함께 빈칸이 되고, 저장은 한 번이다.
  - 아무 곡도 안 쓰게 된 옛 이름 행은 버린다. 상태 0 행은 **실제로 지운다**(삭제 표시가 아니다). 아티스트 A→B로 바꾼 A, 비운 장르·작곡가, 비운 앨범이 그랬다. 동기화(256) 행은 258·삭제 표시로 바꾼다(아래 "동기화 상태(256·257)인 곡"). 지운 앨범의 앨범 아티스트 행은 아무 곡도 안 쓰는데도 남았다. 다른 곡도 쓰는 이름은 그대로다.
  - 동기화(256·257) **앨범** 행이 버려졌는지는 **살아 있는 곡의 참조로만** 센다[확인](#173 S2 U04: 지운 곡 여럿이 가리키던 동기화 앨범도 비우자 258, U01·U14도 동기화 앨범). 동기화 아티스트·장르 행에서 지운 곡이나 258 앨범이 가리킬 때는 보지 못했다[미확인]: 버려진 동기화 아티스트·장르(S1 T02·T05, S2 U03·U05·U06·U14, S3 V03)는 모두 그런 참조가 없었다. DJCrate는 그런 참조가 남은 동기화 아티스트·장르를 건드리지 않고 남긴다. 상태 0 행은 근거가 없어 예전처럼 지운 곡·앨범까지 센다(지워도 외래 키가 끊기지 않게). 라이브러리 조사에서 살아 있는 참조가 0인 살아 있는 이름 행은 없었고, 지운 곡만 가리키는 상태 0 이름·앨범 행도 없었다.
- **아티스트를 고치면 그 곡의 앨범 행도 저장된다**: `AlbumArtistID`가 NULL이면 `''`, 값이 있으면 그대로이고, 변경 번호·`updated_at`를 받는다(실험곡 5, 묶음 2). 앨범에 곡을 붙일 때(있는 앨범 이름)도 그 앨범 행이 같은 식으로 저장됐다. 제목·코멘트·장르·작곡가·연도·트랙 번호를 고칠 때는 앨범 행이 그대로였다. 저장되는 앨범 행은 자기 상태로 256 → 257, 0·257은 그대로다(#173).
- 앨범 이름이 유일하면 앨범 아티스트를 **제자리에서** 고친다(새 이름이면 아티스트 행 추가). 빈 값은 `''`이고, 더 이상 참조하지 않는 이전 아티스트 행은 버린다. 다른 곡·앨범이 참조하면 남긴다. 지운 곡만 함께 쓰던 앨범도 "유일한 곡의 앨범"이다(#173 S2 U01·U14).
- 공유 앨범도 같은 행을 고치므로 **선택하지 않은 곡의 앨범 아티스트까지 바뀐다**. 그 곡들의 `TrackInfoUpdated`는 그대로이고 화면 값은 다시 불러오기 전까지 낡을 수 있다.
- 새 앨범 행: `AlbumArtistID`는 기존 앨범 아티스트 ID를 이어받고 없으면 `''`(NULL 아님), `Compilation` 0, `ImagePath`·`SearchStr` NULL, 나머지 이름 행 공통 칸은 위와 같다. 이전 앨범은 미참조이면 버린다.
- 이름이 유일한 기존 앨범에 붙이면 그 앨범 행을 저장하고 곡의 이전 앨범 아티스트로 덮어쓴다. 다른 앨범 아티스트를 가진 앨범에 붙이는 것은 다른 곡까지 바꾸므로 DJCrate에서는 막는다.
- **동명 앨범**: 아티스트를 저장할 때 곡의 앨범 이름을 살아 있는 앨범 둘 이상이 쓰면, 옛 앨범은 저장하지 않고 같은 이름의 새 앨범을 만들어 곡을 옮긴다. 새 앨범은 옛 앨범 아티스트를 이어받고(NULL이면 `''`) 상태 0이다. 옛 앨범은 쓰는 곡이 없어지면 버린다. `TrackInfoUpdated`는 +1이다[확인](#173 S3 V02: 상태 0 곡·앨범 아티스트 있음·이 곡만 씀·나중에 만든 행, S2 U13: 동기화 곡·앨범 아티스트 NULL·다른 곡도 씀·가장 먼저 만든 행. 네 조건이 모두 반대인데 결과가 같았다. U13의 +2는 rekordbox가 그 곡을 두 번 저장한 것으로 본다[추정]: V02는 한 번 저장에 +1이고, U13에는 빈 번호도 더 많았다). `(이름, 앨범 아티스트)` 짝이 같은 행이 있어도 새로 만든다(실험 3·V02). 이름이 유일한 공유 앨범은 갈라지지 않고 제자리 저장이다(S3 V01). 아티스트 비우기도 같은 규칙일 것으로 보지만[추정] 실험하지 않아 DJCrate는 막는다(S4 대상).
- 변경 번호: 새 이름 행 → (빈 번호) → 앨범 행 → 옛 행(258·지움) → 곡 행(#173 S1~S3 모두 같은 순서). rekordbox는 저장 한 번에 곡 행을 두 번 고쳐 번호를 두 개 쓰는 것으로 보인다. DJCrate는 행마다 한 번이고, 258을 쓰면 곡 행이 마지막 번호를 한 번 더 받는다(번호 값은 비교하지 않는다).
- 곡 정보를 저장하면 그 곡이 든 살아 있는 재생 목록마다 `masterPlaylists6.xml`의 `Timestamp`를 저장 시각(UTC epoch ms)으로 바꾼다. 부모 폴더·다른 목록·DB 재생 목록 표는 그대로다. 곡 상태 0도 같다. 제목·아티스트·장르·같은 값 저장은 [확인](#173 S1 X1, S2 U11·U12·X4, S3 V07). 앨범·앨범 아티스트·작곡가·연도·트랙 번호·코멘트는 [미확인]이다(S3 V06 연도는 같은 목록의 V07이 덮어 가려졌다, S4 대상). DJCrate는 확인한 세 칸을 쓴 초안에서만 고친다. S2에서 "앨범·작곡가 저장은 XML을 안 바꾼다"고 본 근거('전체' 목록)는 그 목록 항목이 모두 삭제 표시라 무효다. 그림 저장은 바꾸지 않는다(S1 X2·S3 V04).

라이브러리 조사(2026-09-27, 스냅샷 사본 읽기 전용): 비어 있는 이름 칸은 NULL·`''`·`'0'`(장르)가 섞여 있다. NULL은 곡 넣기, `''`·`'0'`은 정보 편집에서 온 것으로 보인다. `ReleaseDate`(`YYYY-MM-DD`)가 든 곡은 앞 네 자가 `ReleaseYear`와 같다. 아무 곡도 쓰지 않는 이름 행은 삭제 표시(`rb_local_deleted` 1)된 것만 있다.

**사본 재현**(2026-09-27): S0 사본에 실험 2의 저장을 한 번씩 `djc lab tag-write-test`로 되풀이하고, S1·S2와 곡 행·이름 행을 칸마다(ID·UUID·변경 번호 값·시각 말고) 비교했다. 번호를 받은 행의 순서도 비교했다.
- 제목·코멘트·아티스트(새 이름·있는 이름, 버려진 A 삭제, 앨범 행 `''`)·장르·작곡가(넣기·비우기·삭제)·연도·트랙 번호·`TrackInfoUpdated`·번호 순서가 두 세션 모두 같다.
- 앨범 비우기(`''`, 앨범 행 삭제, 앨범 아티스트 행 남김)도 같다.
- 다른 것은 있는 앨범 이름을 붙일 때 rekordbox가 그 앨범 행을 저장(`AlbumArtistID` NULL → `''`)한 것 하나다.
- 묶음 2 실험 전 사본 재현에서도 제목·코멘트·새 아티스트·장르 행이 같았다(`TrackInfoUpdated`는 섞인 실험이라 비교하지 않음).

**DJCrate가 쓰는 것**(`RekordboxWriter+Tags`, 반영 ⌘⇧E, #1):
- rekordbox 라이브러리만 쓰고 음원 파일 태그는 건드리지 않는다(2026-09-26 결정). 확인 창에 "음원 파일의 태그는 그대로"라고 알린다.
- 여러 칸을 한 번에 쓰되 **칸마다 한 번 저장한 것과 같은 결과**를 낸다.
  - `TrackInfoUpdated` += 바꾼 칸 수. 앨범을 비우며 앨범 아티스트도 비우면 하나로 센다. 동명 앨범이라 새 앨범으로 옮겨도 아티스트 칸 하나로 센다.
  - 비운 값은 위와 같다. 버려진 이름·앨범 행은 상태 0이면 지우고 256이면 258로 표시한다. 참조는 곡 행의 아티스트·작곡가·원곡 아티스트·리믹서·앨범·장르와 앨범의 앨범 아티스트다. 세는 범위는 버려질 행의 표와 상태로 정한다(`ReferenceRows.scope`): 동기화(256·257) 앨범은 살아 있는 곡만, 그 밖(동기화 아티스트·장르, 상태 0 행)은 지운 곡·앨범까지 센다(258로 표시한 앨범도 앨범 아티스트 칸을 그대로 가리킨다). 지운 곡·258 앨범만 가리키는 동기화 아티스트·장르는 건드리지 않고 남긴다(257이어도 막지 않는다). 칸마다 인덱스로 센 개수를 UNION ALL로 이어 살아 있음·지움별 개수만 센다(`ReferenceCount`). 곡 빼기(`RekordboxTrackWriter.referenceCount`)는 지운 곡까지 세는 옛 규칙 그대로다.
  - 아티스트를 고치면 곡의 앨범 행을 저장한다(256 → 257). 곡의 앨범 이름을 살아 있는 앨범 둘 이상이 쓰면 저장하지 않고 같은 이름의 새 앨범으로 옮긴다(위 "동명 앨범"). 그런 곡의 아티스트 비우기는 막는다.
  - 변경 번호는 정보 패널 칸 순서에서 앨범을 아티스트보다 앞에 둔다: 앨범 → 아티스트(→ 바뀐 뒤의 앨범 행) → 장르 → 작곡가 새 행 → 곡 행 → 버려진 행(258) → 곡 행 한 번 더(258을 썼을 때). 앨범과 아티스트를 함께 고치면 rekordbox에서 앨범 → 아티스트 순으로 저장한 결과와 같다(이 곡만 쓰던 옛 앨범을 저장했다가 버리지 않는다).
  - 곡 상태 0·256·257은 위 칸을 모두 쓰고, 동기화 곡은 곡 행 상태를 256 → 257로 올린다(아래 "동기화 상태(256·257)인 곡"). 그 밖의 곡 상태, 저장할 앨범의 상태가 0·256·257이 아닌 경우(NULL 포함)는 막는다.
  - 제목·아티스트·장르 중 하나라도 쓴 곡이 든 살아 있는 재생 목록(지운 목록·지운 곡 항목 제외)의 `masterPlaylists6.xml` Timestamp를 쓴 시각으로 고친다(`playlistTimestampTagKeys`). 그 밖의 칸만 쓴 초안과, 그 곡이 든 살아 있는 목록이 없는 초안은 XML을 읽지도 고치지도 않는다. 쓰는 DB 옆 파일만 고치고, 없으면 DB만 쓴다. 사본 옆 XML이 라이브 XML의 링크면 백업 전에 쓰기째 막는다. XML이 필요한데 읽지 못하면 그 곡정보 초안들만 할 일과 함께 막고 같은 쓰기의 큐·그리드·게인·다른 초안은 쓴다(재생 목록·합치기 쓰기는 예전처럼 쓰기째 막는다). XML은 재생 목록 쓰기와 같은 경로로 DB를 확인한 뒤 적고(고칠 목록의 Timestamp는 모아 한 번에 고친다), 적지 못하면 DB·XML 모두 백업으로 되돌린다. 되돌릴 때 XML은 DB와 따로 되살려 DB 복사가 실패해도 쓰기 전으로 돌려 둔다(`restoreFiles`, 사용자의 "쓰기 전으로 복원…"도 같다).
- 초안의 base(초안을 만들 때 rekordbox 값)와 지금 곡 정보가 한 칸이라도 다르면 그 곡은 쓰지 않는다. 빈 제목, 숫자가 아니거나 음수인 연도·트랙 번호, 비운 앨범에 새 앨범 아티스트도 막는다.
- 앨범과 앨범 아티스트를 동시에 바꾸는 조합은 비우기를 제외하고 한 칸씩 반영하도록 막는다. 공유 앨범 아티스트·동명 앨범으로 붙이기도 막힌 이유와 rekordbox에서 할 일을 알린다.
- 버릴 행과 방법은 함수 하나(`planReleases`)가 정한다. 쓴 뒤 곡 행·앨범 행이 가리킬 것을 계산해 다른 곡·앨범의 참조와 더하고, 버려질 행이 257이거나 0·256·257이 아닌 상태면 막는다. 백업 전 확인(`checkTagDrafts`)과 트랜잭션 안의 확인이 이 함수 하나를 그때의 DB로 부른다(백업 전은 시작 DB, 트랜잭션 안은 앞 초안을 쓴 DB). 트랜잭션 안의 결과대로 정리한 뒤 다시 센다(`applyReleases`): 버릴 행이 아직 쓰이거나 남길 행을 아무도 안 쓰면 계산이 틀린 것이라 검증 실패로 쓰기 전체를 되돌린다. 여러 초안이 얽혀 트랜잭션 안에서만 막히는 경우(예: 두 곡이 함께 쓰는 257 앨범을 둘 다 떠나면 둘째)는 트랜잭션의 판단이 기준이다: 그 초안만 막힘으로 보고하고 변경 번호도 되돌리며 나머지는 쓴다(백업은 이미 떠 있다).
- 같은 쓰기에서 큐·그리드·분석도 쓰는 곡은 태그를 마지막에 써서 곡 행이 가장 큰 번호를 받는다.
- 다시 읽어 검증한다: 곡 정보(라이브러리 읽기와 같은 조인)·`TrackInfoUpdated`(글자형)·곡 행 상태(`rb_data_status`)·곡 행의 `AlbumID`(앨범 칸을 쓰거나 옮겼을 때)·곡 행과 앨범 행의 번호와 상태·지운 이름 행·258로 표시한 행(258·`rb_local_deleted` 1·번호, `usn`·`rb_local_synced` 그대로). 쓴 곡의 태그 초안은 지운다(반영한 값이 새 base). 되돌리면 백업의 `tag-drafts/`로 초안을 살린다.

| 칸 | 곡 행 칸 | 쓰기 | 근거 |
|---|---|---|---|
| 제목 | `Title` | 연다 | 실험 1·2, #173 S1 T01·S2 U11·U12, 사본 재현 |
| 아티스트 | `ArtistID` → `djmdArtist`, 곡의 앨범 행 저장(동명 앨범이면 새 앨범) | 연다(비우면 `''`) | 실험 1·2·3, #173 S1 T02·T03·T05·X1·S2 U03·U07·U13·S3 V01~V03·V05, 사본 재현 |
| 장르 | `GenreID` → `djmdGenre`(비우면 `'0'`) | 연다 | 실험 1·2, #173 S1 T06·T07·S2 U05·S3 V07, 사본 재현 |
| 작곡가 | `ComposerID` → `djmdArtist`(비우면 `''`) | 연다 | 실험 2, #173 S1 T08·S2 U06, 사본 재현 |
| 연도 | `ReleaseYear`(비우면 0) | 연다(발매일 보존) | 실험 2·3, #173 S1 T09·S3 V06, 사본 재현 |
| 트랙 번호 | `TrackNo`(비우면 0) | 연다 | 실험 2, #173 S1 T10, 사본 재현 |
| 코멘트 | `Commnt`(비우면 `''`) | 연다 | 실험 1·2·4, #173 S1 T16, 사본 재현 |
| 앨범 | `AlbumID` → `djmdAlbum`(비우면 `''`) | 조건부 | 새 앨범·같은 아티스트의 유일한 기존 앨범·비우기, 실험 2·3, #173 S1 T04·S2 U02·U04, 사본 재현 |
| 앨범 아티스트 | `djmdAlbum.AlbumArtistID` | 조건부 | 단독·유일한 이름의 앨범에서 넣기·바꾸기·비우기, 실험 2·3, #173 S2 U01·U14, 사본 재현 |

`RekordboxWriter.writableTagKeys`가 연 칸이고 `checkTags`가 위 조건을 거른다. 곡 상태 0·256·257은 같은 칸을 연다. 막힌 곡은 반영 미리 보기에 이유와 할 일이 함께 보인다. 전부 막힌 태그만 있으면 백업도 만들지 않는다.

**실험 3 사본 재현**: `djc lab tag-write-test`로 다섯 전후 사본 쌍에 10번 편집을 적용했다. 새 앨범(빈 아티스트·아티스트 있음), 기존 앨범 붙이기, 아티스트 비우기, 발매일 보존 연도 변경·0, 단독 앨범 아티스트 비우기의 곡·앨범 칸과 옛 이름 행 삭제 여부가 모두 일치했다. 난수 ID·UUID·시각·변경 번호 값은 제외하고 외래 키는 가리키는 이름으로 비교한다. 골든 테스트는 `RekordboxTagWriterTests`·`RekordboxTagAlbumTests`에 둔다.

### 동기화 상태(256·257)인 곡 (#171 실험 4, #173 S1·S2·S3)

**#173**(2026-10-04 rekordbox 7.2.18, 위 "#173 세션"): 동기화 곡의 정보 패널 아홉 칸, 상태 0 곡과 동기화 이름·앨범 행이 섞인 경우, 동명 앨범, 재생 목록 XML을 보았다.

공통 규칙 [확인]:
- 곡 행: 상태 0과 같은 칸 + `TrackInfoUpdated` +1 + `rb_data_status` 256 → 257(257·0은 그대로). 클라우드 `usn`·`rb_local_synced`·`rb_local_data_status`·`FileSize`는 그대로다(S1~S3 곡 행 78칸 비교).
- 이름·앨범 행은 곡 상태와 무관하게 **자기 상태로** 정해진다.
  - 저장되는 앨범 행(아티스트를 고친 곡의 앨범, 붙이는 기존 앨범, 제자리 앨범 아티스트): 256 → 257, 257·0은 그대로(S1 T02·T03·T05·X1, S2 U01·U02·U07·U14, S3 V01·V03·V05). 상태 0 곡이 동기화 앨범을 저장해도 257이다(S2 U07).
  - 새 이름·앨범 행은 상태 0이다(S1 T02·T04·T06·T08, S3 V02·V05).
  - 버려진 행: 상태 0은 지우고, 256은 **258 + `rb_local_deleted` 1**로 표시한다. 바뀌는 칸은 `rb_data_status`·`rb_local_deleted`·`rb_local_usn`·`updated_at` 넷뿐이고 `usn`·`rb_local_synced`·`created_at`은 그대로다(S1 T02·T04·T05, S2 U02~U05·U14, S3 V03). 257 행이 버려질 때는 보지 못했다[미확인].
  - 동기화 앨범이 버려졌는지는 살아 있는 곡의 참조로만 센다(S2 U01·U04·U14). 동기화 아티스트·장르에서 지운 곡·258 앨범이 가리킬 때는 보지 못했다[미확인](버려진 행은 모두 그런 참조가 없었다).
- 작곡가 비우기의 옛 행 258은 rekordbox가 다음 아티스트 저장 때 표시했다(S2 U06 → U07). 최종 상태는 같아 DJCrate는 같은 쓰기에서 258로 한다(결정).
- 대상 장르·아티스트 행에 붙일 때 그 행은 그대로다(S1 T07·S3 V07).

| 동작 | 곡 행 칸(빈 값) | 이름 행 | 앨범 행 | 근거 |
|---|---|---|---|---|
| 제목·연도·트랙 번호·코멘트(비우기 포함) | `Title`·`ReleaseYear`·`TrackNo`·`Commnt`(`''`) | — | — | S1 T01·T09·T10·T16, S3 V06 |
| 아티스트 새 이름·있는 이름·비우기 | `ArtistID`(`''`) | 새 0 / 버려지면 258 | 저장 → 257(AA NULL → `''`) | S1 T02·T03·T05·X1, S2 U03·U07, S3 V01·V03·V05 |
| 아티스트, 앨범 이름을 살아 있는 앨범 둘 이상이 씀 | `ArtistID` + `AlbumID` → 새 앨범 | — | 새 앨범(같은 이름, 옛 AA·NULL → `''`, 0), 옛 앨범은 저장하지 않고 버려지면 0 지움·256 258 | S3 V02·S2 U13 |
| 앨범 새 이름·기존 이름·비우기 | `AlbumID`(`''`) | — | 새 0(AA 이어받음) / 대상 → 257 / 옛 258 | S1 T04, S2 U02·U04 |
| 앨범 아티스트 넣기·비우기 | — | 옛 AA 버려지면 258 | 제자리 AA → 257 | S2 U01·U14 |
| 장르 새·있는·비우기 | `GenreID`(`'0'`) | 새 0 / 버려지면 258 | — | S1 T06·T07, S2 U05, S3 V07 |
| 작곡가 넣기·비우기 | `ComposerID`(`''`) | 새 0 / 버려지면 258 | — | S1 T08, S2 U06 |

**사본 재현**(#173, 2026-10-04): 세 기준점 사본의 클론에 각 세션의 저장을 한 번씩 `djc lab tag-write-test`로 쓰고(기준점의 `masterPlaylists6.xml`을 DB 옆에 둠) rekordbox 결과와 비교했다. 곡 행 78칸 `quote()`(외래 키는 기준점에 있던 행은 ID, 새 행은 이름으로), 이름·앨범·파일·재생 목록 행(ID·UUID·시각·변경 번호 값 대신 바뀌었는지만), 함께 번호를 받은 행의 순서, XML에서 Timestamp가 바뀐 NODE 집합을 비교했다. 세 세션 모두 아래 보류·예외 말고 차이 0이고, `djc lab db-diff`로 본 바뀐 표도 같았다. 동기화 아티스트·장르를 지운 곡·258 앨범까지 세도록 바꾼 뒤 다시 재현해도 같았다(rekordbox가 258로 만든 동기화 아티스트·장르는 모두 그런 참조가 없었다).
- 보류(다른 이슈의 경로): 별점·색·키(S1 T11~T13·S2 U10, #65·#5), 그림 넣기·바꾸기·지우기(S1 X2·X3, S2 U03의 그림·U08·U09, S3 V04, #66).
- 예외: S2 X4(같은 값 저장, DJCrate는 바뀐 칸이 없어 쓰지 않음)의 `TrackInfoUpdated`와 그 목록 XML, U13의 `TrackInfoUpdated`(rekordbox +2는 두 번 저장한 것으로 본다, DJCrate +1), 작곡가 258의 번호 위치(최종 상태 같음).

**DJCrate가 쓰는 것**: 곡 상태 256·257도 상태 0과 같은 칸을 쓰고 곡 행에 `rb_data_status` 256 → 257을 더한다. 저장하는 앨범 행에도 같은 `CASE`를 쓰고, 버려진 256 행은 258로 표시한다. 다시 읽어 곡·앨범·258 행의 상태도 비교한다. 같은 곡의 큐·그리드·게인을 함께 쓰면 그쪽이 먼저 257로 올리고, 태그는 마지막 번호를 받는다.

- 막는 것: 곡 상태가 0·256·257이 아닌 곡, 저장할 앨범이 0·256·257이 아닌 곡(NULL 포함), 버려질 행이 257이거나 그 밖의 상태인 곡, 동명 앨범인 곡의 아티스트 비우기, 동명 앨범 중 곡의 앨범이 가장 먼저 만든 행(만든 시각이 같으면 먼저로 본다)이면서 앨범 아티스트가 NULL이 아닌 곡(아래). 모두 백업 전에 막는다.
- 동명 앨범 막힘의 이유: "동명이면 늘 새 앨범"과 "가장 먼저 만든 같은 이름 행을 골라 앨범 아티스트를 비교해 같으면 다시 쓴다"는 두 가설이 이 곡에서만 다른 결과를 낸다(V02·U13은 둘 다 새 앨범). rekordbox 실험으로 가르기 전에는 열지 않는다.
- 골든 테스트: `RekordboxTagSyncedTests`(#171 첫 저장·다시 저장, #173 아홉 칸·코멘트 비우기·258·상태별 참조 범위·앨범 257·앨범 먼저·여러 초안의 확인·계산 검증·막힘), `RekordboxTagAlbumTests`(동명 앨범 V02·U13형·막힘), `RekordboxTagPlaylistXMLTests`(XML Timestamp·확인한 칸만·DB 옆 파일만·링크 막힘), `RekordboxRestoreFailureTests`(큐·BPM·게인과 함께, 커밋 뒤 상태·코멘트가 바뀌면 되돌림, XML을 적지 못하면 되돌림).

#### #171 실험 4 (코멘트)

2026-10-01 rekordbox 7.2.18, 실험 곡 "カクシタワタシ"(곡·앨범 상태 256, 빈 코멘트 `''`). 전·후·다시 저장 뒤 사본을 칸 단위로 비교했다.

- 첫 저장: 곡 행의 `Commnt`, `TrackInfoUpdated`(글자형 +1), `rb_data_status` 256 → 257, `rb_local_usn`, `updated_at`만 바뀌었다. 클라우드 `usn`·`rb_local_synced`·`rb_local_data_status`, 앨범 행(상태 256)과 다른 표는 그대로였다.
- 다시 저장: `rb_data_status`는 257 그대로, `TrackInfoUpdated` +1, `rb_local_usn`·`updated_at`. 큐·그리드·게인·재생 목록의 공통 규칙(256 → 257, 이미 257이면 그대로)과 같다.
- 변경 번호: 다시 저장 한 번에 `localUpdateCount`가 +2였고 곡 행은 마지막 번호를 받았다. 첫 구간은 같은 세션의 상태 0 곡 코멘트 저장과 함께 +3이라 저장별로 나눌 수 없다. DJCrate는 행마다 번호 하나를 쓴다(번호 값은 비교하지 않는다).
- 같은 세션에서 상태 0 곡의 코멘트도 저장됐다. 곡 행의 `Commnt`·`TrackInfoUpdated` +1·번호·시각만 바뀌어 위 상태 0 규칙과 같았다.

**사본 재현**: 전 사본의 복사본에 두 저장(상태 0 곡 → 실험 곡)을 `djc lab tag-write-test`로 같은 순서로 쓰고 후 사본과 `djc lab db-diff`로 비교했다. 후 사본의 복사본에 다시 저장도 같은 방법으로 비교했다. 두 번 모두 `rb_local_usn` 값과 `updated_at` 시각만 다르고 나머지 표·행·칸은 같았다.

**남겨 둔 조건**(#1): 공유 앨범 아티스트를 안전하게 미리 보여 주고 일괄 반영하는 흐름, 다른 아티스트를 가진 기존 앨범 붙이기, 동명 앨범으로 붙이기·그 앨범의 앨범 아티스트 고치기, 앨범·앨범 아티스트 동시 변경, 257 행 버리기, 동명 앨범 중 가장 먼저 만든 행에 앨범 아티스트가 있는 곡의 아티스트 저장, 동명 앨범인 곡의 아티스트 비우기. 추가 화면 실험과 사본 재현 전에는 열지 않는다. 별점·색·키(#65·#5)와 그림(#66)은 근거만 위 세션에 있고 각 이슈에서 연다.

## 시간축

- rekordbox는 압축 음원 앞 지연을 잘라 내지 않는다 → rekordbox 시각 = AVFoundation 시각 + 인코더 지연.
- AAC 2112샘플, LAME MP3 +51.2ms(576+529+1152), ffmpeg MP3 = 프라이밍+529, 태그 없는 MP3 529샘플, 무손실 0.
- 계산: `RekordboxTimeline.predictedOffset(url:)`. 덱·초안의 모든 시각은 rekordbox 시간축이다.

## 쓰기 절차 (`RekordboxWriter.write`)

1. rekordbox·rekordboxAgent가 실행 중이면 거부. `-wal`이 남아 있어도 거부.
2. master.db(+wal/shm) 전체와 바꿀 분석 파일을 `rekordbox-backups/<시각>-write/`에 복사(복사 중 원본이 바뀌면 실패).
3. `BEGIN IMMEDIATE` 한 트랜잭션에서 쓰고, 같은 연결로 다시 읽어 초안과 칸마다 비교. 비교 기준은 초안의 변경(`CueDraft.changes`, 1ms 미만 차이는 변경 아님)만 base에 반영한 큐 목록(`expectedCues(after:)`)이다. 그리드 따라가기로 1ms 미만 움직인 큐는 rekordbox 값 그대로 둔다(#73).
4. 커밋 뒤 다시 열어 한 번 더 검증 + `PRAGMA quick_check` + `cipher_integrity_check`. 커밋한 쓰기는 종류와 상관없이 모두 거친다(BPM만 바꾼 그리드·게인만 쓴 경우도 곡 BPM·카운터·파일 행, 오토게인 칸을 다시 읽는다, #135). 그 뒤 분석 파일·`masterPlaylists6.xml`을 쓴다(백업에 원본을 함께 둔다).
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
  USB에서는 로컬 태그를 마스크로 옮길 뿐 새로 만들지 않는다(`docs/usb-internals.md` §4).
- MP3 프레임 세기: LAME 정보 프레임(첫 프레임 안에 LAME 태그)은 소리로 세고, 다른 인코더(ffmpeg Lavc 등)의 정보 프레임은 세지 않는다. 인코더 칸이 `L3.99r1`인 정보 프레임도 LAME처럼 센다(2026-10-03 #14 곡 F: 큐 2개·PVBR 400칸·끝값·`PWV3` 길이가 세야 맞고, 빼면 PVBR 400칸이 모두 다르고 파형이 4칸 짧다). 시간축 보정(`predictedOffset`)은 이 인코더를 확인하지 않아 LAME 규칙을 붙이지 않았다. 다음 오디오 프레임에 "LAME3.99U"가 찍힌 ffmpeg 파일이 있어 LAME은 첫 프레임 안에서만 찾는다.
- VBR MP3 탐색표: 칸 k = 센 프레임 중 `floor((k+1)·n/400) − 8`번째 프레임의 바이트 위치(첫 센 프레임 기준, 음수면 0번째). 라이브러리 LAME VBR 451곡 400칸 전부 일치(CBR은 전부 0, 2291/2294곡). 8프레임 앞은 디코더 비트 저장소 몫으로 보인다.
- FLAC: 비트레이트 0, 비트는 STREAMINFO, `PVBR`은 탐색표·끝값 모두 0. 대신 `.EXT` 끝(`PWV4` 뒤)에 `PVB2`를 붙인다.
  머리 0x20(`u32 0` · `u64 전체 샘플` · `u32 400` · `u32 20`), 칸 400개 × 20바이트 = (`u64 프레임 시작 샘플` · `u64 첫 프레임 기준 바이트 위치` · `u32 블록 크기`).
  칸 k = 샘플 `k · floor(전체 샘플 / 400)`이 든 FLAC 프레임(나눗셈을 먼저 버리므로 뒤 칸일수록 조금 앞을 가리킨다). 라이브러리 1,083곡 중 1,081곡 바이트까지 일치(`djc lab pvb2-check`). 나머지 2곡은 2026-10-03 복제본 재분석으로 가렸다(#14).
  - 곡 E(44.1kHz/16비트): 새 분석은 DJCrate 계산과 400칸 같고 원래 곡의 저장값만 다르다. DB의 파일 크기도 지금 음원과 달라 분석 뒤 파일이 바뀐 것이다.
  - 곡 D(96kHz/24비트): 새 분석이 원래 곡 저장값과 바이트까지 같다. 가운데 프레임 하나가 14바이트 짧아 CRC-16이 맞지 않는데, rekordbox는 PVB2에서 **그 프레임을 빼고 이어서 번호를 매긴다**(칸의 시작 샘플 = 센 순서 × 블록 크기, 400칸 일치, 프레임 머리 번호를 따르면 374칸 다름). 전체 샘플은 STREAMINFO 값 그대로다.
  - 그런데 라이브러리의 다른 FLAC 1곡은 CRC-16이 맞지 않는 프레임이 12개인데도 저장 PVB2가 프레임 머리 번호 규칙과 같다(2026-10-03 `pvb2-check` 진단). 손상 모양에 따라 rekordbox 규칙이 갈린다. [추정] 곡 D는 프레임이 짧아 디코더가 다음 프레임 머리까지 먹어 한 프레임을 잃은 것으로 보인다. 어느 쪽인지 가릴 규칙을 확인하지 않았으므로 DJCrate는 CRC-16이 맞지 않는 프레임이 있으면 분석을 막는다(그 1곡도 막힌다, 규칙 확인은 #193).
  - 2026-10-03 실험 뒤 사본과 분석 파일 사본으로 다시 대조하면 어긋남은 곡 E 원래 곡 1곡이다. 막아서 비교에서 뺀 곡은 곡 D 원래 곡·복제본과 위 1곡이다.
- 막음: 미확인 ALAC 조건(16/24비트·44.1/48kHz·스테레오 밖), MPEG-1(32·44.1·48kHz)이 아닌 ffmpeg VBR(576샘플 프레임 미확인), 그 밖의 비LAME VBR(L3.99r1 포함), 프레임이 중간에 끊긴 MP3·FLAC(STREAMINFO 전체 샘플과 프레임 합이 다름), 마지막을 뺀 프레임 중 CRC-16이 맞지 않는 FLAC(마지막 프레임은 뒤에 붙은 태그와 끝을 가릴 수 없어 보지 않는다).

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

**DJCrate가 쓰는 것**(골든 테스트 `RekordboxAnalysisAttachTests`: 같은 음원·그리드·음량이면 곡 넣기 결과와 칸·바이트까지 같고, 변경 번호 순서는 위 실험을 따른다. 첫 BPM/Grid 카운터는 두 경로 모두 '1'·'1'):
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
- 곡 정보 저장: 그 곡이 든 살아 있는 목록의 Timestamp(부모 폴더는 그대로, #173, 위 "태그 (곡 정보)"). 제목·아티스트·장르만 확인했다. DJCrate는 재생 목록·합치기·곡 정보의 XML 변경을 한 쓰기에서 모아 한 번에 적는다.

**DJCrate가 쓰는 것**: `RekordboxWriter.write(playlists:)`가 편집(`PlaylistEdit`)을 적힌 순서대로 한 트랜잭션에서 쓴다. 번호를 받는 순서와 비우는 번호까지 위 표와 같게 한다. 만들기는 이름을 붙인 뒤 모양으로 한 번에 쓰고(XML Timestamp = 쓴 시각), 가운데 넣기는 넣은 뒤 옮기기(`moveTracks`)다. 막힌 편집은 그 편집만 되돌린다(번호도). 다 쓴 뒤 재생 목록 표 전체를 다시 읽어 계획과 같은지, 거울 행이 있는지 트랜잭션 안과 커밋 뒤에 본다. XML은 커밋·확인 뒤 적는다. 적지 못하면 DB·XML 모두 되돌린다. 백업에 XML을 함께 두어 되돌리기 때 같이 살린다. DB 옆에 XML이 없는 사본은 DB만 쓴다. 사본 시험은 `djc playlist-write --db <사본.db> <편집.json>`.

**앱의 재생 목록 초안**(#39·#40): 앱은 편집을 바로 쓰지 않고 `PlaylistDraft`(편집 순서 + 편집마다 기대는 rekordbox 목록의 처음 상태 `base`)로 쌓았다가 반영 때 `write(playlistDraft:)`로 넘긴다. 쓰기 모듈은 트랜잭션 안에서 쓰기 전 재생 목록 표를 `PlaylistLayout`으로 읽어 base와 비교하고, 달라진 목록에 기대는 편집은 "초안을 만든 뒤 rekordbox에서 이 목록이 바뀌었습니다"로 막는다(나머지는 위 규칙대로). 비교하는 것: 곡 넣기·빼기·옮기기·이름·옮기기는 그 목록의 이름·부모·곡 항목(TrackNo까지), 순서 바꾸기는 부모 안 순서도, 폴더 지우기는 그 아래 모든 목록과 자식 순서. 만들기·옮겨 넣을 폴더는 폴더가 있기만 하면 된다. 초안을 얹은 모양과 쓴 뒤 다시 읽은 모양이 같은지는 `RekordboxPlaylistWriterTests`의 초안 시험이 본다.

**초안 복구**(#179): 목록별로 기준·현재 상태·막힌 편집과 다시 적용한 결과를 비교한 뒤, 다시 적용하거나 막힌 편집만 버린다. 다시 적용할 수 있는 편집은 `PlaylistDraft.rebuilt`로 순서대로 쌓고 현재 상태를 새 기준으로 잡는다. 목록에 같은 곡이 여러 번 있어 대응이 모호하거나 목록·곡·부모가 사라지면 그 편집은 남긴다. 선택하지 않은 편집의 기준은 유지하며, 공유 기준이 있으면 선택한 편집에만 `Step.recoveryBase`를 저장한다(옛 초안의 이 칸은 없어도 된다). 선택 직전에 현재값을 다시 읽고 저장에 성공해야 메모리를 바꾼다. 복구는 초안만 바꾸며, 기존 쓰기 미리 보기·최종 확인·트랜잭션 안의 기준 검사는 그대로 거친다.

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

**현재 결론(2026-10-03 묶음 1): ALAC 16/24비트·44.1/48kHz 스테레오와 32·44.1·48kHz ffmpeg Xing(Lavc/Lavf) VBR은 분석 쓰기를 연다.** 44.1kHz는 #95 첫 BPM/Grid 카운터 사본 재현(2026-09-27), 32·48kHz는 아래 "묶음 1" 절의 128 BPM 클릭 실험과 사본 재현으로 확인했다. 아래 조사 2 당시에는 카운터가 달라 닫았으며, 후속 재현은 다음 절에 기록한다. `TrackAddPlan`은 ALAC을 코덱으로 판별해 `FileType=6`으로 넣는다.

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
- `Xing L3.99r1`은 같은 후보식에서 PVBR이 다르고 파형이 4칸 길었다. 2026-10-03(#14 곡 F)에 정보 프레임을 LAME처럼 세면 PVBR 400칸·끝값·파형 길이가 맞는 것을 확인했다(위 "MP3 프레임 세기"). 이 인코더의 분석 쓰기(비트레이트 0·시간축 보정·사본 재현)는 아직 확인하지 않아 막는다. 알 수 없는 인코더·Xing이 아닌 머리도 새 규칙으로 인정하지 않는다. 음원 누락은 일치와 구분해 제외했다.
- 읽기 전용 재현: `djc lab nonlame-vbr-check --db <스냅샷>`. 인코더·비트레이트 후보·PVBR 일치 여부·파형 길이 차이의 중복 없는 익명 수치만 출력하며 곡 이름·경로·곡 수는 출력하지 않는다.

**[확인] 사본 재현과 남은 불일치**:
- 시험용 후보 구현으로 사본에 7곡을 분석 포함 추가하고, 별도 분석 전 사본의 7곡에 분석을 붙였다. 각 경로가 분석 파일 21개를 만들었다. 음원 칸과 `PPTH·PVBR·빈 PCOB`는 일치했고, 같은 그리드를 넣어 만든 `.DAT`는 `PQTZ`까지 일치했다. 파형 길이는 맞지만 파형 값은 기존 근사이며 전체 파일 바이트 일치를 주장하지 않는다.
- 카운터는 rekordbox 자동 분석이 `AnalysisUpdated='1'·TrackInfoUpdated='1'`, 곡 추가 사본이 `'3'·'2'`, 분석 붙이기 사본이 `'2'·'1'`로 달랐다. 기존 공통 카운터 규칙은 바꾸지 않았고 **후보 쓰기 허용을 제거했다**. 골든 테스트는 두 쓰기 경로가 막히고 기존 행·분석 파일을 남겨 두는 것까지 확인한다.
- 48kHz VBR q5는 곡 행 `BPM=12000`인데 첫 정밀 그리드는 `119.96 BPM`이다. 정밀 그리드를 가져온 분석 붙이기 사본은 `BPM=11996`이므로 카운터 외에도 이 차이가 남는다. #95 후속 실험에서 행 BPM과 정밀 그리드 BPM을 함께 기록해야 한다.
- 골든 테스트: `AnalysisFormatGoldenTests`(실험 날짜·시험 제목 명시). 저장소에는 음원·DB·분석 파일 사본을 넣지 않으며, ALAC은 런타임 합성하고 MP3는 정보·음성 프레임을 칸 단위로 만든다. ALAC 큐의 MPEG·SeekInfo와 미확인 ALAC 비트 깊이·샘플레이트·채널 수는 이번 실험으로 열지 않는다.

### #95 후속 사본 재현 (2026-09-27)

- 보존된 #8·#9 가져오기 전/분석 전 사본에서 ALAC 4조건·44.1kHz ffmpeg VBR 2조건을 두 경로로 재현했다. `FileType·BPM·Length·BitRate·BitDepth·SampleRate·Analysed·ContentLink·AnalysisUpdated·TrackInfoUpdated`가 기준과 일치했다. 분석 붙이기의 나머지 곡 행도 신원·경로·변경 번호·시각을 제외하면 일치했다. 새 곡의 아티스트 ID는 새 난수이므로 동일 문자열을 기대하지 않는다.
- `PPTH·PVBR·빈 PCOB/PCO2·PVB2 유무`, 파일 행의 신원·경로·해시·크기·변경 번호·시각을 제외한 칸, 파형 태그 길이를 대조했다. PVBR 400칸과 끝값은 같다. 파형·게인·박 재생성의 기존 차이는 위 검증 범위대로 남기며, 해시와 크기는 각 생성 파일 자체를 다시 읽어 검증한다. `.3EX`는 만들지 않는다.
- 이때는 48kHz ffmpeg VBR을 막았다: q5 표본은 곡 행과 `PQTZ`에 12000을 기록했지만 정밀 박 간격으로 복원한 첫 구간은 119.96 BPM이었다. 다른 표본의 행/PQTZ는 ALAC 11995, ffmpeg 11997도 있어 정수 BPM 반올림을 공통 규칙으로 쓰면 틀린다. 아래 "묶음 1"에서 이것은 샘플레이트 규칙이 아니라 이 표본 소리(떨리는 사인파)에 대한 rekordbox 분석기 결과로 정리했다.
- `AnalysisFormatGoldenTests`는 ALAC 4조건과 32·44.1·48kHz ffmpeg의 두 쓰기 경로·글자형 '1'·'1', MPEG-2 샘플레이트 ffmpeg의 두 경로 차단과 행·파일 미생성을 검증한다(2026-10-03에 48kHz 차단 시험을 바꿨다). ALAC 큐의 MPEG·SeekInfo와 그 밖의 ALAC 형식은 이번에 열지 않는다.

### 묶음 1: 32·48kHz ffmpeg VBR·#14 재분석 (2026-10-03)

**[확인] 실험 조건**: rekordbox 7.2.18에서 자동 분석을 켜고 합성 곡을 넣었다. #9용은 128 BPM 클릭 96초를 ffmpeg 기본 libmp3lame VBR로 만든 "DJC VBR 32kHz 128BPM"·"DJC VBR 48kHz 128BPM"과 대조 "DJC VBR 44.1kHz 대조 128BPM"이다(첫 Xing 머리 `Lavc`). #14용은 어긋난 원래 곡 5개의 Finder 복제본이며 원래 곡은 다시 분석하지 않았다. 전후 사본과 분석 파일 실제 복사본을 비교했다.

| 시험 곡 | BitRate | SampleRate | Length | 곡 행·PQTZ BPM | 정밀 박 간격 | 첫 박(rekordbox / DJCrate 예측 지연) |
|---|---:|---:|---:|---:|---:|---:|
| 32kHz | 160 | 32000 | 96 | 12800 (205박) | 468.75000ms | 34.65 / 34.53ms |
| 44.1kHz 대조 | 256 | 44100 | 96 | 12800 (205박) | 468.74995ms | 24.74 / 25.06ms |
| 48kHz | 256 | 48000 | 96 | 12800 (205박) | 468.75000ms | 22.77 / 23.02ms |

- 음원의 클릭은 0ms부터 468.75ms 간격이다(ffmpeg 디코드로 확인). rekordbox 박은 세 샘플레이트 모두 `첫 박 + k × 468.75ms`라서 48·32kHz에서도 시간축이 늘거나 줄지 않는다. 첫 박과 예측 지연의 차이는 0.3ms 안으로 44.1kHz 대조와 같다.
- 곡 행 BPM·`PQTZ`·정밀 박 간격이 세 곡 모두 같은 값이다. 2026-09-27 48kHz q5 표본의 차이(12000 대 119.96)는 같은 소리로 만든 ALAC 48kHz(이미 엶)가 12000·119.9991로 맞으므로 샘플레이트 규칙이 아니라 그 소리(떨리는 사인파)에 대한 분석기 결과로 본다. DJCrate는 초안 그리드에서 곡 행 BPM과 `PQTZ`를 함께 만들므로 이 차이를 재현할 필요가 없다.
- DJCrate 계산(`djc lab analysis-repro`): 세 곡 모두 BitRate·SampleRate·BitDepth·Length, `.DAT` 머리·태그 순서, PPTH·PVBR(400칸·끝값)·PCOB 바이트, `PWV3`·`PWV5` 길이(32kHz 14408, 44.1·48kHz 14404)가 같다.
- 사본 재현(실험 전 사본, 임시 share): ① `djc track-add --analyze`(추정 그리드), ② 분석 없이 넣은 뒤 `djc lab analysis-attach-test --grid-from <rekordbox .DAT>`. 두 경로 모두 곡 행 78칸 중 신원(ID·UUID·MasterSongID·아티스트·앨범 ID)·분석 경로·변경 번호·시각 말고는 rekordbox와 같다(FileType·BPM 12800·Length·BitRate·BitDepth·SampleRate·`Analysed` 105·`ContentLink` 0x2C060E·`AnalysisUpdated` '1'·`TrackInfoUpdated` '1'). 파일 행은 `.3EX` 행이 없는 것과 신원·해시·크기·변경 번호·시각 말고 같고, 오토게인은 0.1dB 안이다. 분석 파일은 태그 순서·PPTH·PVBR·PCOB·PCO2·파형 길이가 같다. rekordbox 그리드를 넣은 ②에서 32·48kHz `PQTZ`는 바이트까지 같다(44.1kHz 대조본은 정밀 시각이 ms 경계에 붙은 51박이 1ms 다르다: 기존 44.1kHz와 같은 차이). ①은 32kHz의 박 번호(마디 위치)만 달랐다(강세 없는 클릭).
- 그래서 32·48kHz ffmpeg Xing VBR 분석 쓰기를 연다(`AnalysisFormatGoldenTests`). MPEG-2 샘플레이트(16·22.05·24kHz, 576샘플 프레임)는 실험하지 않아 막는다.

**[확인] #14 재분석**(원래 곡 표기는 #14 이슈와 같다):
- 곡 B·C(CBR MP3): 복제본의 새 분석은 DJCrate 계산과 PVBR·비트레이트가 같다. 원래 곡의 PVBR 미기록(0)·정보 프레임 포함은 옛 분석 상태다.
- 곡 D·E(FLAC): 위 "곡 추가"의 PVB2. 곡 E는 분석 뒤 파일이 바뀌었고, 곡 D는 CRC-16이 맞지 않는 프레임 때문에 rekordbox 규칙이 달라 DJCrate가 분석을 막는다.
- 곡 F(L3.99r1 VBR MP3): 위 "파일 형식별 탐색 위치"·"MP3 프레임 세기". 정보 프레임을 세도록 고쳤다.
- 다시 돌린 대조: `pvbr-check`·`pvb2-check`(새 분석 파일 사본) 어긋남 0, `seekinfo-check` FLAC·VBR 큐 어긋남 0. 라이브러리 FLAC 전체 `pvb2-check`는 위 "곡 추가" 참고.

## 막아 둔 것 (규칙 미확인)

- **미확인 ALAC·VBR 형식의 분석 쓰기**: ALAC 16/24비트·44.1/48kHz·스테레오 밖, MPEG-1(32·44.1·48kHz)이 아닌 ffmpeg VBR, L3.99r1·알 수 없는 비LAME VBR은 계속 막는다.
- **CRC-16이 맞지 않는 프레임이 있는 FLAC의 분석 쓰기**: rekordbox의 PVB2 규칙이 손상 모양에 따라 갈렸다(잘린 프레임 1곡은 빼고 이어 매김, CRC만 틀린 프레임 12개 1곡은 머리 번호, 위 "곡 추가", #14). 규칙 확인은 #193.
- **반쪽 분석 곡(.DAT만 있고 .EXT 없음)의 그리드·분석 붙이기**: rekordbox가 다시 분석한 모양은 한 곡 보았지만(위 "분석 붙이기") 사본 재현으로 확인하지 않았다.
- **카운터가 이미 있는 분석 전 곡에 분석 붙이기**: `AnalysisUpdated`·`TrackInfoUpdated`가 NULL인 곡만 확인했다.
- **태그의 공유 앨범 값 변경·동명 앨범으로 붙이기·앨범과 앨범 아티스트 동시 변경·257 행 버리기·동명 앨범 중 가장 먼저 만든 행에 앨범 아티스트가 있는 곡의 아티스트 저장·동명 앨범인 곡의 아티스트 비우기·0·256·257이 아닌 곡·앨범 상태·앨범·앨범 아티스트·작곡가·연도·트랙 번호·코멘트 저장의 XML Timestamp**: 위 "태그 (곡 정보)"의 조건표와 "동기화 상태(256·257)인 곡". 새 앨범·단독 앨범 아티스트·아티스트 비우기·발매일 보존 연도·동기화 상태 곡의 아홉 칸·동명 앨범인 곡의 새 앨범 옮기기는 연다(#173).

## 중복 곡 합치기 (#63)

`RekordboxWriter.write(merges:)`는 검증된 큐 쓰기·재생 목록 편집·곡 삭제를 하나의 트랜잭션으로 조합한다. 새 DB 칸의 쓰기 규칙은 추가하지 않는다. 합성 사본 시험은 `DuplicateMergeWriterTests`에 있으며, 큐·목록·삭제 도중 오류 시 전체 롤백과 DB·분석 파일·초안 복원을 확인한다. 실제 화면에서 합치기 전체를 확인하는 일은 별도다.

- `DuplicateMergeDraft`는 남길 곡·뺄 곡과 준비 당시의 상태 지문을 저장한다. 관련 곡·큐·파일·게인·이력 행, 관련 재생 목록 전체, 음원의 SHA-256이 바뀌면 쓰지 않는다. 여러 묶음은 트랜잭션 시작 상태에서 한꺼번에 검사한다.
- 큐는 새 곡의 시간축으로 `대상 offset − 원본 offset`만큼 옮긴다. 읽을 수 있는 PCM·FLAC·AAC·확인된 MP3 시간축만 허용하고, 실제 길이 차이가 20ms를 넘으면 막는다. 동일 음원 여부는 사용자가 확인한다. 오디오 지문으로 동일 음원임을 판정하는 기능은 없다.
- 이름·종류·ms 시각·루프 정보가 같은 큐만 하나로 합친다. 서로 다른 핫큐가 같은 슬롯을 쓰거나 활성 루프가 충돌하면 막고, 메모리 큐 한도·옮긴 큐의 범위를 검사한다. 뺄 곡의 자동 큐와 큐 색은 옮기지 않는다(남길 곡의 자동 큐는 그대로 남는다).
- 재생 목록에 남길 곡이 있으면 그 항목과 반복을 보존하고 뺄 곡의 항목을 제거한다. 없으면 첫 삭제 항목의 자리를 기억하고 **빼기 → 끝에 넣기 → 순서 바꾸기**로 옮긴다. 인텔리전트 목록은 막는다.
- 삭제는 `RekordboxTrackWriter.deleteRow`의 기존 규칙을 공유한다. `unverifiedReferenceTables` 중 하나에 참조가 있으면 해당 묶음을 막는다. 재생 기록·재생 횟수·평점·색·마이 태그·그리드·게인은 옮기지 않으며 확인 창에 알린다.
- 한 묶음의 큐·목록·삭제 중 하나가 막히면 그 묶음 전체를 되돌린다. 분석·그림 파일은 커밋 전에 백업하고, DB 검증 뒤 지우며, 파일 삭제 실패도 자동 복원한다. 파일 정리는 아래 UUID 경로 규칙을 따르고, 경로가 다르면 파일은 남기고 결과에 알린다. 음원은 읽기만 한다.
- 같은 곡의 다른 초안 또는 재생 목록 초안과는 동시에 반영하지 않는다. 기존 초안을 먼저 반영하거나 버린 뒤 합친다. 성공한 합치기 초안은 백업 옆에 남겨 ‘반영 되돌리기’ 때 다시 살린다.

## 곡 삭제·합치기·되돌리기의 파일 경계

`RekordboxWriter+FileOwnership`은 곡 UUID로 `PIONEER/USBANLZ/<앞 3자>/<나머지>/`와 `PIONEER/Artwork/<앞 3자>/<나머지>/`를 만들고 DB 경로의 부모 폴더가 정확히 같을 때만 파일을 정리한다. 전자는 `ANLZ0000.DAT`·`.EXT`·`.2EX`·`.3EX`, 후자는 `artwork.jpg`·`artwork_m.jpg`·`artwork_s.jpg`만 대상으로 삼는다. 심볼릭 링크, 음원으로 쓰는 경로, 다른 곡이 공유하는 폴더는 건드리지 않는다. 다른 파일이 섞여 있으면 남기고 곡 폴더가 비었을 때만 폴더도 지운다.

경로가 맞지 않아도 컬렉션에서는 빼되 결과에 ‘분석 파일을 지우지 않음(경로가 예상과 다름)’을 남긴다. 파일은 DB 커밋 전에 백업하고, 삭제 실패는 DB와 파일을 함께 복원한다. 백업 복원은 아래 규칙으로 DB를 바꾸기 전에 모든 파일을 검증한다.

- `anlz/manifest.json`과 보고서의 `createdFiles`·`removedFiles`는 `share` 기준 상대 경로(`PIONEER/USBANLZ/…`, `PIONEER/Artwork/…`)로 저장한다. 쓰기 API가 반환하는 보고서는 기존처럼 절대 경로다.
- 옛 절대 경로는 지정한 share 안에 있을 때만 받아들인다. 임시 폴더의 `/tmp`·`/private/tmp`(`/var`·`/private/var`)처럼 표기만 다른 같은 폴더는 비교 전에 한 표기로 맞춘다(`URL.comparablePath`, #136). `..`, 심볼릭 링크, 중복 대상, 허용하지 않은 파일명, 손상된 메타데이터와 없는 백업 원본은 복원을 거부한다. 복원할 DB의 UUID·경로와 같은 파일명 허용 목록도 확인한다.
- 앱의 되돌리기와 `djc rekordbox-restore`는 같은 검증을 쓴다. 사본 DB 옆에 share가 없다면 CLI에 `--share <폴더>`를 명시한다. 모든 검증을 통과한 뒤에만 복원 직전 백업을 만들고 DB·파일을 바꾼다.

회귀 시험(`RekordboxDeletionFilesTests`): 음원 폴더를 가리키는 분석 경로, 다른 UUID 폴더, 폴더·파일 심볼릭 링크, 다른 파일이 섞인 폴더, 옛 백업의 잘못된 복원·삭제 경로. 임시 폴더 사본의 네 표기(`RekordboxTempCopyPathTests`)도 같은 규칙으로 통과·거부하는지 본다. 모두 합성 파일과 DB 사본으로 확인하며 음원은 보존한다.

## 새 쓰기 경로를 여는 방법

1. 사용자에게 rekordbox에서 그 편집을 직접 해 달라고 한다(곡 이름 받기, 끝나면 rekordbox 종료).
2. 편집 전 스냅샷과 새 스냅샷(`djc snapshot --force`)을 `djc lab sql <사본> "…"`·`djc lab db-diff`로 비교: 바뀐 테이블·칸·usn 순서. rekordbox가 조작마다 바로 쓰는 표면 켜 둔 채 단계마다 떠서 비교할 수 있다(`djc lab playlist-watch --out <폴더>`, 읽기 전용 복사만).
3. 실험 전 사본에 DJCrate로 같은 편집을 써서 칸마다 비교(예: `djc lab loop-repro --old … --new … --ids … --work <폴더>`).
4. 일치하면 `Tests/RekordboxKitTests`에 골든 테스트를 먼저 쓰고, 막아 둔 조건을 풀고, 이 문서에 규칙을 적는다.
