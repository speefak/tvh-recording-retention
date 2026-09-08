#!/usr/bin/env bash
# =============================================================================
# tvh-storage-cleanup
# Version: 1.2 (2026-09-08)
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
CONFIG_FILE="/var/lib/tvheadend/tvh-storage-cleanup.conf"
LOGFILE="/var/log/tvh-storage-cleanup.log"
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
    echo "  -t   Test/diagnose current busy status only (no changes made)"
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
# Check whether Tvheadend is currently "busy" (active recording and/or
# active client stream) — used to decide whether a service restart is safe.
# No API / login needed:
#   1) recording check: any recording file actually written to recently
#      (mtime-based — independent of any assumed DVR-log JSON field/value,
#      which turned out to be unreliable)
#   2) physical tuner check: any DVB frontend device currently held open
#   3) traffic check: real network throughput of the tvheadend process
#      itself, measured via nethogs — not tied to any specific port/
#      protocol, and not just "a connection exists" (Kodi/HTSP clients
#      keep an idle connection open even when nothing is playing)
# ────────────────────────────────────────────────────────────────────────────────────────────────────
tvh_busy() {
    echo "  [check] Checking recording activity in $RECORDINGS_BASE ..." | tee -a "$LOGFILE"
    # 1) Any recording currently being written to disk?
    if find "$RECORDINGS_BASE" -type f \( -name '*.ts' -o -name '*.mkv' -o -name '*.mp4' \) \
         -newermt '-15 seconds' 2>/dev/null | grep -q .; then
        echo "    Busy: a recording file was modified in the last 15s (active recording)." | tee -a "$LOGFILE"
        return 0
    fi

    # 2) Any DVB frontend currently opened by a process?
    local fe found_fe=0
    for fe in /dev/dvb/adapter*/frontend*; do
        [ -e "$fe" ] || continue
        found_fe=1
        echo "  [check] Checking frontend $fe ..." | tee -a "$LOGFILE"
        if fuser "$fe" >/dev/null 2>&1; then
            echo "    Busy: frontend $fe currently in use." | tee -a "$LOGFILE"
            return 0
        fi
    done
    [ "$found_fe" -eq 0 ] && echo "  [check] No DVB frontend devices found on this system." | tee -a "$LOGFILE"

    # 3) Real network traffic caused by the tvheadend process itself
    # (covers HTSP, HTTP streaming, RTSP, whatever protocol is in use —
    # measured per-process instead of per-connection/-port).
    if command -v nethogs >/dev/null 2>&1; then
        if check_tvh_process_traffic; then
            echo "    Busy: tvheadend process is actively sending/receiving data (live stream)." | tee -a "$LOGFILE"
            return 0
        fi
    else
        echo "    WARNING: 'nethogs' not installed — cannot verify live traffic, assuming busy to be safe." | tee -a "$LOGFILE"
        return 0
    fi

    return 1
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Measure the tvheadend process' own network throughput via nethogs' batch/
# trace mode ("-t"), which prints "<program>/<pid>/<uid>\t<sent_KBps>\t<recv_KBps>"
# lines per refresh cycle. Real client traffic (unlike an idle HTSP/EPG
# connection) shows up here as continuous non-zero KB/s. Returns 0 (true) if
# any refresh cycle shows tvheadend sending or receiving above the threshold.
# ────────────────────────────────────────────────────────────────────────────────────────────────────
check_tvh_process_traffic() {
    local threshold_kbps=50
    local iface output prog sent recv

    iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
    if [ -z "$iface" ]; then
        echo "  [check] Could not auto-detect network interface for nethogs." | tee -a "$LOGFILE"
        return 1
    fi
    echo "  [check] Measuring tvheadend traffic on interface '$iface' via nethogs..." | tee -a "$LOGFILE"

    output=$(timeout 6 nethogs -t -c 3 "$iface" 2>/dev/null)

    while IFS=$'\t' read -r prog sent recv; do
        [[ "$prog" == *"tvheadend"* ]] || continue
        echo "  [check] nethogs: $prog sent=${sent:-0} KB/s recv=${recv:-0} KB/s" | tee -a "$LOGFILE"
        if awk -v s="${sent:-0}" -v r="${recv:-0}" -v t="$threshold_kbps" 'BEGIN{exit !(s>t || r>t)}'; then
            return 0
        fi
    done <<< "$output"

    return 1
}
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Main program
# ────────────────────────────────────────────────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then show_usage; fi

while getopts ":oreslht" opt; do
    case $opt in
        r) RUN_CLEANUP=1 ;;
        o) RUN_ORPHAN=1 ;;
        t) DO_TEST=1 ;;
        e) DO_EDIT=1 ;;
        s) DO_SHOW=1 ;;
        l) DO_LIST=1 ;;
        h) DO_HELP=1 ;;
        \?) echo "Invalid option"; show_usage ;;
    esac
done

[ "${DO_HELP:-0}" -eq 1 ] && show_usage

if [ "${RUN_CLEANUP:-0}" -ne 1 ] && [ "${RUN_ORPHAN:-0}" -ne 1 ] && [ "${DO_TEST:-0}" -ne 1 ] && \
   [ "${DO_EDIT:-0}" -ne 1 ] && [ "${DO_SHOW:-0}" -ne 1 ] && [ "${DO_LIST:-0}" -ne 1 ]; then
    echo "Error: No valid option given"
    show_usage
fi

