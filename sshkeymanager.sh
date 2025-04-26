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

# Capture start time for execution duration logging
_script_start_time=$(date +%s.%N) # Use %s.%N for nanoseconds if supported, fallback needed if not

# Strict error handling: exit on error, treat unset variables as error, fail pipelines on first error
set -euo pipefail

# --- Global Variable Declarations ---

# Control Flags
declare IS_VERBOSE="false"

# Logging Configuration
declare LOG_FILE="/dev/null" # Default: Ensure variable exists for EXIT trap
declare LOG_FILENAME="${SKM_LOG_FILENAME:-sshkeygen.log}"
declare LOG_DIR="" # Determined below based on platform/env

# Platform Detection & Platform-Specific Settings
declare PLATFORM
PLATFORM=$(uname -s)
declare STAT_CMD
case "$PLATFORM" in
    "Darwin")
        STAT_CMD="stat -f %z"
        # Default Log Dir for Darwin
        LOG_DIR="${SKM_LOG_DIR:-$HOME/Library/Logs/sshkeygen}"
        ;;
    "Linux")
        STAT_CMD="stat -c %s"
        # Default Log Dir for Linux (check /var/log write permission)
        if [ -n "${SKM_LOG_DIR:-}" ]; then
            LOG_DIR="$SKM_LOG_DIR"
        elif [ -w "/var/log" ]; then
            LOG_DIR="/var/log/sshkeygen"
        else
            LOG_DIR="$HOME/.local/log/sshkeygen"
        fi
        ;;
    *)
        # Default for others
        STAT_CMD="stat -c %s"
        LOG_DIR="${SKM_LOG_DIR:-$HOME/.ssh/logs}"
        ;;
esac

# Core Application Paths
declare SSH_DIR="${SKM_SSH_DIR:-$HOME/.ssh}" # Allow override via SKM_SSH_DIR
declare VALID_KEY_LIST_FILE="${SKM_VALID_KEYS_FILE:-$HOME/.config/sshkeymanager/ssh_keys_list}" # Allow override
declare AGENT_ENV_FILE="${SKM_AGENT_ENV_FILE:-$HOME/.ssh/agent.env}" # Allow override

# Temporary File (Declared here, created later after logging setup)
declare KEYS_LIST_TMP=""

# Script Action State (Set by argument parsing)
declare ACTION="menu" # Default action
declare source_key_file="" # For --file option

# --- Argument Parsing --- (Parse arguments after functions are defined)

# Note: Global variables ACTION, source_key_file, IS_VERBOSE were declared with defaults earlier.
# This loop updates them based on the provided arguments.
# Use a temporary array to avoid consuming $@ globally if this were sourced.
original_args=("$@")
while [[ $# -gt 0 ]]; do
    # log_debug "Parsing argument: $1" # Cannot log reliably until setup_logging runs
    case $1 in
        -l|--list)
            ACTION="list"
            shift # past argument
            ;;
        -a|--add)
            ACTION="add"
            shift # past argument
            ;;
        -f|--file)
            if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                 printf "Error: Option '%s' requires a filename argument.\\n\\n" "$1" >&2
                 ACTION="help"
                 # Don't shift here, let the help action handle it or exit
                 break # Stop processing args on error
            fi
            ACTION="file"
            source_key_file="$2"
            shift # past argument (-f or --file)
            shift # past value (filename)
            ;;
        -D|--delete-all)
            ACTION="delete-all"
            shift # past argument
            ;;
        -m|--menu)
            ACTION="menu"
            shift # past argument
            ;;
        -v|--verbose)
            IS_VERBOSE="true"
            shift # past argument
            ;;
        -h|--help)
            ACTION="help"
            shift # past argument
            ;;
        *)
            # Unknown option
            printf "Error: Unknown option '%s'\\n\\n" "$1" >&2
            ACTION="help"
            break # Stop processing args on error
            ;;
    esac
done

# --- Runtime Initialization ---

# Function: setup_logging
# Purpose: Initializes the logging system, creating the log directory and file,
#          and handling log rotation based on size.
# Inputs: Global variables LOG_DIR, LOG_FILENAME, STAT_CMD.
# Outputs: Sets the global LOG_FILE variable. Creates log directory/file. Performs rotation. Returns 0/1.
setup_logging() {
    local max_log_size=1048576  # 1MB
    local max_log_files=5
    local initial_log_dir="$LOG_DIR"

    # Create log directory if it doesn't exist
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf "Warning: Could not create log directory '$LOG_DIR'. Using fallback location.\\n" >&2
        LOG_DIR="$HOME/.ssh/logs"
        printf "Attempting fallback log directory: %s\\n" "$LOG_DIR" >&2
        if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
            printf "Warning: Could not create fallback log directory. Logging disabled.\\n" >&2
            LOG_FILE="/dev/null"
            return 1
        fi
    fi

    # Now we should have a valid LOG_DIR, attempt to set LOG_FILE
    LOG_FILE="${LOG_DIR}/${LOG_FILENAME}"
    # Now we can use _try_log_debug, but also direct log_debug should work if verbose is set early
    # Use direct log_debug as the functions should be defined by now
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "Initial log directory determined/created: $LOG_DIR"; fi
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "Attempting to use log file: $LOG_FILE"; fi

    # Set up log file with rotation
    if ! touch "$LOG_FILE" 2>/dev/null; then
        printf "Warning: Could not create log file. Logging disabled.\\n" >&2
        LOG_FILE="/dev/null"
        return 1
    fi

    # Check log file size and rotate if needed
    if [ -f "$LOG_FILE" ]; then
        local log_size
        if ! log_size=$($STAT_CMD "$LOG_FILE" 2>/dev/null); then
            printf "Warning: Could not determine log file size. Log rotation disabled.\\n" >&2
        elif [ "$log_size" -gt "$max_log_size" ]; then
             if [ "$IS_VERBOSE" = "true" ]; then log_debug "Log file size ($log_size) exceeds limit ($max_log_size). Rotating logs."; fi
            for i in $(seq $((max_log_files-1)) -1 1); do
                if [ -f "${LOG_FILE}.${i}" ]; then
                     if [ "$IS_VERBOSE" = "true" ]; then log_debug "Moving ${LOG_FILE}.${i} to ${LOG_FILE}.$((i+1))"; fi
                    mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))" 2>/dev/null || true
                fi
            done
             if [ "$IS_VERBOSE" = "true" ]; then log_debug "Moving $LOG_FILE to ${LOG_FILE}.1"; fi
            mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
            touch "$LOG_FILE"
        fi
    else
         if [ "$IS_VERBOSE" = "true" ]; then log_debug "Log file does not exist, skipping rotation check."; fi
    fi

    chmod 600 "$LOG_FILE" 2>/dev/null || true
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "Logging setup complete. LOG_FILE set to: $LOG_FILE"; fi
    return 0
} # END setup_logging

# Function: log, log_error, log_warn, log_debug, log_info
# Purpose: Provide standard logging interfaces. Appends timestamped messages
#          to the configured LOG_FILE. log_error/log_warn also print to stderr.
#          log_debug only logs if IS_VERBOSE is "true".
# Inputs: $1=Message. Uses global LOG_FILE, IS_VERBOSE.
# Outputs: Appends to log file. Prints to stderr (for error/warn).

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - INFO: $1" >> "$LOG_FILE"
    fi
} # END log

log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "Error: %s\\n" "$1" >&2
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - ERROR: $1" >> "$LOG_FILE"
    fi
} # END log_error

log_warn() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "Warning: %s\\n" "$1" >&2
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - WARN: $1" >> "$LOG_FILE"
    fi
} # END log_warn

log_debug() {
    # Only log if verbose mode is enabled
    [ "$IS_VERBOSE" = "true" ] || return 0
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - DEBUG: $1" >> "$LOG_FILE"
    fi
} # END log_debug

log_info() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$timestamp - $$ - INFO: $1" >> "$LOG_FILE"
    fi
} # END log_info


# --- Validation Functions ---

# Function: validate_directory
# Description: Validates a directory's existence and permissions.
# Input: $1=Directory path, $2=Description (for error messages).
# Output: Returns 0 on success, 1 on failure. Prints errors to stderr.
validate_directory() {
    log_debug "Entering function: ${FUNCNAME[0]} (Dir: $1, Desc: $2)"
    local dir="$1"
    local description="$2"
    local return_status=0

    # Check if directory exists
    if [ ! -d "$dir" ]; then
        # Keep printf for immediate user feedback on validation failure
        printf "Error: %s directory '%s' does not exist.\n" "$description" "$dir" >&2
        log_error "Validation failed: Directory '$dir' ($description) does not exist."
        return_status=1
    # Check if directory is readable
    elif [ ! -r "$dir" ]; then
        printf "Error: %s directory '%s' is not readable.\n" "$description" "$dir" >&2
        log_error "Validation failed: Directory '$dir' ($description) is not readable."
        return_status=1
    # Check if directory is writable
    elif [ ! -w "$dir" ]; then
        printf "Error: %s directory '%s' is not writable.\n" "$description" "$dir" >&2
        log_error "Validation failed: Directory '$dir' ($description) is not writable."
        return_status=1
    # Check if directory is executable (accessible)
    elif [ ! -x "$dir" ]; then
        printf "Error: %s directory '%s' is not accessible.\n" "$description" "$dir" >&2
        log_error "Validation failed: Directory '$dir' ($description) is not accessible."
        return_status=1
    else
        log_debug "Validation successful for '$dir' ($description)."
    fi

    log_debug "Exiting function: ${FUNCNAME[0]} (Dir: $1, Status: $return_status)"
    return $return_status
} # END validate_directory

