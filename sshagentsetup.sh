#!/usr/bin/env bash
#
# SSH Agent Setup Script (for sourcing in .zshrc/.zshenv/.zprofile)
# ================================================================
#
# Purpose:
#   Ensures a single ssh-agent is running per login session, exports the necessary
#   environment variables (SSH_AUTH_SOCK, SSH_AGENT_PID) for process inheritance,
#   and loads SSH keys into the agent.
#
# Features:
#   - Reuses existing agents identified via a persistent environment file.
#   - Starts a new agent if no valid one is found.
#   - Saves new agent details to the persistent environment file.
#   - Loads SSH keys into the agent based on different methods:
#     - Scanning the SSH directory for private keys with matching .pub files (default).
#     - Reading key names from a specified file provided as an argument.
#   - Prevents redundant key loading if the agent already seems to hold the correct keys.
#   - Provides optional verbose logging for debugging.
#   - Designed to be sourced, using `return` instead of `exit`.
#   - Uses function-local `set -u` for robustness without impacting the sourcing shell.
#
# Best Practice for Sourcing:
#   - Source this script from your login shell profile (e.g., ~/.zprofile for Zsh, ~/.profile).
#     This ensures the agent runs once per login session, and variables are inherited.
#     Example: `source /path/to/ssh_agent_setup.sh`
#   - Sourcing from interactive shell profiles (e.g., ~/.zshrc) is possible but less efficient,
#     as parts of the script will run in every new terminal (though optimizations exist).
#
# Usage Examples (when sourcing):
#   `source /path/to/ssh_agent_setup.sh`           # Scan default SSH dir for keys
#   `source /path/to/ssh_agent_setup.sh ~/.ssh/my_keys.txt` # Load keys listed in file
#   `source /path/to/ssh_agent_setup.sh -v`         # Scan with verbose logging
#   `source /path/to/ssh_agent_setup.sh -v ~/.ssh/my_keys.txt` # Load from file with verbose logging
#
# Key Loading Details:
#   - Identifies private keys by finding files in $SSH_DIR that do *not* end in .pub
#     and *do* have a corresponding file with the same name plus .pub.
#   - On macOS, automatically uses `--apple-use-keychain` with `ssh-add` to attempt
#     loading keys stored in the Keychain without passphrase prompts.
#   - Keys requiring passphrases (not stored in Keychain) will likely fail to load silently
#     when added via `ssh-add` non-interactively.
#
# Logging Configuration:
#   - Controlled by the `IS_VERBOSE` flag (set via `-v`/`--verbose` argument).
#   - Log file location determined automatically based on OS (macOS: ~/Library/Logs, Linux: /var/log or ~/.local/log)
#     or can be overridden by setting the `SSH_AGENT_SETUP_LOG` environment variable.
#

# --- Script Initialization ---

# Capture start time for execution duration logging.
# Avoids resetting if script is sourced multiple times in the same environment (though not recommended).
_sa_script_start_time=${_sa_script_start_time:-$(date +%s.%N)}

# Determine script directory to source libraries relative to the script itself
# Handle the case where BASH_SOURCE might be empty (e.g., if script is piped)
# Using a default directory of '.' if detection fails
declare SCRIPT_DIR
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]:-$0}" )" &> /dev/null && pwd )

# --- Set Platform Variable ---
declare PLATFORM
PLATFORM=$(uname -s) # Set PLATFORM for use by libraries

# --- Source Libraries ---
source "$SCRIPT_DIR/lib/logging.sh" # Source the logging library

# Global flag to control verbose/debug logging. Set by sa_setup() argument parsing.
declare IS_VERBOSE="false"

# --- Configuration Variables ---
# These variables define key locations used throughout the script.

declare SSH_DIR="$HOME/.ssh"                                         # Standard SSH directory
declare AGENT_ENV_FILE="$HOME/.config/sshkeymanager/agent.env"       # File to store/read agent connection details
declare VALID_KEY_LIST_FILE="$HOME/.config/sshkeymanager/ssh_keys_list"  # Persistent file to cache list of valid key *basenames*

# --- Log File Configuration Variables ---
# Define standard names and potential directory locations for the log file.

