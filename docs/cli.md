# djc 읽기·초안 명령과 JSON

`search`, `track`, `duplicates`, `playlists`, `playlist`, `histories`, `history`, `drafts`는 기존 최신 `LibrarySnapshot`을 읽는다. 스냅샷이 없으면 오류이며 라이브 DB로 대체하거나 자동으로 스냅샷을 만들지 않는다. 먼저 `djc snapshot`을 실행하거나 `--db <사본.db>`를 준다. 실제 라이브 `master.db` 경로와 그 심볼릭 링크·하드 링크는 거부한다. 읽기 명령은 초안·DB·음원을 변경하지 않는다.

에이전트(Claude Code·Codex)에게 이 명령으로 조회·제안하고 사용자가 고른 것만 초안으로 만들게 하는 스킬은 `skills/djcrate/SKILL.md`다(`.claude/skills/djcrate`·`.agents/skills/djcrate`는 그 폴더의 링크). 명령·JSON 계약을 바꾸면 스킬도 함께 고친다. AI 연동에는 CLI와 스킬을 사용하며 MCP 서버·별도 플러그인은 설치하지 않아도 된다.

`--db`는 이 문서의 DB 읽기 명령에서 쓸 수 있다. 이때 그리드 파일은 사본 DB 옆 `share/PIONEER/USBANLZ`에서 읽으며, 없는 경우 라이브 분석 파일로 대체하지 않는다. 기본 스냅샷은 `DJC_REKORDBOX_DIR` 또는 기본 rekordbox 폴더의 `share`에서 분석 파일을 읽는다. 초안은 `DJC_HOME` 또는 기본 DJCrate 데이터 폴더에서 읽는다. `DJC_DB`는 이 CLI 조회·초안 명령의 DB 선택에 쓰이지 않으므로 사본은 `--db`로 지정한다. 시험할 때는 `--db`와 별개로 임시 `DJC_HOME`과 합성 또는 사본 폴더인 `DJC_REKORDBOX_DIR`을 함께 지정한다.

사람이 읽는 문구는 macOS 언어 설정(`Locale.preferredLanguages`)을 따르며 `DJC_LANG=ko|en|ja`로 우선 지정할 수 있다(예: `DJC_LANG=en djc search '시험' --json`, 지원하지 않는 언어는 영어). JSON의 `code`·칸 이름·데이터는 그대로 두고 오류 `message`만 번역한다.

PATH로 옮길 때는 `djc`와 같은 빌드 폴더의 `DJCrate_djc.bundle`도 실행 파일 옆에 둔다(기존 실행 의존성 `SQLCipher.framework`도 함께 유지). 번역 번들이 없으면 한국어 원문으로 실행한다. 개발자용 `djc lab …`은 한국어를 유지한다.

## 사용법

아래 ID·이름·경로는 모두 합성 데이터 예시다.

```sh
djc search '시험' --bpm 120-130 --key 8A --playlist p1 --filter all --db /tmp/djc-fixture/master.db --json
djc track 101 --db /tmp/djc-fixture/master.db --json
djc duplicates --db /tmp/djc-fixture/master.db --json
djc playlists --tree --db /tmp/djc-fixture/master.db --json
djc playlist p1 --db /tmp/djc-fixture/master.db --json
djc histories --db /tmp/djc-fixture/master.db --json
djc history h1 --db /tmp/djc-fixture/master.db --json
djc drafts --db /tmp/djc-fixture/master.db --json
djc report --db /tmp/djc-fixture/master.db --files --json
djc path '시험' --db /tmp/djc-fixture/master.db --json
djc parse 'TVA 시험 OP 1' --json
djc compat --db /tmp/djc-fixture/master.db --json
```

`--json`을 빼면 사람이 읽는 출력이다. 기존 `report`, `path`, `parse`, `compat`의 일반 출력은 유지한다. 분석·파일 생성·실험·쓰기 명령(`analyze`, `snapshot`, `schema-dump`, `lab`, `reflection-dry-run`, `cue-write`, `track-add`, `track-delete`, `playlist-write`, `rekordbox-restore`)은 이 JSON 계약에 포함하지 않는다.

검색은 제목·아티스트·코멘트·장르에 대한 대소문자 무시 부분 검색이다. 빈 검색어 `''`는 전체이며 삭제된 곡은 항상 제외한다. BPM은 양 끝을 포함하는 양수 범위, 키는 대소문자를 무시한 정확한 일치이고 조건은 모두 함께 적용한다. 암호화된 Spotify 제목·아티스트는 검색 대상에서 제외한다. `path`는 기존과 같이 제목의 대소문자를 구분하고 로컬 곡만 찾는다.

`search`·`report`는 `--comment-preset none|anisong`을 받으며 기본값은 `none`이다. `off-convention`은 `--comment-preset anisong`이 있어야 하고, 없으면 `invalid_arguments`로 거절한다. `report`의 `commentClasses`·`prefixes`·`usages`는 이 프리셋을 지정할 때만 나온다. `parse`는 프리셋 옵션 없이 애니송 코멘트 규칙을 검사한다.

`--filter`는 다음 이름 중 하나다. 앱과 동일한 판정을 사용하며 생략하면 `all`이다.

| 이름 | 조건 |
|---|---|
| `all` | 전체 컬렉션 |
| `empty-comment` | 빈 코멘트 |
| `off-convention` | 규칙 밖 코멘트(구형·잔재·크레딧·기타) |
| `no-cues` | 자동 큐를 포함해 큐가 하나도 없음 |
| `played` | 재생 이력 있음 |
| `streaming` | 스트리밍 곡 |
| `no-bpm` | BPM이 없는 로컬 곡 |
| `tempo-change` | 읽은 그리드에 변속 흐름 있음(분석 파일을 읽지 못하면 제외) |

