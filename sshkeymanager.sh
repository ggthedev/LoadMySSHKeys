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
# - Key loading from SSH directory
# - Individual and bulk key deletion
# - Comprehensive logging system
# - Directory validation and management
#
# Author: [Your Name]
# Version: 1.0.0
# License: MIT
#

# --- Script Initialization ---
_script_start_time=$(date +%s.%N) # Use %s.%N for nanoseconds if supported
set -euo pipefail

# --- Global Variable Declarations ---

# Control Flags
declare IS_VERBOSE="false"

# Logging Configuration
declare LOG_FILE="/dev/null" # Default: Ensure variable exists for traps
declare LOG_FILENAME="${SKM_LOG_FILENAME:-sshkeymanager.log}"
# Platform-specific log directory preferences (used in setup_logging):
declare LOG_DIR_MACOS="$HOME/Library/Logs/sshkeymanager"
declare LOG_DIR_LINUX_VAR="/var/log/sshkeymanager"
declare LOG_DIR_LINUX_LOCAL="$HOME/.local/log/sshkeymanager"
declare LOG_DIR_FALLBACK="$HOME/.ssh/logs" # Fallback if others fail
# Actual LOG_DIR will be determined in setup_logging
declare LOG_DIR=""

# Platform Detection & Platform-Specific Settings
declare PLATFORM
PLATFORM=$(uname -s)
declare STAT_CMD
case "$PLATFORM" in
    "Darwin")
        STAT_CMD="stat -f %z"
        ;;
    "Linux")
        STAT_CMD="stat -c %s"
        ;;
    *)
        STAT_CMD="stat -c %s" # Default to Linux style
        ;;
esac

# Core Application Paths
declare SSH_DIR="${SKM_SSH_DIR:-$HOME/.ssh}"
declare VALID_KEY_LIST_FILE="${SKM_VALID_KEYS_FILE:-$HOME/.config/sshkeymanager/ssh_keys_list}"
declare AGENT_ENV_FILE="${SKM_AGENT_ENV_FILE:-$HOME/.config/agent.env}"

# Temporary File (Declared here, created in main())
declare KEYS_LIST_TMP=""

# Script Action State (Set by argument parsing in main())
declare ACTION="help" # Default action
declare source_key_file=""

# --- Function Definitions ---

# --- Logging Functions ---
setup_logging() {
    local max_log_size=1048576  # 1MB
    local max_log_files=5

    # Determine LOG_DIR based on platform and environment override
    # Use SKM_LOG_DIR env var if set, otherwise determine based on platform
    if [ -n "${SKM_LOG_DIR:-}" ]; then
         LOG_DIR="$SKM_LOG_DIR"
         # Log this choice later, after LOG_FILE is potentially usable
    else
        case "$PLATFORM" in
            "Darwin")
                LOG_DIR="$LOG_DIR_MACOS"
                ;;
            "Linux")
                # Prefer /var/log if writable, else local user log
                if [ -w "$LOG_DIR_LINUX_VAR" ]; then
                     LOG_DIR="$LOG_DIR_LINUX_VAR"
                else
                     LOG_DIR="$LOG_DIR_LINUX_LOCAL"
                fi
                ;;
            *)
                LOG_DIR="$LOG_DIR_FALLBACK" # Default for other systems
                ;;
        esac
    fi

    local initial_log_dir="$LOG_DIR" # Store determined dir for messages

    # Create log directory if it doesn't exist
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf "Warning: Could not create log directory '$initial_log_dir'. Trying fallback '$LOG_DIR_FALLBACK'.\\n" >&2
        LOG_DIR="$LOG_DIR_FALLBACK"
        if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
            printf "Warning: Could not create fallback log directory. Logging disabled.\\n" >&2
            LOG_FILE="/dev/null" # Ensure it stays /dev/null
            return 1
        fi
    fi

    # Now LOG_DIR should be valid, set the LOG_FILE path
    # This assignment makes LOG_FILE potentially usable by subsequent logging calls
    LOG_FILE="${LOG_DIR}/${LOG_FILENAME}"

    # Use printf for initial messages as log_debug might not work if IS_VERBOSE isn't set yet
    if [ "$IS_VERBOSE" = "true" ]; then printf "DEBUG: Determined log directory: %s\\n" "$LOG_DIR"; fi
    if [ "$IS_VERBOSE" = "true" ]; then printf "DEBUG: Attempting log file: %s\\n" "$LOG_FILE"; fi

    # Set up log file with rotation
    if ! touch "$LOG_FILE" 2>/dev/null; then
        printf "Warning: Could not create log file '%s'. Logging disabled.\\n" "$LOG_FILE" >&2
        LOG_FILE="/dev/null" # Reset to /dev/null on failure
        return 1
    fi

    # Rotate logs if needed
    if [ -f "$LOG_FILE" ]; then
        local log_size
        if ! log_size=$($STAT_CMD "$LOG_FILE" 2>/dev/null); then
            printf "Warning: Could not determine log file size. Log rotation disabled.\\n" >&2
        elif [ "$log_size" -gt "$max_log_size" ]; then
            if [ "$IS_VERBOSE" = "true" ]; then printf "DEBUG: Rotating logs (size %s > %s)...\\n" "$log_size" "$max_log_size"; fi
            for i in $(seq $((max_log_files-1)) -1 1); do
                [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))" 2>/dev/null || true
            done
            mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
            touch "$LOG_FILE" # Create new empty log file
        fi
    fi

    chmod 600 "$LOG_FILE" 2>/dev/null || true
    # Now log_debug should work if IS_VERBOSE is true
    log_debug "Logging setup complete. LOG_FILE set to: $LOG_FILE"
    return 0
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

