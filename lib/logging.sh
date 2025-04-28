#!/usr/bin/env bash
# ==============================================================================
# Library: logging.sh
# Description: Provides logging functions for the sshkeymanager.sh script.
#              Handles log file creation, rotation, and different log levels.
# Dependencies: Relies on several global variables set by the main script:
#                 - SKM_LOG_DIR: Optional environment variable override for log directory.
#                 - PLATFORM: OS type ("Darwin", "Linux", etc.) detected by main script.
#                 - LOG_DIR_MACOS, LOG_DIR_LINUX_VAR, LOG_DIR_LINUX_LOCAL, LOG_DIR_FALLBACK:
#                   Default platform-specific log directory paths.
#                 - LOG_FILENAME: Base name for the log file.
#                 - IS_VERBOSE: Flag ("true" or "false") indicating verbose mode.
#                 - STAT_CMD: Platform-specific command to get file size.
#                 - LOG_DIR: (Set by setup_logging) The final chosen log directory path.
#                 - LOG_FILE: (Set by setup_logging) The full path to the log file.
# ==============================================================================

# --- Safety Check ---
# Ensure this script is sourced, not executed directly. Protects against unintended execution.
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "Error: This script (logging.sh) should be sourced, not executed directly." >&2
    exit 1
fi

# ==============================================================================
# --- Logging Setup Function ---
# ==============================================================================