일반 재생 목록은 원래 곡 순서와 중복을 보존한다. 폴더를 `playlist` 또는 검색의 `--playlist`에 주면 하위 목록을 순서대로 합치고 같은 곡은 첫 등장만 남긴다. 삭제되거나 없는 곡 ID는 제외한다. 목록·폴더는 `sequence`, 같은 순번이면 ID 순서이고 검색 결과는 문자열 ID 순서다.

### 중복 후보

`duplicates`와 앱 사이드바의 **중복 후보**는 스냅샷의 제목·아티스트·길이만 비교한다. 음원을 열거나 음향 지문을 계산하지 않으며 같은 녹음임을 보장하지 않는다. 합치기·큐 이동·재생 목록 변경·곡 삭제는 지원하지 않는다.

- 제목·아티스트는 NFC, 소문자, 앞뒤 공백 제거·연속 공백 한 칸으로 정규화한다. 괄호 속 버전(예: Live·Remix), 악센트, 문장부호, 전각·반각 차이는 보존한다.
- 제목·아티스트가 모두 있고 길이가 양수인 로컬 곡만 비교한다. 삭제·스트리밍·암호화 제목은 제외한다. 파일 형식·경로가 달라도 후보이며, 같은 경로의 서로 다른 ContentID도 후보가 될 수 있다.
- 묶음 안 최장·최단 길이 차이는 **2초 이내**다. 부분 묶음은 생략한다. 합성 예 180·182·184초는 `[180, 182]`, `[182, 184]`로 겹쳐 표시해 모든 후보 쌍을 보존한다. 한 곡이 여러 묶음에 나올 수 있다.
- 곡은 길이·문자열 ID 순서, 묶음은 첫 곡 ID 순서다. 메타데이터별로 나눈 뒤 정렬·구간 탐색하며 앱에서는 스냅샷 로드의 백그라운드 작업에서 계산한다.
- 비교 수치는 초안을 적용하지 않은 스냅샷 기준이다. 큐 수는 자동 큐를 포함하며 수동 큐 수도 별도로 제공한다. 재생 목록 수는 직접 포함된 목록만 세고 같은 목록의 반복 항목·상위 폴더는 중복 집계하지 않는다. 재생 횟수는 삭제되지 않은 재생 기록 수다.
- 앱은 묶음별로 큐·재생 목록·재생 횟수·형식·비트레이트·길이·경로를 보여 준다. 검색은 일치하는 곡의 비교 상대까지 남긴다. 곡을 한 번 누르면 고르기만 하고, 더블클릭·Return·오른쪽 클릭 "덱에 불러오기"로 덱에 올린다. 비트레이트가 없거나 0 이하면 `알 수 없음`으로 표시한다.

## JSON v1

성공 시 stdout에 JSON 문서 하나와 줄바꿈만 출력하고 종료 코드는 0이다.

```json
{"schemaVersion":1,"command":"search","data":{"tracks":[]}}
```

실패 시 stdout은 비우고 stderr에 JSON 문서 하나를 출력하며 종료 코드는 1이다.

```json
{"schemaVersion":1,"command":"track","error":{"code":"not_found","message":"곡을 찾지 못했습니다. search로 ContentID를 확인하세요"}}
```

오류 코드는 `invalid_arguments`(인자), `not_found`(곡·재생 목록 ID), `live_database`(라이브 DB), `read_failed`(그 밖의 읽기·호환성 오류)다. JSON 키는 영문이고 ID·UUID는 문자열이다. 선택 값이 없으면 키를 생략하며 빈 목록은 `[]`다. 필드 추가에 대비해 소비자는 모르는 키를 무시한다. 의미나 타입이 달라지는 변경은 `schemaVersion`을 올린다.

| 명령 | `data` |
|---|---|
| `search` | `{tracks: Track[]}` |
| `duplicates` | `{lengthToleranceSeconds: 2, groups: [{id: string, tracks: DuplicateMember[]}]}` |
| `track` | `{track: Track, cues: Cue[], grid: Grid, gain?: Gain, playlists: Playlist[], drafts: DraftState}` |
| `playlists` | `{playlists: Playlist[]}`; `--tree`면 루트부터 `children`으로 중첩 |
| `playlist` | `{playlist: Playlist, tracks: Track[]}` |
| `drafts` | `{drafts: Draft[]}`; UUID 순서, 컬렉션에 없는 초안도 포함 |
| `histories` | `{histories: History[]}` |
| `history` | `{history: History, entries: HistoryEntry[]}` |
| `report` | 아래 집계 필드 |
| `path` | `{paths: string[]}` |
| `parse` | `{classification: string, parsed?: ParsedComment}` |
| `compat` | `{appVersion?: string, verifiedAppVersions: string[], databaseVersion: string, localUpdateCount?: number, cloudUpdateCount?: number}` |
| `usb-info` | `UsbInfo`(아래 "USB 읽기") |