# --- Validation Functions ---
validate_directory() {
    log_debug "Entering function: ${FUNCNAME[0]} (Dir: $1, Desc: $2)"
    local dir="$1"
    local description="$2"
    local return_status=0
    if [ ! -d "$dir" ]; then
        log_error "Validation failed: $description directory '$dir' does not exist."
        return_status=1
    elif [ ! -r "$dir" ]; then
        log_error "Validation failed: $description directory '$dir' is not readable."
        return_status=1
    elif [ ! -w "$dir" ]; then
        log_error "Validation failed: $description directory '$dir' is not writable."
        return_status=1
    elif [ ! -x "$dir" ]; then
        log_error "Validation failed: $description directory '$dir' is not accessible."
        return_status=1
    else
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
            return 1
        fi
        log_info "Successfully created SSH directory '$SSH_DIR'."
        printf "Successfully created SSH directory '%s'.\n" "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        log_debug "Set permissions (700) on '$SSH_DIR'."
    fi
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0
}

# --- SSH Agent Management Functions ---
check_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "Checking agent status... (PID='${SSH_AGENT_PID:-}', SOCK='${SSH_AUTH_SOCK:-}')"
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ -z "${SSH_AGENT_PID:-}" ]; then
        log_debug "check_ssh_agent: Required SSH_AUTH_SOCK or SSH_AGENT_PID not set."; return 1;
    fi
    if [ ! -S "$SSH_AUTH_SOCK" ]; then
        log_debug "check_ssh_agent: SSH_AUTH_SOCK ('$SSH_AUTH_SOCK') is not a valid socket."; return 1;
    fi
    if ! ps -p "$SSH_AGENT_PID" > /dev/null 2>&1; then
        log_error "check_ssh_agent: Agent process PID '$SSH_AGENT_PID' not running."; return 1;
    fi
    # Check communication
    ssh-add -l > /dev/null 2>&1 || true
    local exit_code=${PIPESTATUS[0]:-$?}
    log_debug "check_ssh_agent: ssh-add -l exit code: $exit_code"
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 1 ]; then
        log_debug "Agent communication successful (exit code $exit_code)."; return 0;
    else
        log_error "check_ssh_agent: Cannot communicate with agent (ssh-add -l exit code $exit_code)."; return 1;
    fi
}

