#!/usr/bin/env bash
# =============================================================================
# tvh-recording-retention
# Version: 1.0 (2026-03-27)
# Purpose: Tvheadend recording cleanup script (Keep Days + Keep Last Count)
#
# Author:    itoss (itoss@gmx.de)
# License:   CC BY-NC
#
# Options:
#   -r   Run cleanup (delete files)
#   -e   Edit config file (nano)
#   -s   Show config file
#   -l   List all recordings
#   -c   Setup cron job
#   -h   Show this help
#
# Without any option → show help
# =============================================================================

RECORDINGS_BASE="/mnt/fstab_virtiofs_tvh-storage/recordings"
CONFIG_FILE="/var/lib/tvheadend/tvh-storage-cleanup.conf"
LOGFILE="/var/log/tvh-storage-cleanup.log"

# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Functions
# ────────────────────────────────────────────────────────────────────────────────────────────────────

show_usage() {
    echo "Usage: $0 [OPTION]"
    echo "  -r   Run cleanup"
    echo "  -e   Edit config file"
    echo "  -s   Show config file"
    echo "  -l   List all recordings"
    echo "  -h   Show help"
    exit 1
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
create_default_config() {
    echo "Creating default config..." | tee -a "$LOGFILE"
    cat > "$CONFIG_FILE" << 'EOF'    
# =============================================================================
# tvh-storage-cleanup.conf
# Format: <Recording Name> <keep_days> <keep_count>
#
# keep_days = 0  → Disable deletion by age
# keep_count = 0 → Disable "keep only last X" (when keep_day=0)
# =============================================================================
Tagesschau              3    0
Tagesthemen             3    0
Tatort                  0    5
Polizeiruf 110          0    5
Spacetime               0    0
EOF
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
edit_config() { echo "Opening config..."; sudo nano "$CONFIG_FILE"; exit 0; }
# ────────────────────────────────────────────────────────────────────────────────────────────────────
show_config() { echo "=== Config ==="; cat "$CONFIG_FILE" 2>/dev/null || echo "Not found"; exit 0; }
# ────────────────────────────────────────────────────────────────────────────────────────────────────
list_records() {
    echo "=== Recordings ==="
    OUTPUT=$(sudo -u hts bash -c "
        cd '$RECORDINGS_BASE' 2>/dev/null || exit 1
        find . -type f \( -name '*.ts' -o -name '*.mkv' -o -name '*.mp4' \) -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n'
    " 2>/dev/null)
    
    echo "$OUTPUT" | numfmt --field=3 --to=si --format="%.2f" | awk '{ $3=$3"B"; print }' | sed 's/\.[0-9]\{10\}//g' | sed 's/GB \.\// GB -> /g'

    exit 0
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Main program
# ────────────────────────────────────────────────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then show_usage; fi

while getopts ":reslh" opt; do
    case $opt in
        r) RUN_CLEANUP=1 ;;
        e) edit_config ;;
        s) show_config ;;
        l) list_records ;;
        h) show_usage ;;
        \?) echo "Invalid option"; show_usage ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────────────────────────────

if [ "${RUN_CLEANUP:-0}" -ne 1 ]; then
    echo "Error: Use -r to run cleanup"
    exit 1
fi

echo "=== Tvheadend Storage Cleanup started: $(date) ===" | tee -a "$LOGFILE"

[ ! -f "$CONFIG_FILE" ] && create_default_config
[ ! -d "$RECORDINGS_BASE" ] && { echo "ERROR: Recording directory not found!"; exit 1; }

declare -a FILES_TO_DELETE=()
TOTAL_SIZE=0

echo "Reading config and searching for files to delete..."

