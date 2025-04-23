#!/bin/bash
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

# --- SSH Agent Management ---
#
# Function: start_ssh_agent
# Description: Starts the SSH agent if it's not already running
# Input: None
# Output:
#   - Success: Returns 0 and sets SSH_AUTH_SOCK and SSH_AGENT_PID environment variables
#   - Failure: Returns 1 with error message
# Side Effects:
#   - Starts ssh-agent process
#   - Sets environment variables for SSH agent
#
start_ssh_agent() {
    printf "Starting ssh-agent...\n"

    # Check if we're already in an ssh-agent session
    if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ]; then
        printf "SSH agent already running.\n"
        return 0
    fi

    # Start ssh-agent and capture its output
    local agent_output
    if ! agent_output=$(ssh-agent -s 2>/dev/null); then
        printf "Error: Failed to start ssh-agent\n" >&2
        return 1
    fi

    # Extract the environment variables from the agent output
    eval "$agent_output" >/dev/null

    # Verify the agent is running
    if ! ssh-add -l >/dev/null 2>&1; then
        printf "Error: Failed to verify ssh-agent is running\n" >&2
        return 1
    fi

    printf "SSH agent started successfully.\n"
    return 0
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

# --- Working Directory Management ---
check_and_set_ssh_dir() {
    printf "\n+++ Set SSH Directory +++\n"
    printf "Current SSH directory: %s\n" "$SSH_DIR"

    # Display options
    printf "\nSelect SSH directory:\n"
    printf "  1) Use standard location (%s)\n" "$HOME/.ssh"
    printf "  2) Enter custom directory path\n"
    printf "  c) Cancel\n"

    while true; do
        read -r -p "Enter choice [1-2, c]: " choice < /dev/tty

        case "$choice" in
            1)
                # Try to switch to standard location
                if ! mkdir -p "$HOME/.ssh"; then
                    printf "Error: Unable to create directory %s\n" "$HOME/.ssh" >&2
                    log_error "Unable to create directory $HOME/.ssh"
                    return 1
                fi

                # Set correct permissions for ~/.ssh directory
                chmod 700 "$HOME/.ssh"
                SSH_DIR="$HOME/.ssh"
                printf "Working directory set to: %s\n" "$SSH_DIR"
                log "Working directory set to standard location: $SSH_DIR"
                return 0
                ;;
            2)
                read -r -p "Enter full path to directory: " custom_dir < /dev/tty
                custom_dir="${custom_dir%/}"

                if [ -z "$custom_dir" ]; then
                    printf "Error: Directory path cannot be empty\n" >&2
                    log_error "Directory path cannot be empty"
                    continue
                fi

                if ! mkdir -p "$custom_dir"; then
                    printf "Error: Unable to create directory %s\n" "$custom_dir" >&2
                    log_error "Unable to create directory $custom_dir"
                    continue
                fi

                SSH_DIR="$custom_dir"
                printf "Working directory set to: %s\n" "$SSH_DIR"
                log "Working directory set to custom location: $SSH_DIR"
                return 0
                ;;
            c|C)
                printf "Directory change cancelled.\n"
                return 0
                ;;
            *)
                printf "Invalid choice. Please enter 1, 2, or c.\n"
                ;;
        esac
    done
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
    printf "\n+++ Currently Loaded SSH Keys +++\n"

    # First check if ssh-agent is running
    if ! ssh-add -l >/dev/null 2>&1; then
        printf "  SSH agent is not running or not accessible.\n"
        printf "  Would you like to:\n"
        printf "    1) Start SSH agent and load keys\n"
        printf "    2) Return to main menu\n"

        while true; do
            read -r -p "Enter choice [1-2]: " choice < /dev/tty
            case "$choice" in
                1)
                    printf "Starting SSH agent...\n"
                    if ! start_ssh_agent; then
                        printf "  Failed to start SSH agent. Please try again.\n"
                        return
                    fi
                    # After starting agent, try to load keys
                    printf "Loading keys from SSH directory...\n"
                    update_keys_list_file
                    add_keys_to_agent
                    return
                    ;;
                2)
                    return
                    ;;
                *)
                    printf "Invalid choice. Please enter 1 or 2.\n"
                    ;;
            esac
        done
    fi

    # If we get here, ssh-agent is running, check for keys
    local key_list
    key_list=$(ssh-add -l 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -ne 0 ] || [ -z "$key_list" ]; then
        printf "  No keys currently loaded in ssh-agent.\n"
        printf "  Would you like to:\n"
        printf "    1) Load keys from SSH directory\n"
        printf "    2) Return to main menu\n"

        while true; do
            read -r -p "Enter choice [1-2]: " choice < /dev/tty
            case "$choice" in
                1)
                    printf "Loading keys from SSH directory...\n"
                    update_keys_list_file
                    add_keys_to_agent
                    return
                    ;;
                2)
                    return
                    ;;
                *)
                    printf "Invalid choice. Please enter 1 or 2.\n"
                    ;;
            esac
        done
    else
        # Keys are loaded, display them
        local i=1
        while IFS= read -r line; do
            printf "  %2d) %s\n" "$i" "$line"
            ((i++))
        done <<< "$key_list"
    fi
    printf "++++++++++++++++++++++++++++++++++++\n"
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
    local key_list
    key_list=$(ssh-add -l 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -ne 0 ] || [ -z "$key_list" ]; then
        printf "No keys currently loaded in ssh-agent\n"
        printf "Note: This is normal if you haven't added any keys yet\n"
        return
    fi

    # Display numbered list of keys
    printf "Select a key to delete:\n"
    local i=1
    local keys=()
    while IFS= read -r line; do
        printf "  %2d) %s\n" "$i" "$line"
        keys+=("$line")
        ((i++))
    done <<< "$key_list"

    # Get user selection
    while true; do
        read -r -p "Enter key number to delete (or 'c' to cancel): " choice < /dev/tty
        case "$choice" in
            c|C)
                printf "Operation cancelled.\n"
                return
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#keys[@]}" ]; then
                    local selected_key="${keys[$((choice-1))]}"
                    local key_fingerprint
                    key_fingerprint=$(echo "$selected_key" | awk '{print $2}')

                    printf "Deleting key: %s\n" "$selected_key"
                    if ssh-add -d "$key_fingerprint" 2>/dev/null; then
                        printf "Key successfully deleted.\n"
                        log "Deleted key: $selected_key"
                    else
                        printf "Failed to delete key.\n"
                        log_error "Failed to delete key: $selected_key"
                    fi
                    return
                else
                    printf "Invalid selection. Please enter a number between 1 and %d, or 'c' to cancel.\n" "${#keys[@]}"
                fi
                ;;
        esac
    done
}