ensure_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Ensuring SSH agent is active..."
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -n "${SSH_AGENT_PID:-}" ] && check_ssh_agent; then
        log_info "Agent already running and sourced (PID: ${SSH_AGENT_PID:-})."
        printf "SSH agent is already running (PID: %s).\n" "${SSH_AGENT_PID:-Unknown}"
        export SSH_AUTH_SOCK SSH_AGENT_PID # Ensure exported
        return 0
    fi
    log_debug "Agent not running or sourced in current environment."
    if [ -f "$AGENT_ENV_FILE" ]; then
        log_debug "Sourcing persistent agent file: $AGENT_ENV_FILE"
        # shellcheck disable=SC1090
        . "$AGENT_ENV_FILE" >/dev/null
        if check_ssh_agent; then
            log_info "Sourced persistent file. Reusing agent (PID: ${SSH_AGENT_PID:-})."
            printf "Successfully connected to existing ssh-agent (PID: %s).\n" "${SSH_AGENT_PID:-Unknown}"
            export SSH_AUTH_SOCK SSH_AGENT_PID # Ensure exported
            return 0
        else
            log_debug "Agent file '$AGENT_ENV_FILE' found but agent invalid after sourcing. Removing stale file."
            rm -f "$AGENT_ENV_FILE"
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    fi
    log_info "Starting new ssh-agent..."
    printf "Starting new ssh-agent...\n"
    if ! mkdir -p "$HOME/.ssh"; then log_error "Failed to create $HOME/.ssh directory."; return 1; fi
    chmod 700 "$HOME/.ssh" || log_warn "Failed to set permissions on $HOME/.ssh"
    local agent_output
    if ! agent_output=$(ssh-agent -s); then
        log_error "Failed to execute ssh-agent -s."; return 1;
    fi
    log_debug "ssh-agent -s output captured."
    # Extract and export vars
    eval "$agent_output" > /dev/null # Use eval to export directly
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ -z "${SSH_AGENT_PID:-}" ]; then
        log_error "Failed to parse/export vars from ssh-agent output."; return 1;
    fi
    log_info "Extracted new agent details: SOCK=$SSH_AUTH_SOCK PID=$SSH_AGENT_PID"
    # Save to persistent file
    log_debug "Saving agent environment to $AGENT_ENV_FILE"
    echo "$agent_output" > "$AGENT_ENV_FILE" # Save the raw output for sourcing
    chmod 600 "$AGENT_ENV_FILE" || log_warn "Failed to set permissions on $AGENT_ENV_FILE"
    log_info "Agent environment saved to $AGENT_ENV_FILE."
    sleep 0.5 # Give agent a moment
    if check_ssh_agent; then
        log_info "New agent started and verified successfully."
        printf "Successfully started new ssh-agent (PID: %s).\n" "$SSH_AGENT_PID"
        return 0
    else
        log_error "Started new agent but failed final verification!"
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        rm -f "$AGENT_ENV_FILE"
        return 1
    fi
}

# --- Core Key Management Functions ---
update_keys_list_file() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Finding potential private key files in $SSH_DIR..."
    log_debug "Clearing temporary key list file: $KEYS_LIST_TMP"
    > "$KEYS_LIST_TMP"
    log_debug "Running find command for platform $PLATFORM..."
    # Using simplified find, potentially excluding password-protected or incompatible keys.
    # Excludes files with extensions, known_hosts, authorized_keys, config.
    if [[ "$PLATFORM" == "Darwin" ]]; then
        find "$SSH_DIR" -maxdepth 1 -type f \
            ! -name 'known_hosts*' ! -name 'authorized_keys*' ! -name '*.*' ! -name 'config' \
            -exec basename {} \; > "$KEYS_LIST_TMP"
    else
        find "$SSH_DIR" -maxdepth 1 -type f \
            ! -name 'known_hosts*' ! -name 'authorized_keys*' ! -name '*.*' ! -name 'config' \
            -printf '%f\n' > "$KEYS_LIST_TMP"
    fi
    local key_count
    key_count=$(wc -l < "$KEYS_LIST_TMP")
    log_info "Found $key_count potential key entries in temp file $KEYS_LIST_TMP."
    if [ "$key_count" -eq 0 ]; then
        printf "No potential SSH key files found in %s\n" "$SSH_DIR"
        log_info "No potential SSH key files found in $SSH_DIR using find logic."
        return 1
    else
        printf "Found %d potential key file(s) in %s (written to temp list).\n" "$key_count" "$SSH_DIR"
        return 0
    fi
}

