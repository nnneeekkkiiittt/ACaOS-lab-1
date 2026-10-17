#!/usr/bin/env bash

set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$BASE_DIR/main.sh"

TEST_ROOT="/tmp/lab1_test_env"
IMG_FILE="$TEST_ROOT/fs.img"
LOG_DIR="$TEST_ROOT/log"
BACKUP_DIR="$TEST_ROOT/backup"

TOTAL_TESTS=0
PASSED_TESTS=0

if [[ ! -x "$MAIN_SCRIPT" ]]; then
    if [[ -f "$MAIN_SCRIPT" ]]; then
        chmod +x "$MAIN_SCRIPT"
    else
        echo "Error: executable script not found: $MAIN_SCRIPT" >&2
        exit 1
    fi
fi

if ! command -v fuse2fs >/dev/null 2>&1; then
    echo "Error: fuse2fs utility not found. Please install e2fsprogs." >&2
    exit 2
fi

cleanup() {
    cd /tmp
    if mountpoint -q "$LOG_DIR" 2>/dev/null; then
        fusermount -u -z "$LOG_DIR" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

setup_fs() {
    cleanup
    mkdir -p "$LOG_DIR" "$BACKUP_DIR"
    truncate -s 700M "$IMG_FILE"
    mkfs.ext4 -q -F -O ^has_journal -E "root_owner=$(id -u):$(id -g)" "$IMG_FILE"
    fuse2fs "$IMG_FILE" "$LOG_DIR"

    local retries=0
    while ! mountpoint -q "$LOG_DIR" && (( retries < 20 )); do
        sleep 0.05
        retries=$((retries + 1))
    done

    rmdir "$LOG_DIR/lost+found" 2>/dev/null || true
}

record_result() {
    local test_name="$1"
    local status="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if (( status == 0 )); then
        echo "[PASS] $test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo "[FAIL] $test_name"
    fi
}

run_test_1() {
    local test_name="Test 1: Usage below threshold - files untouched, no archive created"
    setup_fs

    fallocate -l 260M "$LOG_DIR/log1.log"
    fallocate -l 260M "$LOG_DIR/log2.log"

    "$MAIN_SCRIPT" "$LOG_DIR" 90 "$BACKUP_DIR" >/dev/null 2>&1
    local ret=$?

    local files_count backups_count
    files_count=$(find "$LOG_DIR" -type f 2>/dev/null | wc -l)
    backups_count=$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l)

    if (( ret == 0 && files_count == 2 && backups_count == 0 )); then
        record_result "$test_name" 0
    else
        record_result "$test_name" 1
    fi
}

run_test_2() {
    local test_name="Test 2: Threshold exceeded - oldest files archived and removed"
    setup_fs

    fallocate -l 180M "$LOG_DIR/old.log"
    touch -d "3 days ago" "$LOG_DIR/old.log"

    fallocate -l 180M "$LOG_DIR/mid.log"
    touch -d "2 days ago" "$LOG_DIR/mid.log"

    fallocate -l 180M "$LOG_DIR/new.log"
    touch -d "1 day ago" "$LOG_DIR/new.log"

    "$MAIN_SCRIPT" "$LOG_DIR" 60 "$BACKUP_DIR" >/dev/null 2>&1
    local ret=$?

    local archive
    archive=$(find "$BACKUP_DIR" -type f -name "*.tar.gz" 2>/dev/null | head -n 1)

    if (( ret == 0 )) && \
       [[ ! -f "$LOG_DIR/old.log" ]] && \
       [[ -f "$LOG_DIR/mid.log" ]] && \
       [[ -f "$LOG_DIR/new.log" ]] && \
       [[ -n "$archive" ]]; then
        record_result "$test_name" 0
    else
        record_result "$test_name" 1
    fi
}

run_test_3() {
    local test_name="Test 3: Boundary threshold value THRESHOLD=0% (full purge)"
    setup_fs

    fallocate -l 260M "$LOG_DIR/data1.log"
    touch -d "2 days ago" "$LOG_DIR/data1.log"
    fallocate -l 260M "$LOG_DIR/data2.log"
    touch -d "1 day ago" "$LOG_DIR/data2.log"

    "$MAIN_SCRIPT" "$LOG_DIR" 0 "$BACKUP_DIR" >/dev/null 2>&1
    local ret=$?

    local remaining_files archive
    remaining_files=$(find "$LOG_DIR" -type f 2>/dev/null | wc -l)
    archive=$(find "$BACKUP_DIR" -type f -name "*.tar.gz" 2>/dev/null | head -n 1)

    if (( ret == 0 && remaining_files == 0 )) && [[ -n "$archive" ]]; then
        record_result "$test_name" 0
    else
        record_result "$test_name" 1
    fi
}

run_test_4() {
    local test_name="Test 4: Invalid arguments validation"
    setup_fs

    local status=0

    "$MAIN_SCRIPT" >/dev/null 2>&1 && status=1
    "$MAIN_SCRIPT" "$LOG_DIR" "abc" "$BACKUP_DIR" >/dev/null 2>&1 && status=1
    "$MAIN_SCRIPT" "$LOG_DIR" -10 "$BACKUP_DIR" >/dev/null 2>&1 && status=1
    "$MAIN_SCRIPT" "$LOG_DIR" 101 "$BACKUP_DIR" >/dev/null 2>&1 && status=1
    "$MAIN_SCRIPT" "/tmp/non_existent_dir_$(date +%s)" 50 "$BACKUP_DIR" >/dev/null 2>&1 && status=1

    record_result "$test_name" "$status"
}

run_test_5() {
    local test_name="Test 5: Maximum compression with LZMA (LAB1_MAX_COMPRESSION=1)"
    setup_fs

    fallocate -l 270M "$LOG_DIR/pack1.log"
    touch -d "2 days ago" "$LOG_DIR/pack1.log"
    fallocate -l 270M "$LOG_DIR/pack2.log"
    touch -d "1 day ago" "$LOG_DIR/pack2.log"

    export LAB1_MAX_COMPRESSION=1
    "$MAIN_SCRIPT" "$LOG_DIR" 50 "$BACKUP_DIR" >/dev/null 2>&1
    local ret=$?
    unset LAB1_MAX_COMPRESSION

    local archive
    archive=$(find "$BACKUP_DIR" -type f -name "*.tar.lzma" 2>/dev/null | head -n 1)

    if (( ret == 0 )) && [[ -n "$archive" ]] && tar --lzma -tf "$archive" >/dev/null 2>&1; then
        record_result "$test_name" 0
    else
        record_result "$test_name" 1
    fi
}

echo "Running Test Suite..."
run_test_1
run_test_2
run_test_3
run_test_4
run_test_5

echo "======================================="
echo "Summary: $PASSED_TESTS of $TOTAL_TESTS tests passed."

if (( PASSED_TESTS == TOTAL_TESTS )); then
    exit 0
else
    exit 1
fi
