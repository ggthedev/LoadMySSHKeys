#!/usr/bin/env bash
#
# SSH Agent Setup Script (for sourcing in .zshrc/.zshenv)
# ------------------------------------------------------
# Ensures a single ssh-agent is running per session and exports
# the necessary environment variables (SSH_AUTH_SOCK, SSH_AGENT_PID).
# Reuses existing agents via ~/.ssh/agent.env if possible.
# Loads keys into the agent, either by scanning the SSH directory or
# from an optional filename argument provided during sourcing.
#
# Designed to be sourced:
#   `source /path/to/ssh_agent_setup.sh`
#   `source /path/to/ssh_agent_setup.sh [filename]`
#   `source /path/to/ssh_agent_setup.sh -v [filename]`
#
# Behavior:
# - Silent by default.
# - Checks if SSH_AUTH_SOCK/SSH_AGENT_PID are already set and valid; if so, exits.
# - Tries to source ~/.ssh/agent.env and validate that agent.
# - If no valid agent found, starts a new one and saves details to ~/.ssh/agent.env.
# - If sourced *without* a filename argument, scans $SSH_DIR for private keys
#   (identified by matching .pub files) and attempts to load them.
# - If sourced *with* a readable filename as an argument, attempts to load
#   the key names listed in that file (one per line, # comments ignored).
# - The `-v` or `--verbose` flag can be passed as the first argument to enable
#   DEBUG level logging (e.g., `source ... -v my_keys.txt`).
# - Uses `return` instead of `exit`.
#
# Key Loading Notes:
# - On macOS, uses --apple-use-keychain to avoid passphrase prompts if possible.
# - Keys requiring passphrases not in Keychain will likely fail to load silently.
#
# Logging:
# - Logging is OFF by default, except if `-v` or `--verbose` is passed.
# - Log file location is determined automatically (OS-specific) or by the
#   `SSH_AGENT_SETUP_LOG` environment variable (if set).
#   Example: `export SSH_AGENT_SETUP_LOG=~/.ssh/agent_setup.log`

# Capture start time for execution duration logging
_sa_script_start_time=$(date +%s.%N) # Use %s.%N for nanoseconds if supported

# Treat unset variables as errors
#set -u

# --- Configuration ---
declare SSH_DIR="$HOME/.ssh"
declare AGENT_ENV_FILE="$HOME/.config/sshkeysloader/agent.env"
# Persistent file within SSH_DIR to cache the list of valid key filenames
declare VALID_KEY_LIST_FILE="$HOME/.config/sshkeysloader/.ssh_keys"

# --- Log File Configuration ---
declare LOG_FILENAME="sshkeysloader.log"
declare LOG_DIR_MACOS="$HOME/Library/Logs/sshkeysloader"
declare LOG_DIR_LINUX_VAR="/var/log/sshkeysloader"
declare LOG_DIR_LINUX_LOCAL="$HOME/.local/log/sshkeysloader"
declare LOG_DIR_FALLBACK="$HOME/.ssh/logs"

# Flag to control verbose/debug logging (will be set by argument parsing)
declare _sa_IS_VERBOSE="false"

# --- Logging Setup ---
declare LOG_FILE="" # Initialize empty; will be set if logging is configured successfully

_setup_default_logging() {
    set -u # Enable strict mode for this function

    local target_log_path
    local log_dir
    local platform

    platform=$(uname -s)

    # Determine platform-specific default log directory
    case "$platform" in
        "Darwin")
            log_dir="$LOG_DIR_MACOS"
            ;;
        "Linux")
            # Prefer /var/log if writable, else use ~/.local
            if [ -w "$(dirname "$LOG_DIR_LINUX_VAR")" ]; then # Check writability of parent
                 log_dir="$LOG_DIR_LINUX_VAR"
            else
                log_dir="$LOG_DIR_LINUX_LOCAL"
            fi
            ;;
        *)
            # Fallback for other systems
            log_dir="$LOG_DIR_FALLBACK"
            ;;
    esac

    target_log_path="$log_dir/$LOG_FILENAME"

    # Attempt to create directory and file
    if ! mkdir -p "$log_dir" 2>/dev/null; then
        # Cannot create directory, logging remains disabled
        LOG_FILE=""
        set +u # Disable strict mode before returning
        return 1
    fi
    if ! touch "$target_log_path" 2>/dev/null; then
        # Cannot create file, logging remains disabled
        LOG_FILE=""
        set +u # Disable strict mode before returning
        return 1
    fi

    # Set log file path and permissions if successful
    LOG_FILE="$target_log_path"
    chmod 600 "$LOG_FILE" 2>/dev/null || true # Best effort on chmod
    set +u # Disable strict mode before returning
    return 0
}

