# DJCrate

[![빌드·테스트](https://github.com/fotoner/DJCrate/actions/workflows/check.yml/badge.svg?branch=dev)](https://github.com/fotoner/DJCrate/actions/workflows/check.yml)

rekordbox 7용 DJ 라이브러리 관리 macOS 앱(약칭 DJC, 명령줄 도구 `djc`). rekordbox 라이브러리를 읽어 큐·그리드·오토게인·루프를 고치고, **rekordbox를 깨뜨리지 않는 선에서** rekordbox에 직접 반영한다. 목표는 rekordbox를 켜지 않고도 곡을 넣고 빼고 고치는 것이다. DJ 공연 프로그램이 아니라 라이브러리 관리 도구다. rekordbox Export 모드의 라이브러리 관리 기능에 1:1로 대응하면서 더 낫게 만들고, 랩탑 공연 기능은 만들지 않는다. 애니송 코멘트 규칙 같은 애니송 DJ용 기능도 들어 있다.

옛 이름은 anicue(2026-09-26 이름 바꿈). 처음 켤 때 옛 데이터 폴더·설정을 새 이름으로 옮긴다.

## 무엇을 하나

**라이브러리**
- rekordbox `master.db`를 스냅샷 사본으로 읽어 라이브러리의 곡을 목록으로 본다(플레이리스트 트리 포함).
- 필터: 빈 코멘트, 규칙 밖 코멘트, 큐 없음, BPM·그리드 없음, 변속 곡, 반영 대기 등.
- 컬럼 추가·삭제(헤더 오른쪽 클릭), 앨범·길이·형식·변속 정보·핫큐/메모리 큐 수 표시.
- 코멘트 규칙(`TVA 작품명(약칭) 2기 OP 1 TVSIZE`) 파싱, 태그 편집(인스펙터·엑셀식 태그 시트).

**덱**
- 3밴드 파형(확대·전체), 마디.박 표시, 조성 흐름 띠, 지금 BPM·조성.
- CDJ식 CUE, 핫큐 A~H, 메모리 큐(다음 큐까지 남은 박 표시), 퀀타이즈, 메트로놈, 템포(키 락).
- 루프:
  - 즉석 루프(`L`, ½·×2), 반복 중 빈 핫큐 칸 = 루프 핫큐, 활성 루프
  - 이음새가 끊기지 않게 샘플 단위로 되풀이
- 오토게인(rekordbox 값 또는 잰 음량 기준), 레벨 미터·최고 피크, 이상한 게인 제안.

**분석과 제안**
- 곡 구조 분석으로 메모리 큐 후보 제안.
- rekordbox 그리드가 없는 곡의 BPM·그리드 추정(변속 곡 포함), 제안 받기·무시·재분석.
- 알파뉴메릭 표기(1A–12B)로 조성 흐름 추정, 곡 음량(LUFS)·클리핑 흔적.

**그리드 편집**
- 이동(1·10ms, 끌기), BPM 입력·×2·÷2, ½박 이동, 여기를 1박으로, 변속 지점, 탭 템포.
- "큐도 함께(핫큐·메모리)"를 켜면 그리드를 옮기거나 BPM을 바꿀 때 핫큐와 메모리 큐(루프 포함)가 같은 박을 따라간다.

**rekordbox 반영**
- 큐(메모리·핫큐·루프·활성 루프), 그리드·BPM, 오토게인을 rekordbox 라이브러리에 바로 쓴다(⌘⇧E).
- 반영 전 미리 보기로 무엇이 들어가고 막히는지 보여 주고, 끝나면 알림과 되돌리기를 띄운다.

**새 곡**
- 파일·폴더를 끌어다 놓으면 BPM·그리드를 추정한다.
- "rekordbox에 바로 넣기"로 rekordbox를 켜지 않고 컬렉션에 넣는다: 곡 행, 추정 그리드·파형·오토게인(분석 파일 .DAT·.EXT·.2EX), 태그 초안까지. 큐 초안은 새 곡의 반영 대기로 옮긴다. 프레이즈·보컬 분석은 rekordbox에서 Phrase만 분석하면 더해진다.
- 라이브러리 곡은 오른쪽 클릭 "rekordbox에서 빼기"로 컬렉션에서 뺀다(음원 파일은 그대로, 큐·재생 목록 항목·분석 파일은 함께 사라짐).
- 넣기·빼기 모두 쓰기 직전 백업을 떠서 "되돌리기"로 무를 수 있다. rekordbox XML(Import To Collection) 경로도 남아 있다.
- 라이브러리에 있는데 rekordbox 분석 전인 곡(분석 파일 없음)은 그리드 초안을 반영할 때 파형·그리드·오토게인 분석 파일을 DJCrate가 만들어 붙인다. 키·프레이즈·보컬 분석은 없다.

## 안전 장치

- rekordbox(또는 rekordboxAgent)가 켜져 있으면 **절대 쓰지 않는다**.
- 확인한 rekordbox(7.2.x)·DB 구조가 아니면 쓰지 않는다. rekordbox를 업데이트했다면 `djc compat`으로 먼저 확인한다.
- 쓰기 전에 라이브러리 전체와 바꿀 분석 파일을 백업하고, 한 트랜잭션으로 쓴 뒤 다시 읽어 검증한다. 무결성 검사에 실패하면 백업으로 되돌린다.
- 쓰기 규칙은 rekordbox 7.2.18에서 직접 편집한 결과와 칸 단위로 같은지 확인한 것만 쓴다. 확인하지 못한 경우는 이유와 함께 막는다:
  - 템포 구간이 여러 개인 곡의 BPM 변경
  - rekordbox 분석이 끝나지 않은 반쪽 곡(.DAT만 있고 파형 없음)의 그리드
- 반영한 뒤에도 사이드바의 "마지막 반영 되돌리기"로 쓰기 전 상태로 돌릴 수 있다.

## 요구 사항

- macOS 27 이상, Swift 6.2 툴체인(Xcode)
- rekordbox 7(7.2.18에서 확인)

## 빌드·설치

```bash
scripts/check.sh                   # 빌드·단위 테스트·커버리지 목표
scripts/build-app.sh               # dist/DJCrate.app
scripts/build-app.sh --install     # /Applications/DJCrate.app에 설치
```

## 쓰는 법

1. rekordbox를 끄고 DJCrate를 연다. 툴바의 ⟳(새 스냅샷)로 라이브러리 사본을 뜬다. rekordbox가 켜져 있어도 읽기용 사본은 뜬다.
2. 곡을 골라 덱에서 큐·루프·그리드·게인을 고친다. 모두 초안으로 저장되고 목록에 "반영 대기"로 표시된다.
3. rekordbox를 완전히 끈 뒤 사이드바의 "rekordbox에 반영"(⌘⇧E)을 누른다. 미리 보기를 확인하고 쓴다.

### 단축키

| 키 | 동작 |
|---|---|
| Space | 재생 / 정지 |
| C | CUE(재생 중: 큐로 돌아가 정지, 멈춤: 큐 지점 설정, 누르고 있기: 미리 듣기) |
| 1~8 / Shift+1~8 | 핫큐 A~H (없으면 찍기) / 지우기 |
| ` 또는 M / Shift+` · M | 메모리 큐 찍기 / 이 자리 메모리 큐 지우기 |
| Q / E | 이전 · 다음 큐 |
| ← → / ⌫ | 선택한 큐 1박 이동 / 지우기 |
| L / [ ] | 루프 걸기·나가기 / 루프 길이 ½ · ×2 |
| T | 탭 템포 |
| 휠 · + − | 파형 확대·축소(가로 스크롤: 이동) |
| ⌘⇧E / ⌘I | rekordbox에 반영 / 태그 편집 |

## CLI

`DJCrate`는 개발용 명령줄 도구다(`swift build` 후 `.build/debug/djc`). 인자 없이 실행하면 명령 목록이 나온다.
- 조회: `snapshot`(라이브 DB 사본), `report`(라이브러리 현황), `compat`(쓰기 전 버전·구조 확인)
- 쓰기 시험: `cue-write`(초안 쓰기, 기본은 사본), `rekordbox-restore`(백업으로 되돌리기)
- 실험: `djc lab …` — rekordbox 규칙을 알아낼 때 쓴 명령(`sql`, `db-diff`, `loop-repro`, `seekinfo-check`, `key-eval` 등)
- 에이전트: Claude Code·Codex가 `djc` 읽기 명령으로 라이브러리를 찾아보고 고칠 것을 제안한 뒤, 사용자가 고른 것만 `djc draft`로 큐·태그 초안을 만드는 스킬 `skills/djcrate/SKILL.md`(이 저장소에서 열면 `.claude/skills`·`.agents/skills`로 읽힌다). rekordbox에는 쓰지 않는다(반영은 앱에서).

## 데이터 위치

- `~/Library/Application Support/DJCrate/`(옛 `anicue/` 폴더가 있으면 처음 켤 때 옮긴다)
  - 초안: `cue-drafts/`, `grid-drafts/`, `gain-drafts.json`, `tag-drafts/`
  - 백업: `rekordbox-backups/`
  - 스냅샷: `snapshots/`
  - 캐시: `analysis/`, `waveforms/`, `loudness.json`
- 스냅샷·백업에는 rekordbox 클라우드 토큰이 들어 있으니 공유하지 않는다.

## 한계

- 새 곡을 분석까지 붙여 넣을 수 있는 형식은 MP3(CBR·LAME VBR)·AAC·WAV·FLAC이다. ALAC은 분석 전 추가만 한다. 프레이즈·보컬·AI 특징은 rekordbox만 만들 수 있다.
- 변속 곡의 BPM 변경은 쓰지 않는다.
- 스트리밍 곡은 파형·재생·분석을 하지 않는다.

## 할 일과 이슈

할 일·조사·계획은 [GitHub 이슈](https://github.com/fotoner/DJCrate/issues)로 관리한다. 큰 주제는 [상위 이슈](https://github.com/fotoner/DJCrate/issues?q=is%3Aopen%20label%3Aepic)(USB 내보내기, 재생 목록 편집, AI 에이전트 연동, VirtualDJ, CI/CD 등) 아래에 하위 이슈로 묶는다. 제목·라벨·본문 형식과 이슈에 넣지 않을 것은 `docs/issues.md`에 있다.

## 문서

- `AGENTS.md`: 작업 규칙(사람·에이전트 공통)
- [CONTRIBUTING.md](CONTRIBUTING.md): 빌드·검증·기여 안내
- `docs/architecture.md`: 구조와 설계 결정
- `docs/rekordbox-internals.md`: rekordbox DB·분석 파일 쓰기 규칙(실험으로 확인한 것)
- `docs/issues.md`: 이슈 관리 규칙(제목·라벨·본문·흐름)

라이선스: [MIT(LICENSE)](LICENSE), 제3자 고지: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

rekordbox는 AlphaTheta의 상표다. 이 앱은 AlphaTheta와 관계없는 개인 도구다. rekordbox DB 키는 [pyrekordbox](https://github.com/dylanljones/pyrekordbox)(MIT)와 같은 방식으로 푼다.
