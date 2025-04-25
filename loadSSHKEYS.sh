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

# Strict error handling: exit on error, treat unset variables as error, fail pipelines on first error
set -euo pipefail

# --- Configuration Section ---
# Platform-specific configurations
PLATFORM=$(uname -s)
case "$PLATFORM" in
    "Darwin")
        # macOS specific settings
        LOG_DIR="$HOME/Library/Logs/sshkeygen"
        STAT_CMD="stat -f %z"
        ;;
    "Linux")
        # Linux specific settings
        if [ -w "/var/log" ]; then
            LOG_DIR="/var/log/sshkeygen"
        else
            LOG_DIR="$HOME/.local/log/sshkeygen"
        fi
        STAT_CMD="stat -c %s"
        ;;
    *)
        # Default settings for other platforms
        LOG_DIR="$HOME/.ssh/logs"
        STAT_CMD="stat -c %s"  # Default to Linux style
        ;;
esac

# Define the target SSH directory
declare SSH_DIR="$HOME/.ssh"

# Use a temporary file for the key list
declare KEYS_LIST_TMP
if ! KEYS_LIST_TMP=$(mktemp "${TMPDIR:-/tmp}/ssh_keys_list.XXXXXX"); then
    printf "Error: Failed to create temporary file. Please check your system's temporary directory permissions.\n" >&2
    exit 1
fi

# Flag to control verbose output
declare IS_VERBOSE="true" # Default to verbose for menu-driven interface

# --- Cleanup trap ---
trap 'rm -f "$KEYS_LIST_TMP"' EXIT

# --- Logging Functions ---
setup_logging() {
    local max_log_size=1048576  # 1MB
    local max_log_files=5

    # Create log directory if it doesn't exist
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf "Warning: Could not create log directory. Using fallback location.\n" >&2
        LOG_DIR="$HOME/.ssh/logs"
        if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
            printf "Warning: Could not create fallback log directory. Logging disabled.\n" >&2
            LOG_FILE="/dev/null"
            return 1
        fi
    fi

    # Set up log file with rotation
    LOG_FILE="${LOG_DIR}/sshkeygen.log"
    if ! touch "$LOG_FILE" 2>/dev/null; then
        printf "Warning: Could not create log file. Logging disabled.\n" >&2
        LOG_FILE="/dev/null"
        return 1
    fi

    # Check log file size and rotate if needed
    if [ -f "$LOG_FILE" ]; then
        local log_size
        if ! log_size=$($STAT_CMD "$LOG_FILE" 2>/dev/null); then
            printf "Warning: Could not determine log file size. Log rotation disabled.\n" >&2
        elif [ "$log_size" -gt "$max_log_size" ]; then
            for i in $(seq $((max_log_files-1)) -1 1); do
                if [ -f "${LOG_FILE}.${i}" ]; then
                    mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))" 2>/dev/null || true
                fi
            done
            mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
            touch "$LOG_FILE"
        fi
    fi

    chmod 600 "$LOG_FILE" 2>/dev/null || true
    return 0
}

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - INFO: $1" >> "$LOG_FILE"
    fi
}

log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "Error: %s\n" "$1" >&2
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - ERROR: $1" >> "$LOG_FILE"
    fi
}

log_warn() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "Warning: %s\n" "$1" >&2
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - WARN: $1" >> "$LOG_FILE"
    fi
}

log_debug() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - DEBUG: $1" >> "$LOG_FILE"
    fi
}

log_info() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - INFO: $1" >> "$LOG_FILE"
    fi
}

# --- Validation Functions ---
#
# Function: validate_directory
# Description: Validates a directory's existence and permissions
# Input:
#   $1: Directory path to validate
#   $2: Description of the directory (for error messages)
# Output:
#   - Success: Returns 0
#   - Failure: Returns 1 with error message
# Side Effects: None
#
validate_directory() {
    local dir="$1"
    local description="$2"

    # Check if directory exists
    if [ ! -d "$dir" ]; then
        printf "Error: %s directory '%s' does not exist\n" "$description" "$dir" >&2
        return 1
    fi

    # Check if directory is readable
    if [ ! -r "$dir" ]; then
        printf "Error: %s directory '%s' is not readable\n" "$description" "$dir" >&2
        return 1
    fi

    # Check if directory is writable
    if [ ! -w "$dir" ]; then
        printf "Error: %s directory '%s' is not writable\n" "$description" "$dir" >&2
        return 1
    fi

    # Check if directory is executable
    if [ ! -x "$dir" ]; then
        printf "Error: %s directory '%s' is not accessible\n" "$description" "$dir" >&2
        return 1
    fi

    return 0
}