# Function: validate_ssh_dir
# Purpose: Specifically validates the configured SSH directory ($SSH_DIR).
#          Attempts to create it with mode 700 if it doesn't exist.
# Inputs: Uses global SSH_DIR.
# Outputs: Returns 0 on success (dir exists/created and is valid), 1 on failure. Prints errors.
validate_ssh_dir() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Validating SSH directory: $SSH_DIR"
    if ! validate_directory "$SSH_DIR" "SSH"; then
        log_warn "validate_ssh_dir: Initial validation failed for $SSH_DIR. Attempting to create."
        # Keep printf for user feedback during potentially interactive startup
        printf "Attempting to create SSH directory '%s'...\n" "$SSH_DIR"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Attempting to create SSH directory '$SSH_DIR'..."; fi
        log_info "Attempting to create SSH directory '$SSH_DIR'..."
        if ! mkdir -p "$SSH_DIR"; then
            # Error logged by log_error below
            # printf "Error: Failed to create SSH directory '%s'\n" "$SSH_DIR" >&2
            log_error "validate_ssh_dir: Failed to create directory $SSH_DIR"
            log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - create failed)"
            return 1
        fi
        log_info "validate_ssh_dir: Successfully created directory $SSH_DIR."
        printf "Successfully created SSH directory '%s'.\n" "$SSH_DIR"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Successfully created SSH directory '$SSH_DIR'."; fi
        log_debug "validate_ssh_dir: Setting permissions (700) on $SSH_DIR."
        chmod 700 "$SSH_DIR"
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - created OK)"
        return 0
    fi
    log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - exists and valid)"
    return 0
} # END validate_ssh_dir


# --- SSH Agent Management Functions ---

# Function: check_ssh_agent
# Description: Checks if the currently set SSH_AUTH_SOCK and SSH_AGENT_PID
#              point to a live and responsive ssh-agent process.
# Input: Uses environment vars SSH_AUTH_SOCK, SSH_AGENT_PID (with default expansion).
# Output: Returns 0 if agent is accessible, 1 otherwise. Logs details.
check_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "Checking agent status... (PID='${SSH_AGENT_PID:-}', SOCK='${SSH_AUTH_SOCK:-}')"
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ -z "${SSH_AGENT_PID:-}" ]; then log "check_ssh_agent: Required environment variables not set."; return 1; fi
    if [ ! -S "$SSH_AUTH_SOCK" ]; then log_debug "SSH_AUTH_SOCK ('$SSH_AUTH_SOCK') is not a socket."; log_error "check_ssh_agent: SSH_AUTH_SOCK is not a socket: $SSH_AUTH_SOCK"; return 1; fi
    log_debug "check_ssh_agent: Verifying agent process PID: $SSH_AGENT_PID"
    if ! ps -p "$SSH_AGENT_PID" > /dev/null 2>&1; then log_debug "Process with PID $SSH_AGENT_PID not found."; log_error "check_ssh_agent: SSH_AGENT_PID ($SSH_AGENT_PID) process not running."; return 1; fi
    log_debug "check_ssh_agent: Attempting communication via ssh-add -l"
    # Pipe output to /dev/null but capture status of ssh-add, not tee (or true)
    ssh-add -l > /dev/null 2>&1 || true
    local exit_code=${PIPESTATUS[0]:-$?} # Use PIPESTATUS if available, fallback to $?
    log_debug "check_ssh_agent: ssh-add -l communication attempt exit code: $exit_code"
    # Exit codes 0 (keys listed) and 1 (no keys) indicate successful communication
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 1 ]; then log_debug "Agent communication successful (exit code $exit_code)."; log_debug "Exiting function: ${FUNCNAME[0]} (status: 0)"; return 0; fi
    # Exit code 2 means cannot connect
    if [ $exit_code -eq 2 ]; then log_debug "Cannot communicate with agent (ssh-add -l exit code $exit_code). SOCK invalid or agent died?"; log_error "check_ssh_agent: Cannot communicate with agent (ssh-add -l exit code $exit_code). SOCK invalid or agent died?"; return 1; fi
    # Other exit codes are unexpected errors
    log_debug "Unexpected error communicating with agent (ssh-add -l exit code $exit_code)."
    log_error "check_ssh_agent: Unexpected error communicating with agent (ssh-add -l exit code $exit_code)."
    log_debug "Exiting function: ${FUNCNAME[0]} (status: 1)"
    return 1
} # END check_ssh_agent

# Function: ensure_ssh_agent
# Description: Ensures a single, accessible ssh-agent is running and its
#              environment variables are EXPORTED for the current script.
#              Reuses existing agents if possible via ~/.ssh/agent.env.
#              Starts a new agent if necessary.
# Input: None. Uses global SSH_DIR. Reads/writes $HOME/.ssh/agent.env.
# Output: Exports SSH_AUTH_SOCK/PID. Returns 0 on success, 1 on failure. Prints status messages.
ensure_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Ensuring SSH agent is active..."
    # Uses global AGENT_ENV_FILE

    # 1. Check if agent is already configured and working in this environment
    log_debug "ensure_ssh_agent: Checking current environment variables and agent status..."
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -n "${SSH_AGENT_PID:-}" ] && check_ssh_agent; then
        log_info "Agent already running and sourced (PID: ${SSH_AGENT_PID:-})."
        # Keep printf for immediate feedback
        printf "SSH agent is already running (PID: %s).\n" "${SSH_AGENT_PID:-Unknown}"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: SSH agent is already running (PID: ${SSH_AGENT_PID:-Unknown})."; fi
        # Ensure they are exported, just in case
        export SSH_AUTH_SOCK SSH_AGENT_PID
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - existing agent OK)"
        return 0
    fi
    log_debug "Agent not (verifiably) running or sourced in current environment."

    # 2. Try sourcing persistent environment file
    if [ -f "$AGENT_ENV_FILE" ]; then
        log_debug "Found persistent agent file: $AGENT_ENV_FILE. Sourcing..."
        # Source the file into the current script's environment
        # shellcheck disable=SC1090 # Dynamically sourced file
        . "$AGENT_ENV_FILE" >/dev/null
        log_debug "ensure_ssh_agent: Sourced persistent file. Checking agent status again..."
        # Now check if sourcing worked and the agent is valid
        if check_ssh_agent; then
            log_info "Sourcing persistent file successful. Reusing agent (PID: ${SSH_AGENT_PID:-})."
            # Keep printf for immediate feedback
            printf "Successfully connected to existing ssh-agent (PID: %s).\n" "${SSH_AGENT_PID:-Unknown}"
            if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Successfully connected to existing ssh-agent (PID: ${SSH_AGENT_PID:-Unknown})."; fi
            # Ensure they are exported
            export SSH_AUTH_SOCK SSH_AGENT_PID
            log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - sourced agent OK)"
            return 0
        else
            log_warn "Persistent file found ($AGENT_ENV_FILE) but agent invalid/inaccessible after sourcing. Removing stale file."
            rm -f "$AGENT_ENV_FILE" # Remove stale file
            # Unset potentially incorrect variables sourced from the stale file
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    else
        log_debug "No persistent agent file found ($AGENT_ENV_FILE)."
    fi

    # 3. Start a new agent
    log_info "Starting new ssh-agent..."
    # Keep printf for immediate feedback
    printf "Starting new ssh-agent...\n"
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Starting new ssh-agent..."; fi

    # Create .ssh directory if needed
    log_debug "ensure_ssh_agent: Ensuring $HOME/.ssh directory exists..."
    if ! mkdir -p "$HOME/.ssh"; then log_error "Failed to create SSH directory $HOME/.ssh"; return 1; fi
    log_debug "ensure_ssh_agent: Setting permissions on $HOME/.ssh..."
    if ! chmod 700 "$HOME/.ssh"; then log_warn "Failed to set permissions on $HOME/.ssh"; fi

    # Start ssh-agent and capture output
    log_debug "ensure_ssh_agent: Executing ssh-agent -s..."
    local agent_output
    if ! agent_output=$(ssh-agent -s); then
        log_error "Failed to execute ssh-agent -s"
        # Error already printed by log_error
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - ssh-agent failed)"
        return 1
    fi
    log_debug "ssh-agent -s output captured: $agent_output"

    # Extract environment variables
    log_debug "ensure_ssh_agent: Extracting environment variables from agent output..."
    local ssh_auth_sock="${agent_output#*SSH_AUTH_SOCK=}"
    ssh_auth_sock="${ssh_auth_sock%%;*}"
    local ssh_agent_pid="${agent_output#*SSH_AGENT_PID=}"
    ssh_agent_pid="${ssh_agent_pid%%;*}"
    if [ -z "$ssh_auth_sock" ] || [ -z "$ssh_agent_pid" ]; then
        log_error "Failed to extract env vars from ssh-agent output: $agent_output"
        # Error already printed by log_error
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - parse failed)"
        return 1
    fi
    log_info "Extracted new agent details: SOCK=$ssh_auth_sock PID=$ssh_agent_pid"

    # Export variables into the current script's environment
    export SSH_AUTH_SOCK="$ssh_auth_sock"
    export SSH_AGENT_PID="$ssh_agent_pid"
    log_debug "Exported new agent variables into current scope."

    # Save agent environment variables to persistent file
    log "ensure_ssh_agent: Saving agent environment to $AGENT_ENV_FILE"
    {
        printf 'SSH_AUTH_SOCK=%s; export SSH_AUTH_SOCK;\n' "$ssh_auth_sock"
        printf 'SSH_AGENT_PID=%s; export SSH_AGENT_PID;\n' "$ssh_agent_pid"
        printf '# Agent started on %s\n' "$(date)"
    } > "$AGENT_ENV_FILE"
    log_debug "ensure_ssh_agent: Setting permissions on $AGENT_ENV_FILE..."
    if ! chmod 600 "$AGENT_ENV_FILE"; then log_warn "Failed to set permissions on $AGENT_ENV_FILE"; fi
    log_info "Agent environment saved to $AGENT_ENV_FILE."

    # Final verification (using the exported variables in current scope)
    log_debug "ensure_ssh_agent: Performing final verification of new agent..."
    sleep 0.5 # Give agent a moment
    if check_ssh_agent; then
        log_info "New agent started and verified successfully."
        # Keep printf for immediate feedback
        printf "Successfully started new ssh-agent (PID: %s).\n" "$ssh_agent_pid"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Successfully started new ssh-agent (PID: $ssh_agent_pid)."; fi
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - new agent OK)"
        return 0 # Success!
    else
        log_error "Started new agent but failed final verification."
        # Error already printed by log_error
        # Clean up potentially bad environment state
        log_debug "ensure_ssh_agent: Cleaning up failed agent state..."
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        rm -f "$AGENT_ENV_FILE" # Remove possibly bad file
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - verification failed)"
        return 1 # Failure!
    fi
} # END ensure_ssh_agent