- `DuplicateMember`: `track`(Track), 정수 `cueCount`, `manualCueCount`, `playlistCount`, `playCount`, 문자열 `format`, 선택 정수 `bitrateKbps`(양수 kbps). 비트레이트를 모르면 키를 생략한다. 묶음 `id`는 첫 곡의 ContentID다.
- `Track`: `id`, `uuid`, `title`, `lengthSeconds`, `path`, `comment`, `isStreaming`; 선택 필드 `artist`, `album`, `albumArtist`, `genre`, `composer`, `releaseYear`, `trackNumber`, `key`, `bpm`, `importedOn`. 연도·트랙 번호·길이·BPM은 숫자이고 `importedOn`은 `YYYY-MM-DD`다. 값은 사본 DB 기준이며 초안으로 덮어쓰지 않는다.
- `Cue`: `id`, `kind`(0 메모리, 그 밖은 rekordbox 슬롯 값), `inMsec`, `outMsec`, `name`, `isLoop`, `activeLoop`, `isAutoGenerated`; 선택 필드 `hotCueSlot`(A~H), `loopBeats`, `color`, `colorTableIndex`. 시각은 rekordbox 시간축의 밀리초다. `outMsec`는 원본 값이며 루프 판정은 `isLoop`를 쓴다. 시작 시각·ID 순서다.
- `Grid`: `status`(`available` 또는 `unavailable`), `beatCount`, `segments`, `tempoChanges`. 각 구간은 `{start: number, bpm: number, firstBeatNumber: number}`이며 `start`는 rekordbox 시간축의 초다. 분석 경로·파일·유효한 박이 없으면 `unavailable`, 개수 0, 빈 배열을 반환한다.
- `Gain`: `linear`, `decibels`, 선택 `peak`(선형 피크). 유효한 게인 행이 없으면 `gain`을 생략한다.
- `Playlist`: `id`, `name`, `parentID`, `sequence`, `isFolder`, `trackCount`; `--tree`의 폴더에만 `children` 배열이 있다. `trackCount`는 조회 가능한 곡 수이며 폴더는 중복을 제거한 수다. 곡 상세의 소속은 직접 포함된 재생 목록만 담는다.
- `History`: `id`, `name`, `trackCount`; 선택 문자열 `dateCreated`. `histories`는 날짜순이며 `trackCount`는 반복 재생을 포함한 조회 가능한 항목 수다.
- `HistoryEntry`: `id`, 정수 `trackNumber`, `track`(Track). 같은 곡을 여러 번 재생한 항목은 그대로 남긴다.
- `DraftState`: `cue`, `grid`, `gain`, `tag` 불리언 네 개다.
- `Draft`: `trackUUID`, `kinds`(`cue`, `grid`, `gain`, `tag` 순서), 선택 `contentID`, `title`. 컬렉션에 없으면 마지막 두 필드를 생략한다. 큐·그리드·태그는 읽을 수 있고 실제 변경이 있는 초안만, 게인은 저장된 값이 있는 초안만 센다. 손상된 초안의 진단·반영 가능 여부 판정은 하지 않는다.
- `report`: 정수 `totalRows`, `deletedRows`, `liveTracks`, `streamingTracks`, `tracksWithCues`, `tracksWithManualCues`, `tracksWithOnlyAutoCues`, `tracksWithoutCues`, `playedTracks`, `emptyCommentPlayed`; 문자열→정수 사전 `extensions`, `emptyByImportYear`, `hotCueSlots`; `--comment-preset anisong`일 때만 `commentClasses`, `prefixes`, `usages`. `--files`를 주면 정수 `missingFiles`를 더한다.
- `ParsedComment`: `prefix`, `workRef`, `workName`, `abbreviations`, `usages`(`{kind, numbers}` 배열), `episodes`, `isCharacterSong`, `isTVSize`, `variants`, `isFormerAffiliation`, `boomboxVolumes`; 선택 `season`, `seasonStyle`(`parenthesized`, `plain`, `season`), `airingYear`, `airingQuarter`, `movieYear`. `classification`은 `convention`, `legacy`, `residue`, `credit`, `empty`, `other` 중 하나다.

`compat` 성공은 기존 앱 버전·DB 구조·카운터 검사 통과를 뜻한다. rekordbox 실행 여부 등 실제 쓰기 사전 확인을 대체하지 않는다.

## 큐·태그 초안 만들기

`djc draft`는 위와 같은 `LibraryRead` 스냅샷 경로를 쓰며 라이브 DB를 거절한다. DB·분석 파일·음원에는 쓰지 않고 `DJC_HOME`의 `cue-drafts/`·`tag-drafts/`에 앱과 같은 JSON을 저장한다. 처음 만들 때 스냅샷의 rekordbox 값을 `base`에 담고, 기존 초안을 이어 고칠 때는 그 `base`와 다른 편집을 보존한다. rekordbox 반영은 앱에서 사람이 별도로 실행한다.

```sh
# 시험할 때는 반드시 임시 DJC_HOME을 쓴다.
export DJC_HOME="$(mktemp -d)"
djc draft cue 101 --time 12.5 --name '진입' --db /tmp/djc-fixture/master.db --dry-run --json
djc draft cue 101 --slot B --time 16 --loop-end 20 --beats 8 --active --db /tmp/djc-fixture/master.db
djc draft tag 101 --title '합성 제목' --artist '합성 가수' --comment '' --db /tmp/djc-fixture/master.db --json
djc draft rm cue 101 --db /tmp/djc-fixture/master.db --dry-run --json
djc draft rm tag 101 --db /tmp/djc-fixture/master.db
```

