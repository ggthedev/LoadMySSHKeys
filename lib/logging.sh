#!/usr/bin/env bash
# Library for logging functions for sshkeymanager.sh

# Ensure this script is sourced, not executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "This script should be sourced, not executed directly." >&2
    exit 1
fi

# --- Logging Functions ---

# Depends on global variables: SKM_LOG_DIR, PLATFORM, LOG_DIR_MACOS,
#             LOG_DIR_LINUX_VAR, LOG_DIR_LINUX_LOCAL, LOG_DIR_FALLBACK,
#             LOG_FILENAME, IS_VERBOSE, STAT_CMD, LOG_DIR, LOG_FILE.
# Expects these to be set by the main script before setup_logging is called.

# --- setup_logging ---
# ... (description omitted for brevity)
setup_logging() {
    local max_log_size=1048576  # Max log size in bytes (1MB).
    local max_log_files=5       # Number of rotated log files to keep (e.g., .1, .2, ..., .5).

    # Determine LOG_DIR based on environment override or platform defaults.
    if [ -n "${SKM_LOG_DIR:-}" ]; then
         LOG_DIR="$SKM_LOG_DIR"
    else
        case "$PLATFORM" in
            "Darwin")
                LOG_DIR="$LOG_DIR_MACOS"
                ;;
            "Linux")
                if [ -w "$LOG_DIR_LINUX_VAR" ] 2>/dev/null; then
                     LOG_DIR="$LOG_DIR_LINUX_VAR"
                else
                     LOG_DIR="$LOG_DIR_LINUX_LOCAL"
                fi
                ;;
            *)
                LOG_DIR="$LOG_DIR_FALLBACK"
                ;;
        esac
    fi

    local initial_log_dir="$LOG_DIR"

    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf "Warning: Could not create log directory '$initial_log_dir'. Trying fallback '$LOG_DIR_FALLBACK'.\\n" >&2
        LOG_DIR="$LOG_DIR_FALLBACK"
        if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
            printf "Warning: Could not create fallback log directory. Logging disabled.\\n" >&2
            LOG_FILE="/dev/null"
            return 1
        fi
         printf "Warning: Using fallback log directory '$LOG_DIR'.\\n" >&2
    fi

    LOG_FILE="${LOG_DIR}/${LOG_FILENAME}"

    if ! touch "$LOG_FILE" 2>/dev/null; then
        printf "Warning: Could not create log file '%s'. Logging disabled.\\n" "$LOG_FILE" >&2
        LOG_FILE="/dev/null"
        return 1
    fi

    if [ -f "$LOG_FILE" ]; then
        local log_size
        if ! log_size=$($STAT_CMD "$LOG_FILE" 2>/dev/null); then
            printf "Warning: Could not determine size of log file '%s'. Log rotation skipped.\\n" "$LOG_FILE" >&2
        elif [ "$log_size" -gt "$max_log_size" ]; then
            if [ "$IS_VERBOSE" = "true" ]; then
                log_debug "Rotating logs (size $log_size > $max_log_size)..."
            fi
            for i in $(seq $((max_log_files-1)) -1 1); do
                [ -f "${LOG_FILE}.${i}" ] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))" 2>/dev/null || true
            done
            mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
            touch "$LOG_FILE" 2>/dev/null || printf "Warning: Failed to create new log file after rotation: %s\\n" "$LOG_FILE" >&2
        fi
    fi

    chmod 600 "$LOG_FILE" 2>/dev/null || printf "Warning: Could not set permissions (600) on log file: %s\\n" "$LOG_FILE" >&2

    log_debug "Logging setup complete. LOG_FILE set to: $LOG_FILE"
    return 0
} # END setup_logging

# --- _log_marker ---
_log_marker() {
    local marker_text="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ "$LOG_FILE" == "/dev/null" ]]; then
        printf "%s - %s - MARKER: %s\n" "$timestamp" "$$" "$marker_text" >&2
    else
        echo "$timestamp - $$ - MARKER: $marker_text" >> "$LOG_FILE"
    fi
}

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - INFO: $1" >> "$LOG_FILE"
    fi
}

log_error() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - ERROR: $1" >> "$LOG_FILE"
        printf "An error occurred. See log for details: %s\\n" "$LOG_FILE" >&2
    else
        printf "An error occurred. (Logging disabled)\\n" >&2
    fi
}

log_warn() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - WARN: $1" >> "$LOG_FILE"
        printf "A warning occurred. See log for details: %s\\n" "$LOG_FILE" >&2
    else
        printf "A warning occurred. (Logging disabled)\\n" >&2
    fi
}

log_debug() {
    [ "$IS_VERBOSE" = "true" ] || return 0
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - DEBUG: $1" >> "$LOG_FILE"
    fi
}

log_info() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - INFO: $1" >> "$LOG_FILE"
    fi
} 