validate_ssh_dir() {
    if ! validate_directory "$SSH_DIR" "SSH"; then
        printf "Attempting to create SSH directory...\n"
        if ! mkdir -p "$SSH_DIR"; then
            printf "Error: Failed to create SSH directory '%s'\n" "$SSH_DIR" >&2
            return 1
        fi
        chmod 700 "$SSH_DIR"
        return 0
    fi
    return 0
}

# --- SSH Agent Management ---

# Function: check_ssh_agent
# Description: Checks if the currently set SSH_AUTH_SOCK and SSH_AGENT_PID
#              point to a live and responsive ssh-agent process.
# Input: None
# Output:
#   - Success: Returns 0 if agent is accessible.
#   - Failure: Returns 1 otherwise.
# Side Effects: None (Does NOT unset variables anymore)
check_ssh_agent() {
    log "check_ssh_agent: Checking agent status... (PID='${SSH_AGENT_PID:-}', SOCK='${SSH_AUTH_SOCK:-}')"
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ -z "${SSH_AGENT_PID:-}" ]; then log "check_ssh_agent: Required environment variables not set."; return 1; fi
    if [ ! -S "$SSH_AUTH_SOCK" ]; then log_error "check_ssh_agent: SSH_AUTH_SOCK is not a socket: $SSH_AUTH_SOCK"; return 1; fi
    if ! ps -p "$SSH_AGENT_PID" > /dev/null 2>&1; then log_error "check_ssh_agent: SSH_AGENT_PID ($SSH_AGENT_PID) process not running."; return 1; fi
    ssh-add -l > /dev/null 2>&1
    local exit_code=$?
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 1 ]; then log "check_ssh_agent: Agent communication successful (exit code $exit_code)."; return 0; fi
    log_error "check_ssh_agent: Cannot communicate with agent (ssh-add -l exit code $exit_code)."
    return 1
}