# Check if logging is explicitly enabled via environment variable
if [ -n "${SSH_AGENT_SETUP_LOG:-}" ]; then
    log_dir=$(dirname "$SSH_AGENT_SETUP_LOG")
    target_log_path="$SSH_AGENT_SETUP_LOG" # Use the full path provided

    if mkdir -p "$log_dir" 2>/dev/null && touch "$target_log_path" 2>/dev/null; then
        LOG_FILE="$target_log_path"
        chmod 600 "$LOG_FILE" 2>/dev/null || true
    else
        # Explicit path given but failed to create/touch. Logging disabled.
        LOG_FILE=""
        # Optionally print a warning to stderr if this script were interactive
        : # No output for sourced script
    fi
else
    # Environment variable not set, try setting up default logging
    if ! _setup_default_logging; then
         # Default setup failed, LOG_FILE will be empty
         : # No output for sourced script
    fi
fi

# --- Logging Functions (Conditional) ---
_log_base() {
    # Only log if LOG_FILE is set (not empty)
    [ -z "$LOG_FILE" ] && return 0 # Exit if LOG_FILE wasn't successfully configured
    local type="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Use printf for safer handling of potentially weird characters in msg
    printf "%s - %s - %s - %s\n" "$timestamp" "$$" "$type" "$msg" >> "$LOG_FILE"
}
log_info() { _log_base "INFO" "$1"; }
log_error() { _log_base "ERROR" "$1"; }
log_warn() { _log_base "WARN" "$1"; }
log_debug() {
    # Only log if verbose mode is enabled
    [ "$_sa_IS_VERBOSE" = "true" ] || return 0
    _log_base "DEBUG" "$1";
}

# --- Helper Functions ---

# Cleanup function for trap
_sa_cleanup() {
  # Use parameter expansion default to handle potentially unset variable with set -u
  if [ -n "${VALID_KEY_LIST_FILE:-}" ] && [ -f "${VALID_KEY_LIST_FILE:-}" ]; then
    # Decide if we should remove the persistent list file on exit?
    # For now, let's keep it as it caches the valid keys found.
    # log_debug "_sa_cleanup: Removing key list file $VALID_KEY_LIST_FILE"
    : # No cleanup needed for the persistent file
  fi
}

# --- Finalization Function ---

_sa_log_execution_time() {
    log_debug "_sa_log_execution_time: Trap triggered."
    local _sa_end_time _sa_script_duration
    # Check if start time variable exists (it should if script reached this point)
    if [ -n "${_sa_script_start_time:-}" ]; then
        log_debug "_sa_log_execution_time: Start time found: ${_sa_script_start_time}"
        _sa_end_time=$(date +%s.%N)
        log_debug "_sa_log_execution_time: End time captured: ${_sa_end_time}"

        # Use bc for floating point calculation if available
        if command -v bc > /dev/null; then
            log_debug "_sa_log_execution_time: Found 'bc'. Attempting calculation: ${_sa_end_time} - ${_sa_script_start_time}"
            _sa_script_duration=$(echo "$_sa_end_time - $_sa_script_start_time" | bc -l)
            local bc_status=$?
            log_debug "_sa_log_execution_time: bc status: $bc_status, Result: '$_sa_script_duration'"
            if [ $bc_status -ne 0 ]; then
                log_error "_sa_log_execution_time: bc calculation failed."
            else
                # Format using printf
                local _sa_formatted_duration
                _sa_formatted_duration=$(printf "%.3f" "$_sa_script_duration")
                log_info "Total setup script execution time: ${_sa_formatted_duration} seconds."
            fi
        else
            log_warn "'bc' command not found, attempting fallback to integer seconds."
            # Fallback to integer seconds using parameter expansion (more portable)
            local _sa_start_seconds _sa_end_seconds
             _sa_start_seconds=${_sa_script_start_time%%.*}
             _sa_end_seconds=${_sa_end_time%%.*}
             log_debug "_sa_log_execution_time: Fallback seconds: Start=$_sa_start_seconds, End=$_sa_end_seconds"
             if [[ -n "$_sa_start_seconds" && -n "$_sa_end_seconds" ]]; then
                 _sa_script_duration=$((_sa_end_seconds - _sa_start_seconds))
                 log_info "Total setup script execution time: ${_sa_script_duration} seconds."
             else
                 log_error "_sa_log_execution_time: Failed to parse integer seconds for fallback calculation."
             fi
        fi
    else
        log_warn "_sa_log_execution_time: Could not calculate execution time: start time variable (_sa_script_start_time) not found."
    fi
    log_debug "_sa_log_execution_time: Function finished."
}

# --- Core Agent Functions (Adapted from loadSSHKEYS.sh) ---

