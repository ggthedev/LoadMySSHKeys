#!/usr/bin/env bash
#
# SSH Key Manager
# ==============
#
# Description:
# -----------
# A comprehensive SSH key management tool that provides a menu-driven interface
# for managing SSH keys in the ssh-agent. It supports both macOS and Linux
# platforms, handles key loading, listing, and deletion operations, and includes
# robust error handling and logging capabilities.
#
# Features:
# --------
# - Menu-driven interface for key management
# - Cross-platform support (macOS and Linux)
# - Automatic ssh-agent management
# - Key loading from SSH directory (simple find or specified list)
# - Individual and bulk key deletion
# - Comprehensive logging system with rotation
# - Directory validation and management
#
# Author: [Your Name]
# Version: 1.0.0
# License: MIT
#

# ==============================================================================
# --- Script Initialization and Global Configuration ---
# ==============================================================================

_script_start_time=$(date +%s) # Record script start time for duration calculation (portable seconds).
set -euo pipefail              # Exit on error, unset variable, or pipe failure.

# --- Global Variable Declarations ---
# These variables are used throughout the script. Default values are provided,
# and some can be overridden by environment variables (e.g., SKM_LOG_DIR).

# Control Flags
declare IS_VERBOSE="false"      # Set to "true" by -v/--verbose for debug logging.

# Logging Configuration
declare LOG_FILE="/dev/null"    # Default log destination (disabled). Set by setup_logging.
declare LOG_FILENAME="${SKM_LOG_FILENAME:-sshkeymanager.log}" # Log filename. Env override: SKM_LOG_FILENAME.
# Platform-specific log directory preferences (used in setup_logging):
declare LOG_DIR_MACOS="$HOME/Library/Logs/sshkeymanager" # macOS preferred log directory.
declare LOG_DIR_LINUX_VAR="/var/log/sshkeymanager"       # Linux system-wide log directory.
declare LOG_DIR_LINUX_LOCAL="$HOME/.local/log/sshkeymanager" # Linux user-local log directory.
declare LOG_DIR_FALLBACK="$HOME/.ssh/logs"               # Fallback log directory if others fail.
# Actual LOG_DIR will be determined in setup_logging
declare LOG_DIR=""

# Platform Detection & Platform-Specific Settings
declare PLATFORM
PLATFORM=$(uname -s) # Detect Operating System (e.g., "Darwin", "Linux").
declare STAT_CMD     # Command to get file size (differs between platforms).
case "$PLATFORM" in
    "Darwin")
        STAT_CMD="stat -f %z" # macOS stat command for size in bytes.
        ;;
    "Linux")
        STAT_CMD="stat -c %s" # Linux stat command for size in bytes.
        ;;
    *)
        # Default to Linux style for other *nix systems, might need adjustment.
        STAT_CMD="stat -c %s"
        ;;
esac

# Core Application Paths
declare SSH_DIR="${SKM_SSH_DIR:-$HOME/.ssh}" # SSH directory path. Env override: SKM_SSH_DIR.
# File storing the list of key basenames to be loaded by add_keys_to_agent.
declare VALID_KEY_LIST_FILE="${SKM_VALID_KEYS_FILE:-$HOME/.config/sshkeymanager/ssh_keys_list}" # Env override: SKM_VALID_KEYS_FILE.
# File storing the running ssh-agent environment variables for persistence.
declare AGENT_ENV_FILE="${SKM_AGENT_ENV_FILE:-$HOME/.config/agent.env}" # Env override: SKM_AGENT_ENV_FILE.

# Temporary File (Declared globally, created in main())
declare KEYS_LIST_TMP="" # Path to the temporary file used for listing keys found by `find`.

# Script Action State (Set by argument parsing in main())
declare ACTION="help"       # Default action if no arguments are provided.
declare source_key_file="" # Stores the filename provided with the -f/--file option.

# ==============================================================================
# --- Function Definitions ---
# ==============================================================================

# ------------------------------------------------------------------------------
# --- Logging Functions ---
# ------------------------------------------------------------------------------

# --- setup_logging ---
#
# @description Configures the logging system for the script.
#              Determines the appropriate log directory based on platform and
#              environment variables, creates the directory if needed, sets
#              the LOG_FILE global variable, touches the log file, performs
#              log rotation if the file exceeds a size limit, and sets file
#              permissions. If logging setup fails at any critical step, it
#              defaults LOG_FILE to /dev/null, disabling logging.
# @arg        None
# @set        LOG_DIR Global variable containing the chosen log directory path.
# @set        LOG_FILE Global variable containing the full log file path.
# @return     0 If logging setup is successful.
# @return     1 If logging setup fails (e.g., cannot create directory/file).
# @prints     Warnings to stderr if directories/files cannot be created or accessed.
#             Debug messages to stdout if IS_VERBOSE is true during initial setup.
# @stdout     None (except potential debug messages).
# @stderr     Warnings on failure.
# @depends    Global variables: SKM_LOG_DIR, PLATFORM, LOG_DIR_MACOS,
#             LOG_DIR_LINUX_VAR, LOG_DIR_LINUX_LOCAL, LOG_DIR_FALLBACK,
#             LOG_FILENAME, IS_VERBOSE, STAT_CMD.
#             External commands: mkdir, printf, touch, stat (via STAT_CMD),
#             mv, seq, chmod, date.
# ---
setup_logging() {
    local max_log_size=1048576  # Max log size in bytes (1MB).
    local max_log_files=5       # Number of rotated log files to keep (e.g., .1, .2, ..., .5).

    # Determine LOG_DIR based on environment override or platform defaults.
    if [ -n "${SKM_LOG_DIR:-}" ]; then
         LOG_DIR="$SKM_LOG_DIR"
         # Log this choice later, after LOG_FILE is potentially usable and log_debug works.
    else
        case "$PLATFORM" in
            "Darwin")
                LOG_DIR="$LOG_DIR_MACOS"
                ;;
            "Linux")
                # Prefer system log directory if writable, otherwise use user's local log directory.
                if [ -w "$LOG_DIR_LINUX_VAR" ] 2>/dev/null; then # Check writability silently first
                     LOG_DIR="$LOG_DIR_LINUX_VAR"
                else
                     # If system dir isn't writable or doesn't exist, try user dir.
                     LOG_DIR="$LOG_DIR_LINUX_LOCAL"
                fi
                ;;
            *)
                # Fallback for other platforms.
                LOG_DIR="$LOG_DIR_FALLBACK"
                ;;
        esac
    fi

    local initial_log_dir="$LOG_DIR" # Store determined dir for potential warning messages.

    # Attempt to create the determined log directory.
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf "Warning: Could not create log directory '$initial_log_dir'. Trying fallback '$LOG_DIR_FALLBACK'.\\n" >&2
        LOG_DIR="$LOG_DIR_FALLBACK"
        # Attempt to create the fallback directory.
        if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
            printf "Warning: Could not create fallback log directory. Logging disabled.\\n" >&2
            LOG_FILE="/dev/null" # Ensure logging is disabled.
            return 1 # Indicate failure.
        fi
         printf "Warning: Using fallback log directory '$LOG_DIR'.\\n" >&2 # Inform user about fallback
    fi

    # At this point, LOG_DIR should be a valid, created directory. Set LOG_FILE path.
    LOG_FILE="${LOG_DIR}/${LOG_FILENAME}"

    # Set up log file with rotation
    if ! touch "$LOG_FILE" 2>/dev/null; then
        printf "Warning: Could not create log file '%s'. Logging disabled.\\n" "$LOG_FILE" >&2
        LOG_FILE="/dev/null" # Reset to /dev/null on failure
        return 1 # Indicate failure.
    fi

    # Rotate logs if the current log file exists and exceeds the size limit.
    if [ -f "$LOG_FILE" ]; then
        local log_size
        # Get log file size using the platform-specific command.
        if ! log_size=$($STAT_CMD "$LOG_FILE" 2>/dev/null); then
            printf "Warning: Could not determine size of log file '%s'. Log rotation skipped.\\n" "$LOG_FILE" >&2
        elif [ "$log_size" -gt "$max_log_size" ]; then
            # Log rotation needed.
            if [ "$IS_VERBOSE" = "true" ]; then
                # Use log_debug now that LOG_FILE should be usable
                log_debug "Rotating logs (size $log_size > $max_log_size)..."
            fi
            # Shift existing rotated logs (log.5 -> log.6 (deleted implicitly), log.4 -> log.5, ..., log.1 -> log.2).
            for i in $(seq $((max_log_files-1)) -1 1); do
                [ -f "${LOG_FILE}.${i}" ] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))" 2>/dev/null || true
            done
            # Move the current log file to log.1.
            mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
            # Create a new empty log file.
            touch "$LOG_FILE" 2>/dev/null || printf "Warning: Failed to create new log file after rotation: %s\\n" "$LOG_FILE" >&2
        fi
    fi

    # Set log file permissions to be readable/writable only by the owner.
    chmod 600 "$LOG_FILE" 2>/dev/null || printf "Warning: Could not set permissions (600) on log file: %s\\n" "$LOG_FILE" >&2

    # Now log_debug should work reliably if IS_VERBOSE is true.
    log_debug "Logging setup complete. LOG_FILE set to: $LOG_FILE"
    return 0 # Indicate success.
} # END setup_logging

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Check LOG_FILE is not /dev/null before writing
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - INFO: $1" >> "$LOG_FILE"
    fi
}

log_error() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - ERROR: $1" >> "$LOG_FILE"
        # Print user-friendly message to stderr, pointing to log file
        printf "An error occurred. See log for details: %s\\n" "$LOG_FILE" >&2
    else
        # If logging is disabled, print a generic error message to stderr
        printf "An error occurred. (Logging disabled)\\n" >&2
    fi
}