# Function: ensure_ssh_agent
# Description: Ensures a single, accessible ssh-agent is running and its
#              environment variables are EXPORTED for the current script.
#              Reuses existing agents if possible via ~/.ssh/agent.env.
# Input: None
# Output:
#   - Success: Returns 0. SSH_AUTH_SOCK and SSH_AGENT_PID are exported.
#   - Failure: Returns 1 with error message.
# Side Effects: May start ssh-agent, exports variables, creates/updates ~/.ssh/agent.env
ensure_ssh_agent() {
    log "Ensuring SSH agent is active..."
    local agent_env_file="$HOME/.ssh/agent.env"

    # 1. Check if agent is already configured and working in this environment
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -n "${SSH_AGENT_PID:-}" ] && check_ssh_agent; then
        log "ensure_ssh_agent: Agent already running and sourced."
        printf "SSH agent is already running.\n"
        # Ensure they are exported, just in case
        export SSH_AUTH_SOCK SSH_AGENT_PID
        return 0
    fi
    log "ensure_ssh_agent: Agent not (verifiably) running or sourced in current environment."

    # 2. Try sourcing persistent environment file
    if [ -f "$agent_env_file" ]; then
        log "ensure_ssh_agent: Found persistent agent file: $agent_env_file. Sourcing..."
        # Source the file into the current script's environment
        . "$agent_env_file" >/dev/null
        # Now check if sourcing worked and the agent is valid
        if check_ssh_agent; then
            log "ensure_ssh_agent: Sourcing persistent file successful. Reusing agent."
            printf "Successfully connected to existing ssh-agent.\n"
            # Ensure they are exported
            export SSH_AUTH_SOCK SSH_AGENT_PID
            return 0
        else
            log_warn "ensure_ssh_agent: Persistent file found but agent invalid/inaccessible after sourcing. Removing stale file."
            rm -f "$agent_env_file" # Remove stale file
            # Unset potentially incorrect variables sourced from the stale file
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    else
        log "ensure_ssh_agent: No persistent agent file found."
    fi

    # 3. Start a new agent
    log "ensure_ssh_agent: Starting new ssh-agent..."
    printf "Starting new ssh-agent...\n"

    # Create .ssh directory if needed
    if ! mkdir -p "$HOME/.ssh"; then log_error "ensure_ssh_agent: Failed to create SSH directory $HOME/.ssh"; printf "Error..."; return 1; fi
    if ! chmod 700 "$HOME/.ssh"; then log_error "ensure_ssh_agent: Failed to set permissions on $HOME/.ssh"; printf "Warning..."; fi

    # Start ssh-agent and capture output
    local agent_output
    if ! agent_output=$(ssh-agent -s); then
        log_error "ensure_ssh_agent: Failed to execute ssh-agent -s"
        printf "Error: Failed to start ssh-agent process\n" >&2
        return 1
    fi
    log "ensure_ssh_agent: ssh-add -s output captured."

    # Extract environment variables
    local ssh_auth_sock="${agent_output#*SSH_AUTH_SOCK=}"
    ssh_auth_sock="${ssh_auth_sock%%;*}"
    local ssh_agent_pid="${agent_output#*SSH_AGENT_PID=}"
    ssh_agent_pid="${ssh_agent_pid%%;*}"
    if [ -z "$ssh_auth_sock" ] || [ -z "$ssh_agent_pid" ]; then
        log_error "ensure_ssh_agent: Failed to extract env vars from output: $agent_output"
        printf "Error: Failed to parse ssh-agent output\n" >&2
        return 1
    fi
    log "ensure_ssh_agent: Extracted SOCK=$ssh_auth_sock PID=$ssh_agent_pid"

    # Export variables into the current script's environment
    export SSH_AUTH_SOCK="$ssh_auth_sock"
    export SSH_AGENT_PID="$ssh_agent_pid"
    log "ensure_ssh_agent: Exported new agent variables into current scope."

    # Save agent environment variables to persistent file
    log "ensure_ssh_agent: Saving agent environment to $agent_env_file"
    {
        printf 'SSH_AUTH_SOCK=%s; export SSH_AUTH_SOCK;\n' "$ssh_auth_sock"
        printf 'SSH_AGENT_PID=%s; export SSH_AGENT_PID;\n' "$ssh_agent_pid"
        printf '# Agent started on %s\n' "$(date)"
    } > "$agent_env_file"
    if ! chmod 600 "$agent_env_file"; then log_error "ensure_ssh_agent: Failed to set permissions on $agent_env_file"; printf "Warning..."; fi
    log "ensure_ssh_agent: Agent environment saved."

    # Final verification (using the exported variables in current scope)
    sleep 0.5
    if check_ssh_agent; then
        log "ensure_ssh_agent: New agent started and verified successfully."
        printf "Successfully started new ssh-agent.\n"
        return 0 # Success!
    else
        log_error "ensure_ssh_agent: Started new agent but failed final verification."
        printf "Error: Failed to verify new ssh-agent after starting it.\n" >&2
        # Clean up potentially bad environment state
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        rm -f "$agent_env_file" # Remove possibly bad file
        return 1 # Failure!
    fi
}

# --- Core Functions ---
update_keys_list_file() {
    log "Finding private key files in $SSH_DIR..."

    # Clear the temporary file
    > "$KEYS_LIST_TMP"

    # Platform-specific find command
    if [[ "$PLATFORM" == "Darwin" ]]; then
        # macOS version (without -printf)
        find "$SSH_DIR" -maxdepth 1 -type f \
            ! -name 'known_hosts*' \
            ! -name 'authorized_keys*' \
            ! -name '*.*' \
            ! -name 'config' \
            -exec basename {} \; > "$KEYS_LIST_TMP"
    else
        # Linux version (with -printf)
        find "$SSH_DIR" -maxdepth 1 -type f \
            ! -name 'known_hosts*' \
            ! -name 'authorized_keys*' \
            ! -name '*.*' \
            ! -name 'config' \
            -printf '%f\n' > "$KEYS_LIST_TMP"
    fi

    # Count the number of keys found
    local key_count
    key_count=$(wc -l < "$KEYS_LIST_TMP")

    if [ "$key_count" -eq 0 ]; then
        printf "No SSH keys found in %s\n" "$SSH_DIR"
        log "No SSH keys found in directory"
    else
        printf "Found %d SSH key(s) in %s\n" "$key_count" "$SSH_DIR"
        log "Found $key_count SSH key(s) in directory"
    fi
}

delete_keys_from_agent() {
    log "Deleting all keys from ssh-agent..."
    if ssh-add -D; then
        log "All keys successfully deleted from agent."
    else
        log_warn "Could not delete keys from agent (maybe none were loaded?). Status: $?"
    fi
}