# --- setup_logging ---
#
# @description Initializes the logging system. Determines the log directory,
#              creates the log file if it doesn't exist, performs log rotation
#              if the file exceeds a size limit, and sets appropriate permissions.
#              Sets the global LOG_DIR and LOG_FILE variables.
# @arg        None
# @set        LOG_DIR Global variable with the determined log directory path.
# @set        LOG_FILE Global variable with the full path to the log file
#             (or /dev/null if logging setup fails).
# @return     0 If logging setup is successful.
# @return     1 If logging setup fails (e.g., cannot create log directory or file).
# @prints     Warning messages to stderr if directories/files cannot be created
#             or permissions cannot be set.
# @stdout     None
# @stderr     Warning messages.
# @depends    Global variables: SKM_LOG_DIR, PLATFORM, LOG_DIR_MACOS, LOG_DIR_LINUX_VAR,
#             LOG_DIR_LINUX_LOCAL, LOG_DIR_FALLBACK, LOG_FILENAME, IS_VERBOSE, STAT_CMD.
#             Functions: log_debug (conditionally, if IS_VERBOSE is true).
#             External commands: mkdir, printf, touch, mv, seq, chmod, date.
# ---
setup_logging() {
    # --- Configuration Variables ---
    local max_log_size=1048576  # Max log size in bytes (1 MiB). Rotation triggered above this.
    local max_log_files=5       # Number of rotated log files to keep (e.g., log.1, log.2, ..., log.5).

    # --- Determine Log Directory ---
    # Priority:
    # 1. Environment variable SKM_LOG_DIR.
    # 2. Platform-specific defaults.
    # 3. Fallback directory ($HOME/.ssh/logs).
    if [ -n "${SKM_LOG_DIR:-}" ]; then
         # Use environment variable if set and non-empty.
         LOG_DIR="$SKM_LOG_DIR"
         # log_debug cannot be called reliably yet, as LOG_FILE is not set.
         # Consider printing to stderr if verbose needed here.
         # printf "Debug: Using log directory from SKM_LOG_DIR: %s\n" "$LOG_DIR" >&2
    else
        # Determine directory based on OS platform.
        case "$PLATFORM" in
            "Darwin")
                LOG_DIR="$LOG_DIR_MACOS" # ~/Library/Logs/sshkeymanager
                ;;
            "Linux")
                # Prefer system-wide log if writable, otherwise user-local.
                if [ -w "$LOG_DIR_LINUX_VAR" ] 2>/dev/null; then
                     LOG_DIR="$LOG_DIR_LINUX_VAR" # /var/log/sshkeymanager
                else
                     LOG_DIR="$LOG_DIR_LINUX_LOCAL" # ~/.local/log/sshkeymanager
                fi
                ;;
            *)
                # Default for unknown platforms.
                LOG_DIR="$LOG_DIR_FALLBACK" # ~/.ssh/logs
                ;;
        esac
        # printf "Debug: Using platform default log directory: %s\n" "$LOG_DIR" >&2
    fi

    # --- Create Log Directory (with Fallback) ---
    local initial_log_dir="$LOG_DIR"
    local mkdir_status
    
    # Attempt to create the chosen log directory, capture status
    mkdir -p "$LOG_DIR"
    mkdir_status=$?
    # printf "DEBUG_TERM: mkdir status for initial LOG_DIR (%s): %s\n" "$LOG_DIR" "$mkdir_status" >&2 # DEBUG Removed

    # Check the captured status explicitly
    if [ "$mkdir_status" -ne 0 ]; then 
        local msg="Warning: Could not create log directory '$initial_log_dir' (Status: $mkdir_status). Trying fallback '$LOG_DIR_FALLBACK'."
        # Append warning to log file if possible, else print to stderr
        if [ -n "${LOG_FILE:-}" ] && [ "$LOG_FILE" != "/dev/null" ]; then printf "%s\n" "$msg" >> "$LOG_FILE"; else printf "%s\n" "$msg" >&2; fi
        LOG_DIR="$LOG_DIR_FALLBACK"
        
        # Attempt to create the fallback directory, capture status
        local mkdir_fallback_status
        mkdir -p "$LOG_DIR"
        mkdir_fallback_status=$?
        # printf "DEBUG_TERM: mkdir status for fallback LOG_DIR (%s): %s\n" "$LOG_DIR" "$mkdir_fallback_status" >&2 # DEBUG Removed

        if [ "$mkdir_fallback_status" -ne 0 ]; then 
            local msg2="Warning: Could not create fallback log directory '$LOG_DIR' (Status: $mkdir_fallback_status). Logging disabled."
            # Append warning to log file if possible, else print to stderr
            if [ -n "${LOG_FILE:-}" ] && [ "$LOG_FILE" != "/dev/null" ]; then printf "%s\n" "$msg2" >> "$LOG_FILE"; else printf "%s\n" "$msg2" >&2; fi
            LOG_FILE="/dev/null"
            return 1
        fi
        local msg3="Warning: Using fallback log directory '$LOG_DIR'."
        # Append warning to log file if possible, else print to stderr
        if [ -n "${LOG_FILE:-}" ] && [ "$LOG_FILE" != "/dev/null" ]; then printf "%s\n" "$msg3" >> "$LOG_FILE"; else printf "%s\n" "$msg3" >&2; fi
    fi

    # --- Set Log File Path ---
    LOG_FILE="${LOG_DIR}/${LOG_FILENAME}"

    # --- Create Log File (if needed) ---
    if ! touch "$LOG_FILE" 2>/dev/null; then
        local msg="Warning: Could not create log file '$LOG_FILE'. Logging disabled."
        # Print to stderr as LOG_FILE setup failed
        printf "%s\n" "$msg" >&2
        LOG_FILE="/dev/null"
        return 1
    fi

    # --- Log Rotation ---
    if [ -f "$LOG_FILE" ]; then
        local log_size
        if ! log_size=$($STAT_CMD "$LOG_FILE" 2>/dev/null); then
            local msg="Warning: Could not determine size of log file '$LOG_FILE'. Log rotation skipped."
            # Append warning to log file if possible
            if [ "$LOG_FILE" != "/dev/null" ]; then printf "%s\n" "$msg" >> "$LOG_FILE"; else printf "%s\n" "$msg" >&2; fi
        elif [ "$log_size" -gt "$max_log_size" ]; then
            # If log size exceeds the maximum, perform rotation.
            # Log rotation start only if verbose mode is enabled.
            # Note: log_debug might not work perfectly here if called *during* setup,
            # but we attempt it. A printf might be more reliable if issues arise.
            if [ "${IS_VERBOSE:-false}" = "true" ]; then
                 # Use printf as log_debug itself relies on LOG_FILE being fully set.
                 # If log_debug was defined *before* setup_logging, this would be okay.
                 local ts_rot; ts_rot=$(date '+%Y-%m-%d %H:%M:%S')
                 echo "$ts_rot - $$ - DEBUG: Rotating logs (size $log_size > $max_log_size)..." >> "$LOG_FILE.prerotate_debug" # Log to temp file during rotation
            fi
            # Rotate existing log files: log.4 -> log.5, log.3 -> log.4, ..., log.1 -> log.2
            # Loop from max_log_files-1 down to 1.
            local i
            for i in $(seq $((max_log_files-1)) -1 1); do
                # If the source rotated file exists, move it to the next number.
                # -f forces overwrite. Redirect stderr to ignore errors (e.g., file not found).
                [ -f "${LOG_FILE}.${i}" ] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))" 2>/dev/null || true
            done
            # Move the current log file to log.1.
            mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
            # Create a new empty log file.
            touch "$LOG_FILE" 2>/dev/null || printf "Warning: Failed to create new log file after rotation: %s\n" "$LOG_FILE" >&2
            # Clean up temporary debug log if created
            rm -f "$LOG_FILE.prerotate_debug" 2>/dev/null
            local rot_warn_msg=""
            # Append rotation warning to log file if it occurred
            if [ -n "$rot_warn_msg" ] && [ "$LOG_FILE" != "/dev/null" ]; then printf "%s\n" "$rot_warn_msg" >> "$LOG_FILE"; fi
        fi
    fi

    # --- Set Permissions ---
    local perm_warn_msg=""
    chmod 600 "$LOG_FILE" 2>/dev/null || perm_warn_msg="Warning: Could not set permissions (600) on log file: $LOG_FILE"
    # Append permission warning to log file if it occurred
    if [ -n "$perm_warn_msg" ] && [ "$LOG_FILE" != "/dev/null" ]; then printf "%s\n" "$perm_warn_msg" >> "$LOG_FILE"; fi

    # --- Final Log Message (Requires working logging) ---
    # Log the successful setup and the final log file path.
    # This relies on the logging functions defined below being available AND LOG_FILE being set.
    # If this is the first log message, it implicitly tests if logging works.
    log_debug "Logging setup complete. LOG_FILE set to: $LOG_FILE"
    return 0 # Indicate successful setup.

} # END setup_logging