log_warn() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - WARN: $1" >> "$LOG_FILE"
        # Print user-friendly message to stderr, pointing to log file
        printf "A warning occurred. See log for details: %s\\n" "$LOG_FILE" >&2
    else
        # If logging is disabled, print a generic warning message to stderr
        printf "A warning occurred. (Logging disabled)\\n" >&2
    fi
}

log_debug() {
    [ "$IS_VERBOSE" = "true" ] || return 0 # Exit if not verbose
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

# ------------------------------------------------------------------------------
# --- Validation Functions ---
# ------------------------------------------------------------------------------

# --- validate_directory ---
#
# @description Checks if a given directory exists and has the necessary
#              read, write, and execute permissions. Logs errors if checks fail.
# @arg         $1 String Path to the directory to validate.
# @arg         $2 String Description of the directory (e.g., "SSH", "Log") for error messages.
# @return     0 If the directory exists and has required permissions.
# @return     1 If any validation check fails.
# @stdout      None
# @stderr      None (errors logged via log_error).
# @depends     Function: log_debug, log_error.
# ---
validate_directory() {
    log_debug "Entering function: ${FUNCNAME[0]} (Dir: $1, Desc: $2)"
    local dir="$1"
    local description="$2"
    local return_status=0 # Assume success initially

    # Perform checks in sequence. If one fails, set status and log, but continue checks.
    if [ ! -d "$dir" ]; then
        log_error "Validation failed: $description directory '$dir' does not exist."
        return_status=1
    # Only check permissions if the directory exists.
    else
        if [ ! -r "$dir" ]; then
            log_error "Validation failed: $description directory '$dir' is not readable."
        return_status=1
        fi
        # Note: Write permission check might not always be necessary depending on usage.
        if [ ! -w "$dir" ]; then
            log_error "Validation failed: $description directory '$dir' is not writable."
        return_status=1
        fi
        if [ ! -x "$dir" ]; then
            log_error "Validation failed: $description directory '$dir' is not accessible."
        return_status=1
        fi
    fi

    if [ "$return_status" -eq 0 ]; then
        log_debug "Validation successful for '$dir' ($description)."
    fi
    log_debug "Exiting function: ${FUNCNAME[0]} (Dir: $1, Status: $return_status)"
    return $return_status
}

validate_ssh_dir() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Validating SSH directory: $SSH_DIR"
    if ! validate_directory "$SSH_DIR" "SSH"; then
        log_warn "SSH directory '$SSH_DIR' validation failed. Attempting to create..."
        printf "Attempting to create SSH directory '%s'...\n" "$SSH_DIR"
        if ! mkdir -p "$SSH_DIR"; then
            log_error "Failed to create SSH directory '$SSH_DIR'."
            printf "Error: Failed to create SSH directory '%s'. Check permissions.\n" "$SSH_DIR" >&2
            return 1 # Creation failed.
        fi
        log_info "Successfully created SSH directory '$SSH_DIR'."
        printf "Successfully created SSH directory '%s'.\n" "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        log_debug "Set permissions (700) on '$SSH_DIR'."
    fi
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0
}

# ------------------------------------------------------------------------------
# --- SSH Agent Management Functions ---
# ------------------------------------------------------------------------------

# --- check_ssh_agent ---
#
# @description Performs checks to determine if a seemingly valid ssh-agent
#              is running and accessible via the current environment variables
#              (SSH_AUTH_SOCK, SSH_AGENT_PID).
#              Checks for existence of the socket file and the agent process.
#              Does *not* attempt to communicate with the agent (e.g., via ssh-add -l)
#              to avoid potential blocking or side effects during simple checks.
# @arg        None
# @uses       Global environment variables: SSH_AUTH_SOCK, SSH_AGENT_PID.
# @return     0 If SSH_AUTH_SOCK and SSH_AGENT_PID are set, the socket exists,
#               and the process associated with SSH_AGENT_PID is running.
# @return     1 If any of the checks fail.
# @stdout      None
# @stderr      None (status logged via log_debug).
# @depends     Function: log_debug. External command: ps.
# ---
check_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "Checking agent status... (PID='${SSH_AGENT_PID:-}', SOCK='${SSH_AUTH_SOCK:-}')"

    # Check if required environment variables are set.
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ -z "${SSH_AGENT_PID:-}" ]; then
        log_debug "check_ssh_agent: Required SSH_AUTH_SOCK or SSH_AGENT_PID not set."
        return 1;
    fi

    # Check if the socket path points to an actual socket file.
    if [ ! -S "$SSH_AUTH_SOCK" ]; then
        log_debug "check_ssh_agent: SSH_AUTH_SOCK ('$SSH_AUTH_SOCK') is not a valid socket."
        return 1;
    fi

    # Check if the process ID stored in SSH_AGENT_PID corresponds to a running process.
    # Redirect stdout and stderr to /dev/null for a silent check.
    if ! ps -p "$SSH_AGENT_PID" > /dev/null 2>&1; then
        log_debug "check_ssh_agent: Agent process PID '$SSH_AGENT_PID' not running."
        return 1;
    fi

    # If all checks pass, assume the agent is likely usable.
    # Note: Communication could still fail, but this is a good basic check.
    log_debug "check_ssh_agent: Socket exists and process PID found. Assuming agent is usable for check purposes."
    return 0
}

ensure_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Ensuring SSH agent is active..."
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -n "${SSH_AGENT_PID:-}" ] && check_ssh_agent; then
        log_info "Agent already running and sourced (PID: ${SSH_AGENT_PID:-Unknown})."
        printf "SSH agent is already running (PID: %s).\\n" "${SSH_AGENT_PID:-Unknown}"
        export SSH_AUTH_SOCK SSH_AGENT_PID # Ensure exported
        return 0
    fi
    log_debug "Agent not running or sourced in current environment."
    if [ -f "$AGENT_ENV_FILE" ]; then
        log_debug "Sourcing persistent agent file: $AGENT_ENV_FILE"
        # shellcheck disable=SC1090
        . "$AGENT_ENV_FILE" >/dev/null
        if check_ssh_agent; then
            log_info "Sourced persistent file. Reusing agent (PID: ${SSH_AGENT_PID:-Unknown})."
            printf "Successfully connected to existing ssh-agent (PID: %s).\\n" "${SSH_AGENT_PID:-Unknown}"
            export SSH_AUTH_SOCK SSH_AGENT_PID # Ensure exported
            return 0
        else
            log_debug "Agent file '$AGENT_ENV_FILE' found but agent invalid after sourcing. Removing stale file."
            rm -f "$AGENT_ENV_FILE"
            # Unset potentially invalid variables sourced from the stale file.
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    fi
    log_info "Starting new ssh-agent..."
    printf "Starting new ssh-agent...\\n"
    if ! mkdir -p "$HOME/.ssh"; then log_error "Failed to create $HOME/.ssh directory."; return 1; fi
    chmod 700 "$HOME/.ssh" || log_warn "Failed to set permissions on $HOME/.ssh"
    local agent_output
    if ! agent_output=$(ssh-agent -s); then
        log_error "Failed to execute ssh-agent -s."; return 1;
    fi
    log_debug "ssh-agent -s output captured."
    # Parse and export vars safely, avoiding eval
    local ssh_auth_sock ssh_agent_pid
    # Extract SSH_AUTH_SOCK value
    ssh_auth_sock=$(echo "$agent_output" | grep 'SSH_AUTH_SOCK=' | cut -d'=' -f2 | cut -d';' -f1)
    # Extract SSH_AGENT_PID value
    ssh_agent_pid=$(echo "$agent_output" | grep 'SSH_AGENT_PID=' | cut -d'=' -f2 | cut -d';' -f1)

    # Export the extracted variables directly.
    if [ -n "$ssh_auth_sock" ] && [ -n "$ssh_agent_pid" ]; then
    export SSH_AUTH_SOCK="$ssh_auth_sock"
    export SSH_AGENT_PID="$ssh_agent_pid"
        log_info "Extracted and exported new agent details: SOCK=$SSH_AUTH_SOCK PID=$SSH_AGENT_PID"
    else
        log_error "Failed to parse SSH_AUTH_SOCK or SSH_AGENT_PID from ssh-agent output."
        log_debug "ssh-agent output was: $agent_output"
        return 1;
    fi

    # Save the new agent environment to the persistent file.
    log_debug "Saving agent environment to $AGENT_ENV_FILE"
    # Create parent directory for AGENT_ENV_FILE if it doesn't exist.
    local agent_env_dir
    agent_env_dir=$(dirname "$AGENT_ENV_FILE")
    if ! mkdir -p "$agent_env_dir"; then
        log_warn "Could not create directory '$agent_env_dir' for agent environment file. Agent persistence disabled."
    else
        # Write the export commands to the file. Quoting SSH_AUTH_SOCK is important if path contains spaces.
        {
            echo "SSH_AUTH_SOCK='$SSH_AUTH_SOCK'; export SSH_AUTH_SOCK;"
            echo "SSH_AGENT_PID=$SSH_AGENT_PID; export SSH_AGENT_PID;"
            echo "# Agent details saved on $(date)"
        } > "$AGENT_ENV_FILE"
        chmod 600 "$AGENT_ENV_FILE" || log_warn "Failed to set permissions on $AGENT_ENV_FILE"
        log_info "Agent environment saved to $AGENT_ENV_FILE."
    fi

    # Final verification of the newly started agent.
    sleep 0.5 # Give the agent a brief moment to initialize fully.
    if check_ssh_agent; then
        log_info "New agent started and verified successfully."
        printf "Successfully started new ssh-agent (PID: %s).\\n" "$SSH_AGENT_PID"
        return 0
    else
        # This shouldn't typically happen if ssh-agent succeeded, but check just in case.
        log_error "Started new agent but failed final verification check!"
        printf "Error: Started ssh-agent but failed final verification.\\n" >&2
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        rm -f "$AGENT_ENV_FILE" # Clean up potentially bad env file.
        return 1
    fi
}