# --- Core Key Management Functions ---

# Function: update_keys_list_file
# Purpose: Finds potential private key files in $SSH_DIR and writes their basenames
#          to the temporary file $KEYS_LIST_TMP.
#          NOTE: Uses a less robust find command compared to the .pub matching logic.
# Inputs: Uses global SSH_DIR, KEYS_LIST_TMP, PLATFORM.
# Outputs: Overwrites KEYS_LIST_TMP. Returns 0 if files found, 1 otherwise. Prints status.
update_keys_list_file() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Finding potential private key files in $SSH_DIR..."

    # Clear the temporary file
    log_debug "update_keys_list_file: Clearing temporary key list file: $KEYS_LIST_TMP"
    > "$KEYS_LIST_TMP"

    # Platform-specific find command (less robust than .pub matching)
    log_debug "update_keys_list_file: Running find command for platform $PLATFORM..."
    if [[ "$PLATFORM" == "Darwin" ]]; then
        # macOS version (without -printf) - Attempts to exclude common non-key files/extensions
        find "$SSH_DIR" -maxdepth 1 -type f \
            ! -name 'known_hosts*' \
            ! -name 'authorized_keys*' \
            ! -name '*.*' \
            ! -name 'config' \
            -exec basename {} \; > "$KEYS_LIST_TMP"
    else
        # Linux version (with -printf) - Attempts to exclude common non-key files/extensions
        find "$SSH_DIR" -maxdepth 1 -type f \
            ! -name 'known_hosts*' \
            ! -name 'authorized_keys*' \
            ! -name '*.*' \
            ! -name 'config' \
            -printf '%f\n' > "$KEYS_LIST_TMP"
    fi
    log_debug "update_keys_list_file: Find command complete."

    # Count the number of keys found
    log_debug "update_keys_list_file: Counting keys found..."
    local key_count
    key_count=$(wc -l < "$KEYS_LIST_TMP")
    log_info "Found $key_count potential key entries in temp file $KEYS_LIST_TMP."

    if [ "$key_count" -eq 0 ]; then
        # Keep printf for user feedback
        printf "No potential SSH key files found in %s\n" "$SSH_DIR"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: No potential SSH key files found in $SSH_DIR"; fi
        log_info "No potential SSH key files found in directory $SSH_DIR using find logic."
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - no keys found)" # Assuming update should fail if no keys found
        return 1 # Indicate failure if no keys found, matching previous logic check in main
    else
        # Keep printf for user feedback
        printf "Found %d potential key file(s) in %s (written to temp list).\n" "$key_count" "$SSH_DIR"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Found $key_count potential key file(s) in $SSH_DIR (written to temp list)."; fi
        log_info "Found $key_count potential key file(s) in $SSH_DIR using find logic."
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - keys found)"
        return 0
    fi
} # END update_keys_list_file

# Function: delete_keys_from_agent
# Purpose: Deletes all keys currently loaded in the ssh-agent using `ssh-add -D`.
# Inputs: None. Interacts with ssh-agent.
# Outputs: Returns 0 on success (or if no keys were present), 1 on failure. Prints status.
delete_keys_from_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Attempting to delete all keys from ssh-agent..."
    log_debug "delete_keys_from_agent: Running ssh-add -D..."
    # Add || true to prevent set -e exit on failure, then check status
    ssh-add -D || true
    local del_status=${PIPESTATUS[0]:-$?} # Get status of ssh-add, not true
    log_debug "delete_keys_from_agent: ssh-add -D exit status: $del_status"

    if [ "$del_status" -eq 0 ]; then
        log_info "All keys successfully deleted from agent."
        # Keep printf for user feedback
        printf "All keys successfully deleted from agent.\n"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: All keys successfully deleted from agent."; fi
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 0)"
        return 0
    elif [ "$del_status" -eq 1 ]; then
        # Exit code 1 from ssh-add -D often means "no keys to delete"
        log_info "Could not delete keys from agent (status: $del_status) - likely none were loaded."
        # Keep printf for user feedback
        printf "No keys found in agent to delete.\n"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: No keys found in agent to delete."; fi
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - no keys)"
        return 0 # Treat as success in this context
    else
        # Other non-zero codes indicate an error
        log_error "Failed to delete keys from agent (status: $del_status)."
        # Error already printed by log_error
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - error)"
        return 1
    fi
} # END delete_keys_from_agent