declare LOG_FILENAME="sshkeymanager.log"
# Platform-specific log directory preferences:
declare LOG_DIR_MACOS="$HOME/Library/Logs/sshkeymanager"
declare LOG_DIR_LINUX_VAR="/var/log/sshkeymanager"
declare LOG_DIR_LINUX_LOCAL="$HOME/.local/log/sshkeymanager"
declare LOG_DIR_FALLBACK="$HOME/.ssh/logs"                             # Fallback if others fail

# --- Logging Setup ---
# Logging setup is now handled by setup_logging() from lib/logging.sh
# which is called within sa_setup() after argument parsing.

# --- Helper and Finalization Functions ---

# Function: _sa_cleanup
# Purpose: Performs cleanup actions when the script exits (called via EXIT trap).
#          Currently, it only contains logic related to the persistent key list file,
#          which is commented out to avoid deleting it.
#
# Inputs:
#   - Global Variables: VALID_KEY_LIST_FILE (uses default expansion `${VAR:-}` for safety with set -u)
#
# Outputs: None.
#
# Core Logic:
#   1. Checks if the persistent key list file exists.
#   2. (Commented out) Optionally remove the file (`rm -f`).
_sa_cleanup() {
  # Use parameter expansion default to handle potentially unset variable with set -u
  if [ -n "${VALID_KEY_LIST_FILE:-}" ] && [ -f "${VALID_KEY_LIST_FILE:-}" ]; then
    # Decide if we should remove the persistent list file on exit?
    # For now, let's keep it as it caches the valid keys found.
    # log_debug "_sa_cleanup: Removing key list file $VALID_KEY_LIST_FILE"
    : # No cleanup needed for the persistent file
  fi
} # END _sa_cleanup

# Function: _sa_log_execution_time
# Purpose: Calculates and logs the total execution time of the script.
#          Called explicitly by sa_setup() before it returns.
#
# Inputs: None.
#
# Outputs:
#   - Log Output: Debug/Info messages about execution time.
#
# Core Logic:
#   1. Checks if start time variable exists (it should if script reached this point)
#   2. Captures end time.
#   3. Calculates duration using `date` command.
#   4. Logs duration using log_info.
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
} # END _sa_log_execution_time

# --- Core Agent and Key Management Functions ---

# Function: _sa_write_valid_key_basenames_to_file
# Purpose: Finds valid private SSH keys in the SSH directory (those with a
#          corresponding .pub file), and writes their basenames (one per line) to the specified file.
#
# Input: Uses SSH_DIR
# Argument $1: target_file - The file to write the basenames into.
#
# Output: Writes to the target file. Returns 0 if keys found and written, 1 otherwise.
#
# Core Logic:
#   1. Checks if the target file exists and is writable.
#   2. Finds all files in SSH_DIR that do not end in .pub.
#   3. Checks if each file has a corresponding .pub file.
#   4. Appends basenames of valid keys to the target file.
#   5. Returns 0 if keys found and written, 1 otherwise.
_sa_write_valid_key_basenames_to_file() {
    trap 'set +u' EXIT # Ensure strict mode is disabled on exit (use EXIT for portability)
    set -u # Enable strict mode for this function

    local target_file="$1"
    log_debug "_sa_write_valid_key_basenames_to_file: Entering function. Target file: '$target_file'"

    if [ -z "$target_file" ]; then
        log_error "_sa_write_valid_key_basenames_to_file: No target file specified."
        # set +u # Disable strict mode before returning - Handled by trap
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
            # set +u # Disable strict mode before returning - Handled by trap
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
             # set +u # Disable strict mode before returning - Handled by trap
             return 1
        fi
        chmod 600 "$target_file" 2>/dev/null || log_warn "_sa_write_valid_key_basenames_to_file: Could not set permissions on $target_file"
        # set +u # Disable strict mode before returning - Handled by trap
        return 1 # Indicate failure if no valid keys found
    else
        log_info "_sa_write_valid_key_basenames_to_file: Found ${#valid_key_basenames[@]} private key file(s). Writing to '$target_file'..."

        # Clear the target file first
        if ! :> "$target_file"; then
             log_error "_sa_write_valid_key_basenames_to_file: Failed to clear target file '$target_file' before writing."
             # set +u # Disable strict mode before returning - Handled by trap
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
                # set +u # Disable strict mode before returning - Handled by trap
                return 1 # Abort on first write error
            fi
        done
        log_info "_sa_write_valid_key_basenames_to_file: Successfully wrote ${#valid_key_basenames[@]} basenames to '$target_file'."
        # set +u # Disable strict mode before returning - Handled by trap
        return 0 # Success
    fi
} # END _sa_write_valid_key_basenames_to_file