# --- add_keys_to_agent ---
#
# @description Reads a list of key file basenames from the persistent key list
#              file ($VALID_KEY_LIST_FILE) and attempts to add each corresponding
#              key file (located in $SSH_DIR) to the ssh-agent using `ssh-add`
#              individually within a loop.
#              On macOS, it uses the `--apple-use-keychain` option to attempt
#              storing passphrases in the macOS Keychain.
# @arg        None
# @requires   $VALID_KEY_LIST_FILE must exist, be readable, and contain one key
#             basename per line. $SSH_DIR must be the correct directory containing
#             the actual key files. An ssh-agent must be running and accessible.
# @return     0 If at least one key was successfully added to the agent.
# @return     1 If the key list file is missing/empty OR if all attempts to add
#               keys failed (including keys not found or passphrase issues).
# @prints     Status messages to stdout indicating success/failure for each key
#             attempt and a final summary.
# @stdout     Progress and summary messages.
# @stderr     None (errors logged).
# @depends    Global variables: VALID_KEY_LIST_FILE, SSH_DIR, PLATFORM.
#             Functions: log_debug, log_info, log_error, log_warn.
#             External command: ssh-add, printf, read.
# ---
add_keys_to_agent() {
    log_debug "Entering function: ${FUNCNAME[0]} (loop version)"
    log_info "Adding keys listed in $VALID_KEY_LIST_FILE..."

    # Check if the key list file exists and is not empty.
    if [ ! -s "$VALID_KEY_LIST_FILE" ]; then
        log_error "Key list file '$VALID_KEY_LIST_FILE' is empty or missing."
        printf "Key list file '%s' is empty or does not exist. Cannot add keys.\\n" "$VALID_KEY_LIST_FILE"
        return 1
    fi

    printf "Adding SSH keys to agent (using list: %s)...\n" "$VALID_KEY_LIST_FILE"
    # Use local PLATFORM detection for robustness if global isn't set, fallback to global
    local platform_local
    platform_local=$(uname -s)
    local keyfile key_path added_count=0 failed_count=0 ssh_add_output ssh_add_status cmd_to_run

    # Read the key list file line by line.
    # Temporarily disable exit-on-error for the read loop to handle ssh-add status manually
    set +e
    while IFS= read -r keyfile; do
        # Skip empty lines.
        [ -z "$keyfile" ] && continue

        key_path="$SSH_DIR/$keyfile" # Construct the full path to the key.
        log_debug "Processing key entry: '$keyfile' (Path: '$key_path')"

        # Check if the key file actually exists.
        if [ -f "$key_path" ]; then
            log_info "Attempting to add key: $key_path"
            # Platform-specific ssh-add command.
            if [[ "$platform_local" == "Darwin" ]]; then
                # Use macOS Keychain integration if possible.
                cmd_to_run="ssh-add --apple-use-keychain \"$key_path\""
                # Important: Run command directly, not via variable, to allow TTY interaction for passphrases.
                # Removed < /dev/null diagnostic
                ssh_add_output=$(ssh-add --apple-use-keychain "$key_path" 2>&1 || true)
                ssh_add_status=${PIPESTATUS[0]:-$?}
            else
                # Standard ssh-add for Linux/other.
                cmd_to_run="ssh-add \"$key_path\""
                 # Removed < /dev/null diagnostic
                ssh_add_output=$(ssh-add "$key_path" 2>&1 || true)
                ssh_add_status=${PIPESTATUS[0]:-$?}
            fi

            log_debug "ssh-add command status for '$keyfile': $ssh_add_status"
            # Log output only if there was an error, to avoid spamming logs with passphrase prompts.
            if [ "$ssh_add_status" -ne 0 ]; then
                log_debug "ssh-add output/error: $ssh_add_output"
            fi

            # Check the exit status of ssh-add.
            if [ "$ssh_add_status" -eq 0 ]; then
                # Status 0: Success.
                log_info "Successfully added '$keyfile'"
                printf "  ✓ Added key '%s'\\n" "$keyfile" # Uncommented printf
                ((added_count++))
            elif [ "$ssh_add_status" -eq 1 ]; then
                 # Status 1: Usually means key requires a passphrase and none was provided,
                 # or the agent couldn't access it (e.g., keychain locked on macOS).
                 # Or sometimes duplicate key?
                 printf "  ✗ Failed to add key '%s' (status: %d - passphrase needed or other issue?)\\n" "$keyfile" "$ssh_add_status" # Uncommented printf
                 log_warn "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status). Check passphrase or permissions."
                 ((failed_count++))
            elif [ "$ssh_add_status" -eq 2 ]; then
                 # Status 2: Cannot connect to agent. Should ideally be caught earlier, but handle here too.
                 printf "  ✗ Failed to add key '%s' (status: %d - cannot connect to agent)\\n" "$keyfile" "$ssh_add_status" # Uncommented printf
                 log_error "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status - Cannot connect to agent)."
                 ((failed_count++))
                 # Maybe break here as subsequent adds will likely fail too? For now, continue.
            else
                 # Other errors (e.g., bad key format).
                 printf "  ✗ Failed to add key '%s' (status: %d - unexpected error)\\n" "$keyfile" "$ssh_add_status" # Uncommented printf
                 log_error "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status - Unexpected)."
                ((failed_count++))
            fi
        else
            # Key file listed in $VALID_KEY_LIST_FILE does not exist.
            printf "  ✗ Key file '%s' not found at '%s' (skipped)\\n" "$keyfile" "$key_path" # Uncommented printf
            log_warn "Key file '$keyfile' listed in '$VALID_KEY_LIST_FILE' but not found at '$key_path'."
            ((failed_count++))
        fi
    done < "$VALID_KEY_LIST_FILE"
    local read_status=$?
    # Re-enable exit-on-error *after* the loop finishes
    set -e

    # Check the final status of the read command if needed (0 is ok, 1 is EOF is ok)
    if [ $read_status -ne 0 ] && [ $read_status -ne 1 ]; then
        log_error "add_keys_to_agent: Error reading key list file '$VALID_KEY_LIST_FILE' (status: $read_status)."
        # No set +u needed here as it wasn't used in this version
        return 1 # Indicate failure
    fi

    # Print summary.
    printf "\\nSummary: %d key(s) added, %d key(s) failed/skipped.\\n" "$added_count" "$failed_count"
    log_info "Finished adding keys. Added: $added_count, Failed/Skipped: $failed_count"

    # Return success if at least one key was added.
    [ "$added_count" -gt 0 ] && return 0 || return 1
} # END add_keys_to_agent

# ------------------------------------------------------------------------------
# --- Core Key Management Functions ---
# ------------------------------------------------------------------------------

# --- update_keys_list_file ---
#
# @description Scans the $SSH_DIR for potential private key files using `find`
#              and writes their basenames to the temporary file specified by
#              the global $KEYS_LIST_TMP variable.
#              The `find` command attempts to exclude common non-key files like
#              `known_hosts`, `authorized_keys`, `config`, and files with extensions
#              (like `.pub`). This is a basic heuristic and might include invalid
#              keys or exclude valid ones with unusual names.
# @arg        None
# @modifies   Overwrites the temporary file $KEYS_LIST_TMP with found key basenames.
# @return     0 If at least one potential key file is found.
# @return     1 If no potential key files are found.
# @prints     Status messages to stdout indicating the number of keys found.
# @stdout     Count of potential key files found.
# @stderr     None (errors logged).
# @depends    Global variables: SSH_DIR, KEYS_LIST_TMP, PLATFORM.
#             Functions: log_debug, log_info.
#             External commands: printf, find, wc.
# ---
update_keys_list_file() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Finding potential private key files in $SSH_DIR using 'find'..."

    # Ensure the temporary file exists and is empty before writing.
    if [ -z "$KEYS_LIST_TMP" ] || ! > "$KEYS_LIST_TMP"; then
        log_error "Temporary key list file ($KEYS_LIST_TMP) is not set or not writable."
        printf "Error: Cannot prepare temporary file for key list.\\n" >&2
      return 1
    fi
    log_debug "Cleared temporary key list file: $KEYS_LIST_TMP"

    log_debug "Running find command for platform $PLATFORM..."
    # Use platform-specific `find` syntax.
    # Exclude common non-private-key files.
    # -maxdepth 1: Don't search subdirectories.
    # -type f: Only find files.
    # ! -name ...: Exclude specific filenames or patterns.
    #   '*.*': Excludes files with extensions (like .pub, potentially others).
    # -exec basename {} \; (macOS): Print only the filename.
    # -printf '%f\\n' (Linux): Print only the filename, followed by a newline.
    if [[ "$PLATFORM" == "Darwin" ]]; then
        find "$SSH_DIR" -maxdepth 1 -type f \
            ! -name 'known_hosts*' ! -name 'authorized_keys*' ! -name '*.*' ! -name 'config' \
            -exec basename {} \; > "$KEYS_LIST_TMP" 2>/dev/null || { log_error "find command failed on Darwin."; return 1; }
    else # Linux or other
        find "$SSH_DIR" -maxdepth 1 -type f \
            ! -name 'known_hosts*' ! -name 'authorized_keys*' ! -name '*.*' ! -name 'config' \
            -printf '%f\\n' > "$KEYS_LIST_TMP" 2>/dev/null || { log_error "find command failed on Linux/other."; return 1; }
    fi

    # Count the number of lines (keys) found.
    local key_count
    key_count=$(wc -l < "$KEYS_LIST_TMP")
    # Remove leading whitespace from wc output if necessary (though `<` redirection usually avoids this).
    key_count=${key_count##* }

    log_info "Found $key_count potential key entries in temp file $KEYS_LIST_TMP."
    if [ "$key_count" -eq 0 ]; then
        printf "No potential SSH private key files found in %s (using find filters).\\n" "$SSH_DIR"
        log_info "No potential SSH key files found in $SSH_DIR using find logic."
        # Return 1 indicating no keys found, but not necessarily an error in the process.
        return 1
    else
        printf "Found %d potential key file(s) in %s (written to temp list %s).\\n" "$key_count" "$SSH_DIR" "$KEYS_LIST_TMP"
        return 0
    fi
}