# Function: add_keys_to_agent
# Purpose: Adds SSH keys to the agent based on a list of key *basenames*.
#          It reads the basenames from the persistent cache file ($VALID_KEY_LIST_FILE).
# Inputs: Uses global VALID_KEY_LIST_FILE, SSH_DIR, PLATFORM.
# Outputs: Adds keys to agent. Returns 0 if at least one key added, 1 otherwise. Prints status.
add_keys_to_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Attempting to add keys listed in $VALID_KEY_LIST_FILE to the agent..."
    local keyfile
    local key_path
    local added_count=0
    local failed_count=0
    local platform
    platform=$(uname -s)

    # Check if VALID_KEY_LIST_FILE exists and is non-empty
    if [ ! -s "$VALID_KEY_LIST_FILE" ]; then
        # Keep printf for user feedback
        printf "Key list file '%s' is empty or does not exist. Cannot add keys.\n" "$VALID_KEY_LIST_FILE"
        log_error "Key list file ($VALID_KEY_LIST_FILE) is empty or does not exist. No keys to add."
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - no keys list)"
        return 1 # Indicate failure condition - no keys to even try adding
    fi

    # Keep printf for user feedback
    printf "Adding SSH keys to agent (using list: %s)...\n" "$VALID_KEY_LIST_FILE"
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Adding SSH keys to agent (using list: $VALID_KEY_LIST_FILE)..."; fi
    log_info "Adding SSH keys to agent using list file: $VALID_KEY_LIST_FILE"
    log_debug "add_keys_to_agent: Starting loop through keys in $VALID_KEY_LIST_FILE..."
    while IFS= read -r keyfile || [[ -n "$keyfile" ]]; do
        [ -z "$keyfile" ] && continue
        key_path="$SSH_DIR/$keyfile"
        log_debug "add_keys_to_agent: Processing key entry: $keyfile (Path: $key_path)"

        if [ -f "$key_path" ]; then
            # Omit per-key printf, rely on summary. Log instead.
            # printf "Adding key: %s\n" "$keyfile"
            log_info "Attempting to add key: $key_path"
            local ssh_add_output
            local ssh_add_status=0
            local cmd_to_run

            log_debug "add_keys_to_agent: Running ssh-add for $key_path (Platform: $PLATFORM)"
            # Run ssh-add, capture output and status, allow failure without set -e exit
            # Pipe stderr to stdout to capture errors in the output variable
            if [[ "$PLATFORM" == "Darwin" ]]; then
                cmd_to_run="ssh-add --apple-use-keychain \"$key_path\""
                ssh_add_output=$(ssh-add --apple-use-keychain "$key_path" 2>&1 || true)
                ssh_add_status=${PIPESTATUS[0]:-$?}
            else
                cmd_to_run="ssh-add \"$key_path\""
                ssh_add_output=$(ssh-add "$key_path" 2>&1 || true)
                ssh_add_status=${PIPESTATUS[0]:-$?}
            fi
            log_debug "add_keys_to_agent: ssh-add command ('$cmd_to_run') finished with status: $ssh_add_status"
            log_debug "add_keys_to_agent: ssh-add output: $ssh_add_output"

            # Log the raw output from ssh-add as well
            if [ -n "$ssh_add_output" ]; then
                 # Avoid logging the full key data if successful?
                 # Maybe just log if status is non-zero or output contains 'fail'/'error'
                 if [ "$ssh_add_status" -ne 0 ] || [[ "$ssh_add_output" == *[Ee][Rr][Rr][Oo][Rr]* ]] || [[ "$ssh_add_output" == *[Ff][Aa][Ii][Ll]* ]]; then
                     log "ssh-add output: $ssh_add_output"
                 fi
            fi

            if [ $ssh_add_status -eq 0 ]; then
                # Omit per-key printf
                # printf "  ✓ Successfully added\n"
                log_info "Successfully added $keyfile"
                ((added_count++))
            else
                # Keep printf for failure feedback
                printf "  ✗ Failed to add key '%s' (status: %d)\n" "$keyfile" "$ssh_add_status"
                if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf:   ✗ Failed to add key '$keyfile' (status: $ssh_add_status)"; fi
                log_error "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status). Output logged if relevant."
                ((failed_count++))
            fi
        else
            # Keep printf for failure feedback
            printf "  ✗ Key file '%s' not found at '%s'\n" "$keyfile" "$key_path"
            if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf:   ✗ Key file '$keyfile' not found at '$key_path'"; fi
            log_warn "Key file '$keyfile' listed but not found at '$key_path'. Skipping."
            ((failed_count++)) # Count missing files as failures too
        fi
    done < "$VALID_KEY_LIST_FILE"
    log_debug "add_keys_to_agent: Finished loop through keys."

    # Keep final summary printf
    printf "\nSummary: %d key(s) added, %d key(s) failed.\n" "$added_count" "$failed_count"
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Summary: $added_count key(s) added, $failed_count key(s) failed."; fi
    log_info "Finished adding keys. Added: $added_count, Failed: $failed_count"

    # Determine final return status: 0 if at least one key added, 1 otherwise
    if [ "$added_count" -gt 0 ]; then
      log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - some keys added)"
      return 0
    else
      log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - no keys added)"
      return 1
    fi
} # END add_keys_to_agent


# --- Interactive Menu Helper Functions ---

# Function: display_main_menu
# Purpose: Clears the screen and displays the main menu options.
# Inputs: Uses global PLATFORM, SSH_DIR.
# Outputs: Prints menu to stdout.
display_main_menu() {
    log_debug "printf: Displaying main menu..." # Log summary before printing block
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
} # END display_main_menu

# Function: get_menu_choice
# Purpose: Prompts the user for input and validates it against menu options.
# Inputs: Reads from stdin (/dev/tty).
# Outputs: Echoes the valid choice (1-6, q, Q) to stdout. Prints errors to stdout.
get_menu_choice() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    while true; do
        read -r -p "Enter choice [1-6, q]: " choice < /dev/tty
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "prompt: Enter choice [1-6, q]: (User entered: '$choice')"; fi
        log_debug "get_menu_choice: User entered: '$choice'"
        case "$choice" in
            [1-6]|q|Q)
                log_debug "get_menu_choice: Valid choice '$choice' selected."
                log_debug "Exiting function: ${FUNCNAME[0]} (selected: $choice)"
                echo "$choice"
                return 0
                ;;
            *)
                printf "Invalid choice '%s'. Please enter a number between 1 and 6, or 'q' to quit.\n" "$choice"
                if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Invalid choice '$choice'. Please enter a number between 1 and 6, or 'q' to quit."; fi
                log_warn "get_menu_choice: Invalid choice entered: '$choice'"
                sleep 1
                ;;
        esac
    done
} # END get_menu_choice

# Function: wait_for_key
# Purpose: Pauses script execution until the user presses any key.
# Inputs: Reads from stdin (/dev/tty).
# Outputs: Prints prompt to stdout.
wait_for_key() {
    printf "\nPress any key to return to the main menu...\n"
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Press any key to return to the main menu..."; fi
    read -n 1 -s -r < /dev/tty
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "read: Key pressed."; fi
} # END wait_for_key


# --- Interactive Menu Core Logic Functions ---

# Function: list_current_keys
# Purpose: Lists keys currently loaded in the ssh-agent using `ssh-add -l`.
# Inputs: None. Interacts with ssh-agent.
# Outputs: Prints key list or status message to stdout. Returns 0 on success, 1 on error.
list_current_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Listing current keys in agent..."
    log_debug "list_current_keys: Running initial ssh-add -l to check status..."
    # Run once to check status without capturing output, avoiding potential command substitution issues
    # Allow exit codes 1 or 2 without triggering set -e
    ssh-add -l >/dev/null 2>&1 || true
    local exit_code=${PIPESTATUS[0]:-$?} # Get status of ssh-add, not true
    log_debug "list_current_keys: Initial ssh-add -l status check exit code: $exit_code"

    local return_status=0 # Default to success

    case $exit_code in
        0)
            log_info "list_current_keys: Agent reports keys are loaded (Exit code: 0). Attempting to list..."
            # Keep printf for user feedback
            printf "Keys currently loaded in the agent:\n"
            if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Keys currently loaded in the agent:"; fi
            log_info "Keys currently loaded in the agent:"
            # Now run it again to actually display the keys and log them
            # Allow exit code 1 (no identities) here, treat other non-zero as error
            # Run ssh-add -l and capture output for logging, print to stdout separately
            local key_list
            key_list=$(ssh-add -l 2>&1 || true)
            local list_exit_code=${PIPESTATUS[0]:-$?} # Get status of ssh-add, not tee
            log_debug "list_current_keys: Second ssh-add -l for listing exit code: $list_exit_code"

            # Print the output (if any) to the user
            if [ -n "$key_list" ]; then
                printf "%s\n" "$key_list"
                if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf (key list):\n$key_list"; fi
                # Log the actual list (trimming potential sensitive info might be better)
                log_info "List of keys reported by agent:\n$key_list"
            fi

            # Check for unexpected errors (neither 0 nor 1)
            if [ "$list_exit_code" -ne 0 ] && [ "$list_exit_code" -ne 1 ]; then
                log_error "list_current_keys: ssh-add -l failed unexpectedly (exit code $list_exit_code) despite initial exit code 0."
                # Don't pipe this error, it's already logged
                printf "Error listing keys (Code: %s), although agent reported keys present.\n" "$list_exit_code" >&2
                return_status=1 # Indicate an error state
            fi
            # If exit code was 0 or 1, the command either listed keys or printed 'no identities'
            # In either case, the function succeeded in its task.
            log_debug "list_current_keys: Listing complete (or agent confirmed no identities)."
            ;;
        1)
            log_info "list_current_keys: No keys currently loaded (Exit code: 1)."
            # Keep printf for user feedback
            printf "No keys currently loaded in the agent.\n"
            if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: No keys currently loaded in the agent."; fi
            printf "Hint: Use option 3 to load keys from '%s'.\n" "$SSH_DIR"
            if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Hint: Use option 3 to load keys from '$SSH_DIR'."; fi
            ;;
        2)
            log_error "list_current_keys: SSH_AUTH_SOCK invalid or agent not running (Exit code: 2)."
            # Don't pipe this error, it's already logged
            printf "Error: Could not connect to the SSH agent. Is it running?\n" >&2
            return_status=1 # Indicate an error state
            ;;
        *)
            log_error "list_current_keys: Unknown error from ssh-add -l check (Exit code: $exit_code)."
            # Don't pipe this error, it's already logged
            printf "Error: An unexpected error occurred while checking SSH keys (Code: %s).\n" "$exit_code" >&2
            return_status=1 # Indicate an error state
            ;;
    esac

    log_debug "Exiting function: ${FUNCNAME[0]} (status: $return_status)"
    return $return_status
} # END list_current_keys

