---
paths:
  - "Sources/AnicueCore/Rekordbox/**"
  - "Sources/AnicueCore/Cue/**"
  - "Sources/AnicueApp/LibraryStore+Writing.swift"
---

# rekordbox 쓰기 코드를 고칠 때

- 먼저 `docs/rekordbox-internals.md`를 읽는다. 거기 적힌 칸·순서·usn 규칙은 rekordbox 실험으로 확인한 것이다. 확인 없이 바꾸지 않는다.
- 막아 둔 조건(VBR MP3, 여러 템포 구간 BPM 변경, 파형 없는 곡의 그리드, 곡 추가)은 rekordbox 실험과 사본 재현으로 칸 단위 일치를 확인하기 전에는 풀지 않는다.
- 새로 쓰는 칸이 생기면 검증 쪽(`verify`, `rowValues`, `key(_:withSource:)`)도 같이 고쳐 그 칸을 다시 읽어 비교하게 한다.
- 바꾼 뒤 확인(모두 사본으로):
  1. `swift test`
  2. `anicue cue-write --db <스냅샷 사본> --dry-run`: 기존 초안의 쓰기/막힘 결과가 바꾸기 전과 같아야 한다.
  3. 그리드면 `anicue grid-write-test <사본.db> <사본 share> <UUID> <BPM>`
  4. 흐름 전체는 `ANICUE_REKORDBOX_DIR=<사본> ANICUE_HOME=<임시> AnicueApp --write-selftest`
- 새 규칙을 알아내면 `docs/rekordbox-internals.md`에 적는다(날짜·실험 곡·확인 방법 포함).
