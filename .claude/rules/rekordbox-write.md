---
paths:
  - "Sources/RekordboxKit/**"
  - "Sources/DJCDomain/Cue/**"
  - "Sources/DJCDomain/Grid/**"
  - "Sources/DJCrate/Library/LibraryStore+Writing.swift"
  - "Sources/DJCrate/Reflection/**"
  - "Tests/RekordboxKitTests/**"
---

# rekordbox 쓰기 코드를 고칠 때

- 먼저 `docs/rekordbox-internals.md`를 읽는다. 거기 적힌 칸·순서·usn 규칙은 rekordbox 실험으로 확인한 것이다. 확인 없이 바꾸지 않는다.
- 막아 둔 조건(반쪽 분석 곡(.DAT만)의 그리드, 카운터가 있는 분석 전 곡의 분석 붙이기, 미확인 ALAC 형식·44.1kHz가 아닌 ffmpeg VBR·그 밖의 비LAME VBR 분석 붙이기)은 rekordbox 실험과 사본 재현으로 칸 단위 일치를 확인하기 전에는 풀지 않는다.
- 새로 쓰는 칸이 생기면 검증 쪽(`RekordboxWriter+Verify`, `key(_:withSource:)`)도 같이 고쳐 그 칸을 다시 읽어 비교하게 한다. 새 행을 넣는 표가 늘면 `RekordboxCompatibility.exactColumns`에, 고치는 칸이 늘면 `requiredColumns`에 더한다.
- 테스트 먼저: `Tests/RekordboxKitTests`에 골든 테스트(실험 곡·날짜를 주석으로)를 쓰고 실패를 본 뒤 고친다. 픽스처는 `RekordboxFixture`(구조만 있는 7.2.18 DB)와 `AnlzBuilder`.
- 쓰기·복원 함수에 라이브 DB를 기본값으로 두지 않는다. 대상은 부르는 쪽이 적고, 새 쓰기 입구는 `RekordboxWriteGuard.checkTargets`(또는 `resolveShareRoot`)를 지나게 해 시험 프로세스의 실제 라이브러리 거부(#182)를 받는다.
- 허용 버전(`verifiedAppVersions`)·`DBVersion`은 rekordbox 실험으로 쓰기 결과를 다시 확인하기 전에는 넓히지 않는다.
- 바꾼 뒤 확인(모두 사본으로):
  1. `scripts/check.sh`(쓰기 커버리지 80% 이상)
  2. `djc compat`, `djc cue-write --db <스냅샷 사본> --dry-run`: 기존 초안의 쓰기/막힘 결과가 바꾸기 전과 같아야 한다.
  3. 그리드면 `djc lab grid-write-test <사본.db> <사본 share> <UUID> <BPM>`
  4. 흐름 전체는 `DJC_REKORDBOX_DIR=<사본> DJC_HOME=<임시> .build/debug/DJCrate --write-selftest`
- 새 규칙을 알아내면 `docs/rekordbox-internals.md`에 적는다(날짜·실험 곡·확인 방법 포함).
