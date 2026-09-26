# anicue 구조와 설계 결정

코드 위치보다 **왜 이렇게 만들었는지**를 적는다. 파일별 설명은 코드와 `AGENTS.md`의 구조 목록을 본다.

## 데이터 흐름

```
rekordbox master.db ──(스냅샷 사본)──▶ RekordboxLibrary ──▶ LibraryStore(목록·필터) ──▶ DeckModel(덱)
        ▲                                                         │
        │                                            편집은 초안으로 쌓임
        │                                    CueDraft · GridDraft · 게인 초안 · TagDraft
        │                                                         │
        └──── RekordboxWriter / RekordboxGridWriter ◀── 반영(rekordbox 꺼져 있을 때만)
                                                                  │
                        새 곡 ── StagedTrack ── rekordbox XML ──▶ rekordbox가 Import
```

- **읽기는 사본에서만.** 라이브 DB를 열어 두면 rekordbox와 잠금·WAL이 얽힌다. `LibrarySnapshot`이 사본을 뜨고, rekordbox가 켜져 있으면 `--force`일 때만 WAL까지 합친 읽기용 사본을 뜬다.
- **편집은 초안.** 초안은 JSON으로 `~/Library/Application Support/anicue/`에 저장된다. 앱을 꺼도 남고, 반영하면 지운다. 초안마다 만들 때의 rekordbox 상태(`base`)가 있어서, 그 뒤 rekordbox에서 바뀐 곡은 쓰지 않는다(덮어쓰기 방지).
- **반영 뒤에는 조용히 다시 읽는다.** 화면을 로딩으로 바꾸지 않고 스냅샷을 새로 떠서 목록을 바꾸고, 덱은 소리·파형·분석을 그대로 둔 채 초안·그리드·게인만 새 값으로 맞춘다(`DeckModel.softReload`).
- **되돌리기.** 쓰기 전 전체 백업(`rekordbox-backups/<시각>-write/`)에 그때 쓴 초안도 함께 넣어 두고, 되돌리면 DB·분석 파일을 복원하고 초안을 다시 살린다.

## 시간축

rekordbox는 압축 음원 앞의 인코더 지연을 잘라 내지 않는다. 그래서 rekordbox의 0초는 AVFoundation의 0초보다 앞선다.

- 덱·초안·그리드의 모든 시각 = **rekordbox 시간축**(음원 시각 + `RekordboxTimeline.predictedOffset`).
- 음원을 읽을 때(재생 프레임 선택)와 파형을 그릴 때만 `timelineOffset`만큼 뺀다.
- 150곡 실측으로 맞췄고, 내보낸 그리드가 rekordbox 그리드와 1ms 안에서 일치한다.

## 분석

| 기능 | 방법 | 수준 |
|---|---|---|
| 섹션·메모리 큐 제안 | Apple Music Understanding 섹션 경계 → 박에 맞춤 | 직접 찍은 큐 ±1박 재현율 62% |
| 그리드 추정 | MU 박·마디 + 1ms 어택 곡선, 105~215 BPM, 구간별 맞춤(변속) | BPM ±0.05 84%, 박 일치 67% |
| 조성 흐름 | 16384점 FFT 크로마 + 라이브러리 400곡으로 학습한 프로필 + 12조표 비터비 | 주 조표 rekordbox 일치 67% |
| 음량 | BS.1770 통합 음량(vDSP K-가중) | ffmpeg ebur128과 ±0.05 LU |

- 결과는 `analysis/`에 캐시한다(파일이 바뀌면 다시 계산).
- 오토게인은 rekordbox 값(약 −10 LUFS 기준)을 기본으로 쓰고, anicue가 잰 음량과 1.5dB 넘게 다르면 제안한다.

## 덱 오디오 (`DeckAudio`)

```
trackNode → gainUnit(오토게인) → trackMixer(볼륨) ┐
clickNode(메트로놈) ─────────────────────────────┴→ subMixer → varispeed → timePitch → 출력
```

- 곡은 불러올 때 메모리에 통째로 디코딩해 둔다(20분 이하). 재생·점프·CUE가 외장 드라이브에서도 바로 반응한다. 디코딩이 끝나기 전에는 파일에서 읽는다.
- **`pause()` 금지, `stop()`만.** pause 뒤 다시 켜면 `play(at:)`의 호스트 시각이 쉬기 전 기준으로 환산돼, 쉰 시간만큼 소리가 늦고 무음이 쌓였다.
- **루프는 샘플 단위.** 재생 노드에 "조각"(노드 샘플 → 곡 프레임, 루프 길이)을 예약해 오디오가 직접 되풀이한다. 화면 틱이 되돌리던 예전 방식은 바퀴마다 짧게 끊겼다.
  - 오프라인 렌더 실험으로 확인한 제약:
    - 시각을 정한 `.interrupts` 예약은 이미 그린 곳보다 렌더 블록 하나 이상 앞서야 정확하다.
    - 되풀이(`.loops`) 버퍼는 바퀴 경계에서만 정확히 끊긴다.
    - `.interrupts` 버퍼 뒤에 시각 없이 줄 세운 버퍼는 지워진다.
  - 곡 위치·메트로놈 클릭도 이 조각을 따라 계산한다.
- 템포는 키 락이면 timePitch, 아니면 varispeed. 클릭도 같은 경로를 지나 템포를 바꿔도 박에 붙어 있다.

## 화면 성능

- 재생 중 매 프레임(디스플레이 링크 60Hz) 바뀌는 값은 `playhead` 하나다. 이 값을 읽는 뷰만 매 프레임 다시 그려진다.
- 매 프레임 SwiftUI 갱신 한 번에 창 전체 비용이 든다(프레임당 약 2ms, 릴리스 측정). 그래서:
  - 글자·전체 파형 재생선은 `displayTime`(15Hz)을 읽는다.
  - 레벨 미터는 자체 30fps 타이머 대신 재생 틱이 올리는 `meterFrame`으로 갱신한다.
  - 결과: 재생 중 메인 스레드 366 → 약 215ms/초. 빠른 목록 스크롤 때 25ms 넘는 프레임 약 30 → 10번(3초당).
- 확대 파형 그리기 자체는 약 1ms로 작다. 막대 그리기를 끄는 A/B에서 차이가 없었다.
- 일부 뷰를 별도 NSHostingView로 떼는 방법은 오히려 느렸다(504ms/초).

## rekordbox 쓰기

규칙·절차·막아 둔 것은 `docs/rekordbox-internals.md`.