while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    line=$(echo "$line" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$line" ] && continue

    KEEP_COUNT=$(echo "$line" | awk '{print $NF}')
    KEEP_DAYS=$(echo "$line" | awk '{print $(NF-1)}')
    recording=$(echo "$line" | awk '{for(i=1; i<NF-1; i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')

    if [[ -z "$recording" ]]; then
        echo "WARNING: Could not parse line: $line" | tee -a "$LOGFILE"
        continue
    fi

    echo "Processing: '$recording' → Days: $KEEP_DAYS | Keep last: $KEEP_COUNT" | tee -a "$LOGFILE"

    # 1. Delete by age
    if [ "$KEEP_DAYS" -gt 0 ]; then
        while IFS= read -r -d '' file; do
            FILES_TO_DELETE+=("$file")
            size=$(stat -c %s "$file" 2>/dev/null || echo 0)
            TOTAL_SIZE=$((TOTAL_SIZE + size))
            echo "    Marked (age): $file" | tee -a "$LOGFILE"
        done < <(
            find "$RECORDINGS_BASE" -type f \( -name "*.ts" -o -name "*.mkv" -o -name "*.mp4" \) \
                 -iname "*${recording}*" -mtime +"$KEEP_DAYS" -print0
        )
    fi

    # 2. Keep only last X files
    if [ "$KEEP_COUNT" -gt 0 ]; then
        FILELIST=$(mktemp)

        find "$RECORDINGS_BASE" -type f \( -name "*.ts" -o -name "*.mkv" -o -name "*.mp4" \) \
             -iname "*${recording}*" -printf '%T@ %p\n' | sort -nr > "$FILELIST"

        while read -r ts file; do
            if ! printf '%s\n' "${FILES_TO_DELETE[@]}" | grep -Fxq "$file"; then
                FILES_TO_DELETE+=("$file")
                size=$(stat -c %s "$file" 2>/dev/null || echo 0)
                TOTAL_SIZE=$((TOTAL_SIZE + size))
                echo "    Marked (count limit): $file" | tee -a "$LOGFILE"
            fi
        done < <(
            tail -n +$((KEEP_COUNT + 1)) "$FILELIST"
        )

        rm -f "$FILELIST"
    fi

done < "$CONFIG_FILE"

# ────────────────────────────────────────────────────────────────────────────────────────────────────
# summary output, 10 sec delete cancel mode before deleting files
# ────────────────────────────────────────────────────────────────────────────────────────────────────
echo "───────────────────────────────────────────────────────────────────────────────────────────"
echo "=== Summary ==="
echo "───────────────────────────────────────────────────────────────────────────────────────────"

if [ ${#FILES_TO_DELETE[@]} -eq 0 ]; then
    echo "No files found to delete."
    echo "→ Check if the recording names in config match parts of your filenames."
    echo "→ Try running: $0 -l"
    exit 0
fi

for file in "${FILES_TO_DELETE[@]}"; do
    if [ -f "$file" ]; then
        size=$(stat -c %s "$file" 2>/dev/null || echo 0)
        size_mb=$((size / 1024 / 1024))
        printf '%8s MB  %s\n' "$size_mb" "$file"
    fi
done

echo "───────────────────────────────────────────────────────────────────────────────────────────"
echo "Total files : ${#FILES_TO_DELETE[@]}"
echo "Total size  : $((TOTAL_SIZE / 1024 / 1024)) MB"
echo "───────────────────────────────────────────────────────────────────────────────────────────"
echo ""

for i in {10..1}; do
    echo -ne " → Deletion in $i seconds... (any key = cancel) \r"
    read -t 1 -n 1 -s key 2>/dev/null
    if [[ -n "$key" ]]; then
        echo -e "\n\nDeletion aborted by user."
        exit 0
    fi
done

echo -e "\n\nStarting deletion...\n"

for file in "${FILES_TO_DELETE[@]}"; do
    if [ -f "$file" ]; then
        echo "Deleting: $file" | tee -a "$LOGFILE"
        rm -f "$file"
    fi
done

echo "=== Cleanup finished: $(date) ===" | tee -a "$LOGFILE"
echo "Successfully deleted ${#FILES_TO_DELETE[@]} files."

# ────────────────────────────────────────────────────────────────────────────────────────────────────
