#!/usr/bin/env bash

set -euo pipefail

# функции
usage() {
    echo "Incorrect usage; Gotta be: $0 <log_dir> <threshold_percent> <backup_dir>"
    exit 1
}

error() {
    echo "Error: $*" >&2
    exit 1
}

(( $# == 3 )) || usage

LOG_DIR="$1"
THRESHOLD="$2"
BACKUP_DIR="$3"

[[ -d "$LOG_DIR" ]] || error "log directory does not exist: $LOG_DIR"

(( THRESHOLD == THRESHOLD + 0 )) 2>/dev/null || error "threshold must be an integer from 0 to 100"

(( THRESHOLD >= 0 && THRESHOLD <= 100 )) || error "threshold must be between 0 and 100"

mkdir -p "$BACKUP_DIR"

COMPRESSION="gzip"
ARCHIVE_SUFFIX="tar.gz"
TAR_COMPRESSION_OPTION="--gzip"

if [[ "${LAB1_MAX_COMPRESSION:-0}" == "1" ]]; then
    COMPRESSION="lzma"
    ARCHIVE_SUFFIX="tar.lzma"
    TAR_COMPRESSION_OPTION="--lzma"
fi

# подсчет размера логов 
{ read -r _; read -r _ TOTAL_KB _; } < <(df -P -k "$LOG_DIR")

read -r DIR_USED_KB _ < <(du -s -k "$LOG_DIR")

[[ -n "$TOTAL_KB" ]] || error "failed to get directory size"

USED_PERCENT=$(( DIR_USED_KB * 10000 / TOTAL_KB ))

USED_PERCENT_INT=$(( USED_PERCENT / 100 ))
USED_PERCENT_FRAC=$(( USED_PERCENT % 100 ))

echo "Directory : $LOG_DIR"
echo "Usage     : ${USED_PERCENT_INT}.${USED_PERCENT_FRAC}%"
echo "Threshold : ${THRESHOLD}%"
echo "Mode      : $COMPRESSION"


if (( USED_PERCENT <= THRESHOLD * 100 )); then
    echo "${USED_PERCENT_INT}.${USED_PERCENT_FRAC}\% <=${THRESHOLD}%; hence nothing to archive"
    exit 0
fi

echo "Threshold exceeded. Selecting oldest files..."


TARGET_USED_KB=$(( TOTAL_KB * THRESHOLD / 100 ))
NEEDED_FREE_KB=$(( DIR_USED_KB - TARGET_USED_KB ))

TMP_DIR=$(mktemp -d)

remove_temp_dir() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap remove_temp_dir EXIT # типа defer

FILE_LIST="$TMP_DIR/files"
SELECTED_LIST="$TMP_DIR/selected"

touch "$SELECTED_LIST"

# type f - искать только файлы, -printf `%T@ %p\0` - вывод формата <timestamp> <path><null-байт>
find "$LOG_DIR" -name "lost+found" -prune -o -type f -printf '%T@ %p\0' 2>/dev/null | sort --zero-terminated --numeric-sort > "$FILE_LIST"

SELECTED_SIZE_KB=0
SELECTED_COUNT=0

{
while IFS="" read -r -d '' FILE_DATA; do # -r - без экранирования, -d - разделитель нулевой байт
    FILE_PATH="${FILE_DATA#* }" # regex - берем то что после первого пробела

    read -r FILE_SIZE_KB _ < <(du -s -k -- "$FILE_PATH")

    RELATIVE_PATH="${FILE_PATH#"$LOG_DIR"/}"

    printf '%s\0' "$RELATIVE_PATH" >> "$SELECTED_LIST" # > - перезапись файла, >> - дозапись

    SELECTED_SIZE_KB=$(( SELECTED_SIZE_KB + FILE_SIZE_KB ))
    SELECTED_COUNT=$(( SELECTED_COUNT + 1 ))

    if (( SELECTED_SIZE_KB >= NEEDED_FREE_KB )); then
        break
    fi

done
 } < "$FILE_LIST"


if (( SELECTED_COUNT == 0 )); then # для защиты от кейса когда ос помечает файлы как удаленные но не удаляет
    error "no files available for archiving"
fi

echo "Selected  : $SELECTED_COUNT file(s)"
echo "Data      : ${SELECTED_SIZE_KB} KiB"

echo "Selected files to archive:"

{
    while IFS="" read -r -d '' RELATIVE_PATH; do
        echo "-$RELATIVE_PATH"
    done
} < "$SELECTED_LIST"


TARGET_ARCHIVE_NAME="${BACKUP_DIR}/archived.${ARCHIVE_SUFFIX}"
ARCHIVE_TEMP="${TMP_DIR}/archived.${ARCHIVE_SUFFIX}"

echo "Creating: $TARGET_ARCHIVE_NAME"

tar --create "$TAR_COMPRESSION_OPTION" \
    --file="$ARCHIVE_TEMP" \
    --directory="$LOG_DIR" \
    --null \
    --verbatim-files-from \
    --files-from="$SELECTED_LIST"

tar --list --file="$ARCHIVE_TEMP" >/dev/null

mv "$ARCHIVE_TEMP" "$TARGET_ARCHIVE_NAME"

echo "Archivated successfully"

{
while IFS= read -r -d '' RELATIVE_PATH; do
    rm -f "$LOG_DIR/$RELATIVE_PATH"
done 
}< "$SELECTED_LIST"