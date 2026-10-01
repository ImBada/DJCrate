#!/bin/zsh
# 커밋·합치기 전 확인: 디버그·릴리스 앱, 번역, 전체 테스트, 쓰기 80%·코어 60% 커버리지.
set -euo pipefail
cd "${0:A:h}/.."

# CI의 두 묶음과 개발 중 부분 검사를 나누되, 인자가 없으면 전체 검사를 유지한다.
test_filter=""
case "$#:${1:-}" in
    0:) mode=full ;;
    1:--coverage) mode=coverage ;;
    1:--release) mode=release ;;
    1:--stress) mode=stress; test_filter=CipherColdOpenTests ;;
    3:--quick)
        if [[ "$2" != --filter || -z "${3//[[:space:]]/}" || "$3" == --* ]]; then
            echo '--quick에는 --filter <비어 있지 않은 정규식>이 필요합니다.' >&2
            exit 2
        fi
        mode=quick; test_filter=$3 ;;
    *) echo '사용: scripts/check.sh [--coverage|--release|--quick --filter <정규식>|--stress]' >&2; exit 2 ;;
esac
case "${DJC_CIPHER_STRESS-0}" in
    0|1) ;;
    *) echo 'DJC_CIPHER_STRESS는 미설정·0·1만 허용합니다.' >&2; exit 2 ;;
esac
if [[ "$mode" == stress ]]; then export DJC_CIPHER_STRESS=1; fi

# 실행마다 다른 폴더를 써서 이전 실패·취소 로그와 섞이지 않게 한다.
log_root=${DJC_CHECK_LOG_ROOT:-.build/check-logs}
mkdir -p "$log_root"
log_dir=$(mktemp -d "$log_root/run.XXXXXX")
printf '단계\t초\t종료코드\n' > "$log_dir/timings.tsv"
# 시험이 사용자 초안·백업 폴더를 건드리지 않게, 따로 주지 않으면 이번 실행 폴더 아래를 DJC_HOME으로 쓴다(CI는 직접 준다).
if [[ -z "${DJC_HOME-}" ]]; then
    export DJC_HOME="${log_dir:A}/djc-home"
    mkdir -p "$DJC_HOME"
fi
# 시험이 실제 rekordbox 라이브러리를 기본값으로 보지 않게, 따로 주지 않으면 빈 임시 폴더를 DJC_REKORDBOX_DIR로 쓴다(#182).
if [[ -z "${DJC_REKORDBOX_DIR-}" ]]; then
    export DJC_REKORDBOX_DIR="${log_dir:A}/rekordbox"
    mkdir -p "$DJC_REKORDBOX_DIR"
fi
# 검사 전후 실제 라이브러리 파일의 크기·수정 시각·inode와 바뀐 분석 파일을 비교한다(#182: 시험이 실제 라이브러리를 덮었다).
live_library="$HOME/Library/Pioneer/rekordbox"
touch "$log_dir/live-reference"
live_fingerprint() {
    /usr/bin/stat -f '%N %z %m %i' "$live_library"/master.db*(N) "$live_library"/masterPlaylists6.xml(N) 2>/dev/null || true
    find "$live_library/share/PIONEER/USBANLZ" -newer "$log_dir/live-reference" 2>/dev/null | head -5 || true
}
live_before=$(live_fingerprint)
integer check_started=$SECONDS stage_started=0
stage_name=""
stage_pid=""
pulse_pid=""