delete_keys_from_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Attempting to delete all keys from ssh-agent (ssh-add -D)..."

    # Execute ssh-add -D. Capture stderr to prevent it cluttering user output if desired,
    # but allow command failure to be detected by PIPESTATUS. `|| true` prevents script exit
    # if `set -e` is active and ssh-add fails.
    ssh-add -D >/dev/null 2>&1 || true
    local del_status=${PIPESTATUS[0]:-$?} # Get exit status of ssh-add.

    log_debug "ssh-add -D exit status: $del_status"
    case "$del_status" in
        0) # Success: Keys were deleted.
            log_info "All keys successfully deleted from agent."
            printf "All keys successfully deleted from agent.\\n"
            return 0
            ;;
        1) # Common "error": No identities found in the agent.
            log_info "No keys found in agent to delete (ssh-add -D status: 1)."
            printf "No keys found in agent to delete.\\n"
            # Treat this as success because the state (no keys) is achieved.
            return 0
            ;;
        2) # Error: Could not connect to the agent.
            log_error "Failed to delete keys: Could not connect to agent (ssh-add -D status: 2)."
            printf "Error: Could not connect to the SSH agent.\\n" >&2
            return 1
            ;;
        *) # Other unexpected errors.
            log_error "Failed to delete keys from agent (ssh-add -D status: $del_status)."
            printf "Error: Failed to delete keys from agent (Code: %s).\\n" "$del_status" >&2
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# --- Interactive Menu Helper Functions ---
# ------------------------------------------------------------------------------

# --- display_main_menu ---
#
# @description Clears the screen and displays the main interactive menu options.
# @arg        None
# @prints     The menu text to stdout.
# @stdout     Formatted menu.
# @stderr      None
# @depends    Global variables: PLATFORM, SSH_DIR. Function: log_debug. External command: clear, printf.
# ---
display_main_menu() {
    log_debug "Displaying main menu..."
    clear # Clear the terminal screen.
    printf "\\n======= SSH Key Manager Menu =======\\n"
    printf " Platform: %s\\n" "$PLATFORM"
    printf " SSH Directory: %s\\n" "$SSH_DIR"
    printf "+++++++++++++++++++++++++++++++++++\\n"
    printf " Please choose an option:\\n"
    printf "   1) Set SSH Directory (Not Implemented)\\n"
    printf "   2) List Current Keys in Agent\\n"
    printf "   3) Reload Keys (Find & Add All)\\n"
    printf "   4) Display Log File Info\\n"
    printf "   5) Delete Single Key from Agent\\n"
    printf "   6) Delete All Keys from Agent\\n"
    printf "   q) Quit\\n"
    printf "+++++++++++++++++++++++++++++++++++\\n"
}

# --- get_menu_choice ---
#
# @description Prompts the user to enter a menu choice and validates the input.
#              Loops until a valid choice (1-6 or q/Q) is entered.
# @arg        None
# @return     0 Always (after a valid choice is made).
# @prints     The prompt to the user via stderr (so it doesn't interfere with stdout capture).
#             Error messages to stdout for invalid choices.
# @reads      User input from /dev/tty for selection.
# @stdout     The valid user choice (1-6, q).
# @stderr     The input prompt.
# @depends    Function: log_debug, log_warn. External command: read, printf, echo.
# ---
get_menu_choice() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local choice
    while true; do
        read -r -p "Enter choice [1-6, q]: " choice < /dev/tty
        log_debug "User entered selection: '$choice'"
        case "$choice" in
            [1-6]|q|Q) echo "$choice"; return 0 ;;
            *) printf "Invalid choice '%s'. Please try again.\\n" "$choice"; log_warn "Invalid menu choice: '$choice'" ;;
        esac
    done
}

# --- wait_for_key ---
#
# @description Pauses execution and waits for the user to press Enter.
#              Used after displaying information in the menu to allow the user
#              to read before returning to the main menu display.
# @arg        None
# @prints     A prompt message to stdout.
# @reads      A line of input from stdin (waits for Enter).
# @stdout     Prompt message.
# @stderr      None
# @depends    External command: printf, read.
# ---
wait_for_key() {
    printf "\\nPress Enter to return to the main menu...\\n"
    # Simple read, requires Enter. No longer reads from /dev/tty directly.
    read -r 
}

# ------------------------------------------------------------------------------
# --- Interactive Menu Core Logic Functions ---
# ------------------------------------------------------------------------------
# These functions implement the actions corresponding to the menu choices.

# --- list_current_keys ---
#
# @description Attempts to list the keys currently loaded in the ssh-agent
#              using `ssh-add -l`. Handles different exit codes from `ssh-add -l`.
# @arg        None
# @requires   An accessible ssh-agent (checked implicitly by ssh-add -l).
# @return     0 If keys were listed successfully OR if no keys were found (status 1).
# @return     1 If there was an error connecting to the agent (status 2) or another
#               unexpected error occurred during listing.
# @prints     The list of keys (if any) or messages indicating no keys or errors to stdout/stderr.
# @stdout     Output from `list_current_keys` or "No agent" message.
# @stderr     Output from `list_current_keys` or "No agent" message hint.
# @depends    Function: log_debug, log_info, log_error. External command: ssh-add, printf.
# ---
list_current_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Listing current keys in agent (ssh-add -l)..."

    # Use if/else structure to capture true exit code robustly with set -e
    local key_list_output exit_code
    if key_list_output=$(ssh-add -l 2>&1); then
        exit_code=0 # Explicitly success
    else
        exit_code=$? # Capture the failure code (1=no keys, 2=no agent, etc.)
    fi
    log_debug "ssh-add -l status check: $exit_code"

    # Handle different outcomes based on the exit code.
    case $exit_code in
        0) # Keys are present
            printf "Keys currently loaded in the agent:\n"
            log_info "Keys currently loaded in the agent:"
            local key_lines=()
            # Read lines into an array
            mapfile -t key_lines <<< "$key_list_output"

            if [ ${#key_lines[@]} -gt 0 ]; then
                local i
                for i in "${!key_lines[@]}"; do
                    printf "  %2d) %s\n" "$((i + 1))" "${key_lines[i]}"
                    log_info "  $((i + 1))) ${key_lines[i]}"
                done
            else
                # Should not happen if exit_code is 0, but handle defensively
                printf "Agent reported success (status 0), but no key lines found.\n"
                log_warn "list_current_keys: ssh-add -l status 0 but mapfile found no lines."
            fi
            ;;
        1) # No keys loaded
            printf "No keys currently loaded in the agent.\n"
            # Provide context-aware hint
            if [ "$ACTION" == "list" ]; then
                printf "Hint: Use -a to add keys found in '%s'.\n" "$SSH_DIR"
            else # Default hint for menu or other contexts
                printf "Hint: Use option 3 (in menu) to load keys from '%s'.\n" "$SSH_DIR"
            fi
            log_info "No keys currently loaded (status 1)."
            ;;
        2) # Cannot connect
            log_error "Could not connect to the SSH agent (ssh-add -l exit code 2)."
            printf "Error: Could not connect to the SSH agent. Is it running?\n" >&2
            return 1
            ;;
        *) # Unknown error
            log_error "Unknown error occurred from ssh-add -l check (Exit code: $exit_code)."
            printf "Error: An unexpected error occurred checking keys (Code: %s).\n" "$exit_code" >&2
            return 1
            ;;
    esac
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0
}

# --- display_log_location ---
#
# @description Displays the location and size of the current log file,
#              or indicates if logging is disabled.
# @arg        None
# @prints     Log file path and size (or disabled status) to stdout.
# @stdout     Log file information.
# @stderr      None
# @depends    Global variable: LOG_FILE. Functions: log_debug, log_info, log_warn.
#             External command: printf, ls, awk.
# ---
display_log_location() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\\n+++ Log File Information +++\\n"
    if [ "$LOG_FILE" = "/dev/null" ]; then
        printf "Logging is currently disabled.\\n"
        log_info "User requested log location: Logging is disabled."
    else
        printf "Current log file location: %s\\n" "$LOG_FILE"
        local log_size_human="-"
        if [ -f "$LOG_FILE" ]; then
            log_size_human=$(ls -lh "$LOG_FILE" 2>/dev/null | awk '{print $5}')
        else
             log_warn "Log file $LOG_FILE not found when trying to get size."
             log_size_human="(File not found)"
        fi
        printf "Current log file size: %s\\n" "$log_size_human"
        log_info "Displaying log file location: $LOG_FILE (Size: $log_size_human)"
    fi
    printf "+++++++++++++++++++++++++++++++++++\\n"
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0
}