- `draft cue <ContentID> --time <초>`: 기본은 메모리 큐다. `--slot A`~`H`를 주면 해당 핫큐를 놓거나 교체한다. `--name`은 이름이다. 시각은 **rekordbox 시간축의 초**이며 자동 퀀타이즈하지 않는다.
- `--loop-end <초>`는 시작보다 뒤인 루프 끝이다. 선택 `--beats <박 수>`는 양의 정수 또는 1/n, `--active`는 활성 루프 지정이다. 두 옵션은 `--loop-end`와 함께 쓴다. 활성 루프는 곡에 하나만 남는다.
- 메모리 큐는 자동 큐를 포함해 10개까지다. 같은 자리 ±30ms의 기존 메모리 큐는 앱처럼 그대로 사용한다(루프 추가 시에는 기존 루프만 해당). 새 이름이나 루프 길이로 그 큐를 덮어쓰지는 않는다.
- `draft tag <ContentID>`: `--title`, `--artist`, `--album`, `--album-artist`, `--genre`, `--composer`, `--year`, `--track-number`, `--comment` 중 하나 이상을 준다. 빈 문자열은 해당 값을 비우며, 빈 제목·숫자가 아닌 연도/트랙 번호는 거절한다.
- `draft rm cue|tag <ContentID>`는 해당 종류의 **초안 전체**를 버린다. 개별 큐나 rekordbox 원본을 지우지 않는다. 이미 없는 초안을 지우는 것은 성공이다. 그리드·게인 초안은 그대로 둔다.
- `--dry-run`은 같은 검증을 거쳐 결과를 보여 주고 폴더·파일을 만들거나 지우지 않는다. 기존 초안이 손상되었으면 덮어쓰지 않고 오류를 낸다.

앱은 실행 중 약 1초마다 큐·태그 초안 파일 변경을 확인한다. 목록의 편집 표시·큐 개수·태그 편집기와 현재 덱의 큐를 갱신하며 재생 위치를 유지한다. 큐·그리드를 드래그하는 동안에는 저장 후에 다시 읽는다. 태그가 외부에서 바뀌면 오래된 되돌리기 기록은 비운다. 태그 초안은 태그 편집기와 쓰기를 기다리는 초안 목록에 표시된다. 앱에서 사람이 큐·그리드·게인·태그와 재생 목록 초안을 미리 보고 rekordbox에 쓸 수 있다. 태그는 rekordbox 곡 정보에만 쓰고 음원 파일의 태그는 바꾸지 않는다. 같은 곡을 앱과 CLI에서 동시에 편집하면 마지막 저장이 앞선 저장을 덮을 수 있으므로 편집을 마친 뒤 다음 명령을 실행한다.

`--json`은 위 JSON v1 성공/오류 출력 규칙을 따른다. `command`는 `draft`, `data`는 `{kind: "cue"|"tag", action: "save"|"remove", contentID, trackUUID, dryRun, hasChanges, cue?, tag?}`다. 저장·미리보기의 `cue` 또는 `tag`에는 앱 파일과 같은 초안 전체(`base` 포함)가 담긴다. `hasChanges`는 명령 적용 후 남을 초안의 변경 여부이며 삭제는 `false`다. 원본으로 되돌아간 초안은 저장소에서 제거된다.

추가 오류 코드는 `invalid_draft`(기존 초안 손상·큐 한도), `draft_io_failed`(초안 저장·삭제 실패)다. 기존 `invalid_arguments`, `not_found`, `live_database`, `read_failed`도 사용한다. 실패 시 종료 코드 1이며 JSON은 stderr에만 나온다.

앱은 재생 목록 초안을 지원하지만 `djc draft`의 대상은 큐·태그뿐이다. `playlist-write`는 JSON 편집을 DB에 쓰는 명령이며 DJCrate 재생 목록 초안 생성 명령이 아니다. 에이전트 스킬에서는 실행하지 않고 사람이 앱에서 재생 목록 초안을 만들도록 안내한다.

## USB 내보내기(`usb-export`)

```sh
djc usb-export --volume <마운트> [--db <스냅샷 사본.db>] [--share <폴더>] [--playlist <ID>]… [--tracks <ContentID>,…]
               [--formats onelibrary,device] [--naming identifier] [--dry-run] [--confirm <볼륨 이름>]
               [--allow-provisional <규칙,…>] [--verify-audio] [--settings <로컬 설정 폴더>] [--snapshot-time <ISO 8601>]

# 디스크 이미지에 시험(임시 폴더 아래만, rekordbox는 꺼 둔다)
export DJC_HOME=$(mktemp -d)
djc lab usb-image create $DJC_HOME/e.img --size 4g --name DJCTEST
mkdir -p $DJC_HOME/mnt && djc lab usb-image attach $DJC_HOME/e.img --mount $DJC_HOME/mnt
djc usb-export --volume $DJC_HOME/mnt --db <스냅샷 사본.db> --playlist <ID> --dry-run
djc usb-export --volume $DJC_HOME/mnt --db <스냅샷 사본.db> --playlist <ID>
djc usb-info $DJC_HOME/mnt
djc lab usb-image detach $DJC_HOME/e.img
```

로컬 스냅샷 사본의 곡·재생 목록을 **빈 FAT32·MBR USB**에 OneLibrary(`exportLibrary.db`)와 Device Library(`export.pdb`·`exportExt.pdb`)로 내보낸다. 음원·분석 파일·아트워크를 함께 쓰고, 쓰기는 `UsbWriter.write` 한 곳으로 한다(백업 → 파일 → DB 교체 → 검증, 실패하면 쓰기 전으로 되돌림). 흐름과 규칙은 `docs/usb-internals.md` §7.12.