add_keys_to_agent() {
    log "Adding keys listed in $KEYS_LIST_TMP to the agent..."
    local keyfile
    local key_path
    local added_count=0
    local failed_count=0

    if [ ! -s "$KEYS_LIST_TMP" ]; then
        printf "No SSH keys found in directory. Nothing to add.\n"
        log "Key list file is empty. No keys to add."
        return
    fi

    printf "Adding SSH keys to agent...\n"
    while IFS= read -r keyfile || [[ -n "$keyfile" ]]; do
        [ -z "$keyfile" ] && continue
        key_path="$SSH_DIR/$keyfile"

        if [ -f "$key_path" ]; then
            printf "Adding key: %s\n" "$keyfile"
            log "Attempting to add key: $key_path"
            local ssh_add_output
            local ssh_add_status=0

            if [[ "$PLATFORM" == "Darwin" ]]; then
                ssh_add_output=$(ssh-add --apple-use-keychain "$key_path" 2>&1) || ssh_add_status=$?
            else
                ssh_add_output=$(ssh-add "$key_path" 2>&1) || ssh_add_status=$?
            fi

            if [ $ssh_add_status -eq 0 ]; then
                printf "  ✓ Successfully added\n"
                log "Successfully added $keyfile"
                ((added_count++))
            else
                printf "  ✗ Failed to add (status: %d)\n" "$ssh_add_status"
                log_error "Failed to add key: $keyfile (status: $ssh_add_status). Output: $ssh_add_output"
                ((failed_count++))
            fi
        else
            printf "  ✗ Key file '%s' not found\n" "$keyfile"
            log_warn "Key file '$keyfile' listed but not found at '$key_path'. Skipping."
        fi
    done < "$KEYS_LIST_TMP"

    printf "\nSummary: %d key(s) added, %d key(s) failed\n" "$added_count" "$failed_count"
    log "Finished adding keys. Added: $added_count, Failed: $failed_count"
}

# --- Menu Functions ---
display_main_menu() {
    clear
    printf "\n======= SSH Key Manager Menu =======\n"
    printf " Platform: %s\n" "$PLATFORM"
    printf " SSH Directory: %s\n" "$SSH_DIR"
    printf "++++++++++++++++++++++++++++++++++++\n"
    printf " Please choose an option:\n"
    printf "   1) Set SSH Directory\n"
    printf "   2) List Current Keys\n"
    printf "   3) Reload All Keys\n"
    printf "   4) Display Log File Location\n"
    printf "   5) Delete Single Key\n"
    printf "   6) Delete All Keys\n"
    printf "   q) Quit\n"
    printf "++++++++++++++++++++++++++++++++++++\n"
}

get_menu_choice() {
    local choice
    while true; do
        read -r -p "Enter choice [1-6, q]: " choice < /dev/tty
        case "$choice" in
            [1-6]|q|Q)
                echo "$choice"
                return 0
                ;;
            *)
                printf "Invalid choice '%s'. Please enter a number between 1 and 6, or 'q' to quit.\n" "$choice"
                sleep 1
                ;;
        esac
    done
}

wait_for_key() {
    printf "\nPress any key to return to the main menu...\n"
    read -n 1 -s -r < /dev/tty
}