# --- delete_single_key ---
#
# @description Interactively prompts the user to select a key file (from a list
#              of potential keys found in $SSH_DIR) and attempts to delete that
#              specific key from the ssh-agent using `ssh-add -d <key_path>`.
# @arg        None
# @requires   An accessible ssh-agent containing keys. The temporary file $KEYS_LIST_TMP
#             should be populated by `update_keys_list_file`.
# @return     0 If the operation was cancelled by the user OR if the selected key
#               was successfully deleted.
# @return     1 If there's an error connecting to the agent, finding key files,
#               reading the temporary list, or if the `ssh-add -d` command fails
#               for the selected key.
# @prints     A numbered list of potential key files, prompts for user input,
#             and status messages about the deletion attempt to stdout/stderr.
# @reads      User input from /dev/tty for selection.
# @stdout     Menu, prompts, success/failure messages.
# @stderr     Error messages (e.g., connection failure, deletion failure).
# @depends    Global variables: SSH_DIR, KEYS_LIST_TMP. Functions: log_debug, log_info,
#             log_error, log_warn, update_keys_list_file. External command: ssh-add, mapfile (bash 4+), read.
# ---
delete_single_key() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Delete Single Key from Agent +++\n"

    # First, check if the agent is accessible and has keys using if/else.
    local agent_check_status list_output
    if list_output=$(ssh-add -l 2>&1); then
        agent_check_status=0 # Explicitly success
    else
        agent_check_status=$? # Capture the failure code (1=no keys, 2=no agent, etc.)
    fi
    log_debug "ssh-add -l status check: $agent_check_status"

    if [ "$agent_check_status" -eq 1 ]; then # No keys loaded
        printf "No keys currently loaded in ssh-agent to delete.\n"
        log_info "delete_single_key: No keys loaded, nothing to do."
        return 0 # Nothing to delete, considered success for this operation.
    elif [ "$agent_check_status" -ne 0 ]; then # Error connecting (status 2 or other)
        log_error "delete_single_key: Cannot query agent (ssh-add -l status: $agent_check_status)."
        printf "Error: Could not query the SSH agent (status: %d).\n" "$agent_check_status" >&2
        return 1 # Connection error.
    fi

    # Agent has keys (status 0), proceed
    log_info "Agent has keys. Listing potential key files..."
    if ! update_keys_list_file; then
        log_error "delete_single_key: Failed to get list of key files."
        # update_keys_list_file prints specific error
        return 1
    fi
    if [ ! -s "$KEYS_LIST_TMP" ]; then
        log_error "delete_single_key: Inconsistency - agent has keys, but temp file list is empty."
        printf "Error: Inconsistency detected - agent reports keys, but no key files found.\n" >&2
        return 1
    fi
    local key_files=()
    mapfile -t key_files < "$KEYS_LIST_TMP" || { log_error "Failed to read keys into array."; return 1; }
    if [ ${#key_files[@]} -eq 0 ]; then
        log_error "delete_single_key: Read 0 keys into array."
        printf "Error reading key file list.\n" >&2
        return 1
    fi
    printf "Select a key file to remove from the agent:\\n"
    local i choice selected_index selected_filename key_path del_status return_status=1
    for i in "${!key_files[@]}"; do
        printf "  %2d) %s\\n" "$((i + 1))" "${key_files[i]}"
    done
    while true; do
        read -r -p "Enter key number to delete (or 'c' to cancel): " choice < /dev/tty
        log_debug "User entered selection: '$choice'"
        case "$choice" in
            c|C) printf "Operation cancelled.\\n"; log_info "User cancelled deletion."; return_status=0; break ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#key_files[@]}" ]; then
                    selected_index=$((choice - 1))
                    selected_filename="${key_files[$selected_index]}"
                    key_path="$SSH_DIR/$selected_filename"
                    log_info "User selected: $choice ($selected_filename)"
                    printf "Attempting to delete key file: %s\n" "$selected_filename"
                    log_info "Attempting: ssh-add -d '$key_path'"
                    ssh-add -d "$key_path" 2>/dev/null || true # Redirect stderr
                    del_status=${PIPESTATUS[0]:-$?}
                    log_debug "ssh-add -d exited with status: $del_status"
                    if [ "$del_status" -eq 0 ]; then
                        printf "Key '%s' successfully deleted from agent.\n" "$selected_filename"
                        log_info "Successfully deleted '$key_path' from agent."
                        return_status=0
                    else
                        printf "Error: Failed to delete key '%s' from agent (status: %d).\n" "$selected_filename" "$del_status" >&2
                        log_error "Failed to delete key '$key_path' (status: $del_status)."
                        if [ "$del_status" -eq 1 ]; then printf "       (This often means the key wasn't loaded.)\n" >&2; fi
                        return_status=1 # Deletion failed
                    fi
                    break # Exit loop after attempt
                else
                    printf "Invalid selection. Please enter 1-%d or 'c'.\n" "${#key_files[@]}"
                fi ;;
        esac
    done
    log_debug "Exiting function: ${FUNCNAME[0]} (status: $return_status)"
    return $return_status
}

# --- delete_all_keys ---
#
# @description Deletes all keys currently loaded in the ssh-agent after prompting
#              the user for confirmation.
# @arg        None
# @requires   An accessible ssh-agent.
# @return     0 If the operation was cancelled by the user OR if all keys were
#               successfully deleted (or if no keys were present initially).
# @return     1 If there was an error connecting to the agent OR if the underlying
#               `delete_keys_from_agent` function failed unexpectedly.
# @prints     Status messages, confirmation prompt, and success/failure messages to stdout/stderr.
# @reads      User input ('y'/'Y') from /dev/tty for confirmation.
# @stdout     Messages about loaded keys, prompt, cancellation/success message.
# @stderr     Error messages (e.g., connection failure).
# @depends    Functions: log_debug, log_info, log_error, log_warn, delete_keys_from_agent.
#             External command: printf, ssh-add, wc, read.
# ---
delete_all_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Delete All Keys from Agent +++\n"

    # Check agent status and count keys if possible using if/else for robust status capture.
    local agent_check_status key_count=0 list_output="" has_keys=0
    if list_output=$(ssh-add -l 2>&1); then
        agent_check_status=0 # Explicitly success
    else
        agent_check_status=$? # Capture the failure code (1=no keys, 2=no agent, etc.)
    fi
    log_debug "ssh-add -l status check: $agent_check_status"

    if [ "$agent_check_status" -eq 0 ]; then # Status 0: Keys are present.
        key_count=$(echo "$list_output" | wc -l)
        key_count=${key_count##* } # Trim whitespace from wc output.
        log_debug "Agent check status 0, counted $key_count keys."
        if [ "$key_count" -gt 0 ]; then
             has_keys=1
        else
             # Should not happen if status was 0, but handle defensively.
             log_warn "delete_all_keys: ssh-add -l status 0 but key count is 0."
             has_keys=0
        fi
    elif [ "$agent_check_status" -eq 1 ]; then # Status 1: No keys loaded.
        log_info "delete_all_keys: No keys loaded in agent (status 1)."
        has_keys=0
    elif [ "$agent_check_status" -eq 2 ]; then # Status 2: Cannot connect.
        log_error "delete_all_keys: Cannot query agent (ssh-add -l status: 2)."
        printf "Error: Could not query the SSH agent (status: %d).\n" "$agent_check_status" >&2
        return 1 # Connection error.
    else # Other errors.
        log_error "delete_all_keys: Error querying agent (ssh-add -l status: $agent_check_status)."
        printf "Error: Could not query the SSH agent (Status: %d).\n" "$agent_check_status" >&2
        return 1 # Other agent error.
    fi

    # If no keys are loaded, inform the user and exit successfully.
    if [ "$has_keys" -eq 0 ]; then
        printf "No keys currently loaded in ssh-agent.\n"
        log_info "delete_all_keys: No keys loaded, nothing to do."
        return 0
    fi

    # Keys are present, proceed with confirmation
    printf "This will delete all %d keys from ssh-agent.\n" "$key_count"
    local confirm del_status return_status=1
    read -r -p "Are you sure you want to continue? (y/N): " confirm < /dev/tty
    log_debug "User confirmation: '$confirm'"

    # Process confirmation.
    case "$confirm" in
        y|Y)
            log_info "User confirmed deletion of all keys."
            if delete_keys_from_agent; then
                return_status=0 # Success reported by underlying function
            else
                return_status=1 # Failure reported by underlying function
                # Error message already printed/logged by delete_keys_from_agent
            fi
            ;;
        *)
            printf "Operation cancelled.\n"
            log_info "User cancelled deletion."
            return_status=0 # Cancelled successfully
            ;;
    esac

    log_debug "Exiting function: ${FUNCNAME[0]} (status: $return_status)"
    return $return_status
}

# ------------------------------------------------------------------------------
# --- Internal Helper Functions ---
# ------------------------------------------------------------------------------