# Function: display_log_location
# Purpose: Displays the configured log file location and its current size.
# Inputs: Uses global LOG_FILE.
# Outputs: Prints log info to stdout. Always returns 0.
display_log_location() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "printf: Displaying log file info..." # Summary log
    printf "\n+++ Log File Information +++\n"
    if [ "$LOG_FILE" = "/dev/null" ]; then
        printf "Logging is currently disabled.\n"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Logging is currently disabled."; fi
        log_info "Logging is disabled."
    else
        log_info "Displaying log file location: $LOG_FILE"
        printf "Current log file location: %s\n" "$LOG_FILE"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Current log file location: $LOG_FILE"; fi
        local log_size_human="-"
        if [ -f "$LOG_FILE" ]; then
            log_size_human=$(ls -lh "$LOG_FILE" 2>/dev/null | awk '{print $5}')
            log_debug "Log file size (human): $log_size_human"
        else
             log_warn "Log file $LOG_FILE not found when trying to get size."
        fi
        printf "Log file size: %s\n" "$log_size_human"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Log file size: $log_size_human"; fi
    fi
    printf "++++++++++++++++++++++++++++++++++++\n"
    log_debug "Exiting function: ${FUNCNAME[0]} (status: 0)"
    # This function doesn't really fail, so always return 0
    return 0
} # END display_log_location

# Function: delete_single_key
# Purpose: Interactively lists potential key files (using `update_keys_list_file`)
#          and prompts the user to select one for deletion from the agent using `ssh-add -d`.
# Inputs: Reads user input. Uses global SSH_DIR, KEYS_LIST_TMP. Interacts with ssh-agent.
# Outputs: Prints prompts and status messages. Returns 0 on success/cancel, 1 on error.
delete_single_key() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "printf: Displaying 'Delete Single Key' header..." # Summary log
    printf "\n+++ Delete Single Key +++\n"

    # FIRST: Check if any keys are actually loaded in the agent right now.
    log_debug "delete_single_key: Checking agent status via ssh-add -l..."
    local agent_list_output
    agent_list_output=$(ssh-add -l 2>/dev/null || true)
    local agent_check_status=${PIPESTATUS[0]:-$?} # Get status of ssh-add
    log_debug "delete_single_key: Initial ssh-add -l check status: $agent_check_status. Output:\n$agent_list_output"

    # Check for errors first (excluding expected status 0 and 1)
    if [ "$agent_check_status" -ne 0 ] && [ "$agent_check_status" -ne 1 ]; then
        # Handle agent connection error (status 2) or other unexpected errors
        log_error "delete_single_key: Cannot query agent (ssh-add -l check status: $agent_check_status)."
        printf "Error: Could not query the SSH agent (status: %d).\n" "$agent_check_status" >&2
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - agent query error)"
        return 1 # Error
    fi

    # Now check if keys are *really* present (Status 1 OR output is 'no identities' means NO keys)
    local trimmed_agent_list
    trimmed_agent_list=$(echo "$agent_list_output" | awk '{$1=$1};1') # Trim whitespace
    if [ "$agent_check_status" -eq 1 ] || [[ "$trimmed_agent_list" == "The agent has no identities."* ]]; then # Use wildcard match for robustness
         log_info "delete_single_key: No keys currently loaded in agent (Status: $agent_check_status, List: '$trimmed_agent_list')."
         printf "No keys currently loaded in ssh-agent to delete.\n"
         if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: No keys currently loaded in ssh-agent to delete."; fi
         log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - no keys loaded)"
         return 0 # Success, nothing to do
    fi

    # If we reach here, agent_check_status was 0 AND output was not "no identities"
    # Meaning keys ARE actually loaded and listed.
    log_info "delete_single_key: Agent has keys loaded. Proceeding to list key *files* for deletion."

    # SECOND: Proceed with listing files for deletion (macOS Keychain compatibility)
    log_debug "delete_single_key: Updating file list cache..."
    if ! update_keys_list_file; then
        log_error "delete_single_key: Failed to update list of key files. Cannot proceed."
        # Error message already printed by update_keys_list_file
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - update_keys_list_file failed)"
        return 1
    fi

    # Check if the temporary file list is empty after update
    if [ ! -s "$KEYS_LIST_TMP" ]; then
        # This case should be unlikely if agent reported keys loaded, but check anyway
        log_error "delete_single_key: Agent reported keys, but no key files found in $SSH_DIR after update."
        printf "Error: Inconsistency detected - agent has keys, but no key files found in %s.\n" "$SSH_DIR" >&2
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - inconsistency)"
        return 1
    fi

    # Read the list of key filenames into an array
    local key_files=()
    log_debug "delete_single_key: Reading key filenames from $KEYS_LIST_TMP..."
    if command -v mapfile >/dev/null; then
        mapfile -t key_files < "$KEYS_LIST_TMP"
    else
        log_warn "delete_single_key: mapfile command not found, using 'while read' loop."
        while IFS= read -r line; do
            # Skip empty lines just in case
            [ -n "$line" ] && key_files+=("$line")
        done < "$KEYS_LIST_TMP"
    fi

    if [ ${#key_files[@]} -eq 0 ]; then
        log_error "delete_single_key: Failed to read key filenames from $KEYS_LIST_TMP after mapfile/read."
        printf "Error reading key file list.\n" >&2
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - read list failed)"
        return 1
    fi

    log_debug "delete_single_key: Found ${#key_files[@]} key files to list."

    # Display numbered list of filenames
    printf "Select a key file to remove from the agent:\n"
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Select a key file to remove from the agent:"; fi
    log_info "Presenting list of key files for deletion selection:"
    local i
    for i in "${!key_files[@]}"; do
        printf "  %2d) %s\n" "$((i + 1))" "${key_files[i]}"
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf:   $((i + 1))) ${key_files[i]}"; fi
        log_info "  $((i + 1))) ${key_files[i]}"
    done

    local return_status=1 # Default to failure unless successful
    # Get user selection
    log_debug "delete_single_key: Waiting for user input..."
    while true; do
        read -r -p "Enter key number to delete (or 'c' to cancel): " choice < /dev/tty
        if [ "$IS_VERBOSE" = "true" ]; then log_debug "prompt: Enter key number to delete (or 'c' to cancel): (User entered: '$choice')"; fi
        log_debug "delete_single_key: User entered: '$choice'"
        case "$choice" in
            c|C)
                printf "Operation cancelled.\n"
                if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Operation cancelled."; fi
                log_info "delete_single_key: User cancelled operation."
                return_status=0 # Cancelled successfully
                break # Exit loop
                ;;
            *) # Validate input is a number within range
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#key_files[@]}" ]; then
                    local selected_index=$((choice - 1))
                    local selected_filename="${key_files[$selected_index]}"
                    local key_path="$SSH_DIR/$selected_filename"
                    log_info "delete_single_key: User selected key file index: $choice (Filename: '$selected_filename', Path: '$key_path')"

                    printf "Attempting to delete key file: %s\n" "$selected_filename"
                    if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Attempting to delete key file: $selected_filename"; fi
                    log_info "delete_single_key: Attempting ssh-add -d '$key_path'"

                    # Perform the deletion using the file path
                    # Redirect stderr to /dev/null
                    ssh-add -d "$key_path" 2>/dev/null || true
                    local del_status=${PIPESTATUS[0]:-$?} # Get status of ssh-add
                    log_debug "delete_single_key: ssh-add -d exited with status: $del_status"

                    if [ "$del_status" -eq 0 ]; then
                        printf "Key '%s' successfully deleted from agent.\n" "$selected_filename"
                        if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Key '$selected_filename' successfully deleted from agent."; fi
                        log_info "delete_single_key: Successfully deleted key file '$key_path' from agent."
                        return_status=0 # Success
                    else
                        # ssh-add -d failed (exit code 1 usually means key not found in agent)
                        printf "Error: Failed to delete key '%s' from agent (status: %d).\n" "$selected_filename" "$del_status" >&2
                        log_error "delete_single_key: Failed to delete key file '$key_path' (ssh-add -d exit status: $del_status)."
                        if [ "$del_status" -eq 1 ]; then
                             printf "       (This often means the key wasn't loaded in the agent session.)\n" >&2
                            if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf:        (This often means the key wasn't loaded in the agent session.)"; fi
                        fi
                        return_status=1 # Indicate deletion failed
                    fi
                    break # Exit loop after attempt
                else
                    printf "Invalid selection. Please enter a number between 1 and %d, or 'c' to cancel.\n" "${#key_files[@]}"
                    if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Invalid selection. Please enter a number between 1 and ${#key_files[@]}, or 'c' to cancel."; fi
                    log_warn "delete_single_key: Invalid user input: '$choice'"
                fi
                ;;
        esac
    done

    log_debug "Exiting function: ${FUNCNAME[0]} (status: $return_status)"
    return $return_status
} # END delete_single_key

# Function: delete_all_keys
# Purpose: Deletes all keys from the agent after user confirmation.
# Inputs: Reads user input. Interacts with ssh-agent.
# Outputs: Prints prompts and status messages. Returns 0 on success/cancel, 1 on error.
delete_all_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "printf: Displaying 'Delete All Keys' header..." # Summary log
    printf "\n+++ Delete All Keys +++\n"
    log_info "Attempting to delete all keys..."

    # Explicitly check agent status and key presence
    ssh-add -l >/dev/null 2>&1 || true
    local exit_code=${PIPESTATUS[0]:-$?} # Get status of ssh-add, not true
    log_debug "delete_all_keys: ssh-add -l status check exit code: $exit_code"

    local key_count=0
    local return_status=0 # Default success

    case $exit_code in
        0)
            # Keys *might* be present (or just agent is reachable). Get list to confirm.
            log_info "delete_all_keys: Agent reachable (initial check status 0). Retrieving list..."
            local key_list
            # Run command, capture output and status, allow status 1 (no keys)
            key_list=$(ssh-add -l 2>/dev/null || true)
            local list_status=${PIPESTATUS[0]:-$?} # Get status of ssh-add, not true
            log_debug "delete_all_keys: ssh-add -l for list retrieval status: $list_status. Output:\n$key_list"

            # Check if the listing command itself failed unexpectedly (not exit code 0 or 1)
            if [ "$list_status" -ne 0 ] && [ "$list_status" -ne 1 ]; then
                 log_error "delete_all_keys: Failed to get key list (ssh-add -l status: $list_status) even though initial check passed."
                 printf "Error: Failed to retrieve key list from agent for counting (Code: %d).\n" "$list_status" >&2
                 log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - list retrieval failed)"
                 return 1 # Error, return to menu
            fi

            # Now, check the *content* if status was 0 or 1
            # Trim potential whitespace for comparison
            local trimmed_key_list
            trimmed_key_list=$(echo "$key_list" | awk '{$1=$1};1') # Trim leading/trailing whitespace
            if [ "$list_status" -eq 1 ] || [ "$trimmed_key_list" = "The agent has no identities." ]; then
                 # Status 1 OR the specific message means no keys
                 log_info "delete_all_keys: Agent has no identities (Status: $list_status, List: '$trimmed_key_list')."
                 key_count=0
            elif [ -n "$key_list" ]; then
                 # Status 0 and not the specific message, count lines
                 key_count=$(echo "$key_list" | wc -l)
                 log_debug "delete_all_keys: Counted $key_count keys."
            else
                 # Status 0 but empty list (shouldn't happen with ssh-add -l?)
                 log_warn "delete_all_keys: ssh-add -l status 0 but output is empty. Treating as 0 keys."
                 key_count=0
            fi

            # Proceed based on final count
            if [ "$key_count" -eq 0 ]; then
                log_info "delete_all_keys: Counted 0 keys. No keys to delete."
                printf "No keys currently loaded in ssh-agent.\n"
                if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: No keys currently loaded in ssh-agent."; fi
                log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - no keys)"
                return 0 # Nothing to delete, return successfully
            fi
            log_info "delete_all_keys: Found $key_count keys to delete."
            ;;
        1)
            log_info "delete_all_keys: No keys loaded (exit code 1)."
            printf "No keys currently loaded in ssh-agent.\n"
            if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: No keys currently loaded in ssh-agent."; fi
            log_debug "Exiting function: ${FUNCNAME[0]} (status: 0 - no keys)"
            return 0 # Nothing to delete, return successfully
            ;;
        2)
            log_error "delete_all_keys: Cannot connect to agent (exit code 2)."
            printf "Error: Could not connect to the SSH agent.\n" >&2
            log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - agent connect error)"
            return 1 # Indicate error, return to menu
            ;;
        *)
            log_error "delete_all_keys: Unknown error from ssh-add -l check (exit code $exit_code)."
            printf "Error: An unexpected error occurred checking keys (Code: %s).\n" "$exit_code" >&2
            log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - unknown error)"
            return 1 # Indicate error, return to menu
            ;;
    esac

    # --- Proceed with deletion confirmation if exit_code was 0 and key_count > 0 ---
    printf "This will delete all %d keys from ssh-agent.\n" "$key_count"
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: This will delete all $key_count keys from ssh-agent."; fi
    log_debug "delete_all_keys: Waiting for user confirmation..."
    # Do not tee read prompt
    read -r -p "Are you sure you want to continue? (y/N): " confirm < /dev/tty
    if [ "$IS_VERBOSE" = "true" ]; then log_debug "prompt: Are you sure you want to continue? (y/N): (User entered: '$confirm')"; fi
    log_debug "delete_all_keys: User entered confirmation: '$confirm'"

    case "$confirm" in
        y|Y)
            log_info "delete_all_keys: User confirmed deletion of all keys."
            log_info "delete_all_keys: Running ssh-add -D..."
            # Add || true to prevent set -e exit on failure, then check status
            ssh-add -D || true
            local del_status=${PIPESTATUS[0]:-$?} # Get status of ssh-add, not true
            log_debug "delete_all_keys: ssh-add -D exited with status: $del_status"

            if [ "$del_status" -eq 0 ]; then
                printf "All keys successfully deleted.\n"
                if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: All keys successfully deleted."; fi
                log_info "delete_all_keys: Successfully deleted all keys from ssh-agent"
                return_status=0 # Success
            else
                # Should not happen if initial checks were okay, but handle anyway
                printf "Error: Failed to delete all keys (status: %d).\n" "$del_status" >&2
                log_error "delete_all_keys: Failed to delete all keys using ssh-add -D (status: $del_status)"
                return_status=1 # Failure
            fi
            ;;
        *)
            printf "Operation cancelled.\n"
            if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Operation cancelled."; fi
            log_info "delete_all_keys: User cancelled operation."
            return_status=0 # Cancelled successfully
            ;;
    esac

    log_debug "Exiting function: ${FUNCNAME[0]} (status: $return_status)"
    return $return_status
} # END delete_all_keys