# ==============================================================================
# --- Core Logging Functions ---
# ==============================================================================

# --- _log_marker ---
#
# @description Writes a distinct marker line to the log file (or stderr if logging disabled).
#              Useful for indicating start/end points or significant events in the log.
# @arg        $1 String The text for the marker.
# @appends    Formatted marker line to the log file or stderr.
# @stdout     None
# @stderr     Marker line if LOG_FILE is /dev/null.
# @depends    Global variable: LOG_FILE. External command: date, printf, echo.
# ---
_log_marker() {
    local marker_text="$1" # The message for the marker.
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S') # Get current timestamp.

    # Check if logging is disabled (LOG_FILE set to /dev/null).
    if [[ "$LOG_FILE" == "/dev/null" ]]; then
        # If disabled, print marker to stderr for immediate visibility.
        printf "%s - %s - MARKER: %s\n" "$timestamp" "$$" "$marker_text" >&2
    else
        # If enabled, append the marker to the log file.
        # Format: Timestamp - PID - MARKER: Message
        echo "$timestamp - $$ - MARKER: $marker_text" >> "$LOG_FILE"
    fi
}


# --- log ---
#
# @description DEPRECATED. Use log_info instead for INFO level messages.
#              Writes a message with an INFO prefix to the log file.
# @arg        $1 String The log message.
# @appends    Formatted log line to the log file if logging is enabled.
# @stdout     None
# @stderr     None
# @depends    Global variable: LOG_FILE. External command: date, echo.
# ---
log() {
    # NOTE: This function is equivalent to log_info. Consider removing or aliasing.
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S') # Get current timestamp.
    # Only log if LOG_FILE is not /dev/null.
    if [ "$LOG_FILE" != "/dev/null" ]; then
        # Format: Timestamp - PID - INFO: Message
        echo "$timestamp - $$ - INFO: $1" >> "$LOG_FILE"
    fi
}