# --- _perform_list_keys_check ---
#
# @description Internal helper to check for a running agent (current env or
#              sourced from $AGENT_ENV_FILE) and then call `list_current_keys`
#              if an agent is found. Used by both the CLI `-l` action and the
#              menu option 2. Provides context-specific hints if no agent is found.
# @arg        None
# @return     Exit status of `list_current_keys` if an agent is found.
# @return     1 If no usable agent is found.
# @prints     Messages indicating agent status or "No agent found" hints to stdout/stderr.
# @stdout     Output from `list_current_keys` or "No agent" message.
# @stderr     Output from `list_current_keys` or "No agent" message hint.
# @depends    Global variable: AGENT_ENV_FILE. Functions: check_ssh_agent,
#             list_current_keys, log_debug, log_info. External command: basename.
# ---
_perform_list_keys_check() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local agent_found_list_check=0 # Flag to track if a usable agent was found.

    # Check 1: Current env first
    log_debug "_perform_list_keys_check: Checking current env..."
    if check_ssh_agent; then
        agent_found_list_check=1
    # If not in env, check file
    elif [ -f "$AGENT_ENV_FILE" ]; then
        log_debug "_perform_list_keys_check: Sourcing $AGENT_ENV_FILE..."
        # Source into current scope for potential use by list_current_keys
        # shellcheck disable=SC1090
        . "$AGENT_ENV_FILE" >/dev/null 
        if check_ssh_agent; then
             log_info "_perform_list_keys_check: Found valid agent via sourced file."
             agent_found_list_check=1
        else
            log_debug "_perform_list_keys_check: Agent invalid after sourcing file."
        fi
    else
         log_debug "_perform_list_keys_check: Agent not in env and no agent file found."
    fi

    if [ "$agent_found_list_check" -eq 1 ]; then
        log_info "_perform_list_keys_check: Agent found, calling list_current_keys."
        # Call the actual listing function, which handles its own errors/output
        list_current_keys
        return $? # Return status of list_current_keys
    else
        log_info "_perform_list_keys_check: No usable agent found."
        printf "No running SSH agent found to list keys from.\n"
        # For CLI context (-l), add hint
        # Check if we are likely in the CLI context (check $ACTION?)
        # Or just always print hint? Let's always print for now.
        printf "Hint: Ensure agent is running or start the menu with '%s --menu'\n" "$(basename "$0")" >&2
        return 1 # Indicate failure to list keys due to no agent
    fi
}

# ------------------------------------------------------------------------------
# --- CLI Action Functions ---
# ------------------------------------------------------------------------------
# These functions implement the command-line argument actions (e.g., -l, -a).
# They typically perform validation, ensure the agent is running (if needed),
# call the appropriate core logic function, and then exit with its status.

# --- run_list_keys ---
#
# @description Handler for the `-l` or `--list` CLI option.
#              Validates the SSH directory and calls the internal helper
#              `_perform_list_keys_check` to find an agent and list keys.
#              Exits with the status code returned by the helper.
# @arg        None
# @exits      With status 0 or 1 based on the outcome of `_perform_list_keys_check`.
# @depends    Functions: validate_ssh_dir, _perform_list_keys_check, log_info, log_debug.
# ---
run_list_keys() {
    log_info "CLI Action: Listing keys (--list)..."
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "run_list_keys: Validating SSH dir..."
    if ! validate_ssh_dir; then exit 1; fi

    # Call the consolidated check/list function
    _perform_list_keys_check
    exit $? # Exit with the status returned by the helper function
}

# --- run_load_keys ---
#
# @description Handler for the `-a` or `--add` CLI option.
#              Validates SSH dir, ensures agent is running, finds potential keys
#              in $SSH_DIR using `update_keys_list_file`, copies the list to
#              $VALID_KEY_LIST_FILE, deletes existing keys from agent, then adds
#              the keys from the list using `add_keys_to_agent`.
#              Exits with the status code of `add_keys_to_agent`.
# @arg        None
# @exits      With status 0 or 1 based on validation, agent setup, key finding,
#             or the final outcome of `add_keys_to_agent`.
# @depends    Global variables: KEYS_LIST_TMP, VALID_KEY_LIST_FILE. Functions:
#             validate_ssh_dir, ensure_ssh_agent, update_keys_list_file,
#             delete_keys_from_agent, add_keys_to_agent, log_info, log_debug, log_error.
#             External command: cp.
# ---
run_load_keys() {
    log_info "CLI Action: Loading keys found in $SSH_DIR (--add)..."
    log_debug "Entering function: ${FUNCNAME[0]}"

    # Initial checks.
    if ! validate_ssh_dir; then exit 1; fi
    if ! ensure_ssh_agent; then exit 1; fi

    # Find potential keys and populate the temporary list file.
    log_debug "run_load_keys: Updating temporary key list file..."
    if ! update_keys_list_file; then
        log_error "run_load_keys: Failed to find keys using find."
        exit 1
    fi

    # Copy temp list to the persistent list file that add_keys_to_agent uses
    log_debug "Copying found keys from temp file $KEYS_LIST_TMP to $VALID_KEY_LIST_FILE"
    cp "$KEYS_LIST_TMP" "$VALID_KEY_LIST_FILE" || { log_error "Failed to copy temp key list."; exit 1; }
    log_info "Deleting existing keys from agent before loading..."
    delete_keys_from_agent # Ignore failure, attempt add anyway? Or exit? Currently ignoring.
    log_info "Adding keys found by find..."
    add_keys_to_agent
    exit $? # Exit with the status of add_keys_to_agent
}

# --- run_delete_all_cli ---
#
# @description Handler for the `-D` or `--delete-all` CLI option.
#              Validates SSH dir, ensures agent is running, and calls
#              `delete_all_keys` which handles confirmation and deletion.
#              Exits with the status code of `delete_all_keys`.
# @arg        None
# @exits      With status 0 or 1 based on validation, agent setup, or the outcome
#             of `delete_all_keys` (including user cancellation).
# @depends    Functions: validate_ssh_dir, ensure_ssh_agent, delete_all_keys,
#             log_info, log_debug.
# ---
run_delete_all_cli() {
    log_info "CLI Action: Deleting all keys (--delete-all)..."
    log_debug "Entering function: ${FUNCNAME[0]}"

    # Initial checks.
    if ! validate_ssh_dir; then exit 1; fi
    if ! ensure_ssh_agent; then exit 1; fi # Agent required for deletion.

    # Call the function that handles confirmation and deletion.
    delete_all_keys
    local delete_status=$?
    log_debug "Exiting function: ${FUNCNAME[0]} with status $delete_status"
    exit $delete_status # Exit with the status of delete_all_keys.
}

# --- run_load_keys_from_file ---
#
# @description Handler for the `-f <file>` or `--file <file>` CLI option.
#              Validates the source key list file, target list directory, SSH dir,
#              ensures agent is running, prepares the $VALID_KEY_LIST_FILE by
#              copying/filtering the source file (removing comments/blanks),
#              then calls `add_keys_to_agent` to load the keys.
#              Exits with the status code of `add_keys_to_agent`.
# @arg        $1 String Path to the source file containing key basenames. Passed from main().
# @exits      With status 0 or 1 based on validation, agent setup, file processing,
#             or the final outcome of `add_keys_to_agent`.
# @depends    Global variable: VALID_KEY_LIST_FILE. Functions: validate_ssh_dir,
#             ensure_ssh_agent, add_keys_to_agent, log_info, log_debug, log_error, log_warn.
#             External commands: dirname, mkdir, grep, chmod.
# ---
run_load_keys_from_file() {
    local source_key_file="$1" # Arg passed from main()
    log_info "CLI Action: Loading keys from specified file (--file '$source_key_file')..."
    log_debug "Entering function: ${FUNCNAME[0]} (Source File: $source_key_file)"

    # Validate the source key list file.
    if [ ! -f "$source_key_file" ] || [ ! -r "$source_key_file" ]; then
        log_error "Source key list file not found or not readable: '$source_key_file'"
        exit 1
    fi

    # Ensure the *directory* for the internal persistent key list file exists.
    local target_list_dir
    target_list_dir=$(dirname "$VALID_KEY_LIST_FILE")
    if ! mkdir -p "$target_list_dir"; then
        log_error "Could not create directory '$target_list_dir' for internal key list."
        exit 1
    fi
    # Validate SSH dir and agent
    if ! validate_ssh_dir; then exit 1; fi
    if ! ensure_ssh_agent; then exit 1; fi
    # Prepare VALID_KEY_LIST_FILE by copying from source, removing comments/blanks
    log_debug "Preparing target list file $VALID_KEY_LIST_FILE from source $source_key_file"
    grep -vE '^\s*(#|$)' "$source_key_file" > "$VALID_KEY_LIST_FILE" || { log_error "Failed to process source key file '$source_key_file'."; exit 1; }
    chmod 600 "$VALID_KEY_LIST_FILE" 2>/dev/null || log_warn "Could not set permissions on $VALID_KEY_LIST_FILE"
    log_info "Adding keys listed in '$source_key_file'..."
    add_keys_to_agent
    exit $? # Exit with the status of add_keys_to_agent
}

# ------------------------------------------------------------------------------
# --- Help Function ---
# ------------------------------------------------------------------------------