# --- CLI Action Functions ---

# Function: run_list_keys
# Purpose: Handles the --list CLI action. Ensures agent is running and calls list_current_keys.
# Inputs: None.
# Outputs: Exits with status code from list_current_keys.
run_list_keys() {
    log_info "CLI Action: Listing keys..."
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "run_list_keys: Validating SSH dir..."
    if ! validate_ssh_dir; then exit 1; fi
    log_debug "run_list_keys: Ensuring agent..."
    if ! ensure_ssh_agent; then exit 1; fi

    log_debug "run_list_keys: Calling list_current_keys..."
    list_current_keys
    local exit_status=$?
    log_info "CLI Action: Listing keys finished with status $exit_status."
    log_debug "Exiting function: ${FUNCNAME[0]} (status: $exit_status)"
    exit $exit_status
} # END run_list_keys

# Function: run_load_keys
# Purpose: Handles the --add CLI action. Updates key list file (using weak find),
#          deletes existing keys, then adds keys listed in VALID_KEY_LIST_FILE.
#          NOTE: Potential mismatch between update_keys_list_file and add_keys_to_agent sources.
# Inputs: None.
# Outputs: Exits with status 0 on success, 1 on failure.
run_load_keys() {
    log_info "CLI Action: Loading keys..."
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "run_load_keys: Validating SSH dir..."
    if ! validate_ssh_dir; then exit 1; fi
    log_debug "run_load_keys: Ensuring agent..."
    if ! ensure_ssh_agent; then exit 1; fi

    log_debug "run_load_keys: Calling update_keys_list_file..."
    if ! update_keys_list_file; then
        log_error "run_load_keys: update_keys_list_file failed."
        exit 1
    fi

    log_debug "run_load_keys: Calling delete_keys_from_agent..."
    if ! delete_keys_from_agent; then
        log_warn "run_load_keys: delete_keys_from_agent failed (continuing anyway)."
        # Decide if this should be fatal? For now, continue to add attempt.
    fi

    log_debug "run_load_keys: Preparing target list file $VALID_KEY_LIST_FILE using update_keys_list_file..."
    if ! update_keys_list_file; then
        log_error "run_load_keys: update_keys_list_file failed."
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - update list failed)"
        exit 1
    fi

    log_debug "run_load_keys: Calling add_keys_to_agent..."
    if ! add_keys_to_agent; then
        log_error "run_load_keys: add_keys_to_agent failed."
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - add failed)"
        exit 1
    fi

    log_info "CLI Action: Loading keys finished successfully."
    log_debug "Exiting function: ${FUNCNAME[0]} (status: 0)"
    exit 0
} # END run_load_keys

# Function: run_delete_all_cli
# Purpose: Handles the --delete-all CLI action. Ensures agent is running and calls delete_all_keys.
# Inputs: None.
# Outputs: Exits with status code from delete_all_keys.
run_delete_all_cli() {
    log_info "CLI Action: Deleting all keys..."
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "run_delete_all_cli: Validating SSH dir..."
    if ! validate_ssh_dir; then exit 1; fi
    log_debug "run_delete_all_cli: Ensuring agent..."
    if ! ensure_ssh_agent; then exit 1; fi

    # Call the core delete function (which includes checks and confirmation)
    log_debug "run_delete_all_cli: Calling delete_all_keys..."
    delete_all_keys # This function handles user confirmation
    local exit_status=$?

    log_info "CLI Action: Delete all keys finished with status $exit_status."
    log_debug "Exiting function: ${FUNCNAME[0]} (status: $exit_status)"
    exit $exit_status
} # END run_delete_all_cli