# Function: _sa_check_ssh_agent
# Purpose: Checks if the currently set SSH_AUTH_SOCK and SSH_AGENT_PID environment
#          variables point to a live and accessible ssh-agent process.
#
# Inputs:
#   - Environment Variables: SSH_AUTH_SOCK, SSH_AGENT_PID (uses default expansion `${VAR:-}`)
#
# Outputs:
#   - Return Value: 0 if the agent is running and accessible, 1 otherwise.
#   - Log Output: Debug/Error messages indicating check status.
#
# Core Logic:
#   1. Checks if SSH_AUTH_SOCK and SSH_AGENT_PID are non-empty.
#   2. Checks if SSH_AUTH_SOCK points to an existing socket file (`-S`).
#   3. Checks if SSH_AGENT_PID corresponds to a running process (`ps -p`).
#   4. Attempts communication using `ssh-add -l`. Status 0 (keys exist) or 1 (no keys)
#      are considered successful communication. Status 2 or higher indicates failure.
_sa_check_ssh_agent() {
    trap 'set +u' EXIT # Ensure strict mode is disabled on exit (use EXIT for portability)
    set -u # Enable strict mode for this function

    log_debug "_sa_check_ssh_agent: Checking agent status... (PID='${SSH_AGENT_PID:-}', SOCK='${SSH_AUTH_SOCK:-}')"
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ -z "${SSH_AGENT_PID:-}" ]; then
        log_debug "_sa_check_ssh_agent: Required environment variables not set."
        # set +u # Disable strict mode before returning - Handled by trap
        return 1
    fi
    # Check if the socket file exists
    if [ ! -S "$SSH_AUTH_SOCK" ]; then
        log_error "_sa_check_ssh_agent: SSH_AUTH_SOCK is not a socket: $SSH_AUTH_SOCK"
        # set +u # Disable strict mode before returning - Handled by trap
        return 1
    fi
    # Check if the agent process is running
    if ! ps -p "$SSH_AGENT_PID" > /dev/null 2>&1; then
        log_error "_sa_check_ssh_agent: SSH_AGENT_PID ($SSH_AGENT_PID) process not running."
        # set +u # Disable strict mode before returning - Handled by trap
        return 1
    fi
    # Check communication with the agent
    # Use ssh-add -l, allow status 1 (no keys) as successful communication
    ssh-add -l > /dev/null 2>&1 || true
    local check_status=${PIPESTATUS[0]:-$?}
    log_debug "_sa_check_ssh_agent: ssh-add -l communication status: $check_status"
    if [ "$check_status" -eq 0 ] || [ "$check_status" -eq 1 ]; then
        log_debug "_sa_check_ssh_agent: Agent communication successful (status $check_status)."
        # set +u # Disable strict mode before returning - Handled by trap
        return 0 # Success
    fi
    log_error "_sa_check_ssh_agent: Cannot communicate with agent (ssh-add -l status $check_status)."
    # set +u # Disable strict mode before returning - Handled by trap
    return 1 # Failure
} # END _sa_check_ssh_agent