# Function: _sa_check_ssh_agent (Internal version)
# Description: Checks if SSH_AUTH_SOCK/SSH_AGENT_PID point to a live agent.
# Input: Uses exported SSH_AUTH_SOCK, SSH_AGENT_PID
# Output: 0 if agent is accessible, 1 otherwise.
_sa_check_ssh_agent() {
    set -u # Enable strict mode for this function

    log_debug "_sa_check_ssh_agent: Checking agent status... (PID='${SSH_AGENT_PID:-}', SOCK='${SSH_AUTH_SOCK:-}')"
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ -z "${SSH_AGENT_PID:-}" ]; then
        log_debug "_sa_check_ssh_agent: Required environment variables not set."
        set +u # Disable strict mode before returning
        return 1
    fi
    # Check if the socket file exists
    if [ ! -S "$SSH_AUTH_SOCK" ]; then
        log_error "_sa_check_ssh_agent: SSH_AUTH_SOCK is not a socket: $SSH_AUTH_SOCK"
        set +u # Disable strict mode before returning
        return 1
    fi
    # Check if the agent process is running
    if ! ps -p "$SSH_AGENT_PID" > /dev/null 2>&1; then
        log_error "_sa_check_ssh_agent: SSH_AGENT_PID ($SSH_AGENT_PID) process not running."
        set +u # Disable strict mode before returning
        return 1
    fi
    # Check communication with the agent
    # Use ssh-add -l, allow status 1 (no keys) as successful communication
    ssh-add -l > /dev/null 2>&1 || true
    local check_status=${PIPESTATUS[0]:-$?}
    log_debug "_sa_check_ssh_agent: ssh-add -l communication status: $check_status"
    if [ "$check_status" -eq 0 ] || [ "$check_status" -eq 1 ]; then
        log_debug "_sa_check_ssh_agent: Agent communication successful (status $check_status)."
        set +u # Disable strict mode before returning
        return 0 # Success
    fi
    log_error "_sa_check_ssh_agent: Cannot communicate with agent (ssh-add -l status $check_status)."
    set +u # Disable strict mode before returning
    return 1 # Failure
}

# Function: _sa_ensure_ssh_agent (Internal version)
# Description: Ensures agent is running and variables exported. Silent.
# Input: None
# Output: Exports SSH_AUTH_SOCK, SSH_AGENT_PID. Returns 0 on success, 1 on failure.
_sa_ensure_ssh_agent() {
    set -u # Enable strict mode for this function

    log_debug "_sa_ensure_ssh_agent: Entering function."

    # 1. Check if already configured and working in this environment
    log_debug "_sa_ensure_ssh_agent: Checking current environment..."
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -n "${SSH_AGENT_PID:-}" ] && _sa_check_ssh_agent; then
        log_info "_sa_ensure_ssh_agent: Agent already running and sourced (PID: $SSH_AGENT_PID)."
        # Ensure they are exported, just in case they weren't initially
        export SSH_AUTH_SOCK SSH_AGENT_PID
        set +u # Disable strict mode before returning
        return 0
    fi
    log_debug "_sa_ensure_ssh_agent: Agent not valid in current environment."

    # 2. Try sourcing persistent environment file
    if [ -f "$AGENT_ENV_FILE" ]; then
        log_debug "_sa_ensure_ssh_agent: Found persistent file: $AGENT_ENV_FILE. Sourcing..."
        # Unset potentially stale vars before sourcing
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        # Source the file into the current shell's environment
        # shellcheck disable=SC1090 # File path is from variable
        . "$AGENT_ENV_FILE" >/dev/null
        log_debug "_sa_ensure_ssh_agent: Sourced persistent file. Checking agent status again..."
        if _sa_check_ssh_agent; then
            log_info "_sa_ensure_ssh_agent: Sourcing persistent file successful. Reusing agent (PID: $SSH_AGENT_PID)."
            # Ensure they are exported
            export SSH_AUTH_SOCK SSH_AGENT_PID
            set +u # Disable strict mode before returning
            return 0
        else
            log_warn "_sa_ensure_ssh_agent: Persistent file found but agent invalid/inaccessible after sourcing. Removing stale file."
            rm -f "$AGENT_ENV_FILE" # Remove stale file
            # Unset potentially incorrect variables sourced from the stale file
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    else
        log_debug "_sa_ensure_ssh_agent: No persistent agent file found ($AGENT_ENV_FILE)."
    fi

    # 3. Start a new agent
    log_info "_sa_ensure_ssh_agent: Starting new ssh-agent..."

    # Ensure .ssh directory exists
    if ! mkdir -p "$SSH_DIR" 2>/dev/null; then
        log_error "_sa_ensure_ssh_agent: Failed to create SSH directory $SSH_DIR"
        set +u # Disable strict mode before returning
        return 1
    fi
    if ! chmod 700 "$SSH_DIR" 2>/dev/null; then log_warn "_sa_ensure_ssh_agent: Failed to set permissions on $SSH_DIR"; fi

    # Start ssh-agent and capture output
    local agent_output
    if ! agent_output=$(ssh-agent -s); then
        log_error "_sa_ensure_ssh_agent: Failed to execute ssh-agent -s"
        set +u # Disable strict mode before returning
        return 1
    fi
    log_debug "_sa_ensure_ssh_agent: ssh-agent -s output captured."

    # Extract environment variables (handle potential variations in output)
    local new_sock new_pid
    new_sock=$(echo "$agent_output" | sed -n 's/SSH_AUTH_SOCK=\([^;]*\);.*/\1/p')
    new_pid=$(echo "$agent_output" | sed -n 's/SSH_AGENT_PID=\([^;]*\);.*/\1/p')

    if [ -z "$new_sock" ] || [ -z "$new_pid" ]; then
        log_error "_sa_ensure_ssh_agent: Failed to extract env vars from output: $agent_output"
        set +u # Disable strict mode before returning
        return 1
    fi
    log_debug "_sa_ensure_ssh_agent: Extracted SOCK=$new_sock PID=$new_pid"

    # Export variables into the current shell's environment
    export SSH_AUTH_SOCK="$new_sock"
    export SSH_AGENT_PID="$new_pid"
    log_debug "_sa_ensure_ssh_agent: Exported new agent variables into current scope."

    # Save agent environment variables to persistent file
    log_debug "_sa_ensure_ssh_agent: Saving agent environment to $AGENT_ENV_FILE"
    {
        # Use printf for reliability
        printf 'SSH_AUTH_SOCK=%s; export SSH_AUTH_SOCK;\n' "$new_sock"
        printf 'SSH_AGENT_PID=%s; export SSH_AGENT_PID;\n' "$new_pid"
        printf '# Agent started on %s by %s\n' "$(date)" "$(basename "$0")"
    } > "$AGENT_ENV_FILE"
    if ! chmod 600 "$AGENT_ENV_FILE"; then log_warn "_sa_ensure_ssh_agent: Failed to set permissions on $AGENT_ENV_FILE"; fi
    log_debug "_sa_ensure_ssh_agent: Agent environment saved."

    # Final verification (using the exported variables in current scope)
    log_debug "_sa_ensure_ssh_agent: Performing final verification of new agent..."
    if _sa_check_ssh_agent; then
        log_info "_sa_ensure_ssh_agent: New agent started and verified successfully (PID: $SSH_AGENT_PID)."
        set +u # Disable strict mode before returning
        return 0 # Success!
    else
        log_error "_sa_ensure_ssh_agent: Started new agent but failed final verification."
        # Clean up potentially bad environment state
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        rm -f "$AGENT_ENV_FILE" # Remove possibly bad file
        set +u # Disable strict mode before returning
        return 1 # Failure!
    fi
}