list_current_keys() {
    log_debug "Running ssh-add -l to get status..."
    # Run once to check status without capturing output, avoiding potential command substitution issues
    ssh-add -l >/dev/null 2>&1 || true # Allow exit codes 1 or 2 without triggering set -e
    local exit_code=$?
    log_debug "ssh-add -l initial exit code: $exit_code"

    case $exit_code in
        0)
            log_info "list_current_keys: Agent reports keys are loaded (Exit code: 0). Attempting to list..."
            printf "Keys currently loaded in the agent:\n"
            # Now run it again to actually display the keys
            # Allow exit code 1 (no identities) here, treat other non-zero as error
            ssh-add -l || true # Allow exit code 1 without terminating script via set -e
            local list_exit_code=$?
            log_debug "list_current_keys: Second ssh-add -l exit code: $list_exit_code"
            if [ "$list_exit_code" -ne 0 ] && [ "$list_exit_code" -ne 1 ]; then
                log_error "list_current_keys: ssh-add -l failed unexpectedly (exit code $list_exit_code) despite initial exit code 0."
                printf "Error listing keys (Code: %s), although agent reported keys present.\n" "$list_exit_code" >&2
                return 1 # Indicate an error state
            fi
            # If exit code was 0 or 1, the command either listed keys or printed 'no identities'
            # In either case, the function succeeded in its task.
            ;;
        1)
            log_info "list_current_keys: No keys currently loaded (Exit code: 1)."
            printf "No keys currently loaded in the agent.\n"
            printf "Hint: Use option 3 to load keys from '%s'.\n" "$SSH_DIR"
            ;;
        2)
            log_error "list_current_keys: SSH_AUTH_SOCK invalid or agent not running (Exit code: 2)."
            printf "Error: Could not connect to the SSH agent. Is it running?\n" >&2
            return 1 # Indicate an error state
            ;;
        *)
            log_error "list_current_keys: Unknown error from ssh-add -l (Exit code: $exit_code)."
            printf "Error: An unexpected error occurred while checking SSH keys (Code: %s).\n" "$exit_code" >&2
            return 1 # Indicate an error state
            ;;
    esac

    return 0 # Indicate success (either listed or confirmed no keys)
}

display_log_location() {
    printf "\n+++ Log File Information +++\n"
    if [ "$LOG_FILE" = "/dev/null" ]; then
        printf "Logging is currently disabled.\n"
    else
        printf "Current log file location: %s\n" "$LOG_FILE"
        printf "Log file size: %s\n" "$(ls -lh "$LOG_FILE" 2>/dev/null | awk '{print $5}')"
    fi
    printf "++++++++++++++++++++++++++++++++++++\n"
}

delete_single_key() {
    printf "\n+++ Delete Single Key +++\n"
    log_debug "delete_single_key: Checking for loaded keys..."

    # Explicitly check agent status and key presence
    ssh-add -l >/dev/null 2>&1
    local exit_code=$?
    log_debug "delete_single_key: ssh-add -l status check exit code: $exit_code"

    case $exit_code in
        0)
            # Keys are present, proceed with deletion logic
            log_info "delete_single_key: Keys found. Proceeding with selection."
            ;;
        1)
            log_info "delete_single_key: No keys loaded (exit code 1)."
            printf "No keys currently loaded in ssh-agent.\n"
            return 0 # Nothing to delete, return to menu successfully
            ;;
        2)
            log_error "delete_single_key: Cannot connect to agent (exit code 2)."
            printf "Error: Could not connect to the SSH agent.\n" >&2
            return 1 # Indicate error, return to menu
            ;;
        *)
            log_error "delete_single_key: Unknown error from ssh-add -l check (exit code $exit_code)."
            printf "Error: An unexpected error occurred checking keys (Code: %s).\n" "$exit_code" >&2
            return 1 # Indicate error, return to menu
            ;;
    esac

    # --- Proceed with deletion if exit_code was 0 ---
    local key_list
    # Now get the list for display (error here would be unexpected)
    if ! key_list=$(ssh-add -l 2>&1); then
        log_error "delete_single_key: Failed to get key list via ssh-add -l even though initial check passed."
        printf "Error: Failed to retrieve key list from agent.\n" >&2
        return 1
    fi

    if [ -z "$key_list" ]; then
        log_warn "delete_single_key: ssh-add -l returned 0 but produced empty output. Treating as no keys."
        printf "No keys currently loaded in ssh-agent (unexpected empty list).\n"
        return 0
    fi

    # Display numbered list of keys
    printf "Select a key to delete:\n"
    local i=1
    local keys=()
    # Use mapfile/readarray if available for safer parsing, otherwise use while read
    if command -v mapfile >/dev/null; then
        mapfile -t keys <<< "$key_list"
    else
        # Fallback for shells without mapfile (less robust with weird chars)
        log_warn "delete_single_key: mapfile command not found, using 'while read' loop (may have issues with special characters)."
        while IFS= read -r line; do
            keys+=("$line")
        done <<< "$key_list"
    fi

    for i in "${!keys[@]}"; do
        printf "  %2d) %s\n" "$((i + 1))" "${keys[i]}"
    done

    # Get user selection
    while true; do
        read -r -p "Enter key number to delete (or 'c' to cancel): " choice < /dev/tty
        case "$choice" in
            c|C)
                printf "Operation cancelled.\n"
                log_info "delete_single_key: User cancelled operation."
                return 0 # Cancelled successfully
                ;;
            *) # Validate input is a number within range
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#keys[@]}" ]; then
                    local selected_index=$((choice - 1))
                    local selected_key_line="${keys[$selected_index]}"
                    local key_path_or_fingerprint # Can be path or fingerprint depending on ssh-add version/output

                    # Attempt to extract fingerprint (more reliable for deletion)
                    # Fingerprint is usually the second field (SHA256:...) or third field if bits/type are first
                    # Let's try extracting what looks like a fingerprint or fallback to path
                    key_path_or_fingerprint=$(echo "$selected_key_line" | awk '{ for(i=1; i<=NF; i++) if ($i ~ /^(SHA256:|MD5:|[0-9a-f:]+$)/) { print $i; exit } }')

                    # If fingerprint extraction failed, try getting the path (usually last field)
                    if [ -z "$key_path_or_fingerprint" ]; then
                         key_path_or_fingerprint=$(echo "$selected_key_line" | awk '{print $NF}')
                         log_warn "delete_single_key: Could not reliably extract fingerprint for '$selected_key_line', attempting deletion using path/comment: '$key_path_or_fingerprint'"
                    else
                         log_info "delete_single_key: Extracted fingerprint/identifier: '$key_path_or_fingerprint' for '$selected_key_line'"
                    fi

                    printf "Attempting to delete key corresponding to: %s\n" "$selected_key_line"
                    log "delete_single_key: Attempting ssh-add -d '$key_path_or_fingerprint'"

                    # Perform the deletion, explicitly check return status
                    if ssh-add -d "$key_path_or_fingerprint"; then
                        printf "Key successfully deleted.\n"
                        log "delete_single_key: Successfully deleted key matching '$key_path_or_fingerprint'"
                        return 0 # Success
                    else
                        # ssh-add -d might fail if the identifier wasn't precise enough
                        local del_status=$?
                        log_error "delete_single_key: Failed to delete key matching '$key_path_or_fingerprint' (ssh-add -d exit status: $del_status)."
                        printf "Error: Failed to delete the selected key (status: %d). The agent might require the exact private key file path which isn't always available from 'ssh-add -l'.\n" "$del_status"
                        printf "You may need to use 'ssh-add -D' to remove all keys if specific deletion fails.\n"
                        return 1 # Indicate deletion failed
                    fi
                else
                    printf "Invalid selection. Please enter a number between 1 and %d, or 'c' to cancel.\n" "${#keys[@]}"
                fi
                ;;
        esac
    done
}