# Function: _sa_ensure_ssh_agent
# Purpose: Ensures a valid ssh-agent is running and its environment variables
#          (SSH_AUTH_SOCK, SSH_AGENT_PID) are exported in the current shell scope.
#          It prioritizes reusing an existing agent found via environment variables
#          or the persistent agent environment file.
#
# Inputs:
#   - Global Variables: AGENT_ENV_FILE, SSH_DIR
#   - Environment Variables: Checks existing SSH_AUTH_SOCK, SSH_AGENT_PID.
#
# Outputs:
#   - Exports: Exports SSH_AUTH_SOCK and SSH_AGENT_PID into the current shell environment.
#   - Files Modified: Creates/overwrites AGENT_ENV_FILE with new agent details if a new agent is started.
#                    Removes AGENT_ENV_FILE if it points to a stale/invalid agent.
#   - Return Value: 0 on success (agent running and vars exported), 1 on failure.
#
# Core Logic:
#   1. Check Current Environment: If SSH_AUTH_SOCK/PID are set and `_sa_check_ssh_agent` passes, export them and return success.
#   2. Check Persistent File: If AGENT_ENV_FILE exists:
#      a. Unset current SSH_AUTH_SOCK/PID.
#      b. Source AGENT_ENV_FILE.
#      c. If `_sa_check_ssh_agent` passes, export the sourced variables and return success.
#      d. If check fails, remove the stale AGENT_ENV_FILE and unset the variables.
#   3. Start New Agent: If no valid agent found yet:
#      a. Ensure $SSH_DIR exists.
#      b. Execute `ssh-agent -s` to start a new agent and capture its output.
#      c. Parse the output using `sed` to extract the new socket and PID.
#      d. Export the new SSH_AUTH_SOCK and SSH_AGENT_PID variables.
#      e. Write the export commands for the new variables to AGENT_ENV_FILE.
#      f. Perform a final verification using `_sa_check_ssh_agent`.
#      g. Return success (0) or failure (1) based on verification.
_sa_ensure_ssh_agent() {
    trap 'set +u' EXIT # Ensure strict mode is disabled on exit (use EXIT for portability)
    set -u # Enable strict mode for this function

    log_debug "_sa_ensure_ssh_agent: Entering function."

    # 1. Check if already configured and working in this environment
    log_debug "_sa_ensure_ssh_agent: Checking current environment..."
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -n "${SSH_AGENT_PID:-}" ] && _sa_check_ssh_agent; then
        log_info "_sa_ensure_ssh_agent: Agent already running and sourced (PID: $SSH_AGENT_PID)."
        # Ensure they are exported, just in case they weren't initially
        export SSH_AUTH_SOCK SSH_AGENT_PID
        # set +u # Disable strict mode before returning - Handled by trap
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
            # set +u # Disable strict mode before returning - Handled by trap
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
        # set +u # Disable strict mode before returning - Handled by trap
        return 1
    fi
    if ! chmod 700 "$SSH_DIR" 2>/dev/null; then log_warn "_sa_ensure_ssh_agent: Failed to set permissions on $SSH_DIR"; fi

    # Start ssh-agent and capture output
    local agent_output
    if ! agent_output=$(ssh-agent -s); then
        log_error "_sa_ensure_ssh_agent: Failed to execute ssh-agent -s"
        # set +u # Disable strict mode before returning - Handled by trap
        return 1
    fi
    log_debug "_sa_ensure_ssh_agent: ssh-agent -s output captured."

    # Extract environment variables (handle potential variations in output)
    local new_sock new_pid
    new_sock=$(echo "$agent_output" | sed -n 's/SSH_AUTH_SOCK=\([^;]*\);.*/\1/p')
    new_pid=$(echo "$agent_output" | sed -n 's/SSH_AGENT_PID=\([^;]*\);.*/\1/p')

    if [ -z "$new_sock" ] || [ -z "$new_pid" ]; then
        log_error "_sa_ensure_ssh_agent: Failed to extract env vars from output: $agent_output"
        # set +u # Disable strict mode before returning - Handled by trap
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
        # set +u # Disable strict mode before returning - Handled by trap
        return 0 # Success!
    else
        log_error "_sa_ensure_ssh_agent: Started new agent but failed final verification."
        # Clean up potentially bad environment state
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        rm -f "$AGENT_ENV_FILE" # Remove possibly bad file
        # set +u # Disable strict mode before returning - Handled by trap
        return 1 # Failure!
    fi
} # END _sa_ensure_ssh_agent