- **실물 USB는 막혀 있다**(`physicalDisabled`). `--confirm`·`--allow-provisional`을 줘도 풀리지 않는다. 지금은 임시 폴더 아래에 붙인 디스크 이미지에만 쓴다.
- `--db`를 빼면 가장 최근 스냅샷(읽기만 한다. 새로 뜨거나 정리하지 않는다). 라이브 master.db는 열지 않고 거부한다(`liveDatabase`). 명령은 받은 사본을 세션 전용 폴더(`usb-snapshots/local-<세션>/`)에 한 번 더 떠서 읽고 끝나면 지운다. `--share`를 빼면 rekordbox 폴더의 `share`(읽기만).
- `--playlist`는 여러 번 줄 수 있고 폴더면 그 안까지 간다. `--tracks`는 ContentID를 쉼표로. 둘 다 주면 목록 곡 다음에 곡을 더한다.
- `--snapshot-time`: 사본을 뜬 시각(시간대를 넣은 ISO 8601). 빼면 사본 이름(`master-YYYY-MM-DDTHHMMSS.db`, UTC) → 파일 수정 시각 순으로 푼다. 이 시각 뒤에 로컬 분석 파일이 바뀐 곡은 `analysisNewerThanSnapshot`으로 막는다. 요약 첫 줄에 어디서 풀었는지(`explicit`·`fileName`·`modificationDate`)를 적는다.
- `--formats`: 기본 둘 다. `onelibrary`·`device` 중 하나만 줄 수 있다. `--naming`은 지금 `identifier`(DJCrate 고유 이름)만 있다.
- `--dry-run`: 계획·준비·쓰기 전 확인까지 하고 USB에 쓰지 않는다(저널을 `dryRun`으로 닫는다). 같은 명령을 `--dry-run` 없이 다시 부르면 막히지 않고 쓴다. 명령은 늘 지금 USB를 다시 읽어 새로 계획한다.
- `--allow-provisional <규칙,…>`: 확인 안 된 규칙(요약의 "확인 안 된 규칙" 이름)을 실물에서 풀 때 쓴다. `physicalVolume`은 받지 않는다(`gateOnlyRule`). 디스크 이미지는 확인 안 된 규칙으로 막지 않는다.
- `--settings <로컬 설정 폴더>`: 로컬 rekordbox 설정 폴더의 `MYSETTING.DAT`·`MYSETTING2.DAT`·`DJMMYSETTING.DAT`를 내보내기 모양으로 `PIONEER/`에 옮긴다(확인 안 된 규칙 `settingFiles`). 빼면 설정 파일을 만들지 않는다. `DEVSETTING.DAT`·`djprofile.nxs`는 만들지 않는다.
- `--verify-audio`: 음원도 쓴 뒤 USB에서 다시 읽어 해시를 본다.
- 막힘: 곡 단위 막힘(`audioSizeMismatch`·`analysisNewerThanSnapshot`·`trackRowTooLarge`·`nameTooLongForDeviceLibrary`·`fileTypeMismatchForDeviceLibrary`·`isrcNotASCIIForDeviceLibrary`·`valueOutOfRangeForDeviceLibrary` 등)은 그 곡만 빼고 쓴다. 볼륨 단위 막힘이 하나라도 있으면 쓰지 않는다: `localVersionUnverified`(이 Mac의 rekordbox가 확인한 버전이 아님), `libraryExists`(이미 rekordbox 라이브러리가 있는 USB — USB 수정으로), `leftoverPioneer`(`PIONEER/` 바로 아래에 다른 것이 남음), `myTagNameTooLongForDeviceLibrary`, `noTracks`, 볼륨 정책(FAT32·MBR 등), 보호 폴더(`protectedPath`), 실물 관문(`physicalDisabled`·`denied`), `insufficientSpace`, 쓰기 절차의 막힘(`rekordboxRunning`·`recoveryNeeded`·`destinationExists` 등). 볼륨 정책·보호 폴더·실물 관문에 막힌 볼륨은 이름도 열거하지 않는다.
- `Contents/`에 사용자가 넣어 둔 음원이 있으면 덮어쓰지 않는다: 같은 이름·같은 내용이면 그 파일을 가리키고(쓰지 않음), 내용이 다르면 ` (2)`처럼 번호를 붙인다.
- 출력: 진행은 표준 오류에 단계마다 한 줄, 요약은 표준 출력(스냅샷 시각 → 곡·재생 목록·막힌 곡 수 → 막힘 code별 수와 ContentID → 확인 안 된 규칙별 곡 수 → 경고 code별 수 → 필요 공간 → 결과·백업 폴더·파일 수). 곡 제목·USB 경로는 찍지 않는다. 쓴 뒤에는 "USB를 꺼낸 뒤 뽑으세요(Finder 또는 `diskutil eject`)"로 끝난다.
- 종료 코드는 성공 0, 막힘·실패 1이다. JSON 계약에는 포함하지 않는다.

## USB 수정(`usb-edit`)

```sh
djc usb-edit --volume <마운트> (<편집.json> | --draft) [--db <스냅샷 사본.db>] [--share <폴더>] [--dry-run]
             [--confirm <볼륨 이름>] [--allow-provisional <규칙,…>] [--snapshot-time <ISO 8601>]
```

이미 라이브러리가 있는 USB(DJCrate가 만든 것·rekordbox가 만든 것)에 곡 더하기·빼기·갱신과 재생 목록 편집을 한 번에 쓴다. OneLibrary는 USB DB 사본에 편집마다 SQL로 고치고, Device Library는 고친 모델에서 새로 만든다. 쓰기는 `UsbWriter.write` 한 곳이다(백업 → 파일 → DB 교체 → 지우기 → 검증, 실패하면 쓰기 전으로 되돌림). 규칙은 `docs/usb-internals.md` §8.3.