delete_keys_from_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Attempting to delete all keys from ssh-agent..."
    ssh-add -D || true
    local del_status=${PIPESTATUS[0]:-$?}
    log_debug "ssh-add -D exit status: $del_status"
    if [ "$del_status" -eq 0 ]; then
        log_info "All keys successfully deleted from agent."
        printf "All keys successfully deleted from agent.\n"
        return 0
    elif [ "$del_status" -eq 1 ]; then
        log_info "No keys found in agent to delete (status: $del_status)."
        printf "No keys found in agent to delete.\n"
        return 0 # Treat as success
    else
        log_error "Failed to delete keys from agent (ssh-add -D status: $del_status)."
        return 1
    fi
}

add_keys_to_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Adding keys listed in $VALID_KEY_LIST_FILE..."
    if [ ! -s "$VALID_KEY_LIST_FILE" ]; then
        log_error "Key list file '$VALID_KEY_LIST_FILE' is empty or missing."
        printf "Key list file '%s' is empty or does not exist. Cannot add keys.\n" "$VALID_KEY_LIST_FILE"
        return 1
    fi
    printf "Adding SSH keys to agent (using list: %s)...\n" "$VALID_KEY_LIST_FILE"
    local keyfile key_path added_count=0 failed_count=0 ssh_add_output ssh_add_status cmd_to_run
    while IFS= read -r keyfile || [[ -n "$keyfile" ]]; do
        [ -z "$keyfile" ] && continue
        key_path="$SSH_DIR/$keyfile"
        log_debug "Processing key entry: $keyfile (Path: $key_path)"
        if [ -f "$key_path" ]; then
            log_info "Attempting to add key: $key_path"
            if [[ "$PLATFORM" == "Darwin" ]]; then
                cmd_to_run="ssh-add --apple-use-keychain \"$key_path\""
                ssh_add_output=$(ssh-add --apple-use-keychain "$key_path" 2>&1 || true)
            else
                cmd_to_run="ssh-add \"$key_path\""
                ssh_add_output=$(ssh-add "$key_path" 2>&1 || true)
            fi
            ssh_add_status=${PIPESTATUS[0]:-$?}
            log_debug "ssh-add command ('$cmd_to_run') status: $ssh_add_status"
            if [ "$ssh_add_status" -ne 0 ]; then log_debug "ssh-add output: $ssh_add_output"; fi

            if [ "$ssh_add_status" -eq 0 ]; then
                log_info "Successfully added $keyfile"
                ((added_count++))
            else
                printf "  ✗ Failed to add key '%s' (status: %d)\n" "$keyfile" "$ssh_add_status"
                log_error "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status)."
                ((failed_count++))
            fi
        else
            printf "  ✗ Key file '%s' not found at '%s'\n" "$keyfile" "$key_path"
            log_warn "Key file '$keyfile' listed but not found at '$key_path'."
            ((failed_count++))
        fi
    done < "$VALID_KEY_LIST_FILE"
    printf "\nSummary: %d key(s) added, %d key(s) failed.\n" "$added_count" "$failed_count"
    log_info "Finished adding keys. Added: $added_count, Failed: $failed_count"
    [ "$added_count" -gt 0 ] && return 0 || return 1
}

# --- Interactive Menu Helper Functions ---
display_main_menu() {
    log_debug "Displaying main menu..."
    clear
    printf "\n======= SSH Key Manager Menu =======\n"
    printf " Platform: %s\n" "$PLATFORM"
    printf " SSH Directory: %s\n" "$SSH_DIR"
    printf "++++++++++++++++++++++++++++++++++++\n"
    printf " Please choose an option:\n"
    printf "   1) Set SSH Directory (Not Implemented)\n"
    printf "   2) List Current Keys\n"
    printf "   3) Reload All Keys\n"
    printf "   4) Display Log File Location\n"
    printf "   5) Delete Single Key\n"
    printf "   6) Delete All Keys\n"
    printf "   q) Quit\n"
    printf "++++++++++++++++++++++++++++++++++++\n"
}