# Function: run_load_keys_from_file
# Purpose: Handles the --file <file> CLI action. Validates input file, copies its contents
#          (key basenames) to VALID_KEY_LIST_FILE, ensures agent is running, and calls add_keys_to_agent.
# Inputs: $1=source_key_file.
# Outputs: Exits with status 0 on success, 1 on failure.
run_load_keys_from_file() {
    local source_key_file="$1"
    log_info "CLI Action: Loading keys from file: $source_key_file..."
    log_debug "Entering function: ${FUNCNAME[0]} (File: $source_key_file)"

    # Validate input file
    if [ ! -f "$source_key_file" ] || [ ! -r "$source_key_file" ]; then
        printf "Error: Key list file not found or not readable: %s\n" "$source_key_file" >&2
        log_error "run_load_keys_from_file: Key list file not found or not readable: $source_key_file"
        exit 1
    fi

    log_debug "run_load_keys_from_file: Validating target list file directory..."
    local target_list_dir
    target_list_dir=$(dirname "$VALID_KEY_LIST_FILE")
    if ! mkdir -p "$target_list_dir"; then
        printf "Error: Could not create directory for internal key list file: %s\n" "$target_list_dir" >&2
        log_error "run_load_keys_from_file: Could not create directory '$target_list_dir' for '$VALID_KEY_LIST_FILE'."
        exit 1
    fi

    log_debug "run_load_keys_from_file: Validating SSH dir ($SSH_DIR)..."
    if ! validate_ssh_dir; then exit 1; fi
    log_debug "run_load_keys_from_file: Ensuring agent..."
    if ! ensure_ssh_agent; then exit 1; fi

    # Prepare the VALID_KEY_LIST_FILE by copying from source
    log_debug "run_load_keys_from_file: Preparing target list file $VALID_KEY_LIST_FILE from source $source_key_file"
    if ! touch "$VALID_KEY_LIST_FILE" 2>/dev/null; then
         printf "Error: Cannot create or touch internal key list file '%s'. Check permissions in %s.\n" "$VALID_KEY_LIST_FILE" "$SSH_DIR" >&2
         log_error "run_load_keys_from_file: Cannot create/touch '$VALID_KEY_LIST_FILE'"
         exit 1
    fi
    chmod 600 "$VALID_KEY_LIST_FILE" 2>/dev/null || log_warn "run_load_keys_from_file: Could not set permissions on $VALID_KEY_LIST_FILE"

    # Clear the list file first
    log_debug "run_load_keys_from_file: Clearing target list file: $VALID_KEY_LIST_FILE"
    if command -v truncate > /dev/null; then
        truncate -s 0 "$VALID_KEY_LIST_FILE"
    else
        echo -n > "$VALID_KEY_LIST_FILE"
    fi
    if [ $? -ne 0 ]; then
         printf "Error: Failed to clear internal key list file '%s'.\n" "$VALID_KEY_LIST_FILE" >&2
         log_error "run_load_keys_from_file: Failed to clear '$VALID_KEY_LIST_FILE'."
         exit 1
    fi

    # Copy lines, skipping empty lines and comments
    log_debug "run_load_keys_from_file: Copying key names from '$source_key_file' to '$VALID_KEY_LIST_FILE'"
    grep -vE '^\s*(#|$)' "$source_key_file" >> "$VALID_KEY_LIST_FILE"
    local copy_status=$?
    if [ $copy_status -ne 0 ] && [ $copy_status -ne 1 ]; then # grep returns 1 if no lines selected
         printf "Error: Failed to read from source key file '%s' (grep status: %d).\n" "$source_key_file" "$copy_status" >&2
         log_error "run_load_keys_from_file: Failed to read from source key file '$source_key_file' (grep status: $copy_status)."
         exit 1
    fi

    # Optional: Delete existing keys before adding? Mimic --add behaviour?
    # For now, just add without deleting like the sourced version.
    # log_debug "run_load_keys_from_file: Calling delete_keys_from_agent..."
    # delete_keys_from_agent

    # Call the core add function
    log_info "run_load_keys_from_file: Calling add_keys_to_agent (using $VALID_KEY_LIST_FILE populated from $source_key_file)..."
    if ! add_keys_to_agent; then
        log_error "run_load_keys_from_file: add_keys_to_agent failed."
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - add failed)"
        exit 1 # Exit with error if adding failed
    fi

    log_info "CLI Action: Loading keys from file finished successfully."
    log_debug "Exiting function: ${FUNCNAME[0]} (status: 0)"
    exit 0
} # END run_load_keys_from_file


# --- Help Function ---

# Function: display_help
# Purpose: Displays the help message describing CLI usage.
# Inputs: None.
# Outputs: Prints help text to stdout.
display_help() {
    log_debug "printf: Displaying help message..." # Summary log
    cat << EOF
SSH Key Manager - $(basename "$0")

Manages SSH keys in ssh-agent.

Usage: $(basename "$0") [OPTIONS]

Options:
  -l, --list      List keys currently loaded in the ssh-agent.
  -a, --add       Add all keys found in the SSH directory ($SSH_DIR) to the agent
                  (uses simple find logic, deletes existing keys first).
                  NOTE: This may differ from keys loaded by ssh_agent_setup.sh.
  -f <file>, --file <file>
                  Add keys listed in the specified <file> (one key name per line,
                  '#' comments and blank lines ignored). Uses the agent's key list cache.
  -D, --delete-all Delete all keys currently loaded in the ssh-agent (prompts for confirmation).
  -m, --menu      Show the interactive menu interface (default if no other action specified).
  -v, --verbose   Enable verbose (DEBUG level) logging to the log file.
  -h, --help      Display this help message and exit.

Default Behavior:
  If run without any options, the interactive menu is displayed.

Examples:
  $(basename "$0") --list        # List loaded keys
  $(basename "$0") --add         # Reload keys based on simple find in $SSH_DIR
  $(basename "$0") --file my_keys.txt # Load keys listed in my_keys.txt
  $(basename "$0") --delete-all  # Delete all loaded keys
  $(basename "$0")               # Start the interactive menu
  $(basename "$0") --menu        # Start the interactive menu

Log File Location: $LOG_FILE (or /dev/null if setup failed)

EOF
} # END display_help


# --- Main Interactive Menu Function ---

# Function: run_interactive_menu
# Purpose: Runs the main interactive menu loop for the script.
# Inputs: Reads user input. Calls various core functions based on selection.
# Outputs: Prints menu and results to stdout. Exits script when user quits.
run_interactive_menu() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Starting SSH Key Manager in Interactive Mode..."
    log_info "Platform: $PLATFORM | User: $USER | Host: $(hostname)"
    log_info "Log file: $LOG_FILE"
    log_info "SSH directory: $SSH_DIR"

    # Validate SSH directory
    log_debug "run_interactive_menu: Validating SSH directory: $SSH_DIR"
    if ! validate_ssh_dir; then
        printf "Error: SSH directory validation failed. Please check permissions and try again.\n" >&2
        log_error "run_interactive_menu: SSH directory validation failed. Exiting."
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - ssh dir validation failed)"
        exit 1
    fi
    log_debug "run_interactive_menu: SSH directory validation successful."

    # Check if required commands are available
    log_debug "run_interactive_menu: Checking for required commands: ssh-add, ssh-agent"
    if ! command -v ssh-add > /dev/null || ! command -v ssh-agent > /dev/null ; then
        printf "Error: 'ssh-add' or 'ssh-agent' command not found. Please ensure SSH tools are installed.\n" >&2
        log_error "run_interactive_menu: 'ssh-add' or 'ssh-agent' command not found. Exiting."
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - command check failed)"
        exit 1
    fi
    log_debug "run_interactive_menu: Required commands found."

    log_debug "run_interactive_menu: Calling ensure_ssh_agent..."
    if ! ensure_ssh_agent; then # Check only for success (0) or failure (1)
        log_error "run_interactive_menu: ensure_ssh_agent failed during startup. Exiting."
        # ensure_ssh_agent already prints detailed errors
        log_debug "Exiting function: ${FUNCNAME[0]} (status: 1 - ensure agent failed)"
        exit 1
    fi
    # If ensure_ssh_agent returned 0, we are guaranteed to have the vars exported
    log_info "run_interactive_menu: Agent setup complete. SOCK='${SSH_AUTH_SOCK:-}', PID='${SSH_AGENT_PID:-}'"
    log_debug "run_interactive_menu: Proceeding to main menu loop..."

    # Main menu loop
    while true; do
        display_main_menu
        choice=$(get_menu_choice)
        log_info "User selected menu option: [$choice]"

        case "$choice" in
            1)
                log_debug "Main loop - Case 1: Calling check_and_set_ssh_dir (Not Implemented Yet)"
                # check_and_set_ssh_dir # TODO: Implement this
                printf "Set SSH Directory functionality not yet implemented.\n"
                if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Set SSH Directory functionality not yet implemented."; fi
                log_warn "Option 1 (Set SSH Directory) selected but not implemented."
                log_debug "Main loop - Case 1: Calling wait_for_key..."
                wait_for_key
                ;;
            2)
                log_debug "Main loop - Case 2: Calling list_current_keys..."
                list_current_keys
                local list_rc=$?
                log_debug "Main loop - Case 2: list_current_keys returned: $list_rc"
                log_debug "Main loop - Case 2: Calling wait_for_key..."
                wait_for_key
                local wait_rc=$?
                log_debug "Main loop - Case 2: wait_for_key returned: $wait_rc"
                ;; # Reached end of case 2 block.
            3)
                log_debug "Main loop - Case 3: Reloading all keys..."
                printf "Reloading all keys...\n"
                if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Reloading all keys..."; fi
                log_info "Main loop - Case 3: Reloading all keys selected."
                log_debug "Main loop - Case 3: Calling update_keys_list_file..."
                if ! update_keys_list_file; then
                    log_error "Main loop - Case 3: update_keys_list_file failed (returned non-zero)."
                    printf "Error: Failed to find keys to reload.\n" >&2 # Error already logged by function
                else
                    log_debug "Main loop - Case 3: update_keys_list_file succeeded."
                    # Only proceed if keys were found
                    log_info "Main loop - Case 3: Deleting existing keys before adding..."
                    log_debug "Main loop - Case 3: Calling delete_keys_from_agent..."
                    delete_keys_from_agent
                    local delete_rc=$?
                    log_debug "Main loop - Case 3: delete_keys_from_agent returned $delete_rc"

                    log_info "Main loop - Case 3: Adding keys listed in $VALID_KEY_LIST_FILE..."
                    log_debug "Main loop - Case 3: Calling add_keys_to_agent..."
                    if ! add_keys_to_agent; then
                        log_error "Main loop - Case 3: add_keys_to_agent failed (returned non-zero)."
                        printf "Error: Failed during key addition process.\n" >&2 # Error already logged by function
                        # Continue to wait_for_key even if add failed
                    else
                        log_debug "Main loop - Case 3: add_keys_to_agent succeeded."
                    fi
                fi
                log_debug "Main loop - Case 3: Calling wait_for_key..."
                wait_for_key
                ;;
            4)
                log_debug "Main loop - Case 4: Calling display_log_location..."
                display_log_location
                log_debug "Main loop - Case 4: Calling wait_for_key..."
                wait_for_key
                ;;
            5)
                log_debug "Main loop - Case 5: Calling delete_single_key..."
                delete_single_key
                log_debug "Main loop - Case 5: Calling wait_for_key..."
                wait_for_key
                ;;
            6)
                log_debug "Main loop - Case 6: Calling delete_all_keys..."
                delete_all_keys
                log_debug "Main loop - Case 6: Calling wait_for_key..."
                wait_for_key
                ;;
            q|Q)
                log_info "User selected Quit option."
                log_debug "Main loop - Case q: Exiting script."
                log_info "Script terminated by user via menu."
                printf "\nThank you for using SSH Key Manager. Goodbye!\n"
                if [ "$IS_VERBOSE" = "true" ]; then log_debug "printf: Thank you for using SSH Key Manager. Goodbye!"; fi
                log_info "************* ENDING SCRIPT (Interactive Mode - Quit) *************"
                exit 0
                ;;
            *)
                # This case should not be reachable due to get_menu_choice validation
                log_error "Main loop - Reached unexpected default case for choice: $choice"
                printf "Error: Unexpected menu choice processed!\n" >&2
                sleep 2
                ;;
        esac
        log_debug "Main loop - End of loop iteration for choice: $choice"
    done
    log "************* ENDING SCRIPT (Interactive Mode) *************"
} # END run_interactive_menu