- **실물 USB는 막혀 있다**(`physicalDisabled`). 지금은 임시 폴더 아래에 붙인 디스크 이미지에만 쓴다. `--allow-provisional physicalVolume`은 받지 않는다(`gateOnlyRule`).
- `<편집.json>`: 편집 배열. 적힌 순서대로 앞 편집을 적용한 결과 위에 다음 편집을 계획한다. `--draft`는 이 볼륨에 쌓인 초안(`usb-drafts/<볼륨 UUID>.json`)을 쓴다. 초안을 만든 뒤 USB가 바뀌었으면 지금 USB 상태로 다시 계획한다("USB가 그 사이 바뀌어 다시 계획했습니다"). 쓴 뒤(또는 쓸 것이 없을 때) 초안에는 막힌 편집만 남기고(새 base는 그때 USB DB 지문 — 새 스냅샷 등으로 풀리면 다시 `--draft`로 쓴다), 막힌 편집이 없으면 초안을 지운다. `--dry-run`은 초안을 건드리지 않는다.
- `--db`: 로컬 스냅샷 사본. 곡 더하기·갱신(로컬을 읽는 편집)에 필요하다. 받은 사본은 곡 더하기·갱신이 있을 때만 세션 전용 폴더(`usb-snapshots/local-<세션>/`)에 한 번 더 떠서 읽고 끝나면 지운다. 곡 빼기에서 음원을 지워도 되는지(로컬 원본과 같은지)는 곡 더하기·갱신과 함께 쓰는 묶음에서만 본다 — 곡 빼기·목록 편집만 있으면 `--db`를 주어도 로컬 사본을 뜨지 않아 음원은 USB에 남기고 알린다(분석 파일·그림은 지운다). `--db`를 빼면 곡 더하기·갱신이 있을 때만 가장 최근 스냅샷을 읽기만 한다(곡 빼기·목록 편집만 있으면 스냅샷 폴더를 보지 않는다). 라이브 master.db는 거부한다.
- `--snapshot-time`: 사본을 뜬 시각(`usb-export`와 같다). 곡 더하기·갱신에서 이 시각 뒤에 분석 파일이 바뀐 곡은 막는다.
- `--dry-run`: 계획·준비·쓰기 전 확인까지만 하고 USB에 쓰지 않는다. 같은 명령을 `--dry-run` 없이 다시 부르면 막히지 않고 쓴다.
- 편집 하나가 막히면 그 편집만 빼고 나머지를 쓴다. 여러 곡 갱신(`refreshTracks`)은 곡 더하기처럼 막힌 곡만 빼고 쓰고(요약의 "빼고 쓴 곡"), 요청한 곡이 모두 막혔을 때만 그 편집을 막는다. USB 전체를 막는 것: 두 형식의 곡 번호·경로가 다름(`formatTrackMismatch`), 같은 번호 재생 목록이 형식마다 다름(`formatPlaylistConflict`), 라이브러리 손상(`libraryCorrupt`), 새 rekordbox의 OneLibrary(`oneLibraryUnsupported`), 볼륨 모양(exFAT·GPT 등), 실물 관문, 끝나지 않은 쓰기(`recoveryNeeded`). Device Library만 막는 것(OneLibrary는 쓴다): 머리 0x10이 5가 아님(`pdbNotClosed`), 기기가 쓴 기록·모르는 표 행(`carriedDeviceRows`), 다시 쓸 수 없는 모양(`pdbRoundTripFailed`). 한 형식이 막히면 파일 지우기를 미루고(`deferred`), 두 형식에 함께 있는 재생 목록의 이름·폴더 바꾸기는 막는다(`playlistInBlockedFormat` — 한 형식만 바꾸면 두 형식 목록이 어긋나 다음부터 USB 전체가 막힌다).
- 출력: 진행은 표준 오류, 요약은 표준 출력(스냅샷 시각 → 편집 번호별 결과 `written`·`unchanged`·`blocked <code>`·`deferred` → 쓴 형식·막힌 형식 → 빼고 쓴 곡 code별 수 → 알림(경로가 붙은 알림은 이유별 수) → 확인 안 된 규칙 → 결과·백업 폴더·파일 수). 곡 제목·USB 경로는 찍지 않는다. 종료 코드는 성공 0, 막힘·실패 1(편집 일부만 막히고 나머지를 썼으면 0).

편집 파일 모양(`UsbLibraryEdit` 배열). 곡은 USB `content_id`(수), 로컬 곡은 로컬 ContentID(글자), 재생 목록은 USB `playlist_id`(글자) 또는 같은 파일에서 만든 목록 `new:<key>`, 맨 위는 `root`다.

```json
[ {"removeTracks": {"usbContentIDs": [5]}},
  {"refreshTracks": {"usbContentIDs": [2], "parts": ["info", "cues", "grid", "artwork"]}},
  {"addTracks": {"localContentIDs": ["123456"], "playlist": "1"}},
  {"playlist": {"edit": {"create": {"key": "p2", "name": "새 목록", "isFolder": false, "parent": "root"}}}},
  {"playlist": {"edit": {"rename": {"playlist": "1", "name": "새 이름"}}}},
  {"playlist": {"edit": {"move": {"playlist": "new:p2", "into": "root"}}}},
  {"playlist": {"edit": {"reorder": {"playlist": "new:p2", "index": 0}}}},
  {"playlist": {"edit": {"delete": {"playlist": "3"}}}},
  {"playlist": {"edit": {"addTracks": {"playlist": "new:p2", "contentIDs": ["1", "2", "3"]}}}},
  {"playlist": {"edit": {"removeTracks": {"playlist": "1", "entries": [{"trackNo": 2, "contentID": "7"}]}}}},
  {"playlist": {"edit": {"moveTracks": {"playlist": "new:p2", "entries": [{"trackNo": 3, "contentID": "3"}], "to": 1}}}} ]
```