get_menu_choice() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local choice
    while true; do
        read -r -p "Enter choice [1-6, q]: " choice < /dev/tty
        log_debug "User entered: '$choice'"
        case "$choice" in
            [1-6]|q|Q) echo "$choice"; return 0 ;;
            *) printf "Invalid choice '%s'. Please try again.\n" "$choice"; log_warn "Invalid menu choice: '$choice'" ;;
        esac
    done
}

wait_for_key() {
    printf "\nPress any key to return to the main menu...\n"
    read -n 1 -s -r < /dev/tty
}

# --- Interactive Menu Core Logic Functions ---
list_current_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Listing current keys in agent..."
    ssh-add -l >/dev/null 2>&1 || true
    local exit_code=${PIPESTATUS[0]:-$?}
    log_debug "Initial ssh-add -l status check: $exit_code"
    case $exit_code in
        0) # Keys are present
            printf "Keys currently loaded in the agent:\n"
            log_info "Keys currently loaded in the agent:"
            local key_list
            key_list=$(ssh-add -l 2>&1 || true)
            local list_exit_code=${PIPESTATUS[0]:-$?}
            log_debug "Second ssh-add -l status: $list_exit_code"
            if [ -n "$key_list" ]; then
                printf "%s\n" "$key_list"
                log_info "List of keys reported by agent:\n$key_list"
            fi
            if [ "$list_exit_code" -ne 0 ] && [ "$list_exit_code" -ne 1 ]; then
                log_error "ssh-add -l failed unexpectedly (exit code $list_exit_code)."
                printf "Error listing keys (Code: %s).\n" "$list_exit_code" >&2
                return 1
            fi
            ;;
        1) # No keys loaded
            printf "No keys currently loaded in the agent.\n"
            printf "Hint: Use option 3 to load keys from '%s'.\n" "$SSH_DIR"
            log_info "No keys currently loaded."
            ;;
        2) # Cannot connect
            log_error "Could not connect to the SSH agent (ssh-add -l exit code 2)."
            printf "Error: Could not connect to the SSH agent. Is it running?\n" >&2
            return 1
            ;;
        *) # Unknown error
            log_error "Unknown error from ssh-add -l check (Exit code: $exit_code)."
            printf "Error: An unexpected error occurred checking keys (Code: %s).\n" "$exit_code" >&2
            return 1
            ;;
    esac
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0
}

display_log_location() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Log File Information +++\n"
    if [ "$LOG_FILE" = "/dev/null" ]; then
        printf "Logging is currently disabled.\n"
        log_info "Logging is disabled."
    else
        printf "Current log file location: %s\n" "$LOG_FILE"
        local log_size_human="-"
        if [ -f "$LOG_FILE" ]; then
            log_size_human=$(ls -lh "$LOG_FILE" 2>/dev/null | awk '{print $5}')
        else
             log_warn "Log file $LOG_FILE not found when trying to get size."
        fi
        printf "Log file size: %s\n" "$log_size_human"
        log_info "Displaying log file location: $LOG_FILE (Size: $log_size_human)"
    fi
    printf "++++++++++++++++++++++++++++++++++++\n"
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0
}

delete_single_key() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Delete Single Key +++\n"
    # Check agent status first
    ssh-add -l >/dev/null 2>&1 || true
    local agent_check_status=${PIPESTATUS[0]:-$?}
    if [ "$agent_check_status" -eq 1 ]; then # No keys loaded
        printf "No keys currently loaded in ssh-agent to delete.\n"
        log_info "delete_single_key: No keys loaded, nothing to do."
        return 0
    elif [ "$agent_check_status" -ne 0 ]; then # Error connecting (status 2 or other)
        log_error "delete_single_key: Cannot query agent (ssh-add -l status: $agent_check_status)."
        printf "Error: Could not query the SSH agent (status: %d).\n" "$agent_check_status" >&2
        return 1
    fi
    # Agent has keys, proceed
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
    printf "Select a key file to remove from the agent:\n"
    local i choice selected_index selected_filename key_path del_status return_status=1
    for i in "${!key_files[@]}"; do
        printf "  %2d) %s\n" "$((i + 1))" "${key_files[i]}"
    done
    while true; do
        read -r -p "Enter key number to delete (or 'c' to cancel): " choice < /dev/tty
        log_debug "User entered selection: '$choice'"
        case "$choice" in
            c|C) printf "Operation cancelled.\n"; log_info "User cancelled deletion."; return_status=0; break ;;
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