# Function: _sa_add_keys_to_agent
# Purpose: Reads a list of key *basenames* from the VALID_KEY_LIST_FILE,
#          constructs their full paths, and attempts to add them to the
#          currently running ssh-agent using a single `ssh-add` command.
#
# Inputs:
#   - Global Variables: VALID_KEY_LIST_FILE, SSH_DIR
#
# Outputs:
#   - Agent State: Adds keys to the ssh-agent.
#   - Return Value: 0 if `ssh-add` call succeeded (status 0 or 1), 1 if `ssh-add` failed critically (status 2+).
#                 Returns 1 immediately if key list file is empty or no valid paths found.
#   - Log Output: Info/Warn/Error messages about the process.
#
# Core Logic:
#   1. Checks if VALID_KEY_LIST_FILE exists and is non-empty.
#   2. Reads each line (key basename) from VALID_KEY_LIST_FILE.
#   3. Constructs the full path ($SSH_DIR/$basename).
#   4. Checks if the full path points to an existing file.
#   5. Adds valid full paths to the `key_paths_to_add` array.
#   6. If no valid paths are found, returns 1.
#   7. Builds the `ssh-add` command array.
#   8. Adds `--apple-use-keychain` on Darwin.
#   9. Appends all valid key paths to the command array.
#  10. Executes the `ssh-add` command with all keys at once.
#  11. Checks the exit status of `ssh-add`:
#      - 0 (Success): Returns 0.
#      - 1 (Partial failure, likely passphrases needed): Logs warning, returns 0 (treated as OK for setup).
#      - 2+ (Connection error or other failure): Logs error, returns 1.
_sa_add_keys_to_agent() {
    trap 'set +u' EXIT # Ensure strict mode is disabled on exit (use EXIT for portability)
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
        # set +u # Disable strict mode before returning - Handled by trap
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
        # set +u # Disable strict mode before returning - Handled by trap
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
        # set +u # Disable strict mode before returning - Handled by trap
        return 0
    elif [ $ssh_add_status -eq 1 ]; then
        # Status 1 implies some keys failed, often due to passphrases.
        # Log this as a warning but consider the setup potentially successful otherwise.
        log_warn "_sa_add_keys_to_agent: ssh-add reported partial failure (status 1). Some keys might require passphrase or be invalid."
        log_warn "ssh-add output (if any): $ssh_add_output"
        log_debug "_sa_add_keys_to_agent: Exiting function (status: 0 - partial success treated as OK for setup)."
        # set +u # Disable strict mode before returning - Handled by trap
        return 0 # Treat partial success as OK for setup purposes
    else # Status 2 or other errors
        log_error "_sa_add_keys_to_agent: ssh-add failed (status: $ssh_add_status). Could not add keys."
        log_error "ssh-add output (if any): $ssh_add_output"
        log_debug "_sa_add_keys_to_agent: Exiting function (status: 1 - failure)."
        # set +u # Disable strict mode before returning - Handled by trap
        return 1 # Major failure
    fi
} # END _sa_add_keys_to_agent

# --- Main Setup Function ---
# This function orchestrates the primary setup process when the script is sourced.