- `refreshTracks.parts`: `info`(곡 정보), `cues`(큐), `grid`(박자 그리드·분석 파일), `artwork`(그림). 로컬 곡은 이 곡을 내보낸 라이브러리의 같은 곡(DB ID·곡 ID·파일 이름)으로 찾는다. 로컬과 같은 곡은 `unchanged`, 기기에서 고친 곡(hasModified·기기 큐 행)은 건너뛰고 알린다. 음원이 바뀐 곡은 막는다(음원은 다시 쓰지 않는다).
- `addTracks.playlist`: 주면 더한 곡을 그 목록 끝에 넣는다. 이미 USB에 있는 곡(`alreadyOnUsb`)과 내보내기에서 막히는 곡은 빼고 더한다.
- 재생 목록 항목 편집(`addTracks`·`removeTracks`·`moveTracks`)은 두 형식의 곡 목록이 같은 목록만 한다(다르면 `playlistEntriesDiffer` — 이름·위치만 바꿀 수 있다). `entries`의 `trackNo`는 1부터의 자리, `contentID`는 그 자리에 있어야 할 USB 곡이다. 지금 그 자리의 곡과 다르면 막는다(`entryMismatch`).

## USB 쓰기 되돌리기·회복

USB 쓰기는 앱(또는 USB 내보내기·수정 명령)이 `UsbWriter.write` 한 곳으로 한다. 아래 두 명령은 그 쓰기를 되돌리거나 끊긴 쓰기를 마무리한다. 둘 다 쓰기와 같은 확인을 먼저 거친다: rekordbox·rekordboxAgent가 켜져 있으면 막고, 실물 USB 쓰기가 열리기 전에는 임시 폴더 아래에 붙인 디스크 이미지만 받는다. `--volume`에 rekordbox 라이브러리나 DJCrate 데이터 폴더를 주면 거부한다. 백업·저널은 `DJC_HOME`(또는 기본 DJCrate 데이터 폴더)의 `usb-backups/`·`usb-sessions/`에 있다. JSON 계약에는 포함하지 않는다.

```sh
djc usb-recover --volume <마운트> [--discard-temp] [--confirm <볼륨 이름>]
djc usb-restore --volume <마운트> [--backup <폴더>] [--discard-device-changes] [--confirm <볼륨 이름>] [--dry-run]
```

- `usb-recover`: 이 볼륨의 끝나지 않은 쓰기(닫히지 않은 저널)를 DB 해시로 판정해 마저 쓰거나 되돌린다. 기기가 그 사이 DB를 바꿨으면 이어 쓰지 않고 "다시 계획"으로 닫는다(지금 USB로 다시 미리 보기한 뒤 쓴다). 끊긴 `usb-restore`는 되돌리기로 마저 한다. 저널이 없으면 "회복할 쓰기가 없습니다"로 끝내고, USB에 `.djc-part-*` 임시 파일이 있으면 보고만 하며 `--discard-temp`를 주면 지운다. 저널을 읽지 못하거나 저널의 경로가 USB 루트 밖을 가리키면 아무것도 하지 않고 `usb-sessions`를 확인하라고 알린다.
- `usb-restore`: 끝난 쓰기를 그 쓰기 전 백업으로 되돌린다. `--backup`을 빼면 이 볼륨의 가장 최근 백업이다. `--backup`은 이 볼륨의 `usb-backups/<볼륨>/` 바로 아래 폴더만 받는다(다른 곳에 복사한 백업·링크는 거부). 그 뒤 기기가 USB에 기록을 남겼으면(DB 해시가 쓰기 결과와 다르거나 `-wal`·`-journal`이 있음) 막고, `--discard-device-changes`를 줘야 그 변경을 버리고 되돌린다. 쓰기가 만든 파일·폴더·DB는 지우고, 덮어쓴 파일은 백업에서 되살리며, 지웠던 음원은 로컬 원본이 그대로일 때만 다시 복사하고, 원본이 없거나 바뀌었으면 알리고 나머지를 되돌린다. 되돌린 백업으로 다시 돌리면 "이미 되돌렸습니다"로 끝낸다. `--dry-run`은 판정만 하고 USB를 바꾸지 않는다.
- `--confirm <볼륨 이름>`은 실물 USB 쓰기가 열린 뒤 실물에 쓸 때 요구하는 볼륨 이름 확인이다.
- 출력은 결과·백업 폴더·파일 수다. USB 경로가 붙은 알림(건너뛴 분석 파일 등)은 이유별 개수만 찍는다.
- 종료 코드는 성공 0, 막힘·실패 1이다. 막힘 이유는 무엇을 하면 되는지까지 한 문장으로 나온다.

## USB 읽기(`usb-info`)

```sh
djc usb-info <볼륨|폴더> [--json]
```