delete_all_keys() {
    printf "\n+++ Delete All Keys +++\n"
    log_debug "delete_all_keys: Checking for loaded keys..."

    # Explicitly check agent status and key presence
    ssh-add -l >/dev/null 2>&1
    local exit_code=$?
    log_debug "delete_all_keys: ssh-add -l status check exit code: $exit_code"

    local key_count=0
    case $exit_code in
        0)
            # Keys are present, count them for confirmation message
            log_info "delete_all_keys: Keys found. Counting keys."
            local key_list
            if key_list=$(ssh-add -l 2>/dev/null); then
                 # Count lines carefully, handle potential empty string from ssh-add -l
                if [ -n "$key_list" ]; then
                    key_count=$(echo "$key_list" | wc -l)
                fi
            else
                 log_error "delete_all_keys: Failed to get key list for counting even though initial check passed."
                 printf "Error: Failed to retrieve key list from agent for counting.\n" >&2
                 return 1 # Error, return to menu
            fi

            if [ "$key_count" -eq 0 ]; then
                log_info "delete_all_keys: ssh-add -l returned 0 but list is empty or count failed. No keys to delete."
                printf "No keys currently loaded in ssh-agent.\n"
                return 0 # Nothing to delete, return successfully
            fi
            log_info "delete_all_keys: Found $key_count keys to delete."
            ;;
        1)
            log_info "delete_all_keys: No keys loaded (exit code 1)."
            printf "No keys currently loaded in ssh-agent.\n"
            return 0 # Nothing to delete, return successfully
            ;;
        2)
            log_error "delete_all_keys: Cannot connect to agent (exit code 2)."
            printf "Error: Could not connect to the SSH agent.\n" >&2
            return 1 # Indicate error, return to menu
            ;;
        *)
            log_error "delete_all_keys: Unknown error from ssh-add -l check (exit code $exit_code)."
            printf "Error: An unexpected error occurred checking keys (Code: %s).\n" "$exit_code" >&2
            return 1 # Indicate error, return to menu
            ;;
    esac

    # --- Proceed with deletion confirmation if exit_code was 0 and key_count > 0 ---
    printf "This will delete all %d keys from ssh-agent.\n" "$key_count"
    read -r -p "Are you sure you want to continue? (y/N): " confirm < /dev/tty

    case "$confirm" in
        y|Y)
            log_info "delete_all_keys: User confirmed deletion of all keys."
            if ssh-add -D; then
                printf "All keys successfully deleted.\n"
                log "delete_all_keys: Successfully deleted all keys from ssh-agent"
                return 0 # Success
            else
                local del_status=$?
                printf "Error: Failed to delete all keys (status: %d).\n" "$del_status"
                log_error "delete_all_keys: Failed to delete all keys using ssh-add -D (status: $del_status)"
                return 1 # Failure
            fi
            ;;
        *)
            printf "Operation cancelled.\n"
            log_info "delete_all_keys: User cancelled operation."
            return 0 # Cancelled successfully
            ;;
    esac
}