# --- display_help ---
#
# @description Displays the help message (usage instructions) for the script.
#              Uses a heredoc for easy formatting. Shows dynamically determined
#              paths where possible.
# @arg        None
# @prints     The help text to stdout.
# @stdout     Formatted help message.
# @stderr      None
# @depends    Global variables: SSH_DIR, LOG_DIR (potentially unset), LOG_FILENAME (potentially unset).
#             External command: basename, cat.
# ---
display_help() {
    # Use cat heredoc for easier formatting.
    # Show default/determined paths. Use :-unavailable if variables might not be set yet
    # (e.g., if called due to early argument parse error before setup_logging).
    cat << EOF
SSH Key Manager - $(basename "$0")

Manages SSH keys in the ssh-agent via command-line options or an interactive menu.

Usage: $(basename "$0") [OPTIONS]

Options:
  -l, --list          List keys currently loaded in the ssh-agent. Checks current
                      environment and persisted agent file ($AGENT_ENV_FILE).
  -a, --add           Finds potential private key files (no extension, not known_hosts, etc.)
                      in the SSH directory ($SSH_DIR), deletes all existing keys
                      from the agent, then adds the found keys. Passphrases may be
                      prompted if keys are protected.
  -f <file>, --file <file>
                      Deletes all existing keys from the agent, then adds keys whose
                      basenames are listed (one per line) in the specified <file>.
                      Lines starting with '#' and blank lines in <file> are ignored.
                      Keys must reside in $SSH_DIR.
  -D, --delete-all    Delete all keys currently loaded in the ssh-agent. Prompts for
                      confirmation before proceeding.
  -m, --menu          Show the interactive text-based menu interface for managing keys.
  -v, --verbose       Enable verbose (DEBUG level) logging to the log file. Useful
                      for troubleshooting.
  -h, --help          Display this help message and exit.

Default Behavior:
  If run without any options, this help message is displayed.

Examples:
  $(basename "$0") --list          # List loaded keys
  $(basename "$0") --add           # Reload keys based on 'find' in $SSH_DIR
  $(basename "$0") --file my_keys.txt # Load keys listed in my_keys.txt
  $(basename "$0") --delete-all    # Delete all loaded keys (prompts)
  $(basename "$0") --menu          # Start the interactive menu
  $(basename "$0")                 # Show this help message

Configuration Files & Paths:
  SSH Directory:       $SSH_DIR
  Agent Env File:    $AGENT_ENV_FILE
  Internal Key List: $VALID_KEY_LIST_FILE (Used by -f, -a, menu reload)
  Log File Target:   ${LOG_DIR:-<determined_at_runtime>}/${LOG_FILENAME:-sshkeymanager.log}
                     (Actual path depends on permissions/environment variables like SKM_LOG_DIR)

EOF
}

# ------------------------------------------------------------------------------
# --- Main Interactive Menu Function ---
# ------------------------------------------------------------------------------

# --- run_interactive_menu ---
#
# @description Main loop for the interactive menu mode.
#              Displays the menu, gets user choice, and calls the corresponding
#              action function. Ensures the agent is running before performing
#              actions that require it (reload, delete).
# @arg        None
# @exits      With status 0 when the user chooses 'q' (Quit).
# @exits      With status 1 if initial SSH directory validation fails.
# @prints     Menu, prompts, and output from action functions to stdout/stderr.
# @reads      User input via `get_menu_choice`.
# @stdout     Output from menu and action functions.
# @stderr     Output from menu and action functions.
# @depends    Functions: validate_ssh_dir, display_main_menu, get_menu_choice,
#             _perform_list_keys_check, ensure_ssh_agent, update_keys_list_file,
#             delete_keys_from_agent, add_keys_to_agent, display_log_location,
#             delete_single_key, delete_all_keys, wait_for_key, log_debug, log_info,
#             log_error, log_warn. External command: printf, cp, sleep.
# ---
run_interactive_menu() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Starting SSH Key Manager in Interactive Mode..."
    # Validate SSH directory and ensure agent is running
    if ! validate_ssh_dir; then log_error "Exiting: SSH directory validation failed."; exit 1; fi
    # Agent will be ensured specifically for actions that require it (3, 5, 6)
    local choice list_rc delete_rc # Local variables for the loop
    while true; do
        display_main_menu
        choice=$(get_menu_choice)
        log_info "User selected menu option: [$choice]"
        case "$choice" in
            1)  # Set SSH Directory (Placeholder)
                printf "Set SSH Directory functionality not yet implemented.\n"
                log_warn "Option 1 (Set SSH Directory) selected but not implemented."
                wait_for_key ;;
            2)  # List Keys
                log_debug "Main loop - Case 2: Checking for agent..."
                # Call the consolidated check/list function
                _perform_list_keys_check || true
                # Helper function handles printing messages
                # Ignore return status in menu? Or display error?
                # For now, just call it and then wait.
                wait_for_key ;;
            3)  # Reload All Keys
                printf "\\n--- Reload All Keys (using find) ---\\n"
                log_info "Menu: Reloading all keys selected (uses find -> delete -> add)."
                log_debug "Menu Reload Keys: Ensuring agent is running..."
                # Ensure agent is running before attempting delete/add.
                if ! ensure_ssh_agent; then
                    log_error "Cannot reload keys: Failed to ensure SSH agent is running."
                    printf "Error: Agent not available. Cannot reload keys.\\n" >&2
                    wait_for_key; continue # Go back to menu
                fi

                # --- Start section where errors should not exit script --- 
                set +e 

                # Agent is confirmed running, proceed with reload logic (find -> copy -> delete -> add).
                log_debug "Menu Reload Keys: Agent confirmed. Updating key list..."
                local update_status=0
                update_keys_list_file || update_status=$? # Capture find status

                if [ "$update_status" -ne 0 ]; then
                    log_error "Menu Reload Keys: update_keys_list_file failed (status: $update_status)."
                    if [ "$update_status" -eq 1 ]; then
                        log_info "Menu Reload Keys: No keys found by 'find'. Will still clear agent keys."
                        printf "No potential key files found in %s.\\n" "$SSH_DIR"
                        > "$VALID_KEY_LIST_FILE" || log_warn "Could not clear $VALID_KEY_LIST_FILE"
                    else
                        printf "Error finding keys. Reload aborted.\\n" >&2
                        set -e # Re-enable before waiting
                        wait_for_key; continue # Go back to menu
                    fi
                fi

                # Copy found keys (if any) to the persistent list.
                log_debug "Copying found keys from temp file '$KEYS_LIST_TMP' to '$VALID_KEY_LIST_FILE'"
                if ! cp "$KEYS_LIST_TMP" "$VALID_KEY_LIST_FILE"; then
                     log_error "Failed to copy temp key list '$KEYS_LIST_TMP' to '$VALID_KEY_LIST_FILE'. Reload aborted."
                     printf "Error copying key list. Reload aborted.\\n" >&2
                     set -e # Re-enable before waiting
                     wait_for_key; continue # Go back to menu
                fi
                chmod 600 "$VALID_KEY_LIST_FILE" 2>/dev/null || log_warn "Could not set permissions on $VALID_KEY_LIST_FILE"

                log_info "Deleting existing keys before adding..."
                # Call delete (no || true needed due to set +e)
                    delete_keys_from_agent

                log_info "Adding keys found by find (from list $VALID_KEY_LIST_FILE)..."
                if [ -s "$VALID_KEY_LIST_FILE" ]; then
                    # Call add (no || true needed due to set +e)
                    add_keys_to_agent 
                    local add_status=$?
                    log_debug "add_keys_to_agent finished with status: $add_status"
                else
                     log_info "No keys found to add after filtering/copying."
                     printf "No keys were found in the directory to add.\\n"
                fi

                # --- Re-enable exit on error before waiting --- 
                set -e 

                log_debug "Menu Case 3: About to call wait_for_key..."
                # Always wait for keypress before showing menu again
                wait_for_key
                log_debug "Menu Case 3: Returned from wait_for_key."

                # Re-enable exit-on-error *after* waiting
                set -e
                ;;
            4)  # Display Log Location
                display_log_location
                wait_for_key ;;
            5)  # Delete Single Key
                log_debug "Main loop - Case 5: Calling delete_single_key..."
                log_debug "Menu Delete Single Key: Ensuring agent is running..."
                if ! ensure_ssh_agent; then
                     log_error "Cannot delete single key: Failed to ensure SSH agent is running."
                else
                    # Agent confirmed running, proceed
                delete_single_key
                fi
                wait_for_key ;;
            6)  # Delete All Keys
                log_debug "Main loop - Case 6: Calling delete_all_keys..."
                log_debug "Menu Delete All Keys: Ensuring agent is running..."
                if ! ensure_ssh_agent; then
                     log_error "Cannot delete all keys: Failed to ensure SSH agent is running."
                else
                    # Agent confirmed running, proceed
                    delete_all_keys # Handles confirmation internally
                fi
                wait_for_key ;;
            q|Q) # Quit
                log_info "User selected Quit from menu."
                printf "\nThank you for using SSH Key Manager. Goodbye!\n"
                exit 0 ;;
            *) # Should not happen
                log_error "Main loop - Reached unexpected default case for choice: $choice"
                printf "Error: Unexpected menu choice processed!\n" >&2
                sleep 2 ;;
        esac
        log_debug "Main loop - End of iteration for choice: $choice"
    done
    # Log statement here is unreachable because loop only exits via 'exit 0'
}

# ------------------------------------------------------------------------------
# --- Finalization and Trap Functions ---
# ------------------------------------------------------------------------------

# --- log_execution_time ---
#
# @description Calculates and logs the total script execution time.
#              Called by the EXIT trap handler (_script_exit_handler).
# @arg        None
# @appends    Execution time message to the log file if logging is enabled
#             and start/end times are valid.
# @stdout      None
# @stderr      None
# @depends     Global variables: LOG_FILE, _script_start_time. Functions: log_info,
#             log_warn. External command: date.
# ---
log_execution_time() {
    local end_time script_duration
    # Check if LOG_FILE is set to something other than /dev/null and _script_start_time is set
    if [ "$LOG_FILE" != "/dev/null" ] && [[ -n "$_script_start_time" ]]; then
        end_time=$(date +%s) # Get end time in seconds since epoch.

        # Validate that start and end times look like integers before calculating.
        if [[ "$end_time" =~ ^[0-9]+$ ]] && [[ "$_script_start_time" =~ ^[0-9]+$ ]]; then
             script_duration=$((end_time - _script_start_time))
             log_info "Total script execution time: ${script_duration} seconds."
        else
             log_warn "Could not calculate execution time: Invalid start or end time (Start: '${_script_start_time}', End: '${end_time}')"
        fi
    fi
}

