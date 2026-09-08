#!/usr/bin/env bash
# =============================================================================
# tvh-recording-retention
# Version: 1.1 (2026-09-07)
# Purpose: Tvheadend recording cleanup script (Keep Days + Keep Last Count)
#          + removes orphaned DVR log entries (fixes stale entries in
#            TVHadmin-JS after a recording file has been deleted)
#
# Author:    Speefak
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
CONFIG_FILE="/var/lib/tvheadend/tvh-recording-retention.conf"
LOGFILE="/var/log/tvh-recording-retention.log"
TVH_SERVICE="tvheadend"

# DVR log directory is auto-detected via locate (see detect_dvr_log_dir)
DVR_LOG_DIR=""

# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Functions
# ────────────────────────────────────────────────────────────────────────────────────────────────────

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options can be combined, e.g.: $0 -r -o -l"
    echo "Processing order is always: -r, then -o, then -e/-s/-l"
    echo "  -r   Run cleanup (delete recordings)"
    echo "  -o   Clean up orphaned DVR entries"
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
# tvh-recording-retention.conf
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
edit_config() { echo "Opening config..."; sudo nano "$CONFIG_FILE"; }
# ────────────────────────────────────────────────────────────────────────────────────────────────────
show_config() { echo "=== Config ==="; cat "$CONFIG_FILE" 2>/dev/null || echo "Not found"; }
# ────────────────────────────────────────────────────────────────────────────────────────────────────
list_records() {
    echo "=== Recordings ==="
    OUTPUT=$(sudo -u hts bash -c "
        cd '$RECORDINGS_BASE' 2>/dev/null || exit 1
        find . -type f \( -name '*.ts' -o -name '*.mkv' -o -name '*.mp4' \) -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n'
    " 2>/dev/null)
    
    echo "$OUTPUT" | numfmt --field=3 --to=si --format="%.2f" | awk '{ $3=$3"B"; print }' | sed 's/\.[0-9]\{10\}//g' | sed 's/GB \.\// GB -> /g'
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Auto-detect the Tvheadend DVR log directory (holds one JSON file per
# finished/removed recording, containing the "filename" field).
# Uses locate, extracts everything up to and including "tvheadend/dvr/log".
# ────────────────────────────────────────────────────────────────────────────────────────────────────
detect_dvr_log_dir() {
    local hit
    hit=$(locate "/tvheadend/dvr/log/" 2>/dev/null | head -n 1)

    if [ -z "$hit" ]; then
        echo "WARNING: Could not auto-detect DVR log directory via locate (updatedb run recently?)." | tee -a "$LOGFILE"
        DVR_LOG_DIR=""
        return 1
    fi

    DVR_LOG_DIR=$(echo "$hit" | grep -oP '.*tvheadend/dvr/log')

    if [ -z "$DVR_LOG_DIR" ] || [ ! -d "$DVR_LOG_DIR" ]; then
        echo "WARNING: Detected DVR log path invalid: '$DVR_LOG_DIR'" | tee -a "$LOGFILE"
        DVR_LOG_DIR=""
        return 1
    fi

    echo "DVR log directory detected: $DVR_LOG_DIR" | tee -a "$LOGFILE"
    return 0
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Remove the DVR log entry (JSON file) belonging to a deleted recording file,
# so Tvheadend / TVHadmin-JS no longer show an orphaned "finished" entry.
# ────────────────────────────────────────────────────────────────────────────────────────────────────
remove_dvr_entry() {
    local file="$1"

    if [ -z "$DVR_LOG_DIR" ]; then
        return 1
    fi

    local entry_file
    entry_file=$(sudo -u hts grep -l "\"filename\":\"$file\"" "$DVR_LOG_DIR"/* 2>/dev/null | head -n1)

    if [ -n "$entry_file" ]; then
        rm -f "$entry_file"
        echo "    DVR entry removed: $entry_file" | tee -a "$LOGFILE"
        DVR_ENTRY_REMOVED=1
        return 0
    else
        echo "    WARNING: No DVR entry found for $file" | tee -a "$LOGFILE"
        return 1
    fi
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Scan ALL existing DVR log entries and remove any whose recording file no
# longer exists on disk (covers entries orphaned before this script's
# file-deletion hook existed, e.g. manually deleted recordings).
# ────────────────────────────────────────────────────────────────────────────────────────────────────
scan_orphaned_dvr_entries() {
    if [ -z "$DVR_LOG_DIR" ]; then
        return
    fi

    echo "Scanning for orphaned DVR entries (recording file no longer exists)..." | tee -a "$LOGFILE"

    for entry in "$DVR_LOG_DIR"/*; do
        [ -f "$entry" ] || continue

        local fname
        fname=$(sudo -u hts grep -oP '"filename"\s*:\s*"\K[^"]+' "$entry" 2>/dev/null | head -n1)
        [ -z "$fname" ] && continue

        # filename may be stored as absolute path or relative to RECORDINGS_BASE
        if [ -f "$fname" ] || [ -f "$RECORDINGS_BASE/$fname" ]; then
            continue
        fi

        echo "    Orphaned entry (file missing): $entry -> $fname" | tee -a "$LOGFILE"
        rm -f "$entry"
        DVR_ENTRY_REMOVED=1
    done
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Main program
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Run the config-based recording cleanup (formerly the -r main body).
# Uses 'return' instead of 'exit' so it can be combined with other options.
# ────────────────────────────────────────────────────────────────────────────────────────────────────
run_cleanup() {
    [ ! -f "$CONFIG_FILE" ] && create_default_config
    [ ! -d "$RECORDINGS_BASE" ] && { echo "ERROR: Recording directory not found!"; return 1; }

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
        return 0
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
            return 0
        fi
    done

    echo -e "\n\nStarting deletion...\n"

    for file in "${FILES_TO_DELETE[@]}"; do
        if [ -f "$file" ]; then
            echo "Deleting: $file" | tee -a "$LOGFILE"
            remove_dvr_entry "$file"
            rm -f "$file"
        fi
    done

    echo "=== Cleanup finished: $(date) ===" | tee -a "$LOGFILE"
    echo "Successfully deleted ${#FILES_TO_DELETE[@]} files."
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Main program
# ────────────────────────────────────────────────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then show_usage; fi

while getopts ":oreslh" opt; do
    case $opt in
        r) RUN_CLEANUP=1 ;;
        o) RUN_ORPHAN=1 ;;
        e) DO_EDIT=1 ;;
        s) DO_SHOW=1 ;;
        l) DO_LIST=1 ;;
        h) DO_HELP=1 ;;
        \?) echo "Invalid option"; show_usage ;;
    esac
done

[ "${DO_HELP:-0}" -eq 1 ] && show_usage

if [ "${RUN_CLEANUP:-0}" -ne 1 ] && [ "${RUN_ORPHAN:-0}" -ne 1 ] && \
   [ "${DO_EDIT:-0}" -ne 1 ] && [ "${DO_SHOW:-0}" -ne 1 ] && [ "${DO_LIST:-0}" -ne 1 ]; then
    echo "Error: No valid option given"
    show_usage
fi

# -r and -o need root (log file, hts-owned files, service restart)
if { [ "${RUN_CLEANUP:-0}" -eq 1 ] || [ "${RUN_ORPHAN:-0}" -eq 1 ]; } && [ "$EUID" -ne 0 ]; then
    echo "ERROR: -r/-o must be run as root (sudo $0 ...)."
    exit 1
fi

DVR_ENTRY_REMOVED=0

if [ "${RUN_CLEANUP:-0}" -eq 1 ] || [ "${RUN_ORPHAN:-0}" -eq 1 ]; then
    echo "=== Tvheadend Storage Cleanup started: $(date) ===" | tee -a "$LOGFILE"
    detect_dvr_log_dir
fi

# Fixed order: 1) delete recordings (-r), 2) clean orphaned DVR entries (-o),
# 3) remaining options (-e, -s, -l) in that order.
[ "${RUN_CLEANUP:-0}" -eq 1 ] && run_cleanup
[ "${RUN_ORPHAN:-0}" -eq 1 ]  && scan_orphaned_dvr_entries

if [ "${RUN_CLEANUP:-0}" -eq 1 ] || [ "${RUN_ORPHAN:-0}" -eq 1 ]; then
    if [ "$DVR_ENTRY_REMOVED" -eq 1 ]; then
        echo "Restarting $TVH_SERVICE to refresh DVR entries..." | tee -a "$LOGFILE"
        sudo systemctl restart "$TVH_SERVICE"
    fi
    echo "=== Done: $(date) ===" | tee -a "$LOGFILE"
fi

[ "${DO_EDIT:-0}" -eq 1 ] && edit_config
[ "${DO_SHOW:-0}" -eq 1 ] && show_config
[ "${DO_LIST:-0}" -eq 1 ] && list_records

exit 0
# ────────────────────────────────────────────────────────────────────────────────────────────────────