# --- Finalization Function ---

# Function: log_execution_time
# Purpose: Calculates and logs the total script execution time.
# Inputs: Uses global script_start_time.
# Outputs: Appends execution time message to log file.
log_execution_time() {
    local end_time script_duration
    # Check if LOG_FILE is set and not /dev/null before trying to log
    if [ -v LOG_FILE ] && [ -n "$LOG_FILE" ] && [ "$LOG_FILE" != "/dev/null" ]; then
        if [[ -n "$_script_start_time" ]]; then
            end_time=$(date +%s.%N)
            # Use bc for floating point calculation if available
            if command -v bc > /dev/null; then
                script_duration=$(echo "$end_time - $_script_start_time" | bc -l)
                printf -v script_duration "%.3f" "$script_duration"
            else
                # Fallback to integer seconds if bc is not available
                local start_seconds end_seconds
                # Need to handle potential differences in date command syntax for %s.%N parsing
                # A simpler integer subtraction might be more portable here
                start_seconds=$(echo "$_script_start_time" | cut -d. -f1)
                end_seconds=$(echo "$end_time" | cut -d. -f1)
                script_duration=$((end_seconds - start_seconds))
                log_warn "'bc' command not found, reporting execution time in integer seconds."
            fi
            log_info "Total script execution time: ${script_duration} seconds."
        fi
    fi
} # END log_execution_time


# --- EXIT Trap for Finalization ---

# Trap EXIT signal to ensure execution time is logged on exit
# This runs regardless of how the script exits (normal, error, signal)
trap 'log_execution_time' EXIT


# --- Argument Parsing and Dispatch ---

# Logging setup is now done earlier, so we don't need the initial call here.
# We can log the start of argument parsing if verbose.
log_debug "Starting argument parsing..."

# Default action is menu if no args or only -v is passed
ACTION="menu"
source_key_file="" # Variable to hold filename for -f/--file

# Check if any arguments were passed besides potentially -v
args_remain=0
temp_args=("$@") # Copy arguments to check

# Pre-scan for verbose flag and remove it
# Note: IS_VERBOSE is already set by the time logging functions are defined
# This scan is now primarily to adjust the default ACTION check
if [[ " ${temp_args[@]} " =~ " -v " ]] || [[ " ${temp_args[@]} " =~ " --verbose " ]]; then
   # IS_VERBOSE="true" # Already set earlier if needed
   log_debug "Verbose logging was enabled by CLI flag."
   # Remove -v/--verbose for the action check (crude removal)
   new_temp_args=()
   for arg in "${temp_args[@]}"; do
       [[ "$arg" != "-v" && "$arg" != "--verbose" ]] && new_temp_args+=("$arg")
   done
   temp_args=("${new_temp_args[@]}")
fi

# If arguments remain after removing verbose flag, default action is potentially overridden
if [ ${#temp_args[@]} -gt 0 ]; then
    ACTION="help" # Assume help/error unless a valid action flag is found
    log_debug "Arguments found besides verbose flag, setting default action to 'help' initially."
else
    log_debug "No arguments found besides verbose flag, default action remains 'menu'."
fi


# Argument parsing loop
while [[ $# -gt 0 ]]; do
    log_debug "Parsing argument: $1"
    case $1 in
        -l|--list)
            ACTION="list"
            log_debug "Action set to: list"
            shift # past argument
            ;;
        -a|--add)
            ACTION="add"
            log_debug "Action set to: add"
            shift # past argument
            ;;
        -f|--file)
            # Check if filename argument exists and is not another option flag
            if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                 # Use log_error now that logging is set up
                 log_error "Option '$1' requires a filename argument."
                 # printf "Error: Option '%s' requires a filename argument.\\n\\n" "$1" >&2 # Covered by log_error
                 ACTION="help" # Set to help on error
                 log_debug "Action set to: help (due to missing file argument)"
                 # To prevent further processing, we break the loop
                 # but need to consume the broken argument first if we want help
                 # It's simpler to just exit here after showing help
                 display_help
                 exit 1
            fi
            ACTION="file"
            source_key_file="$2"
            log_debug "Action set to: file (Source: $source_key_file)"
            shift # past argument (-f or --file)
            shift # past value (filename)
            ;;
        -D|--delete-all)
            ACTION="delete-all"
            log_debug "Action set to: delete-all"
            shift # past argument
            ;;
        -m|--menu)
            ACTION="menu"
            log_debug "Action set to: menu"
            shift # past argument
            ;;
        -v|--verbose)
            # Already handled in pre-scan, just consume the arg
            log_debug "Consuming verbose flag (already processed)."
            shift # past argument
            ;;
        -h|--help)
            ACTION="help"
            log_debug "Action set to: help"
            shift # past argument
            ;;
        *)
            # Unknown option
            log_error "Unknown option '$1'"
            # printf "Error: Unknown option '%s'\\n\\n" "$1" >&2 # Covered by log_error
            ACTION="help" # Show help on error
            log_debug "Action set to: help (due to unknown option '$1')"
            # Since we encountered an error, stop parsing and show help
            display_help
            exit 1
            ;;
    esac
done

# Execute the determined action
log_debug "Dispatching action: $ACTION"
case $ACTION in
    list)
        log_info "Dispatching: List keys"
        run_list_keys
        ;;
    add)
        log_info "Dispatching: Add/Reload all keys"
        run_load_keys
        ;;
    file)
        log_info "Dispatching: Load keys from file: $source_key_file"
        run_load_keys_from_file "$source_key_file"
        ;;
    delete-all)
        log_info "Dispatching: Delete all keys"
        run_delete_all_cli
        ;;
    menu)
        log_info "Dispatching: Interactive Menu"
        run_interactive_menu
        ;;
    help|*)
        log_info "Dispatching: Display Help"
        display_help
        exit 0 # Exit successfully after showing help
        ;;
esac

# Should not be reached if dispatch logic is correct
log_error "Script reached end without dispatching an action or exiting."
exit 1