# Function: _sa_update_keys_list_file (Internal version)
# Description: Finds private keys by checking for corresponding .pub files and saves to VALID_KEY_LIST_FILE.
# Input: Uses SSH_DIR, VALID_KEY_LIST_FILE
# Output: Populates VALID_KEY_LIST_FILE. Returns 0 if valid keys found, 1 otherwise.
_sa_update_keys_list_file() {
    log_debug "_sa_update_keys_list_file: Entering function (pair matching logic)."
    log_info "_sa_update_keys_list_file: Finding private key files in $SSH_DIR by checking for corresponding .pub files..."

    # Ensure the directory for the key list file exists
    local key_list_dir
    key_list_dir=$(dirname "$VALID_KEY_LIST_FILE")
    if [ ! -d "$key_list_dir" ]; then
        log_debug "_sa_update_keys_list_file: Creating directory for key list file: $key_list_dir"
        if ! mkdir -p "$key_list_dir"; then
            log_error "_sa_update_keys_list_file: Failed to create directory '$key_list_dir'. Cannot proceed."
            return 1
        fi
        # Optionally set permissions, although mkdir -p usually does the right thing
        chmod 700 "$key_list_dir" 2>/dev/null || log_warn "_sa_update_keys_list_file: Could not set permissions on $key_list_dir"
    fi

    # Ensure the target list file is usable (create if doesn't exist)
    if ! touch "$VALID_KEY_LIST_FILE" 2>/dev/null; then
         log_error "_sa_update_keys_list_file: Cannot create or touch key list file '$VALID_KEY_LIST_FILE'. Check permissions."
         return 1
    fi
    chmod 600 "$VALID_KEY_LIST_FILE" 2>/dev/null || log_warn "_sa_update_keys_list_file: Could not set permissions on $VALID_KEY_LIST_FILE"

    # Clear the key list file using truncate or echo -n
    log_debug "_sa_update_keys_list_file: Clearing key list file: $VALID_KEY_LIST_FILE"
    if command -v truncate > /dev/null; then
        log_debug "_sa_update_keys_list_file: Using 'truncate' command."
        truncate -s 0 "$VALID_KEY_LIST_FILE"
    else
        log_debug "_sa_update_keys_list_file: 'truncate' not found, using 'echo -n'."
        echo -n > "$VALID_KEY_LIST_FILE"
    fi
    local clear_status=$?
    if [ $clear_status -ne 0 ]; then
        log_error "_sa_update_keys_list_file: Failed to clear key list file '$VALID_KEY_LIST_FILE' (status: $clear_status)."
        return 1
    fi

    local filename # Basename of the potential private key
    local pub_filepath
    local valid_key_count=0

    # Find potential private keys (files not ending in .pub)
    # Use -exec basename {} \; for portability between Linux/macOS
    # Process substitution <(...) reads the output of the find command line by line
    log_debug "_sa_update_keys_list_file: Finding candidate files (excluding .pub)..."
    while IFS= read -r filename || [ -n "$filename" ]; do
        [ -z "$filename" ] && continue # Skip empty lines

        log_debug "_sa_update_keys_list_file: Checking candidate: $filename"
        pub_filepath="$SSH_DIR/${filename}.pub"

        # Check if the corresponding .pub file exists
        if [ -f "$pub_filepath" ]; then
            log_debug "_sa_update_keys_list_file:   Found matching pair: ${filename}.pub. Adding '$filename' to list."
            # Append filename to the list file
            echo "$filename" >> "$VALID_KEY_LIST_FILE"
            ((valid_key_count++))
        else
            log_debug "_sa_update_keys_list_file:   No matching .pub file found at '$pub_filepath'. Skipping."
        fi
    # Use find to get basenames of files not ending in .pub
    # Ensure find operates directly in SSH_DIR to avoid path issues with basename
    done < <(find "$SSH_DIR" -maxdepth 1 -type f ! -name '*.pub' -exec basename {} \;)

    log_debug "_sa_update_keys_list_file: Finished checking candidates."

    if [ "$valid_key_count" -eq 0 ]; then
        log_info "_sa_update_keys_list_file: No private keys with corresponding .pub files found in $SSH_DIR"
        return 1 # Indicate failure if no valid keys found
    else
        log_info "_sa_update_keys_list_file: Found $valid_key_count private key file(s) with matching .pub files in $SSH_DIR"
        return 0 # Success
    fi
}