USB(마운트된 볼륨이나 그 안 폴더, 또는 USB 모양 폴더)를 **읽기만** 해서 형식·곡 수·두 형식이 맞는지·분석 파일·경고를 보여 준다. 앱 사이드바도 같은 판정(`UsbRead`)을 쓴다. USB에는 아무것도 쓰지 않는다. DB는 `DJC_HOME`(또는 기본 DJCrate 데이터 폴더)의 `usb-snapshots/` 아래에 사본으로 떠서 읽고 끝나면 지운다. `PIONEER/extracted`·`PIONEER/CDP`·`djprofile.nxs`는 열지도 "있음"을 알리지도 않는다. 사람용 출력에는 곡 제목·경로·볼륨 이름을 찍지 않는다.

- **실물 USB는 쓰기 금지 목록(증거용 USB)을 등록한 뒤에만 읽는다. 디스크 이미지·폴더는 늘 읽는다.** 대상 경로의 마운트 지점이 Mac 시동 볼륨이 아니면(볼륨 안 하위 폴더여도) 그 볼륨으로 보고 먼저 판정한다: 볼륨 UUID가 쓰기 금지 목록에 있으면 `denylisted`(디스크 이미지여도), 디스크 이미지면 읽음, 목록 파일이 깨졌으면 `denyListUnreadable`, 고정 위치 목록이 없거나 비었으면 `denyListNotRegistered`, 실물인데 볼륨 UUID를 읽지 못했으면 `noVolumeUUID`(목록과 맞춰 볼 수 없으므로). 막히면 사본도 뜨지 않는다.
- rekordbox 라이브러리나 DJCrate 데이터 폴더를 주면 거부한다(`liveLibrary`). 없는 경로는 `not_found`.
- JSON은 위 v1 규칙을 따르되, **`usb-info`는 키를 생략하지 않는다**: 값이 없으면 `null`이다(뒤 판이 값을 채워도 모양이 그대로이게). 오류 코드는 위의 것과 `denylisted`, `denyListUnreadable`, `denyListNotRegistered`, `noVolumeUUID`, `liveLibrary`다.
- **개인 식별값은 내지 않는다**: masterDbId·myTagMasterDBID·볼륨 UUID는 값 대신 "같은지"만 적는다. 볼륨 이름은 `root`(받은 경로)에만 나올 수 있고 다른 키에는 없다.

`data`(`UsbInfo`, `schemaVersion` 1):

| 키 | 타입 | 뜻 |
|---|---|---|
| `schemaVersion` | number | 1 |
| `root` | string | 받은 경로를 절대 경로로 바꾼 것(링크는 풀지 않는다). 볼륨이면 `/Volumes/<이름>`처럼 볼륨 이름이 들어갈 수 있다 |
| `formats` | string[] | `oneLibrary`·`deviceLibrary`(`PIONEER/rekordbox/`의 `exportLibrary.db`·`export.pdb` 이름으로 판정) |
| `volume` | object \| null | 폴더 대상이면 null. `fileSystem`(string, 예 `FAT32`), `partitionScheme`(`mbr`·`gpt`·`apm`·`none`·`unknown`), `isDiskImage`, `writableForExport`, `writableForEdit`(bool, 볼륨 정책 문제가 없는지), `problems`(string[], 정책 문제 code) |
| `oneLibrary` | object \| null | `schemaOK`(확인한 모양), `headerMode`(`wal`·`rollback`, 사본이 온전하지 않으면 `unknown`), `walPresent`, `journalPresent`, `integrityOK`(bool), `tracks`, `playlists`, `myTags`, `histories`(number) |
| `deviceLibrary` | object \| null | `exportFlag10`(number, 머리 0x10), `extFlag10`(number \| null), `roundTripChecked`(bool, 늘 true), `roundTripOK`(bool: 읽기 → 모델 → 다시 쓰기 → 다시 읽기가 같으면 true, 다시 만들지 못하거나 다르면 false와 경고 `pdbRoundTripFailed`. Device Library를 읽지 못하면 `deviceLibrary`가 null), `tracks`, `playlists`, `historyRows`(기록 표 산 행), `unknownTableRows`(모르는 표 산 행), `structureIssues`(number) |
| `consistency` | object | `trackIDsMatch`, `pathsMatch`(bool), `playlistMismatches`(number, 두 형식이 다른 재생 목록 수), `masterDbIdConsistent`(모든 곡이 한 값), `myTagMasterDBIDConsistent`(두 형식 값이 같음), `editBlocked`(고치기를 막는 불일치가 있음) |
| `analysis` | object | `tracksChecked`, `missingFiles`(DB가 가리키는 `.DAT`·`.EXT`·`.2EX` 중 없는 파일 수), `ppthMismatches`(`.DAT` PPTH ≠ 곡 경로인 곡 수), `slotCollisions`(파일 번호가 0이 아닌 경로 수) |
| `localCompatibility` | object | `rekordboxVersion`(string \| null, 이 Mac의 rekordbox), `verified`(bool, DJCrate가 확인한 버전인지) |
| `warnings` | `{code, message}[]` | `pdbOpenFlag`(머리 0x10 ≠ 5), `unknownTableRows`, `pdbStructure`, `deviceLibraryUnreadable`, `oneLibrarySidecar`(`-wal`·`-journal`), `oneLibraryUnsupported`, `oneLibraryUnreadable`, `formatMismatch`(고치기 막힘), `analysisMissing`, `analysisPathMismatch`, `pdbRoundTripFailed`(DJCrate가 이 Device Library를 그대로 다시 쓸 수 없음 — 문제 수만 적음). `message`만 번역한다 |

종료 코드는 성공 0, 막힘·실패 1이다. 형식이 없는 USB도 성공이며 `formats`가 빈 배열이다.