# --- Main Execution Logic ---
main() {
    # Initialize logging
    if ! setup_logging; then
        printf "Warning: Logging setup failed. Continuing with limited logging.\n" >&2
    fi
    log "************* STARTING SCRIPT *************"
    log "Script starting..."
    log "Platform: $PLATFORM"
    log "User: $USER"
    log "Host: $(hostname)"

    # Validate SSH directory
    if ! validate_ssh_dir; then
        printf "Error: SSH directory validation failed. Please check permissions and try again.\n" >&2
        log_error "SSH directory validation failed"
        exit 1
    fi

    # Check if required commands are available
    if ! command -v ssh-add > /dev/null || ! command -v ssh-agent > /dev/null ; then
        printf "Error: 'ssh-add' or 'ssh-agent' command not found. Please ensure SSH tools are installed.\n" >&2
        log_error "'ssh-add' or 'ssh-agent' command not found. Please ensure SSH tools are installed."
        exit 1
    fi

    log "DEBUG: Main - Calling ensure_ssh_agent..."
    if ! ensure_ssh_agent; then # Check only for success (0) or failure (1)
        log_error "ensure_ssh_agent failed. Exiting."
        # ensure_ssh_agent already prints detailed errors
        exit 1
    fi
    # If ensure_ssh_agent returned 0, we are guaranteed to have the vars exported
    log "DEBUG: Main - Agent setup complete. SSH_AUTH_SOCK='${SSH_AUTH_SOCK:-}', SSH_AGENT_PID='${SSH_AGENT_PID:-}'"
    log "DEBUG: Main - Proceeding..."

    # Main menu loop
    while true; do
        display_main_menu
        choice=$(get_menu_choice)

        case "$choice" in
            1)
                check_and_set_ssh_dir
                wait_for_key
                ;;
            2)
                log "DEBUG: Main loop - Calling list_current_keys..."
                list_current_keys # Should now work as agent env is guaranteed
                local list_rc=$?
                log "DEBUG: Main loop - list_current_keys returned: $list_rc"
                # No need to check list_rc here anymore if list_current_keys always returns 0 on success
                log "DEBUG: Main loop - Calling wait_for_key..."
                wait_for_key
                local wait_rc=$?
                log "DEBUG: Main loop - wait_for_key returned: $wait_rc"
                log "DEBUG: Main loop - Reached end of case 2 block."
                ;;
            3)
                printf "Reloading all keys...\n"
                if ! update_keys_list_file; then
                    log_error "Failed to find keys in SSH directory."
                    printf "Error: Failed to find keys to reload.\n" >&2
                else
                    # Only proceed if keys were found
                    delete_keys_from_agent
                    if ! add_keys_to_agent; then
                        log_error "Failed to add one or more keys."
                        printf "Error: Failed during key addition process.\n" >&2
                        # Continue to wait_for_key even if add failed
                    fi
                fi
                wait_for_key
                ;;
            4)
                display_log_location
                wait_for_key
                ;;
            5)
                delete_single_key
                wait_for_key
                ;;
            6)
                delete_all_keys
                wait_for_key
                ;;
            q|Q)
                log "Script terminated by user"
                printf "\nThank you for using SSH Key Manager. Goodbye!\n"
                exit 0
                ;;
        esac
    done
    log "************* ENDING SCRIPT *************"
}

# --- Run Main ---
main
