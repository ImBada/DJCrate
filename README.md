# DJCrate

[![빌드·테스트](https://github.com/fotoner/DJCrate/actions/workflows/check.yml/badge.svg?branch=dev)](https://github.com/fotoner/DJCrate/actions/workflows/check.yml)
[![라이선스: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

rekordbox 7 라이브러리를 관리하는 macOS 앱. 큐·그리드·오토게인을 고치고 곡을 넣고 빼는 일을 rekordbox를 켜지 않고 하며, 결과는 rekordbox 라이브러리에 직접 쓴다. 공연용 DJ 프로그램이 아니라 라이브러리 관리 도구다. 명령줄 도구 `djc`도 함께 있다.

![DJCrate 덱과 곡 목록 화면(합성 시험 데이터)](docs/images/deck-library.png)

화면은 macOS 언어 설정에 따라 한국어·영어·일본어로 나온다. English summary: [below](#english).

## 기능

- **곡 목록**: rekordbox 라이브러리를 사본으로 읽어 재생 목록 트리와 함께 본다. 큐 없음·BPM·그리드 없음·변속 곡·반영 대기 같은 필터, 컬럼 고르기(머리글 오른쪽 클릭), 곡 전체 미리 보기 파형 칸(기본은 숨김).
- **덱**: 3밴드 파형(확대·전체), CDJ식 CUE, 핫큐 A~H, 메모리 큐, 루프(즉석 루프·½·×2·활성 루프, 샘플 단위로 이어 되풀이), 퀀타이즈, 메트로놈, 템포·키 고정, 오토게인과 레벨 미터. 파형은 키보드(박·마디 이동, 제안 받기)와 VoiceOver(위치 값·1박 조절·큐·섹션·조성 변화 로터)로도 다룬다.
- **그리드 편집**: 이동, BPM 입력·×2·÷2, 여기를 1박으로, 변속 지점, 탭 템포. 그리드를 고칠 때 핫큐·메모리 큐·루프가 같은 박을 따라가게 할 수 있다.
- **분석과 제안**: 곡 구조로 메모리 큐 후보 제안, 그리드 없는 곡의 BPM·그리드 추정(변속 곡 포함), 조성 흐름(1A–12B), 음량(LUFS)·클리핑 흔적.
- **태그 편집**: 곡 목록에서 바로(태그 칸 더블클릭 또는 곡을 고르고 Return, Tab으로 옆 칸, 여러 곡을 고르면 모두에), 인스펙터, 엑셀식 태그 시트(복사·붙여넣기·아래로 채우기). 태그는 초안으로 두었다가 새 곡을 넣을 때, 그리고 이미 라이브러리에 있는 곡은 반영(⌘⇧E) 때 rekordbox 곡 정보에 쓴다. 음원 파일의 태그는 바꾸지 않는다. rekordbox 실험으로 쓰기 규칙을 확인한 칸(제목·아티스트·장르·작곡가·연도·트랙 번호·코멘트)만 쓰고, 앨범·앨범 아티스트처럼 아직 확인하지 않은 칸을 고친 곡은 반영 미리 보기에서 이유와 함께 막는다([규칙](docs/rekordbox-internals.md#태그-곡-정보)).
- **rekordbox에 바로 쓰기**: 큐(메모리·핫큐·루프·활성 루프)·그리드·BPM·오토게인·태그(곡 정보)를 rekordbox 라이브러리에 쓴다. 쓰기 전에 무엇이 들어가고 무엇이 막히는지 미리 보여 주고, 쓴 뒤에는 되돌릴 수 있다.
- **곡 넣기·빼기**: 음원 파일·폴더를 끌어다 놓으면 BPM·그리드를 추정하고, rekordbox를 켜지 않고 컬렉션에 넣는다(곡 행, 파형·그리드·오토게인 분석 파일, 태그, 큐). 목록에서 오른쪽 클릭으로 컬렉션에서 뺄 수도 있다(음원 파일은 그대로). 넣기·빼기도 되돌릴 수 있다. rekordbox XML(Import To Collection)로 넘길 수도 있다.
- **곡 편집(시험 기능)**: 덱의 편집… 버튼(덱 › 곡 편집…)으로 마디 단위로 구간을 골라 순서를 바꾸고 늘리거나 줄인 편집본을 WAV로 렌더한다(`~/Music/DJCrate 편집본`). 이음새 앞뒤를 미리 듣고, 그리드·큐는 편집 위치로 옮겨 새 곡으로 "추가한 곡"에 넣는다. 원곡은 그대로다. 템포 구간이 하나인 곡만 된다.
- **분석 전 곡**: rekordbox에서 분석하지 않은 곡은 그리드를 쓸 때 파형·그리드·오토게인 분석 파일을 만들어 붙인다.
- **편집은 초안으로**: 모든 편집은 DJCrate 초안으로 쌓이고 쓰기 전까지 rekordbox는 그대로다. 큐·그리드·게인·태그 편집은 ⌘Z로 되돌린다.
- **코멘트 프리셋(선택 기능)**: 기본은 꺼짐. 설정 › 일반에서 애니송을 고르면 코멘트 분류·필터·현황·형식 검사를 켠다. CLI의 `parse`는 애니송 전용이며 `report`·`search`는 `--comment-preset anisong`으로 명시한다.
- **설정(⌘,)**: 일반·덱·단축키. 덱 단축키를 원하는 키로 바꿀 수 있다.
- **명령줄·AI 에이전트**: `djc`로 라이브러리를 찾아보고 큐·태그 초안을 만든다. Claude Code·Codex용 스킬이 들어 있다([아래](#명령줄과-ai-에이전트)).

## 안전 장치

- rekordbox(또는 rekordboxAgent)가 켜져 있으면 쓰지 않는다.
- 쓰기 규칙을 확인한 rekordbox 버전(7.2.x)과 DB 구조가 아니면 쓰지 않는다. rekordbox를 업데이트했다면 `djc compat`으로 먼저 확인한다.
- 쓰기 전에 라이브러리 전체와 바꿀 분석 파일을 백업한다. 한 트랜잭션으로 쓰고, 다시 읽어 검증하고, 무결성 검사에 실패하면 백업으로 되돌린다.
- rekordbox에서 직접 편집한 결과와 칸 단위로 같은지 확인한 쓰기만 한다. 확인하지 못한 경우는 이유를 보여 주고 막는다.
- 쓴 뒤에도 툴바 "rekordbox에 반영" 메뉴의 "마지막 반영 되돌리기…"로 쓰기 전 상태로 돌릴 수 있다.

## 한계

- 분석 파일까지 만들어 넣을 수 있는 형식은 MP3(CBR·LAME VBR)·AAC·WAV·FLAC이다. ALAC과 LAME이 아닌 VBR MP3는 분석 없이 넣는다.
- DJCrate가 만드는 분석 파일에는 키·프레이즈·보컬 분석이 없다. 필요하면 rekordbox에서 분석한다.
- 템포 구간이 여러 개인 곡(변속 곡)의 BPM 변경은 쓰지 않는다. 구간 이동은 된다.
- 스트리밍 곡은 파형·재생·분석을 하지 않는다.

## 요구 사항과 설치

- macOS 27 이상, Swift 6.2 이상 툴체인(Xcode)
- rekordbox 7.2.x(7.2.18에서 확인)

소스에서 빌드한다.

```bash
git clone https://github.com/fotoner/DJCrate.git
cd DJCrate
scripts/build-app.sh --install        # 빌드해서 /Applications/DJCrate.app에 설치
swift build -c release --product djc  # 명령줄 도구: .build/release/djc
```

## 쓰는 법

1. DJCrate를 열고 툴바의 ⟳(새 스냅샷)로 라이브러리 사본을 뜬다. rekordbox가 켜져 있어도 읽기용 사본은 뜬다.
2. 곡을 골라 덱에서 큐·루프·그리드·게인을 고친다. 편집은 초안으로 저장되고 목록에 반영 대기로 표시된다.
3. rekordbox를 완전히 끈 뒤 사이드바의 "rekordbox에 반영"이나 rekordbox 메뉴의 "반영…"(⌘⇧E)을 누르고, 미리 보기를 확인한 다음 쓴다.

초안·백업·스냅샷은 `~/Library/Application Support/DJCrate/`에 있다. 스냅샷과 백업에는 rekordbox 클라우드 토큰이 들어 있으니 공유하지 않는다.

## 단축키

덱 단축키는 설정(⌘,) › 단축키에서 동작마다 바꿀 수 있다. 키는 자판 위치로 기억해서 한글 입력 상태에서도 같은 키가 같은 일을 한다. ⌘ 조합과 Return·Esc·Tab·↑↓·Home·End·Page Up/Down은 바꿀 수 없다.

| 키(기본) | 동작 |
|---|---|
| Space | 재생 / 정지 |
| C | CUE(재생 중: 큐로 돌아가 정지, 멈춤: 큐 지점 설정, 누르고 있기: 미리 듣기) |
| 1~8 / Shift+1~8 | 핫큐 A~H(없으면 찍기) / 지우기 |
| M 또는 `` ` `` / Shift+M | 메모리 큐 찍기 / 이 자리 메모리 큐 지우기 |
| Q / E | 이전 · 다음 큐 |
| ← → / Shift+← → | 1박 / 1마디 이동(선택한 큐가 있으면 그 큐, 없으면 재생 위치) |
| Esc / ⌫ | 큐 선택 풀기 / 선택한 큐 지우기 |
| S / Shift+S / A | 다음 · 이전 제안으로 / 가장 가까운 제안을 메모리 큐로 받기 |
| L / [ ] | 루프 걸기·나가기 / 루프 길이 ½ · ×2 |
| T | 탭 템포 |
| 휠 · + − | 파형 확대·축소(가로 스크롤: 이동) |
| ⌘⇧E / ⌘I | rekordbox에 반영 / 태그 편집 |
| ⌘O / ⌘R | 곡 추가 / 새 스냅샷 |
| ⌘1 / ⌘2 | 곡 목록 / 태그 시트 |
| ⌘+ / ⌘− / ⌘0 | 글자 크게 / 작게 / 기본 크기(곡 목록·태그 시트·덱·알림) |
| ⌘? | 단축키 창 |
| ⌘Z | 편집 되돌리기 |
| ⌘, | 설정 |

## 명령줄과 AI 에이전트

`djc`는 앱과 같은 라이브러리 사본과 초안을 쓴다. 인자 없이 실행하면 명령 목록이 나온다.

```bash
djc snapshot                          # 라이브러리 사본 뜨기
djc search '' --filter no-cues --json # 큐 없는 곡 찾기
djc track <ContentID>                 # 곡 정보·큐·그리드·게인·초안
djc draft cue <ContentID> --time 12.5 --name '진입'   # 메모리 큐 초안
```

- 읽기: `search`, `track`, `duplicates`, `playlists`, `playlist`, `drafts`, `report`, `compat`. `--json`을 주면 정해진 JSON으로 출력한다.
- 초안: `djc draft cue|tag|rm`은 DJCrate 초안만 만들고 지운다. rekordbox에 쓰는 것은 앱의 반영뿐이다.
- 명령과 JSON 형식은 [docs/cli.md](docs/cli.md)에 있다.

[skills/djcrate](skills/djcrate/SKILL.md)는 Claude Code·Codex용 스킬이다. 에이전트가 `djc` 읽기 명령으로 라이브러리를 찾아보고 고칠 것을 제안하면, 사용자가 고른 것만 초안으로 만든다. 이 저장소를 열면 `.claude/skills`·`.agents/skills`로 읽힌다.

## 기여

빌드·검증 방법과 개발용 명령은 [CONTRIBUTING.md](CONTRIBUTING.md)에 있다. 할 일과 계획은 [GitHub 이슈](https://github.com/fotoner/DJCrate/issues)로 관리하고, 이슈 작성 규칙은 [docs/issues.md](docs/issues.md)를 따른다.

- [AGENTS.md](AGENTS.md): 작업 규칙(사람·에이전트 공통)
- [docs/architecture.md](docs/architecture.md): 구조와 설계 결정
- [docs/rekordbox-internals.md](docs/rekordbox-internals.md): 실험으로 확인한 rekordbox 쓰기 규칙

## English

DJCrate is a macOS app for managing a rekordbox 7 library without launching rekordbox. It edits cues, beat grids and Auto Gain, adds and removes tracks, and writes the results directly into the rekordbox library. It is a library tool, not a DJ performance app. A command-line tool, `djc`, is included.

- **Languages**: the app follows your macOS language setting: English, Japanese or Korean (other languages fall back to English). The `djc` command-line tool is Korean only for now.
- **Safety**: DJCrate never writes while rekordbox or rekordboxAgent is running, and only writes to rekordbox 7.2.x with a verified database layout. It backs up the whole library first, writes in a single transaction, reads the result back to verify it, and restores the backup if anything fails. The last write can be restored from the app.
- **Drafts**: every edit is kept as a DJCrate draft until you write it to rekordbox.
- **Requirements**: macOS 27 or later, a Swift 6.2+ toolchain (Xcode) and rekordbox 7.2.x (verified with 7.2.18). Build and install with `scripts/build-app.sh --install`.
- **Getting started**: take a library snapshot (⟳ in the toolbar), edit cues and grids on the deck, quit rekordbox completely, then choose Write to rekordbox (⇧⌘E), check the preview and write.

Documentation, code comments and issues are written in Korean. rekordbox is a trademark of AlphaTheta; DJCrate is an independent project not affiliated with AlphaTheta. Licensed under the [MIT License](LICENSE).

## 라이선스

[MIT](LICENSE). 제3자 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있다.

rekordbox는 AlphaTheta의 상표다. 이 앱은 AlphaTheta와 관계없는 독립 프로젝트다. rekordbox DB 키는 [pyrekordbox](https://github.com/dylanljones/pyrekordbox)(MIT)와 같은 방식으로 푼다.