# -r, -o and -t need root (log file, hts-owned files, fuser/ss, service restart)
if { [ "${RUN_CLEANUP:-0}" -eq 1 ] || [ "${RUN_ORPHAN:-0}" -eq 1 ] || [ "${DO_TEST:-0}" -eq 1 ]; } && [ "$EUID" -ne 0 ]; then
    echo "ERROR: -r/-o/-t must be run as root (sudo $0 ...)."
    exit 1
fi

DVR_ENTRY_REMOVED=0

if [ "${RUN_CLEANUP:-0}" -eq 1 ] || [ "${RUN_ORPHAN:-0}" -eq 1 ] || [ "${DO_TEST:-0}" -eq 1 ]; then
    [ "${DO_TEST:-0}" -ne 1 ] && echo "=== Tvheadend Storage Cleanup started: $(date) ===" | tee -a "$LOGFILE"
    detect_dvr_log_dir
fi

if [ "${DO_TEST:-0}" -eq 1 ]; then
    echo "Checking current busy status (no changes will be made)..."
    if tvh_busy; then
        echo "Status: BUSY — a restart would be skipped right now."
    else
        echo "Status: IDLE — a restart would proceed right now."
    fi
fi

# Fixed order: 1) delete recordings (-r), 2) clean orphaned DVR entries (-o),
# 3) remaining options (-e, -s, -l) in that order.
[ "${RUN_CLEANUP:-0}" -eq 1 ] && run_cleanup
[ "${RUN_ORPHAN:-0}" -eq 1 ]  && scan_orphaned_dvr_entries

if [ "${RUN_CLEANUP:-0}" -eq 1 ] || [ "${RUN_ORPHAN:-0}" -eq 1 ]; then
    if [ "$DVR_ENTRY_REMOVED" -eq 1 ]; then
        if tvh_busy; then
            echo "Skipping $TVH_SERVICE restart: active recording or stream in progress. Will retry next run." | tee -a "$LOGFILE"
        else
            echo "Restarting $TVH_SERVICE to refresh DVR entries..." | tee -a "$LOGFILE"
            sudo systemctl restart "$TVH_SERVICE"
        fi
    fi
    echo "=== Done: $(date) ===" | tee -a "$LOGFILE"
fi

[ "${DO_EDIT:-0}" -eq 1 ] && edit_config
[ "${DO_SHOW:-0}" -eq 1 ] && show_config
[ "${DO_LIST:-0}" -eq 1 ] && list_records

exit 0
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# Changelog
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# 1.2 (2026-09-08)
#   - Restart-check output ([check] lines: recording activity, frontend
#     status, nethogs traffic measurement) is now always printed and logged,
#     not just in -t mode.
#
# 1.1 (2026-09-07)
#   - Author changed to Speefak.
#   - Auto-detect the Tvheadend DVR log directory via 'locate' instead of a
#     hardcoded path.
#   - remove_dvr_entry(): removes the matching DVR log entry whenever the
#     cleanup deletes a recording file, so it no longer shows up as orphaned
#     in TVHadmin-JS.
#   - scan_orphaned_dvr_entries(): sweeps ALL DVR log entries and removes any
#     whose recording file no longer exists (covers entries orphaned before
#     this script's deletion hook existed).
#   - New -o option: run the orphaned-entry cleanup standalone.
#   - -r and -o (and -e/-s/-l) are now combinable in one call, always
#     processed in a fixed order: -r, then -o, then -e/-s/-l.
#   - Root check: -r/-o/-t now require root (log file, hts-owned files,
#     fuser/nethogs, service restart).
#   - tvh_busy(): guards the Tvheadend service restart so it's skipped while
#     the server is actually in use — checks (1) recording file activity via
#     mtime, (2) DVB frontend device in use via fuser, (3) real tvheadend
#     process network throughput via nethogs (an idle HTSP/EPG connection
#     alone no longer counts as "busy").
#   - New -t option: prints the current busy/idle status only, no changes
#     made — for diagnosing the restart-guard checks.
#
# 1.0 (2026-03-27)
#   - Initial version, config-based recording cleanup by keep-days
#     and keep-last-count.
# 
# v0.9 - 2025-03-28
# - First version with `Keep Days` and `Keep Last Count` rules.
# - Basic logic for identifying and marking files for deletion.
# - Initial error handling for missing directories.
# 
# v0.8 - 2025-03-20
# - Improved parsing logic for configuration file.
# - Better handling of comments and blank lines.
# - Optimized file list processing for deletion.
# 
# v0.7 - 2025-03-15
# - Introduced `Keep Days` and `Keep Last Count` functionality.
# - Improved output formatting and processing feedback.
# - Enhanced user guidance with `show_usage` function.
# 
# v0.5 - 2025-03-01
# - First implementation of `Keep Days` and `Keep Last Count`.
# - Basic script structure for TVH recording cleanup.
# - Initial configuration file support.
# 
# v0.4 - 2025-02-20
# - Standardized configuration file path.
# - Unified log file location.
# 
# v0.3 - 2025-02-10
# - Standardized configuration file path.
# - Unified log file location.
# 
# v0.2 - 2025-02-01
# - Updated `CONFIG_FILE` path to `/home/speefak/tvh-storage-cleanup.conf`.
# - Improved documentation and comments.
# 
# v0.1 - 2025-01-15
# - Initial version of the script.
# - Basic structure for cleaning up Tvheadend recordings.
# - Defined `RECORDINGS_BASE`, `CONFIG_FILE`, and `LOGFILE`.
# ────────────────────────────────────────────────────────────────────────────────────────────────────
