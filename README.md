# anicue

rekordbox 7로 애니송 DJ를 하는 사람을 위한 macOS 라이브러리 관리 앱. rekordbox 라이브러리를 읽어 큐·그리드·오토게인·루프를 고치고, **rekordbox를 깨뜨리지 않는 선에서** rekordbox에 직접 반영한다.

## 무엇을 하나

**라이브러리**
- rekordbox `master.db`를 스냅샷 사본으로 읽어 7천여 곡을 목록으로 본다(플레이리스트 트리 포함).
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
- 조성 흐름 추정(Camelot), 곡 음량(LUFS)·클리핑 흔적.

**그리드 편집**
- 이동(1·10ms, 끌기), BPM 입력·×2·÷2, ½박 이동, 여기를 1박으로, 변속 지점, 탭 템포.
- "큐도 함께(핫큐·메모리)"를 켜면 그리드를 옮기거나 BPM을 바꿀 때 핫큐와 메모리 큐(루프 포함)가 같은 박을 따라간다.

**rekordbox 반영**
- 큐(메모리·핫큐·루프·활성 루프), 그리드·BPM, 오토게인을 rekordbox 라이브러리에 바로 쓴다(⌘⇧E).
- 반영 전 미리 보기로 무엇이 들어가고 막히는지 보여 주고, 끝나면 알림과 되돌리기를 띄운다.

**새 곡**
- 파일·폴더를 끌어다 놓으면 BPM·그리드를 추정한다.
- rekordbox XML로 내보내 rekordbox에서 Import To Collection하면, 새 스냅샷에서 그대로 들어갔는지 확인한다.

## 안전 장치

- rekordbox(또는 rekordboxAgent)가 켜져 있으면 **절대 쓰지 않는다**.
- 확인한 rekordbox(7.2.x)·DB 구조가 아니면 쓰지 않는다. rekordbox를 업데이트했다면 `anicue compat`으로 먼저 확인한다.
- 쓰기 전에 라이브러리 전체와 바꿀 분석 파일을 백업하고, 한 트랜잭션으로 쓴 뒤 다시 읽어 검증한다. 무결성 검사에 실패하면 백업으로 되돌린다.
- 쓰기 규칙은 rekordbox 7.2.18에서 직접 편집한 결과와 칸 단위로 같은지 확인한 것만 쓴다. 확인하지 못한 경우는 이유와 함께 막는다:
  - VBR MP3 큐
  - 템포 구간이 여러 개인 곡의 BPM 변경
  - rekordbox 분석 전 곡(파형 없음)의 그리드
- 반영한 뒤에도 사이드바의 "마지막 반영 되돌리기"로 쓰기 전 상태로 돌릴 수 있다.

## 요구 사항

- macOS 27 이상, Swift 6.2 툴체인(Xcode)
- rekordbox 7(7.2.18에서 확인)

## 빌드·설치

```bash
scripts/check.sh                   # 빌드·단위 테스트·커버리지 목표
scripts/build-app.sh               # dist/anicue.app
scripts/build-app.sh --install     # /Applications/anicue.app에 설치
```

## 쓰는 법

1. rekordbox를 끄고 anicue를 연다. 툴바의 ⟳(새 스냅샷)로 라이브러리 사본을 뜬다. rekordbox가 켜져 있어도 읽기용 사본은 뜬다.
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

`anicue`는 개발용 명령줄 도구다(`swift build` 후 `.build/debug/anicue`). 인자 없이 실행하면 명령 목록이 나온다.
- 조회: `snapshot`(라이브 DB 사본), `report`(라이브러리 현황), `compat`(쓰기 전 버전·구조 확인)
- 쓰기 시험: `cue-write`(초안 쓰기, 기본은 사본), `rekordbox-restore`(백업으로 되돌리기)
- 실험: `anicue lab …` — rekordbox 규칙을 알아낼 때 쓴 명령(`sql`, `db-diff`, `loop-repro`, `seekinfo-check`, `key-eval` 등)

## 데이터 위치

- `~/Library/Application Support/anicue/`
  - 초안: `cue-drafts/`, `grid-drafts/`, `gain-drafts.json`, `tag-drafts/`
  - 백업: `rekordbox-backups/`
  - 스냅샷: `snapshots/`
  - 캐시: `analysis/`, `waveforms/`, `loudness.json`
- 스냅샷·백업에는 rekordbox 클라우드 토큰이 들어 있으니 공유하지 않는다.

## 한계

- 새 곡을 rekordbox에 넣는 건 아직 rekordbox XML을 거친다. rekordbox 분석(파형)은 rekordbox만 만들 수 있다.
- VBR MP3 큐, 변속 곡의 BPM 변경은 쓰지 않는다.
- 스트리밍 곡은 파형·재생·분석을 하지 않는다.

## 문서

- `AGENTS.md`: 작업 규칙(사람·에이전트 공통)
- `docs/architecture.md`: 구조와 설계 결정
- `docs/rekordbox-internals.md`: rekordbox DB·분석 파일 쓰기 규칙(실험으로 확인한 것)

rekordbox는 AlphaTheta의 상표다. 이 앱은 AlphaTheta와 관계없는 개인 도구다. rekordbox DB 키는 [pyrekordbox](https://github.com/dylanljones/pyrekordbox)(MIT)와 같은 방식으로 푼다.