delete_all_keys() {
    printf "\n+++ Delete All Keys +++\n"
    local key_list
    key_list=$(ssh-add -l 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -ne 0 ] || [ -z "$key_list" ]; then
        printf "No keys currently loaded in ssh-agent\n"
        printf "Note: This is normal if you haven't added any keys yet\n"
        return
    fi

    local key_count
    key_count=$(echo "$key_list" | wc -l)

    printf "This will delete all %d keys from ssh-agent.\n" "$key_count"
    read -r -p "Are you sure you want to continue? (y/N): " confirm < /dev/tty

    case "$confirm" in
        y|Y)
            if ssh-add -D 2>/dev/null; then
                printf "All keys successfully deleted.\n"
                log "Deleted all keys from ssh-agent"
            else
                printf "Failed to delete all keys.\n"
                log_error "Failed to delete all keys from ssh-agent"
            fi
            ;;
        *)
            printf "Operation cancelled.\n"
            ;;
    esac
}

# --- Main Execution Logic ---
main() {
    # Initialize logging
    if ! setup_logging; then
        printf "Warning: Logging setup failed. Continuing with limited logging.\n" >&2
    fi

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

    # Check if ssh-add command is available
    if ! command -v ssh-add > /dev/null; then
        printf "Error: 'ssh-add' command not found. Please ensure SSH tools are installed.\n" >&2
        log_error "'ssh-add' command not found. Please ensure SSH tools are installed."
        exit 1
    fi

    # Check if ssh-agent is running, start it if not
    if ! ssh-add -l > /dev/null 2>&1; then
        printf "SSH agent not running. Attempting to start it...\n"
        if ! start_ssh_agent; then
            printf "Error: Failed to start ssh-agent. Please try starting it manually.\n" >&2
            log_error "Failed to start ssh-agent"
            exit 1
        fi
    fi

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
                list_current_keys
                wait_for_key
                ;;
            3)
                printf "Reloading all keys...\n"
                update_keys_list_file
                delete_keys_from_agent
                add_keys_to_agent
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
}

# --- Run Main ---
main