# Function: _sa_add_keys_to_agent (Internal version)
# Description: Adds keys listed in VALID_KEY_LIST_FILE to the agent using a single ssh-add call. Silent.
# Input: Uses SSH_DIR, VALID_KEY_LIST_FILE
# Output: Returns 0 on success (even if some keys failed but agent call succeeded), 1 on major failure.
_sa_add_keys_to_agent() {
    set -u # Enable strict mode for this function

    log_debug "_sa_add_keys_to_agent: Entering function (single call version)."
    log_info "_sa_add_keys_to_agent: Preparing to add keys listed in $VALID_KEY_LIST_FILE..."
    local keyfile
    local key_path
    local key_paths_to_add=() # Array to hold full paths
    local platform
    platform=$(uname -s)

    # Check if VALID_KEY_LIST_FILE exists and is non-empty
    if [ ! -s "$VALID_KEY_LIST_FILE" ]; then
        log_warn "_sa_add_keys_to_agent: Key list file ($VALID_KEY_LIST_FILE) is empty or does not exist. No keys to add."
        set +u # Disable strict mode before returning
        return 1 # Nothing to add
    fi

    # Read filenames and construct full paths
    log_debug "_sa_add_keys_to_agent: Reading filenames from $VALID_KEY_LIST_FILE..."
    local line_count=0
    local invalid_path_count=0
    while IFS= read -r keyfile || [ -n "$keyfile" ]; do
        ((line_count++))
        [ -z "$keyfile" ] && continue # Skip empty lines
        key_path="$SSH_DIR/$keyfile"
        log_debug "_sa_add_keys_to_agent: Processing line $line_count: $keyfile -> $key_path"

        if [ -f "$key_path" ]; then
            key_paths_to_add+=("$key_path")
        else
            log_warn "_sa_add_keys_to_agent: Key file '$keyfile' listed but not found at '$key_path'. Skipping."
            ((invalid_path_count++))
        fi
    done < "$VALID_KEY_LIST_FILE"

    if [ ${#key_paths_to_add[@]} -eq 0 ]; then
        log_warn "_sa_add_keys_to_agent: No valid key file paths found to add after reading list."
        set +u # Disable strict mode before returning
        return 1 # Nothing valid to add
    fi

    log_info "_sa_add_keys_to_agent: Attempting to add ${#key_paths_to_add[@]} keys in a single call..."
    log_debug "_sa_add_keys_to_agent: Keys: ${key_paths_to_add[*]}"

    local ssh_add_cmd=("ssh-add")
    if [[ "$platform" == "Darwin" ]]; then
        ssh_add_cmd+=("--apple-use-keychain")
    fi
    ssh_add_cmd+=("${key_paths_to_add[@]}")

    # Execute the single ssh-add command silently, capture status
    log_debug "_sa_add_keys_to_agent: Executing: ${ssh_add_cmd[*]}"
    # Redirect stderr to stdout to potentially log errors if needed, allow failure
    local ssh_add_output
    ssh_add_output=$("${ssh_add_cmd[@]}" 2>&1 || true)
    local ssh_add_status=${PIPESTATUS[0]:-$?}
    log_debug "_sa_add_keys_to_agent: Single ssh-add call finished with status: $ssh_add_status"

    # Basic check: Status 0 is success, status 1 might mean some failed (e.g., passphrase), status 2 is agent connection error
    if [ $ssh_add_status -eq 0 ]; then
        log_info "_sa_add_keys_to_agent: ssh-add reported success (status 0). Assumed all specified keys added."
        log_debug "_sa_add_keys_to_agent: Exiting function (status: 0)."
        set +u # Disable strict mode before returning
        return 0
    elif [ $ssh_add_status -eq 1 ]; then
        # Status 1 implies some keys failed, often due to passphrases.
        # Log this as a warning but consider the setup potentially successful otherwise.
        log_warn "_sa_add_keys_to_agent: ssh-add reported partial failure (status 1). Some keys might require passphrase or be invalid."
        log_warn "ssh-add output (if any): $ssh_add_output"
        log_debug "_sa_add_keys_to_agent: Exiting function (status: 0 - partial success treated as OK for setup)."
        set +u # Disable strict mode before returning
        return 0 # Treat partial success as OK for setup purposes
    else # Status 2 or other errors
        log_error "_sa_add_keys_to_agent: ssh-add failed (status: $ssh_add_status). Could not add keys."
        log_error "ssh-add output (if any): $ssh_add_output"
        log_debug "_sa_add_keys_to_agent: Exiting function (status: 1 - failure)."
        set +u # Disable strict mode before returning
        return 1 # Major failure
    fi
}

# Function: _sa_write_valid_key_basenames_to_file (Internal version)
# Description: Finds private keys by checking for corresponding .pub files and writes their basenames (one per line) to the specified file.
# Input: Uses SSH_DIR
# Argument $1: target_file - The file to write the basenames into.
# Output: Writes to the target file. Returns 0 if keys found and written, 1 otherwise.
_sa_write_valid_key_basenames_to_file() {
    set -u # Enable strict mode for this function

    local target_file="$1"
    log_debug "_sa_write_valid_key_basenames_to_file: Entering function. Target file: '$target_file'"

    if [ -z "$target_file" ]; then
        log_error "_sa_write_valid_key_basenames_to_file: No target file specified."
        set +u # Disable strict mode before returning
        return 1
    fi

    log_info "_sa_write_valid_key_basenames_to_file: Finding private key files in $SSH_DIR and writing basenames to '$target_file'..."

    local filename # Basename of the potential private key
    local pub_filepath
    local key_full_path

    # Ensure the directory for the target file exists
    local target_dir
    target_dir=$(dirname "$target_file")
    if [ ! -d "$target_dir" ]; then
        log_debug "_sa_write_valid_key_basenames_to_file: Creating directory for target file: $target_dir"
        if ! mkdir -p "$target_dir"; then
            log_error "_sa_write_valid_key_basenames_to_file: Failed to create directory '$target_dir'. Cannot proceed."
            set +u # Disable strict mode before returning
            return 1
        fi
        chmod 700 "$target_dir" 2>/dev/null || log_warn "_sa_write_valid_key_basenames_to_file: Could not set permissions on $target_dir"
    fi

    # Find potential private keys (files not ending in .pub)
    # Process substitution <(...) reads the output of the find command line by line
    log_debug "_sa_write_valid_key_basenames_to_file: Finding candidate files (excluding .pub)..."
    local valid_key_basenames=() # Array to hold basenames
    while IFS= read -r filename || [ -n "$filename" ]; do
        [ -z "$filename" ] && continue # Skip empty lines

        log_debug "_sa_write_valid_key_basenames_to_file: Checking candidate: $filename"
        pub_filepath="$SSH_DIR/${filename}.pub"
        key_full_path="$SSH_DIR/$filename" # Still need this to check private key exists

        # Check if the corresponding .pub file exists and the private key file itself exists
        if [ -f "$pub_filepath" ]; then
            log_debug "_sa_write_valid_key_basenames_to_file:   Found matching pair: ${filename}.pub. Adding basename '$filename' to list."
            # Append basename to the array
            valid_key_basenames+=("$filename")
        else
            log_debug "_sa_write_valid_key_basenames_to_file:   No matching .pub file found at '$pub_filepath'. Skipping."
        fi
    # Use find to get basenames of files not ending in .pub
    # Ensure find operates directly in SSH_DIR to avoid path issues with basename
    done < <(find "$SSH_DIR" -maxdepth 1 -type f ! -name '*.pub' -exec basename {} \;)

    log_debug "_sa_write_valid_key_basenames_to_file: Finished checking candidates."

    if [ ${#valid_key_basenames[@]} -eq 0 ]; then
        log_info "_sa_write_valid_key_basenames_to_file: No private keys with corresponding .pub files found in $SSH_DIR. Clearing target file."
        # Clear the target file even if no keys are found
        if ! :> "$target_file"; then # Using :> for truncation, safer than > potentially
             log_error "_sa_write_valid_key_basenames_to_file: Failed to clear target file '$target_file'."
             set +u # Disable strict mode before returning
             return 1
        fi
        chmod 600 "$target_file" 2>/dev/null || log_warn "_sa_write_valid_key_basenames_to_file: Could not set permissions on $target_file"
        set +u # Disable strict mode before returning
        return 1 # Indicate failure if no valid keys found
    else
        log_info "_sa_write_valid_key_basenames_to_file: Found ${#valid_key_basenames[@]} private key file(s). Writing to '$target_file'..."

        # Clear the target file first
        if ! :> "$target_file"; then
             log_error "_sa_write_valid_key_basenames_to_file: Failed to clear target file '$target_file' before writing."
             set +u # Disable strict mode before returning
             return 1
        fi
        chmod 600 "$target_file" 2>/dev/null || log_warn "_sa_write_valid_key_basenames_to_file: Could not set permissions on $target_file"

        # Write the array elements one per line to the file
        local basename
        for basename in "${valid_key_basenames[@]}"; do
            echo "$basename" >> "$target_file"
            if [ $? -ne 0 ]; then
                log_error "_sa_write_valid_key_basenames_to_file: Failed to write basename '$basename' to '$target_file'."
                # Optionally decide whether to abort or continue
                set +u # Disable strict mode before returning
                return 1 # Abort on first write error
            fi
        done
        log_info "_sa_write_valid_key_basenames_to_file: Successfully wrote ${#valid_key_basenames[@]} basenames to '$target_file'."
        set +u # Disable strict mode before returning
        return 0 # Success
    fi
}

# --- Traps ---
# Cleanup trap (currently does nothing for persistent list file)
trap '_sa_cleanup' EXIT
# Trap to log execution time (removed - called explicitly now)

# --- Main Execution Logic (now encapsulated in a function) ---

sa_setup() {
    set -u # Enable strict mode for this function

    log_debug "sa_setup: Main setup function invoked."

    # Argument Parsing for sourced script
    # Check for verbose flag first
    if [ "$#" -ge 1 ] && [[ "$1" == "-v" || "$1" == "--verbose" ]]; then
        _sa_IS_VERBOSE="true"
        # Logging might not be fully set up yet, but attempt debug log
        log_debug "sa_setup: Verbose logging enabled by argument."
        shift # Remove the verbose flag from arguments
    fi

    # Agent setup must happen regardless of other args
    if ! _sa_ensure_ssh_agent; then
        log_error "sa_setup: Failed to ensure SSH agent is running."
        _sa_log_execution_time # Log time even on failure
        set +u # Disable strict mode before returning
        return 1 # Return failure from this function
    fi
    log_debug "sa_setup: Agent setup complete."

    # --- Load keys ---
    local LOAD_METHOD="scan" # Default: Scan SSH directory
    local KEY_SOURCE_FILE=""

    # Check if a filename argument remains *after* potential verbose flag shift
    if [ "$#" -ge 1 ] && [ -n "$1" ]; then
        log_debug "sa_setup: Remaining argument provided: $1. Treating as key list file."
        # Basic validation: Check if the provided argument is a readable file
        if [ -f "$1" ] && [ -r "$1" ]; then
            log_info "sa_setup: Using provided file '$1' as source for key names."
            LOAD_METHOD="file"
            KEY_SOURCE_FILE="$1"
        else
            log_warn "sa_setup: Argument '$1' is not a readable file. Falling back to scanning $SSH_DIR."
            # Keep LOAD_METHOD="scan"
        fi
    else
        log_debug "sa_setup: No filename argument provided. Scanning $SSH_DIR for keys."
        # Keep LOAD_METHOD="scan"
    fi

    # Populate the VALID_KEY_LIST_FILE based on the load method
    log_debug "sa_setup: Populating key list using method: $LOAD_METHOD"
    if [ "$LOAD_METHOD" = "file" ]; then
        # Copy contents from the source file, ensuring the list file is clear first
        if ! touch "$VALID_KEY_LIST_FILE" 2>/dev/null; then
             log_error "sa_setup: Cannot create or touch key list file '$VALID_KEY_LIST_FILE'. Check permissions."
             # Attempt to continue without loading keys
             VALID_KEY_LIST_FILE=""
        else
            chmod 600 "$VALID_KEY_LIST_FILE" 2>/dev/null || log_warn "sa_setup: Could not set permissions on $VALID_KEY_LIST_FILE"
            # Clear the list file first
            log_debug "sa_setup: Clearing key list file: $VALID_KEY_LIST_FILE"
            if command -v truncate > /dev/null; then
                truncate -s 0 "$VALID_KEY_LIST_FILE"
            else
                echo -n > "$VALID_KEY_LIST_FILE"
            fi
            if [ $? -ne 0 ]; then
                 log_error "sa_setup: Failed to clear key list file '$VALID_KEY_LIST_FILE'. Cannot load keys from file."
                 VALID_KEY_LIST_FILE=""
            else
                 # Copy lines, skipping empty lines and comments
                 log_debug "sa_setup: Copying key names from '$KEY_SOURCE_FILE' to '$VALID_KEY_LIST_FILE'"
                 grep -vE '^\s*(#|$)' "$KEY_SOURCE_FILE" >> "$VALID_KEY_LIST_FILE"
                 local copy_status=$?
                 if [ $copy_status -ne 0 ] && [ $copy_status -ne 1 ]; then # grep returns 1 if no lines selected
                      log_error "sa_setup: Failed to read from source key file '$KEY_SOURCE_FILE' (grep status: $copy_status)."
                      VALID_KEY_LIST_FILE="" # Mark as unusable
                 fi
            fi
        fi
    else # LOAD_METHOD is "scan"
        # Use the existing function to scan the SSH directory
        # NOTE: Using the function that *writes* to the file, not the one that echoes
        log_debug "sa_setup: Calling _sa_write_valid_key_basenames_to_file to scan $SSH_DIR and populate '$VALID_KEY_LIST_FILE'..."
        if ! _sa_write_valid_key_basenames_to_file "$VALID_KEY_LIST_FILE"; then
            # No valid keys found by scanning, or error occurred writing file
            log_info "sa_setup: No valid key files found in $SSH_DIR or update failed."
            VALID_KEY_LIST_FILE="" # Mark as unusable
        fi
    fi

    # Attempt to add keys from the populated list file (if usable)
    # Also check if the number of keys in the agent matches the list to avoid redundant loads.
    if [ -n "$VALID_KEY_LIST_FILE" ] && [ -f "$VALID_KEY_LIST_FILE" ] && [ -s "$VALID_KEY_LIST_FILE" ]; then
        log_debug "sa_setup: Valid key list file found: $VALID_KEY_LIST_FILE. Checking agent key count..."

        local agent_key_count=-1 # Default to -1 to indicate check hasn't run or failed
        local file_key_count=0

        # Get agent key count robustly using ssh-add -l (lists fingerprints)
        ssh-add -l >/dev/null 2>&1
        local agent_status=$?
        if [ $agent_status -eq 0 ]; then
            # Agent has keys
            agent_key_count=$(ssh-add -l | wc -l)
            log_debug "sa_setup: Keys currently in agent: $agent_key_count"
        elif [ $agent_status -eq 1 ]; then
            # Agent is running but has no keys
            agent_key_count=0
            log_debug "sa_setup: Agent has no keys currently loaded."
        else
            # Status 2 or higher: Error communicating with agent
            log_warn "sa_setup: Could not communicate with agent (ssh-add -l status $agent_status) to check key count. Will attempt to add keys."
            # Keep agent_key_count=-1 to force reload attempt
        fi

        # Get file key count (use cat to avoid error if file is empty, though -s check should prevent this)
        file_key_count=$(cat "$VALID_KEY_LIST_FILE" | wc -l | awk '{print $1}')
        log_debug "sa_setup: Keys found in list file '$VALID_KEY_LIST_FILE': $file_key_count"

        # Compare counts if agent communication was successful (agent_key_count >= 0)
        if [ "$agent_key_count" -ge 0 ] && [ "$agent_key_count" -eq "$file_key_count" ]; then
            log_info "sa_setup: Agent key count ($agent_key_count) matches list file count ($file_key_count). Skipping redundant key loading."
        else
            # Counts differ or agent communication failed, attempt to add keys
            if [ "$agent_key_count" -lt 0 ]; then
                log_debug "sa_setup: Agent communication failed, proceeding with key add attempt."
            else
                log_info "sa_setup: Agent key count ($agent_key_count) differs from list file count ($file_key_count). Attempting to add keys..."
            fi

            log_debug "sa_setup: Calling _sa_add_keys_to_agent using list file '$VALID_KEY_LIST_FILE'..."
            if ! _sa_add_keys_to_agent; then
                log_warn "sa_setup: _sa_add_keys_to_agent reported failure or no keys added."
                # This might be okay (e.g., all keys need passphrase), or might indicate issues.
            fi
        fi
    else
         log_warn "sa_setup: Key list file '$VALID_KEY_LIST_FILE' is not available or empty. Skipping key loading."
    fi

    # Log execution time before returning
    _sa_log_execution_time

    log_debug "sa_setup: Reached end of main setup function. Final return 0 coming up."
    log_debug "sa_setup: Setup complete."
    set +u # Disable strict mode before returning
    return 0 # Indicate success from setup function
}

# --- Auto-execution Trigger ---
# Call the main setup function, passing any arguments provided during sourcing.
sa_setup "$@" 