# Function: sa_setup
# Purpose: Main entry point for the SSH agent setup process. Handles argument parsing,
#          ensures the agent is running, determines how to load keys (scan or file),
#          populates the list of keys, checks if keys need loading, loads them if necessary,
#          and logs execution time.
#
# Inputs:
#   - Arguments: Optionally accepts `-v` or `--verbose` for debug logging,
#                followed by an optional filename containing a list of key names to load.
#   - Global Variables: Uses SSH_DIR, VALID_KEY_LIST_FILE, and modifies IS_VERBOSE.
#   - Environment Variables: Relies on `_sa_ensure_ssh_agent` to set SSH_AUTH_SOCK/PID.
#
# Outputs:
#   - Agent State: Ensures agent is running and potentially adds keys.
#   - Environment Variables: Exports SSH_AUTH_SOCK, SSH_AGENT_PID via `_sa_ensure_ssh_agent`.
#   - Files Modified: Populates VALID_KEY_LIST_FILE (either from scan or file input).
#   - Return Value: 0 on success (agent is running), 1 on failure (agent setup failed).
#                    Key loading issues do not cause a failure return code.
#
# Core Logic:
#   1. Enables `set -u` locally for robustness.
#   2. Parses arguments to check for verbose flag (`-v`/`--verbose`) and sets `IS_VERBOSE`.
#   3. Calls `_sa_ensure_ssh_agent` to start/reuse agent and export variables. Exits on failure.
#   4. Determines key loading method (`scan` or `file`) based on remaining arguments.
#   5. If method is `file`, validates the input file and copies its contents (basenames)
#      to VALID_KEY_LIST_FILE.
#   6. If method is `scan`, calls `_sa_write_valid_key_basenames_to_file` to populate
#      VALID_KEY_LIST_FILE by scanning $SSH_DIR.
#   7. Checks if VALID_KEY_LIST_FILE is usable.
#   8. Compares key count in agent (`ssh-add -l`) with count in VALID_KEY_LIST_FILE.
#   9. If counts differ or agent check failed, calls `_sa_add_keys_to_agent`.
#  10. If counts match, skips calling `_sa_add_keys_to_agent`.
#  11. Calls `_sa_log_execution_time`.
#  12. Disables `set -u` and returns status.
sa_setup() {
    # set -u # Enable strict mode for this function - MOVED to be after setup_logging
    # 
    # log_debug "sa_setup: Main setup function invoked." # Cannot log before setup

    # --- Argument Parsing --- 
    local key_list_source_file=""
    local arg
    # We need IS_VERBOSE potentially set BEFORE setup_logging
    # so parse args first.
    for arg in "$@"; do
        case "$arg" in
            -v|--verbose)
                IS_VERBOSE="true"
                # log_debug "Verbose logging enabled by argument." # Cannot log yet
                shift # Consume the argument
                ;;
            -*) 
                # log_warn "Unknown option ignored: $arg" # Cannot log yet
                shift # Consume the argument
                ;;
            *)
                # Assume the first non-option argument is the key list file
                if [ -z "$key_list_source_file" ]; then
                    key_list_source_file="$arg"
                    # log_info "Key list source file specified: $key_list_source_file" # Cannot log yet
                else
                    # log_warn "Ignoring additional argument: $arg" # Cannot log yet
                    :
                fi
                shift # Consume the argument
                ;;
        esac
    done

    # --- Setup Logging (Must happen before any logging calls) ---
    # Call setup_logging from the sourced library
    setup_logging # This function should handle setting LOG_FILE
    # local setup_log_status=$?
    # printf "DEBUG_TERM: setup_logging status: %s\n" "$setup_log_status" >&2 # DEBUG Removed
    # printf "DEBUG_TERM: LOG_FILE after setup_logging: [%s]\n" "${LOG_FILE:-UNSET}" >&2 # DEBUG Removed

    # --- Enable Strict Mode (Now safe to log errors if it fails) ---
    set -u 

    # --- Log Script Start and Config (Now safe) ---
    _log_marker "_______<=:START:=> SSH Agent Setup Script______"
    log_debug "Starting SSH Agent Setup Script (PID: $$)..."
    log_debug "IS_VERBOSE flag set to: ${IS_VERBOSE}"
    log_debug "Using SSH Directory: $SSH_DIR"
    log_debug "Using Agent Env File: $AGENT_ENV_FILE"
    log_debug "Using Valid Key List File: $VALID_KEY_LIST_FILE"
    if [ -n "$key_list_source_file" ]; then
        log_info "Key list source file specified: $key_list_source_file"
    fi
    # Log any warnings about ignored args here if needed

    # --- Agent Check / Start ---
    log_info "Checking/starting SSH agent..."
    if ! _sa_ensure_ssh_agent; then
        log_error "Failed to ensure SSH agent is running. Aborting setup."
        _log_marker "_______<=:EXIT:=> SSH Agent Setup Script (Agent Ensure Failed)______"
        set +u # Disable strict mode before returning
        return 1
    fi
    log_info "SSH Agent is running and sourced (PID: ${SSH_AGENT_PID:-Unknown})."

    # --- Key Loading Logic ---
    if [ -n "$key_list_source_file" ]; then
        # Load keys from the specified file
        log_info "Loading keys from specified file: $key_list_source_file"
        if ! _sa_write_valid_key_basenames_to_file "$key_list_source_file"; then
            log_warn "Loading keys from file '$key_list_source_file' encountered issues."
        fi
    else
        # Scan SSH_DIR and load keys
        log_info "Scanning $SSH_DIR for keys to load..."
        if ! _sa_write_valid_key_basenames_to_file "$VALID_KEY_LIST_FILE"; then
            log_warn "Scanning and loading keys from directory '$SSH_DIR' encountered issues."
        fi
    fi

    # --- Finalization ---
    log_debug "SSH agent setup process completed."
    _sa_log_execution_time # Log execution time
    _log_marker "_______<=:EXIT:=> SSH Agent Setup Script (Agent Ensure Success)______"
    # printf "DEBUG_TERM: LOG_FILE before exit: [%s]\n" "${LOG_FILE:-UNSET}" >&2 # DEBUG Removed
    set +u # Disable strict mode before returning
    return 0
} # END sa_setup

# --- Auto-Execution Trigger ---
# Call the main setup function, passing any arguments provided during sourcing.
sa_setup "$@" 