# --- log_error ---
#
# @description Writes a message with an ERROR prefix to the log file and
#              prints a generic error notification to stderr pointing to the log file.
# @arg        $1 String The error message.
# @appends    Formatted log line to the log file if logging is enabled.
# @prints     Generic error message to stderr if logging is enabled, or a simple
#             error message if logging is disabled.
# @stdout     None
# @stderr     Error notification message.
# @depends    Global variable: LOG_FILE. External command: date, echo, printf.
# ---
log_error() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S') # Get current timestamp.
    # Check if logging is enabled.
    if [ "$LOG_FILE" != "/dev/null" ]; then
        # Append formatted error message to the log file.
        # Format: Timestamp - PID - ERROR: Message
        echo "$timestamp - $$ - ERROR: $1" >> "$LOG_FILE"
    else
        # If logging is disabled, print a simple error message to stderr.
        printf "An error occurred. (Logging disabled)\n" >&2
    fi
}


# --- log_warn ---
#
# @description Writes a message with a WARN prefix to the log file and
#              prints a generic warning notification to stderr pointing to the log file.
# @arg        $1 String The warning message.
# @appends    Formatted log line to the log file if logging is enabled.
# @prints     Generic warning message to stderr if logging is enabled.
# @stdout     None
# @stderr     Warning notification message.
# @depends    Global variable: LOG_FILE. External command: date, echo, printf.
# ---
log_warn() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S') # Get current timestamp.
    # Check if logging is enabled.
    if [ "$LOG_FILE" != "/dev/null" ]; then
        # Append formatted warning message to the log file.
        # Format: Timestamp - PID - WARN: Message
        echo "$timestamp - $$ - WARN: $1" >> "$LOG_FILE"
    else
        # If logging is disabled, perhaps print warning directly?
        # For now, we do nothing on stderr if logging is off for warnings.
        : # No-op
    fi
}


# --- log_debug ---
#
# @description Writes a message with a DEBUG prefix to the log file, *only* if
#              verbose mode is enabled (IS_VERBOSE global variable is "true").
# @arg        $1 String The debug message.
# @appends    Formatted log line to the log file if logging is enabled AND verbose mode is active.
# @stdout     None
# @stderr     None
# @depends    Global variables: IS_VERBOSE, LOG_FILE. External command: date, echo.
# ---
log_debug() {
    # Check if verbose mode is enabled. If not, return immediately.
    # Use parameter expansion default to handle case where IS_VERBOSE might be unset.
    [ "${IS_VERBOSE:-false}" = "true" ] || return 0

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S') # Get current timestamp.
    # Only log if LOG_FILE is not /dev/null (ensures logging is generally enabled).
    if [ "$LOG_FILE" != "/dev/null" ]; then
        # Append formatted debug message to the log file.
        # Format: Timestamp - PID - DEBUG: Message
        echo "$timestamp - $$ - DEBUG: $1" >> "$LOG_FILE"
    fi
}


# --- log_info ---
#
# @description Writes a message with an INFO prefix to the log file.
# @arg        $1 String The informational message.
# @appends    Formatted log line to the log file if logging is enabled.
# @stdout     None
# @stderr     None
# @depends    Global variable: LOG_FILE. External command: date, echo.
# ---
log_info() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S') # Get current timestamp.
    # Only log if LOG_FILE is not /dev/null.
    if [ "$LOG_FILE" != "/dev/null" ]; then
        # Append formatted info message to the log file.
        # Format: Timestamp - PID - INFO: Message
        echo "$timestamp - $$ - INFO: $1" >> "$LOG_FILE"
    fi
}
# ==============================================================================
# --- End of Library ---
# ============================================================================== 