delete_all_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Delete All Keys +++\n"
    # Check agent status first
    ssh-add -l >/dev/null 2>&1 || true
    local agent_check_status=${PIPESTATUS[0]:-$?}
    local key_count=0
    if [ "$agent_check_status" -eq 1 ]; then # No keys loaded
        printf "No keys currently loaded in ssh-agent.\n"
        log_info "delete_all_keys: No keys loaded, nothing to do."
        return 0
    elif [ "$agent_check_status" -ne 0 ]; then # Error connecting (status 2 or other)
        log_error "delete_all_keys: Cannot query agent (ssh-add -l status: $agent_check_status)."
        printf "Error: Could not query the SSH agent (status: %d).\n" "$agent_check_status" >&2
        return 1
    else # Keys might be present, count them
         key_count=$(ssh-add -l | wc -l) # Count lines from actual output
         log_debug "Agent check status 0, counted $key_count keys."
         if [ "$key_count" -eq 0 ]; then # Should not happen if status was 0, but check
             printf "No keys currently loaded in ssh-agent.\n"
             log_warn "delete_all_keys: ssh-add -l status 0 but key count is 0."
             return 0
         fi
    fi
    # Agent has keys, proceed with confirmation
    printf "This will delete all %d keys from ssh-agent.\n" "$key_count"
    local confirm del_status return_status=1
    read -r -p "Are you sure you want to continue? (y/N): " confirm < /dev/tty
    log_debug "User confirmation: '$confirm'"
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

# --- CLI Action Functions ---
run_list_keys() {
    log_info "CLI Action: Listing keys..."
    if ! validate_ssh_dir; then exit 1; fi
    if ! ensure_ssh_agent; then exit 1; fi
    list_current_keys
    exit $? # Exit with the status of list_current_keys
}

