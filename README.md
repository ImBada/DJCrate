# DJCrate

[![빌드·테스트](https://github.com/fotoner/DJCrate/actions/workflows/check.yml/badge.svg?branch=dev)](https://github.com/fotoner/DJCrate/actions/workflows/check.yml)
[![라이선스: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

rekordbox 7 라이브러리를 관리하는 macOS 앱. 큐·그리드·오토게인을 고치고 곡을 넣고 빼는 일을 rekordbox를 켜지 않고 하며, 결과는 rekordbox 라이브러리에 직접 쓴다. 공연용 DJ 프로그램이 아니라 라이브러리 관리 도구다. 명령줄 도구 `djc`도 함께 있다.

![DJCrate 덱과 곡 목록 화면(합성 시험 데이터)](docs/images/deck-library.png)

화면은 macOS 언어 설정에 따라 한국어·영어·일본어로 나온다. English summary: [below](#english).

## 기능

- **곡 목록**: rekordbox 라이브러리를 사본으로 읽어 재생 목록 트리와 함께 본다. 큐 없음·BPM·그리드 없음·파일 없음·변속 곡·쓰기 대기 같은 필터(파일 없음에서는 "폴더에서 찾기…"로 새 위치 후보를 미리 본다: 읽기만 하고 경로는 쓰지 않는다), 컬럼 고르기(머리글 오른쪽 클릭), 곡 전체 미리 보기 파형 칸(기본은 숨김). 한 번 클릭은 곡을 고르기만 하고 덱은 그대로다. 더블클릭·⌘→·덱으로 끌어다 놓기·오른쪽 클릭 "덱에 불러오기"로 덱에 올린다(rekordbox와 같게, 키 칸 더블클릭은 키 고르기). 덱에 올린 곡은 # 칸에 스피커로 보인다.
- **덱**: 3밴드 파형(확대·전체), CDJ식 CUE, 핫큐 A~H, 메모리 큐, 루프(즉석 루프·½·×2·활성 루프, 샘플 단위로 이어 되풀이), 퀀타이즈(Q: 큐·루프 등록을 박에 맞추고 재생 중 핫큐는 다음 큰 박선에서 저장 위치로 이동), 메트로놈, 템포·키 고정, 오토게인과 레벨 미터. 파형은 키보드(박·마디 이동, 제안 받기)와 VoiceOver(위치 값·1박 조절·큐·섹션·조성 변화 로터)로도 다룬다.
- **그리드 편집**: 이동, BPM 입력(↑·↓로 0.01씩)·×2·÷2, 여기서 그리드 시작, 변속 지점(구간별 표시, 현재 위치에서 추가: Q가 켜져 있으면 가장 가까운 박, 꺼져 있으면 재생 위치 그대로), 탭 템포(우클릭으로 초기화). 변속 곡도 구간별 BPM을 고쳐 rekordbox에 쓸 수 있다. 그리드를 고칠 때 핫큐·메모리 큐·루프가 같은 박을 따라가게 할 수 있다.
- **분석과 제안**: 곡 구조로 메모리 큐 후보 제안, 그리드 없는 곡의 BPM·그리드 추정(변속 곡 포함), 조성 흐름(1A–12B, rekordbox 키가 없으면 장·단도 추정), 추가한 곡의 키(파일 태그의 키, 없으면 추정해 목록에 기울임으로 표시), 음량(LUFS)·클리핑 흔적. 덱에 올린 곡의 게인·그리드·키 제안은 덱의 제안 줄 한 곳에 "게인 +1.7 dB (rekordbox -4.0) [적용] [무시]"처럼 같은 모양으로 모이고, [적용]해야만 초안이 되며(실행 취소 가능) [무시]한 제안은 "무시한 제안 다시 보기"로 되살린다.
- **태그 편집**: 곡 목록에서 바로(고른 줄의 태그 칸을 한 번 더 누르고 잠깐 기다리기 또는 곡을 고르고 Return, Tab으로 옆 칸, 여러 곡을 고르면 모두에. 키 칸은 더블클릭하거나 키 칸을 누른 그 줄에서 Return으로 메뉴를 연다), 인스펙터, 엑셀식 태그 시트(복사·붙여넣기·아래로 채우기). 태그는 초안으로 두었다가 새 곡을 넣을 때, 그리고 이미 라이브러리에 있는 곡은 rekordbox에 쓰기(⇧⌘E) 때 rekordbox 곡 정보에 쓴다. 음원 파일의 태그는 바꾸지 않는다. rekordbox 실험으로 쓰기 규칙을 확인한 칸(제목·아티스트·장르·작곡가·연도·트랙 번호·코멘트·키)을 쓰고, 키는 글자를 쓰지 않고 rekordbox 키 목록의 Camelot 이름(1A~12B)이나 없음에서 고르며(키가 빈 곡을 덱에 올리면 DJCrate가 추정한 키(추가한 곡은 파일 태그의 키)가 덱 제안 줄에 "키 8B [적용] [무시]"로만 보이고 [적용]을 누르기 전에는 초안에 들어가지 않는다. [무시]한 제안은 "무시한 제안 다시 보기"나 재분석으로 되살린다. 추가한 곡은 고른 키를 곡을 넣을 때 함께 쓴다), 새 앨범·같은 앨범 아티스트의 유일한 기존 앨범으로 변경·앨범 비우기·이름이 유일하고 한 곡만 쓰는 앨범의 앨범 아티스트 변경도 조건부로 지원한다. 클라우드 동기화 상태인 곡도 같은 칸을 rekordbox처럼 쓴다. 같은 이름 앨범이 여럿인 곡의 아티스트를 바꾸거나 비우면 rekordbox처럼 같은 이름의 새 앨범으로 옮기고, 곡 정보를 쓰면 그 곡이 든 재생 목록의 `masterPlaylists6.xml` 시각도 고친다. 공유 앨범 아티스트 변경·동명 앨범으로 붙이기·앨범과 앨범 아티스트 동시 변경 등 아직 확인하지 않은 조건은 쓰기 미리 보기에서 이유와 함께 막는다([규칙](docs/rekordbox-internals.md#태그-곡-정보)).
- **앨범아트 편집**: 태그 인스펙터의 앨범아트 칸에 앨범아트 파일(JPEG·PNG)을 끌어다 놓거나 골라 rekordbox 앨범아트를 넣거나 바꾸고, 지울 수도 있다. 앨범아트도 초안으로 두었다가 rekordbox에 쓰기 때 rekordbox처럼 앨범아트 파일 셋(800·240·80)과 라이브러리 기록을 고친다. 음원 파일에 든 앨범아트는 바꾸지 않는다. 분석 전 곡·투명한 앨범아트 등 확인하지 않은 조건은 미리 보기에서 이유와 함께 막는다([규칙](docs/rekordbox-internals.md#그림-편집-곡-정보-rekordboxwriterartwork-66)).
- **rekordbox에 바로 쓰기**: 큐(메모리·핫큐·루프·활성 루프)·그리드·BPM·오토게인·태그(곡 정보)·앨범아트를 rekordbox 라이브러리에 쓴다. 쓰기 전에 무엇이 들어가고 무엇이 막히는지 미리 보여 주고, 쓴 뒤에는 되돌릴 수 있다.
- **재생 목록**: 사이드바에서 재생 목록·폴더를 만들고(새 항목은 부모 맨 위), 이름을 바꾸고(두 번 누르기), 지우고, 끌어서 옮긴다. 곡을 사이드바 목록에 끌어다 놓거나 오른쪽 클릭 "재생 목록에 넣기 ▸"(최근 목록·폴더 트리·찾아서 넣기), ⇧⌘P(마지막에 쓴 목록)로 넣고, 목록을 볼 때 ⌫로 빼거나 끌어서 순서를 바꾼다. 모두 초안으로 쌓였다가 rekordbox에 쓰기(⇧⌘E) 때 큐·그리드 초안과 함께 쓰고 쓰기 전으로 복원할 수 있다. 인텔리전트 재생 목록은 고치지 않는다.
- **iTunes 동기화 목록**: 새로고침 옆 **동기화** 버튼에서 폴더·플레이리스트를 고르면 rekordbox의 동기화 선택을 바꾸고 DJCrate에도 같은 결과를 표시한다. 선택 창은 전체 iTunes 목록과 반영할 목록을 나란히 보여 주며, 폴더 선택은 하위 목록도 포함한다. rekordbox를 종료한 상태에서 백업 후 반영하며, 창을 연 뒤 외부에서 선택이 바뀌었으면 덮어쓰지 않는다. rekordbox에서 바꾼 선택도 새로고침하거나 DJCrate로 돌아올 때 다시 읽는다. Framework·XML 읽기 설정, 폴더, 곡 순서, 같은 곡의 반복을 유지한다. 목록의 곡 구성은 Music에서 편집하고 기존 컬렉션에 연결된 곡의 큐·태그는 DJCrate에서 편집할 수 있다. 컬렉션에 없거나 경로가 모호한 곡은 누락 개수를 알린다. 갱신에 실패하면 이전 목록을 오래된 자료로 표시한다.
- **곡 넣기·빼기**: 음원 파일·폴더를 끌어다 놓으면 BPM·그리드를 추정하고, rekordbox를 켜지 않고 컬렉션에 넣는다(곡 행, 파형·그리드·오토게인 분석 파일, 태그, 큐, 고른 키). 목록에서 오른쪽 클릭으로 컬렉션에서 뺄 수도 있다(음원 파일은 그대로, 클라우드와 동기화된 곡은 막고 rekordbox에서 직접 빼라고 알린다). 넣기·빼기도 되돌릴 수 있다. rekordbox XML(Import To Collection)로 넘길 수도 있다.
- **중복 곡 합치기**: 사이드바 ‘중복 후보’에서 같은 음원인지 미리 듣고 ‘이 곡을 남기고 합치기…’로 초안을 만든다. 메모리 큐·핫큐와 재생 목록 항목을 옮기고 나머지를 컬렉션에서 빼며, ⇧⌘E로 한 번에 반영하고 되돌린다. 핫큐·활성 루프 충돌, 음원 길이 차이 20ms 초과, 확인하지 않은 시간축·삭제 참조, 클라우드와 동기화된 곡을 빼게 되는 합치기는 막는다. 재생 기록·평점 등 옮기지 않는 정보는 확인 창에 알린다. 음원 파일은 남긴다.
- **가져온 곡의 재생 목록**: 새 음원 파일·폴더를 사이드바 재생 목록에 놓으면 ‘추가한 곡’에 넣고, 컬렉션 등록 뒤 그 목록 초안에 연결한다. Apple Music XML 가져오기에서 ‘재생 목록도 만들기’를 켜면 선택한 곡의 소속 목록을 맨 위에 만든다. 같은 이름은 ‘ (2)’, ‘ (3)’을 붙여 새로 만들고, 같은 출처는 나눠 가져와도 원래 순서로 이어 넣는다(같은 파일은 한 번). 목록 초안은 다음 쓰기 때 쓴다.
- **곡 편집(시험 기능)**: 덱의 편집… 버튼(덱 › 곡 편집…)으로 여는 컷 편집 창. 원곡 파형을 끌어 마디 단위로 구간을 고르고, 결과 타임라인에서 자르기·복제·지우기·끌어 옮기기·가장자리 끌어 다듬기(실행 취소 ⌘Z)로 늘리거나 줄인 편집본을 만들어 WAV로 렌더한다(`~/Music/DJCrate 편집본`). 고른 구간은 결과의 원하는 자리로 끌어 넣고, 두 줄은 세로 휠·핀치·`=`/`−`/`0` 키로 확대해 가로로 스크롤하며 마디 하나까지 고른다. 창 안에서 덱과 따로 원곡과 결과를 어디서든 재생·시킹하고(스페이스바) 이음새 앞뒤를 들어 본다. 그리드·큐는 편집 위치로 옮겨 새 곡으로 "추가한 곡"에 넣는다. 원곡은 그대로다. 템포 구간이 하나인 곡만 된다.
- **Flip(시험 기능)**: 덱의 편집 단추 아래 Flip 단추(덱 › Flip 기록 시작)를 누르면 기록을 시작한다. 재생하며 쓴 핫큐·메모리 큐 점프, 재생 중 탐색 이동·끌기, 루프 되풀이(바퀴마다)만 모으고, 다시 누르면 결과 창을 연다. 결과는 곡 처음부터 재생하다 점프 출발점에서 끊고 착지점에서 잇는 편집본이라, 재생을 어디서 시작했는지나 멈춘 뒤 자리를 옮긴 것은 들어가지 않는다(마지막 착지보다 앞에서 다시 재생해 점프하면 그 뒤를 다시 쓴다). rekordbox에는 Flip 재생이 없어 같은 소리로 재생되는 WAV로 렌더해 "추가한 곡"에 넣는다. 그리드는 박 줄·박 번호가 끊기는 이음새마다 새 템포 구간으로, 큐는 처음 나오는 자리로 옮긴다. 원곡은 그대로다.
- **분석 전 곡**: rekordbox에서 분석하지 않은 곡은 그리드를 쓸 때 파형·그리드·오토게인 분석 파일을 만들어 붙인다.
- **편집은 초안으로**: 모든 편집은 DJCrate 초안으로 쌓이고 쓰기 전까지 rekordbox는 그대로다. 큐·그리드·게인·태그 편집은 ⌘Z로 되돌린다.
- **코멘트 프리셋(선택 기능)**: 기본은 꺼짐. 설정 › 일반에서 애니송을 고르면 코멘트 분류·필터·현황·형식 검사를 켠다. CLI의 `parse`는 애니송 전용이며 `report`·`search`는 `--comment-preset anisong`으로 명시한다.
- **스트리밍 곡 숨기기(선택 기능)**: 기본은 꺼짐. 설정 › 일반에서 켜면 곡 목록·검색 결과·사이드바 곡 수(필터·재생 목록·재생 기록)에서 스트리밍 곡을 뺀다. 보이는 것만 바꾸므로 재생 목록 편집과 rekordbox에 쓰는 내용은 설정과 상관없이 같다. 곡이 숨은 재생 목록은 끌어서 순서를 바꿀 수 없고(검색으로 거른 목록과 같다), 쓰기 대기 목록은 쓸 곡을 모두 보여 주려고 숨기지 않는다.
- **인텔리전트 재생 목록 보기(실험 기능, 읽기만)**: 기본은 꺼짐. 설정 › 실험실에서 켜면 인텔리전트 재생 목록의 조건을 DJCrate가 계산해 곡을 읽기 전용으로 보인다(이름·곡·순서·지우기는 막는다). 글자 항목(제목·아티스트·앨범·앨범 아티스트·코멘트)과 연도 조건만 계산하고, 그 밖의 조건이 하나라도 들어 있으면 곡을 보이지 않는다. 아직 rekordbox가 보여 주는 곡과 견주지 않았다. 끄면 이 기능이 없던 때와 같다(목록은 곡 없이 보인다).
- **라이브러리 XML 내보내기**: 파일 메뉴의 "라이브러리 XML 내보내기…"로 라이브러리 전체(곡 정보·큐·그리드·재생 목록 트리)를 rekordbox XML 한 파일로 저장한다. 읽기만 하고 쓰지 않은 초안은 넣지 않는다([아래](#라이브러리-xml-내보내기)).
- **설정(⌘,)**: 일반·덱·단축키·파형·실험실. 덱 단축키를 원하는 키로 바꿀 수 있다.
- **명령줄·AI 에이전트**: `djc`로 라이브러리를 찾아보고 큐·태그 초안을 만든다. Claude Code·Codex용 스킬이 들어 있다([아래](#명령줄과-ai-에이전트)).
- **USB(시험 기능)**: OneLibrary·Device Library를 함께 읽고 내보내며, USB 곡·재생 목록 편집을 초안으로 쌓아 미리 보기 후 반영한다. Device Library만 있는 옛 USB에는 원래 파일을 그대로 둔 채 OneLibrary를 더한다(`djc usb-migrate`). 쓰기·복원·회복은 지금은 임시 폴더의 디스크 이미지에만 가능하며 실물 USB 쓰기는 코드에서 닫혀 있다([명령](docs/cli.md), [확인 범위](docs/usb-internals.md#10-막아-둔-것)).

## 안전 장치

- rekordbox(또는 rekordboxAgent)가 켜져 있으면 쓰지 않는다.
- 쓰기 규칙을 확인한 rekordbox 버전(7.2.x)과 DB 구조가 아니면 쓰지 않는다. rekordbox를 업데이트했다면 `djc compat`으로 먼저 확인한다.
- rekordbox에 쓰기 전에 라이브러리 전체와 바꿀 분석 파일을 백업한다. 한 트랜잭션으로 쓰고, 다시 읽어 검증하고, 무결성 검사에 실패하면 백업으로 되돌린다.
- rekordbox에서 직접 편집한 결과와 칸 단위로 같은지 확인한 쓰기만 한다. 확인하지 못한 경우는 이유를 보여 주고 막는다.
- 쓴 뒤에도 툴바 "rekordbox에 쓰기" 메뉴의 "쓰기 전으로 복원…"으로 쓰기 전 상태로 돌릴 수 있다. 이 백업은 DJCrate의 직접 쓰기용이며, rekordbox에서 XML을 가져오는 작업은 별도로 백업한다.
- USB DB는 Mac 사본에서만 연다. USB 쓰기는 별도 백업·저널·파일 교체·다시 읽기 검증을 거치며, 자격 증명·프로필 파일은 열거하거나 읽거나 복사하지 않는다.

## 한계

- 분석 파일까지 만들어 넣을 수 있는 형식은 MP3(CBR·LAME VBR·32/44.1/48kHz ffmpeg Xing VBR)·AAC·WAV·FLAC·ALAC(16/24비트·44.1/48kHz 스테레오)이다. 그 밖의 ALAC·비LAME VBR은 분석 없이 넣는다.
- DJCrate가 만드는 분석 파일에는 키·프레이즈·보컬 분석이 없다. 필요하면 rekordbox에서 분석한다.
- 변속 곡은 구간별 BPM·변속 지점을 쓸 수 있지만, 음원 안의 템포 구간에 박이 하나도 남지 않는 편집은 쓰지 않는다([규칙](docs/rekordbox-internals.md#여러-템포-구간의-bpm-편집-11-2026-09-28)).
- 클라우드와 동기화된 곡(`rb_data_status`가 0이 아닌 곡)을 컬렉션에서 빼거나 중복 합치기로 지우는 일은 rekordbox가 행을 지우지 않고 삭제 표시로 남기는 규칙을 아직 확인하지 못해 막는다. 그 곡만 쓰던 동기화 앨범·아티스트 행이나 동기화된 딸린 행(재생 목록 항목·재생 이력 포함)이 걸려도, 곡을 빼며 순번을 당길 자리에 rekordbox가 지운 표시를 남긴 항목이 있어도, 추천 좋아요 표가 가리키는 곡이어도 막는다. rekordbox에서 직접 빼야 한다([규칙](docs/rekordbox-internals.md#곡-추가삭제-rekordboxtrackwriter-2026-09-26-묶음-12-실험)).
- 스트리밍 곡은 파형·재생·분석을 하지 않는다.
- 실물 USB 쓰기와 실기기 동작은 아직 확인하지 않았다. 분석 파일 폴더 이름 결정·새 rekordbox 골든 실험·실물 허용은 별도 결정과 실험을 기다린다.

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

앱 아이콘은 Xcode 27의 `actool`로 `Assets/AppIcon.icon`을 컴파일한다. 전경 SVG를 바꿀 때는 `swift scripts/make-icon.swift`로 다시 만들고, Icon Composer에서 배경·레이어 순서와 기본·다크·모노 외관을 확인한다. 모서리·반사 효과는 시스템이 입히므로 원본에 그리지 않는다.

## 쓰는 법

1. DJCrate를 열고 툴바의 ⟳(새 스냅샷)로 라이브러리 사본을 뜬다. rekordbox가 켜져 있어도 읽기용 사본은 뜬다.
2. 곡을 골라 덱에서 큐·루프·그리드·게인을 고친다. 편집은 초안으로 저장되고 목록에 쓰기 대기로 표시된다.
3. rekordbox와 rekordboxAgent를 완전히 끈 뒤 "rekordbox에 쓰기…"(⇧⌘E)를 누르고, 미리 보기를 확인한 다음 쓴다.

초안·백업·스냅샷은 `~/Library/Application Support/DJCrate/`에 있다. 스냅샷과 백업에는 rekordbox 클라우드 토큰이 들어 있으니 공유하지 않는다.

### XML 호환 경로

기존 "XML 만들기"도 유지한다. DJCrate가 연동 파일을 만들면 사용자가 rekordbox에서 가져오는 경로다. 이 경로는 전체 라이브러리를 내보내지 않는다(전체 내보내기는 아래 "라이브러리 XML 내보내기"). XML을 DJCrate로 다시 가져오는 기능은 아직 없다.

| 경로 | 내보내거나 쓰는 내용 | 주요 제한 |
|---|---|---|
| rekordbox에 쓰기… | 기존 곡의 큐·루프·활성 루프·그리드·BPM·게인·태그·앨범아트와 재생 목록 초안 | rekordbox·Agent 종료, 버전·DB 구조·초안 충돌 등 사전 확인 필요. 새 곡 넣기·컬렉션에서 빼기는 각각의 직접 쓰기 명령으로 실행 |
| 기존 곡의 XML 만들기 | 큐·그리드 초안, 기존 자동 큐·루프, 스냅샷의 곡 정보 | 태그·게인·앨범아트·재생 목록 초안은 제외. ActiveLoop 표시·색을 지정한 핫큐·알 수 없는 큐 종류 등이 있으면 해당 곡을 제외하고 이유 표시 |
| 추가한 곡의 XML 만들기 | 제목·아티스트·앨범·장르·작곡가·연도·트랙 번호·코멘트, 그리드와 메모리·핫큐 위치·이름 | 앨범 아티스트·키·게인·재생 목록 초안은 제외(키를 고른 곡은 내보내지 않고 이유 표시, 키까지 넣으려면 ‘rekordbox에 넣기…’). 큐는 점 큐로 내보내므로 루프 끝·색·활성 루프는 옮기지 않음. 그리드가 없으면 rekordbox에서 분석 |

1. 기존 곡은 큐·그리드 초안을 만든 뒤 파일 메뉴나 쓰기 대기 목록의 "XML 만들기"를 누른다. 새 곡은 "추가한 곡"에서 "XML 만들기"를 누른다. 새 곡을 선택했으면 그 곡들만, 선택하지 않았으면 추가 목록 전체를 내보낸다.
2. 처음에는 안내 창의 연동 파일을 rekordbox 환경설정 › 고급 › 데이터베이스 › rekordbox xml의 "가져온 라이브러리"로 지정한다. XML을 가져오기 전에 rekordbox의 라이브러리 백업을 해 둔다.
3. rekordbox 트리의 "rekordbox xml"을 새로고침하고, "DJCrate 반영"(기존 곡) 또는 "DJCrate 추가"(새 곡)에서 곡을 골라 **Import To Collection**을 실행한다. 기존 곡은 큐 목록 전체를 바꾸므로 가져오기 전에 대상과 내용을 확인한다.
4. DJCrate에서 새 스냅샷(⟳)을 뜬다. 기존 곡은 보낸 큐·그리드와 곡 정보를 비교하고 일치한 곡의 큐·그리드 초안을 지운다. 새 곡은 같은 경로의 곡을 찾아 그리드를 비교하며, 큐·태그 전체가 일치하는지까지 검증하지는 않는다.

연동 파일은 문서 폴더의 `DJCrate/djcrate-rekordbox.xml` 하나이며, "XML 만들기"를 다시 누르면 이전 내용을 덮어쓴다. 기존 재생 목록 이름 "DJCrate 반영"·"DJCrate 추가"는 화면의 쓰기 용어와 별개로 유지한다. XML 생성만으로 rekordbox 컬렉션이나 분석 파일에 직접 쓰지는 않는다.

### 라이브러리 XML 내보내기

파일 메뉴의 **라이브러리 XML 내보내기…**(CLI는 `djc xml-export`)는 지금 보이는 라이브러리 전체(곡 정보·큐·루프·그리드·재생 목록 폴더 트리)를 rekordbox XML 한 파일로 저장한다. 다른 DJ 소프트웨어·도구로 옮기거나 사본으로 둘 때 쓴다. 위의 "XML 만들기"와 달리 저장 위치를 고르고, rekordbox로 되가져오는 연동 파일이 아니다.

- 읽기만 한다. 스냅샷과 분석 파일은 고치지 않고 고른 파일 하나에만 쓴다. rekordbox 폴더·USB의 PIONEER 폴더·DJCrate 데이터 폴더(백업 포함)·연동 XML 파일 자리에는 저장하지 않는다. CLI는 분석 파일 폴더(`--share <rekordbox 폴더>/share`)를 주거나 그리드 없이 내보낸다고(`--no-analysis`) 명시해야 한다.
- 아직 쓰지 않은 초안은 넣지 않는다(rekordbox에 있는 그대로).
- 인텔리전트 재생 목록·My Tag·핫큐 색·스트리밍 곡·상위 폴더가 없는 재생 목록은 넣지 않고, 끝나면 뺀 개수를 알린다. 자세한 칸 목록은 [docs/cli.md](docs/cli.md#라이브러리-xml-내보내기xml-export).

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
| 더블클릭 / ⌘→ | 곡 목록·태그 시트에서 고른 곡을 덱에 불러오기(덱으로 끌어다 놓아도 된다. 한 번 클릭은 고르기만. 곡 목록의 키 칸 더블클릭은 키 고르기 메뉴) |
| Return | 곡 목록에서 고른 곡의 태그 칸 고치기(고른 줄의 칸을 한 번 더 눌러도 된다. 방금 키 칸을 누른 줄이면 키 고르기 메뉴) |
| ⇧⌘E / ⌘I | rekordbox에 쓰기 / 태그 편집 |
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
- 초안: `djc draft cue|tag|rm`은 DJCrate 초안만 만들고 지운다. 이 초안을 앱에서 쓸 때는 "rekordbox에 쓰기…"를 누른다.
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
- **USB (experimental)**: reads both OneLibrary and Device Library, exports tracks and playlists, applies USB edit drafts after a preview, and adds OneLibrary to Device Library-only USBs without changing their files (`djc usb-migrate`). Writing, restoring and recovery are restricted to disk images in temporary folders; physical USB writes remain disabled and hardware behavior is unverified.
- **Requirements**: macOS 27 or later, a Swift 6.2+ toolchain (Xcode) and rekordbox 7.2.x (verified with 7.2.18). Build and install with `scripts/build-app.sh --install`.
- **Getting started**: take a library snapshot (⟳ in the toolbar), edit cues and grids on the deck, quit rekordbox completely, then choose Write to rekordbox (⇧⌘E), check the preview and write.

Documentation, code comments and issues are written in Korean. rekordbox is a trademark of AlphaTheta; DJCrate is an independent project not affiliated with AlphaTheta. Licensed under the [MIT License](LICENSE).

## 라이선스

[MIT](LICENSE). 제3자 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있다.

rekordbox는 AlphaTheta의 상표다. 이 앱은 AlphaTheta와 관계없는 독립 프로젝트다. rekordbox DB 키는 [pyrekordbox](https://github.com/dylanljones/pyrekordbox)(MIT)와 같은 방식으로 푼다.