# 이 검사에서 시작한 자식만 정리한다. 부모 셸만 취소되어도 빌드가 남지 않아야 한다.
stop_tree() {
    local pid=$1 child
    for child in ${(f)"$(pgrep -P "$pid" || true)"}; do
        [[ -n "$child" ]] && stop_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

finish() {
    local code=$1
    trap '' INT TERM
    if [[ -n "$stage_pid" ]]; then
        stop_tree "$stage_pid"
        wait "$stage_pid" 2>/dev/null || true
        printf '%s\t%d\t%d\n' "$stage_name" "$((SECONDS - stage_started))" "$code" >> "$log_dir/timings.tsv"
        echo "▸ 종료: $stage_name ($((SECONDS - stage_started))초, 종료코드 $code)"
    fi
    if [[ -n "$pulse_pid" ]]; then
        stop_tree "$pulse_pid"
        wait "$pulse_pid" 2>/dev/null || true
    fi
    if [[ "$(live_fingerprint)" != "$live_before" ]]; then
        echo "✘ 검사 중 실제 rekordbox 라이브러리 파일이 바뀌었습니다. rekordbox를 쓰지 않았다면 시험이 실제 라이브러리를 건드린 것이니 바로 멈추고 알리세요" >&2
        (( code == 0 )) && code=3
    fi
    echo "▸ 전체 종료: $((SECONDS - check_started))초, 종료코드 $code (로그: $log_dir)"
    print -r -- "$code" > "$log_dir/exit-code.txt"
    exit "$code"
}
trap 'finish $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 부분 검사 결과를 전체 통과로 오인하지 않도록 설정·후보를 원문 로그에도 남긴다.
check_head=$(git rev-parse --verify HEAD 2>/dev/null || print -r -- unknown)
check_dirty=unknown
if check_worktree=$(git status --porcelain 2>/dev/null); then
    if [[ -n "$check_worktree" ]]; then check_dirty=yes; else check_dirty=no; fi
fi
debug_setting=coverage
release_setting=off
if [[ "$mode" == release ]]; then debug_setting=off; fi
if [[ "$mode" == full || "$mode" == release ]]; then release_setting=on; fi
{
    print -r -- "mode=$mode"
    print -r -- "filter=${test_filter:-none}"
    print -r -- "debug=$debug_setting"
    print -r -- "release=$release_setting"
    print -r -- "cipher_stress=${DJC_CIPHER_STRESS-0}"
    print -r -- "head=$check_head"
    print -r -- "dirty=$check_dirty"
} > "$log_dir/run-info.txt"
cat "$log_dir/run-info.txt"

run_stage() {
    local name=$1 file=$2 code
    shift 2
    stage_name=$name
    stage_started=$SECONDS
    echo "▸ 시작: $name ($(date -u +%Y-%m-%dT%H:%M:%SZ), 로그: $log_dir/$file.log)"
    # 비동기 wait는 셸에 온 취소 신호를 즉시 처리한다. pipefail로 명령·tee 실패를 보존한다.
    # tee의 바이트 청크 사이에 진행 알림이 끼어 UTF-8·한 줄을 나누지 않도록 화면에는 줄로 보낸다.
    (
        "$@" 2>&1 | tee "$log_dir/$file.log" | while IFS= read -r line || [[ -n "$line" ]]; do
            print -r -- "$line"
        done
    ) &
    stage_pid=$!
    (
        while sleep 30; do
            echo "▸ 진행: $name ($((SECONDS - stage_started))초)"
        done
    ) &
    pulse_pid=$!
    if wait "$stage_pid"; then code=0; else code=$?; fi
    stage_pid=""
    stop_tree "$pulse_pid"
    wait "$pulse_pid" 2>/dev/null || true
    pulse_pid=""
    printf '%s\t%d\t%d\n' "$name" "$((SECONDS - stage_started))" "$code" >> "$log_dir/timings.tsv"
    echo "▸ 종료: $name ($((SECONDS - stage_started))초, 종료코드 $code, $(date -u +%Y-%m-%dT%H:%M:%SZ))"
    # zsh의 함수 실패에 따른 errexit은 EXIT 트랩을 건너뛸 수 있어 명시적으로 끝낸다.
    if (( code != 0 )); then exit "$code"; fi
}

require_filtered_tests() {
    # 집계에는 skip된 시험도 들어갈 수 있으므로 실제 개별 시험의 완료를 확인한다.
    if ! awk '/Test .+ passed after / && !/Test run with / { completed = 1 }
        END { exit !completed }' "$log_dir/test.log"; then
        print -r -- "실제로 완료한 시험이 없습니다. 필터를 확인하세요: $test_filter" >&2
        return 1
    fi
}

coverage() {
PROF=.build/out/Products/Debug/codecov/default.profdata
bundles=(.build/out/Products/Debug/*Tests.xctest)
first="${bundles[1]}/Contents/MacOS/$(basename ${bundles[1]} .xctest)"
rest=()
for b in "${bundles[@]:1}"; do rest+=(-object "$b/Contents/MacOS/$(basename $b .xctest)"); done
xcrun llvm-cov report "$first" "${rest[@]}" -instr-profile "$PROF" -ignore-filename-regex='(checkouts|Tests|\.build)/' \
    | awk 'NF>=10 && $1 ~ /\.swift$/ {print $1, $8, $9}' > "$log_dir/coverage.txt"
awk '
    function add(group, lines, missed) { total[group] += lines; miss[group] += missed }
    {
        if ($1 ~ /^RekordboxKit\/(RekordboxWriter|RekordboxGridWriter|RekordboxCompatibility|RekordboxTrackWriter|RekordboxTrackAdd)/ || $1 ~ /^RekordboxKit\/Usb\/Write\//) add("쓰기", $2, $3)
        if ($1 ~ /^(DJCDomain|RekordboxKit|DJCStorage|DJCAnalysis)\//) add("코어", $2, $3)
        if ($1 ~ /^DJCrate\//) add("앱", $2, $3)
    }
    END {
        target["쓰기"] = 80; target["코어"] = 60; target["앱"] = 0
        failed = 0
        n = split("쓰기 코어 앱", order, " ")
        for (i = 1; i <= n; i++) {
            g = order[i]
            pct = total[g] ? 100 * (total[g] - miss[g]) / total[g] : 0
            mark = (pct >= target[g]) ? "✔" : "✘"
            if (pct < target[g]) failed = 1
            printf "  %s %-4s %5.1f%%  (%d줄 중 %d줄, 목표 %d%%)\n", mark, g, pct, total[g], total[g] - miss[g], target[g]
        }
        exit failed
    }' "$log_dir/coverage.txt"
}

# 디버그 앱·CLI·테스트를 같은 계측 설정으로 한 번 빌드해 설정 전환에 따른 재컴파일을 줄인다.
if [[ "$mode" != release ]]; then
    run_stage "디버그·테스트 빌드(커버리지 계측)" debug-build swift build --build-tests --enable-code-coverage
fi
if [[ "$mode" == full || "$mode" == release ]]; then
    run_stage "릴리스 앱 빌드" release-build swift build -c release --product DJCrate
fi
if [[ "$mode" == full || "$mode" == coverage ]]; then
    run_stage "번역(en·ja 누락·안 쓰는 문구·자리표시자)" translations swift scripts/i18n.swift check --enable-code-coverage
    run_stage "전체 테스트 실행·프로파일 수집(빌드 생략)" test swift test --skip-build --enable-code-coverage
    run_stage "커버리지 보고·목표 검사" coverage coverage
elif [[ "$mode" == quick || "$mode" == stress ]]; then
    run_stage "관련 테스트 실행(빌드 생략)" test swift test --skip-build --enable-code-coverage --filter "$test_filter"
    run_stage "필터 결과(1개 이상 완료)" filter-result require_filtered_tests
fi
echo "▸ 통과: $mode"