run_load_keys() {
    log_info "CLI Action: Loading keys (using find)..."
    if ! validate_ssh_dir; then exit 1; fi
    if ! ensure_ssh_agent; then exit 1; fi
    # Update the temporary file using find
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

run_delete_all_cli() {
    log_info "CLI Action: Deleting all keys..."
    if ! validate_ssh_dir; then exit 1; fi
    if ! ensure_ssh_agent; then exit 1; fi
    # delete_all_keys handles confirmation internally
    delete_all_keys
    exit $? # Exit with the status of delete_all_keys
}

run_load_keys_from_file() {
    local source_key_file="$1" # Arg passed from main()
    log_info "CLI Action: Loading keys from file: $source_key_file"
    if [ ! -f "$source_key_file" ] || [ ! -r "$source_key_file" ]; then
        log_error "Source key list file not found or not readable: '$source_key_file'"
        exit 1
    fi
    # Validate target dir for VALID_KEY_LIST_FILE
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

# --- Help Function ---
display_help() {
    # Use cat heredoc for easier formatting
    # Log File location might not be accurate if setup_logging fails, but show default target.
    cat << EOF
SSH Key Manager - $(basename "$0")

Manages SSH keys in ssh-agent.

Usage: $(basename "$0") [OPTIONS]

Options:
  -l, --list          List keys currently loaded in the ssh-agent.
  -a, --add           Add all keys found in the SSH directory ($SSH_DIR) to the agent
                      (uses simple find logic, deletes existing keys first).
                      NOTE: This may differ from keys loaded by other tools.
  -f <file>, --file <file>
                      Add keys listed (one basename per line) in the specified <file>.
                      '#' comments and blank lines ignored. Deletes existing keys first.
  -D, --delete-all    Delete all keys currently loaded in the ssh-agent (prompts).
  -m, --menu          Show the interactive menu interface.
  -v, --verbose       Enable verbose (DEBUG level) logging to the log file.
  -h, --help          Display this help message and exit.

Default Behavior:
  If run without any options, this help message is displayed.

Examples:
  $(basename "$0") --list          # List loaded keys
  $(basename "$0") --add           # Reload keys based on simple find in $SSH_DIR
  $(basename "$0") --file my_keys.txt # Load keys listed in my_keys.txt
  $(basename "$0") --delete-all    # Delete all loaded keys (prompts)
  $(basename "$0")                 # Show this help message
  $(basename "$0") --menu          # Start the interactive menu

Log File Target: ${LOG_DIR:-unavailable}/${LOG_FILENAME:-unavailable} (Actual path depends on permissions/environment)

EOF
}

# --- Main Interactive Menu Function ---
run_interactive_menu() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Starting SSH Key Manager in Interactive Mode..."
    # Validate SSH directory and ensure agent is running
    if ! validate_ssh_dir; then log_error "Exiting: SSH directory validation failed."; exit 1; fi
    if ! ensure_ssh_agent; then log_error "Exiting: Failed to ensure SSH agent is running."; exit 1; fi
    log_info "Agent setup complete. SOCK='${SSH_AUTH_SOCK:-}', PID='${SSH_AGENT_PID:-}'"
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
                list_current_keys
                wait_for_key ;;
            3)  # Reload All Keys
                printf "Reloading all keys (using simple find)...\n"
                log_info "Reloading all keys selected (uses find -> delete -> add)."
                if ! update_keys_list_file; then
                    log_error "Failed to find keys to reload." # Error already printed by func
                else
                    log_debug "Copying found keys from temp file $KEYS_LIST_TMP to $VALID_KEY_LIST_FILE"
                    cp "$KEYS_LIST_TMP" "$VALID_KEY_LIST_FILE" || { log_error "Failed to copy temp key list."; }
                    log_info "Deleting existing keys before adding..."
                    delete_keys_from_agent # Ignore error?
                    log_info "Adding keys found by find..."
                    add_keys_to_agent # Log error if failed?
                fi
                wait_for_key ;;
            4)  # Display Log Location
                display_log_location
                wait_for_key ;;
            5)  # Delete Single Key
                delete_single_key
                wait_for_key ;;
            6)  # Delete All Keys
                delete_all_keys # Handles confirmation internally
                wait_for_key ;;
            q|Q) # Quit
                log_info "User selected Quit."
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

# --- Finalization Functions (for Traps) ---
log_execution_time() {
    local end_time script_duration
    # Use -v to safely check if LOG_FILE is set, even with set -u
    if [ -v LOG_FILE ] && [ -n "$LOG_FILE" ] && [ "$LOG_FILE" != "/dev/null" ]; then
        if [[ -n "$_script_start_time" ]]; then
            end_time=$(date +%s.%N)
            if command -v bc > /dev/null; then
                script_duration=$(echo "$end_time - $_script_start_time" | bc -l)
                printf -v script_duration "%.3f" "$script_duration"
            else
                local start_seconds end_seconds
                start_seconds=$(echo "$_script_start_time" | cut -d. -f1)
                end_seconds=$(echo "$end_time" | cut -d. -f1)
                script_duration=$((end_seconds - start_seconds))
                log_warn "'bc' command not found, reporting execution time in integer seconds."
            fi
            log_info "Total script execution time: ${script_duration} seconds."
        fi
    fi
}

_cleanup_temp_file() {
    if [ -n "${KEYS_LIST_TMP:-}" ] && [ -f "$KEYS_LIST_TMP" ]; then
        # Logging might not be available on early exit or if setup failed
        if command -v log_debug >/dev/null && [ "$IS_VERBOSE" = "true" ]; then
             log_debug "Cleanup trap: Removing temporary file $KEYS_LIST_TMP";
        fi
        rm -f "$KEYS_LIST_TMP"
    fi
}