# --- _cleanup_temp_file ---
#
# @description Removes the temporary file created by `mktemp` for key listing.
#              Called by the EXIT/ERR trap handler (_script_exit_handler).
#              Checks if the temporary file variable is set and if the file exists.
# @arg        None
# @modifies   Deletes the file pointed to by $KEYS_LIST_TMP.
# @stdout      None
# @stderr      None
# @depends     Global variable: KEYS_LIST_TMP, IS_VERBOSE. Function: log_debug.
#             External command: rm.
# ---
_cleanup_temp_file() {
    if [ -n "${KEYS_LIST_TMP:-}" ] && [ -f "$KEYS_LIST_TMP" ]; then
        # Log removal only if verbose, as this happens on every exit.
        # Use command -v check as log_debug might not be defined on very early errors.
        if command -v log_debug >/dev/null && [ "$IS_VERBOSE" = "true" ]; then
             log_debug "Cleanup trap: Removing temporary file '$KEYS_LIST_TMP'";
        fi
        rm -f "$KEYS_LIST_TMP"
    fi
}

# --- _script_exit_handler ---
#
# @description Combined trap handler function called on script EXIT (normal or via exit command)
#              and ERR (due to `set -e` or explicit error).
#              Ensures both cleanup and final logging actions are performed.
# @arg        None - implicitly receives script's exit status in $?.
# @calls      _cleanup_temp_file
# @calls      log_execution_time
# @stdout      None
# @stderr      None
# @depends     Functions: _cleanup_temp_file, log_execution_time, log_debug.
# ---
_script_exit_handler() {
    local exit_status=$? # Capture the script's exit status *immediately*.
    log_debug "_script_exit_handler triggered (Script Exit Status: $exit_status)"

    # Perform cleanup actions.
    _cleanup_temp_file      # Always clean up temp file

    # Perform final logging actions.
    # log_execution_time checks internally if logging is enabled.
    log_execution_time

    # No need to explicitly exit here; the trap handler finishes and script exit proceeds.
    log_debug "_script_exit_handler finished."
}

# ==============================================================================
# --- Main Script Logic ---
# ==============================================================================

# --- main ---
#
# @description Main execution function of the script.
#              Parses command-line arguments, performs runtime initialization
#              (logging, temp file), and dispatches control to the appropriate
#              action function based on parsed arguments or defaults to help.
# @arg        $@ All command-line arguments passed to the script.
# @exits      Delegates exit status determination to the called action functions
#             (run_*, display_help, run_interactive_menu). Exits with 1 on
#             initialization errors (e.g., mktemp failure) or argument parsing errors.
# @stdout      Output from dispatched action functions or help message.
# @stderr      Output from dispatched action functions or error messages.
# @depends     All other functions indirectly. Global variables: ACTION, IS_VERBOSE,
#             source_key_file, PLATFORM, STAT_CMD, LOG_FILE, LOG_DIR, LOG_FILENAME,
#             SSH_DIR, VALID_KEY_LIST_FILE, AGENT_ENV_FILE, KEYS_LIST_TMP, _script_start_time.
#             Functions: setup_logging, log_debug, log_info, log_error, display_help,
#             run_list_keys, run_load_keys, run_load_keys_from_file, run_delete_all_cli,
#             run_interactive_menu. External commands: mktemp, printf.
# ---
main() {
    # --- Argument Parsing ---
    # Loop through arguments, update global ACTION, IS_VERBOSE, source_key_file.
    # Sets local parse_error=1 if invalid options/arguments are found.
    # Allows only the *first* action flag encountered to set the ACTION.
    local parse_error=0          # Flag for parsing errors.
    local FIRST_ACTION_SET=0     # Flag to ensure only one action is processed.
    local args_copy=("$@")       # Copy arguments to avoid issues with modifying $@.
    local i=0
    while [ $i -lt ${#args_copy[@]} ]; do
        local arg="${args_copy[$i]}"
        case $arg in
        -l|--list)
                if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="list"; FIRST_ACTION_SET=1; fi
                i=$((i + 1)) ;;
        -a|--add)
                if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="add"; FIRST_ACTION_SET=1; fi
                i=$((i + 1)) ;;
        -f|--file)
                 # Expects a filename as the next argument.
                 local next_arg_index=$((i + 1))
                 local next_arg="${args_copy[$next_arg_index]:-}" # Get next arg or empty string if none.
                 # Check if next argument exists and doesn't look like another option.
                 if [[ -z "$next_arg" || "${next_arg:0:1}" == "-" ]]; then
                     printf "Error: Option '%s' requires a filename argument.\\n\\n" "$arg" >&2
                     ACTION="help"; parse_error=1; break # Force help display and mark error.
                 fi
                 # Set action only if it's the first one.
                 if [ "$FIRST_ACTION_SET" -eq 0 ]; then
                     ACTION="file"; source_key_file="$next_arg"; FIRST_ACTION_SET=1
                 else
                      printf "Warning: Ignoring subsequent action flag '%s' after action '%s' was already set.\\n" "$arg" "$ACTION" >&2
                 fi
                 i=$((i + 2)) ;; # Consume both -f and filename.
        -D|--delete-all)
                if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="delete-all"; FIRST_ACTION_SET=1; fi
                i=$((i + 1)) ;;
        -m|--menu)
                if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="menu"; FIRST_ACTION_SET=1; fi
                i=$((i + 1)) ;;
        -v|--verbose)
                IS_VERBOSE="true" # Set global flag for verbose logging.
                i=$((i + 1)) ;;
        -h|--help)
                # Help action can override previous actions if encountered.
                ACTION="help"; FIRST_ACTION_SET=1; parse_error=0 # Explicit help is not an error.
                i=$((i + 1)) ;;
            *) # Unknown option.
                printf "Error: Unknown option '%s'\\n\\n" "$arg" >&2
                ACTION="help"; parse_error=1; break # Force help display and mark error.
            ;;
    esac
done

    # --- Runtime Initialization ---

    # Setup logging. This must happen after IS_VERBOSE might be set by args.
    if ! setup_logging; then
        # setup_logging already prints warnings.
        printf "Warning: Logging setup failed. Continuing with logging disabled.\\n" >&2
        # LOG_FILE remains /dev/null (default), logging functions will be no-ops.
    fi

    # Log initial state and configuration (only works if setup_logging succeeded).
    log_debug "--- Script Start ---"
    log_debug "Timestamp: $_script_start_time"
    log_debug "Arguments: $*"
    log_debug "Parsed Action: '$ACTION'"
    log_debug "Verbose Logging: '$IS_VERBOSE'"
    log_debug "Source Key File: '${source_key_file:-N/A}'"
    log_debug "Argument Parse Error: '$parse_error'"
    log_debug "Platform: $PLATFORM"
    log_debug "Stat Command: $STAT_CMD"
    log_debug "SSH Directory: $SSH_DIR"
    log_debug "Agent Env File: $AGENT_ENV_FILE"
    log_debug "Valid Key List File: $VALID_KEY_LIST_FILE"
    log_debug "Log Directory: $LOG_DIR"
    log_debug "Log Filename: $LOG_FILENAME"
    log_debug "Log File Path: $LOG_FILE"

    # Create Temporary File for `find` results. Needs to be done *after* logging setup
    # so potential errors can be logged. Assign path to global KEYS_LIST_TMP.
    if ! KEYS_LIST_TMP=$(mktemp "${TMPDIR:-/tmp}/ssh_keys_list.XXXXXX"); then
        log_error "Fatal: Failed to create temporary file using mktemp. Check permissions in '${TMPDIR:-/tmp}'."
        printf "Error: Could not create required temporary file. Exiting.\\n" >&2
        exit 1 # Critical failure, cannot proceed.
    fi
    log_debug "Temporary file created: $KEYS_LIST_TMP"
    # Temp file will be removed by the EXIT trap handler.

    # --- Dispatch Action ---
    # Execute the function corresponding to the determined ACTION.
    log_info "Selected action: $ACTION"
case $ACTION in
        list)       run_list_keys ;;               # Exits script internally.
        add)        run_load_keys ;;               # Exits script internally.
        file)       run_load_keys_from_file "$source_key_file" ;; # Exits script internally.
        delete-all) run_delete_all_cli ;;          # Exits script internally.
        menu)       run_interactive_menu ;;        # Exits script internally (on quit).
        help|*)     # Default action or explicit help.
            display_help # Display the help message.
            if [ "$parse_error" -eq 1 ]; then
                exit 1 # Exit with error status if help was shown due to a parsing error.
            else
                exit 0 # Exit successfully if help was default or explicit -h/--help.
            fi
        ;;
esac

    # This point should ideally not be reached if dispatch logic and called functions are correct
    # (as they should exit the script). If reached, it indicates an unexpected control flow error.
    log_error "Critical Error: Script main function reached end unexpectedly after dispatching action: $ACTION."
    printf "Error: Unexpected script termination. Please check logs: %s\\n" "${LOG_FILE:-N/A}" >&2
    exit 1 # Exit with error for unexpected fallthrough.
}

# ==============================================================================
# --- Trap Definitions ---
# ==============================================================================
# Traps must be defined *after* the functions they call.

# Register the single combined handler function to run on:
# - EXIT: Normal script termination (end of script or explicit `exit` command).
# - ERR: Script termination due to an error when `set -e` is active.
trap '_script_exit_handler' EXIT ERR
log_debug "EXIT and ERR traps set to call _script_exit_handler."

# ==============================================================================
# --- Main Execution ---
# ==============================================================================
# Call the main function, passing all script arguments ($@).
# The main function handles argument parsing and action dispatching.
# Script execution begins here.
main "$@"
# Script exits within main() or its dispatched functions, or via traps.