# --- main() Function ---
main() {
    # --- Argument Parsing ---
    # Updates global ACTION, IS_VERBOSE, source_key_file
    # Sets local parse_error flag
    local parse_error=0
    local FIRST_ACTION_SET=0
    local args_copy=("$@")
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
                 local next_arg_index=$((i + 1))
                 local next_arg="${args_copy[$next_arg_index]:-}"
                 if [[ -z "$next_arg" || "${next_arg:0:1}" == "-" ]]; then
                     printf "Error: Option '%s' requires a filename argument.\\n\\n" "$arg" >&2
                     ACTION="help"; parse_error=1; break
                 fi
                 if [ "$FIRST_ACTION_SET" -eq 0 ]; then
                     ACTION="file"; source_key_file="$next_arg"; FIRST_ACTION_SET=1
                 fi
                 i=$((i + 2)) ;;
            -D|--delete-all)
                if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="delete-all"; FIRST_ACTION_SET=1; fi
                i=$((i + 1)) ;;
            -m|--menu)
                if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="menu"; FIRST_ACTION_SET=1; fi
                i=$((i + 1)) ;;
            -v|--verbose)
                IS_VERBOSE="true" # Set global flag
                i=$((i + 1)) ;;
            -h|--help)
                if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="help"; FIRST_ACTION_SET=1; fi
                i=$((i + 1)) ;;
            *)
                printf "Error: Unknown option '%s'\\n\\n" "$arg" >&2
                ACTION="help"; parse_error=1; break
                ;;
        esac
    done

    # --- Runtime Initialization ---
    if ! setup_logging; then
        printf "Warning: Logging setup failed during initialization. Continuing with limited logging.\\n" >&2
        # LOG_FILE remains /dev/null (default)
    fi

    # Log details now that logging *might* be set up
    log_debug "Script started at: $_script_start_time"
    log_debug "Argument parsing complete. ACTION='$ACTION', IS_VERBOSE='$IS_VERBOSE', source_key_file='$source_key_file', ParseError='$parse_error'"
    log_debug "Using Platform: $PLATFORM"
    log_debug "Using STAT_CMD: $STAT_CMD"
    log_debug "Using LOG_FILE: $LOG_FILE (from LOG_DIR: $LOG_DIR, FILENAME: $LOG_FILENAME)"
    log_debug "Using SSH_DIR: $SSH_DIR"
    log_debug "Using VALID_KEY_LIST_FILE: $VALID_KEY_LIST_FILE"
    log_debug "Using AGENT_ENV_FILE: $AGENT_ENV_FILE"

    # Create Temporary File *after* logging might be set up
    # Assign to global KEYS_LIST_TMP declared earlier
    if ! KEYS_LIST_TMP=$(mktemp "${TMPDIR:-/tmp}/ssh_keys_list.XXXXXX"); then
        log_error "Failed to create temporary file. Please check permissions."
        exit 1 # Exit script if temp file fails
    fi
    log_debug "Temporary file created: $KEYS_LIST_TMP"

    # --- Dispatch Action ---
    log_info "Selected action: $ACTION"
    case $ACTION in
        list)       run_list_keys ;; # Exits script
        add)        run_load_keys ;; # Exits script
        file)       run_load_keys_from_file "$source_key_file" ;; # Exits script
        delete-all) run_delete_all_cli ;; # Exits script
        menu)       run_interactive_menu ;; # Exits script on quit
        help|*)
            display_help # Display help function defined globally
            if [ "$parse_error" -eq 1 ]; then
                exit 1 # Exit with error if help was due to parsing error
            else
                exit 0 # Exit successfully if help was default or explicit -h/--help
            fi
            ;;
    esac

    # Should not be reached if dispatch logic and called functions are correct
    log_error "Script main function reached end unexpectedly after dispatching action: $ACTION."
    exit 1 # Exit with error for unexpected fallthrough
}

# --- Trap Definitions ---
# Defined AFTER the functions they call
trap 'log_execution_time' EXIT
trap '_cleanup_temp_file' EXIT ERR # Clean up temp file on normal exit or error

# --- Main Execution ---
# Call main, passing all script arguments
main "$@"