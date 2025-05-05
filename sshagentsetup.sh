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
#   - Controlled by the `_sa_IS_VERBOSE` flag (set via `-v`/`--verbose` argument).
#   - Log file location determined automatically based on OS (macOS: ~/Library/Logs, Linux: /var/log or ~/.local/log)
#     or can be overridden by setting the `SSH_AGENT_SETUP_LOG` environment variable.
#

# --- Script Initialization ---

# Capture start time for execution duration logging.
# Avoids resetting if script is sourced multiple times in the same environment (though not recommended).
_sa_script_start_time=${_sa_script_start_time:-$(date +%s.%N)}

# Global flag to control verbose/debug logging. Set by sa_setup() argument parsing.
#declare _sa_IS_VERBOSE="false"
declare _sa_IS_QUIET="false"

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
# Determines the actual log file path to use.

declare LOG_FILE="" # Initialize empty; will be set by setup logic if successful

# Function: _setup_default_logging
# Purpose: Determines the appropriate default log file path based on the OS,
#          creates the necessary directory and log file, and sets the LOG_FILE variable.
#
# Inputs:
#   - Global Variables: LOG_DIR_MACOS, LOG_DIR_LINUX_VAR, LOG_DIR_LINUX_LOCAL,
#                     LOG_DIR_FALLBACK, LOG_FILENAME
#
# Outputs:
#   - Global Variables: Sets LOG_FILE to the determined path if successful, otherwise leaves it empty.
#   - Files Modified: Creates the log directory and touches the log file ($LOG_FILE).
#   - Return Value: 0 on success, 1 on failure (directory/file creation failed).
#
# Core Logic:
#   1. Uses `uname -s` to detect the operating system (Darwin, Linux, other).
#   2. Selects the preferred log directory based on OS conventions and permissions.
#   3. Constructs the full target log path.
#   4. Attempts to create the log directory (`mkdir -p`).
#   5. Attempts to create the log file (`touch`).
#   6. If successful, sets the global LOG_FILE variable and sets file permissions (chmod 600).
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

# Function: _log_base
# Purpose: Core internal function for writing log entries to the configured log file.
#          Handles timestamping and formatting.
#          Checks if LOG_FILE is configured before attempting to write.
#
# Inputs:
#   - Arguments: $1=LogLevel (e.g., "INFO", "DEBUG"), $2=LogMessage
#   - Global Variables: LOG_FILE
#
# Outputs:
#   - Files Modified: Appends the formatted log message to $LOG_FILE.
#
# Core Logic:
#   1. Checks if LOG_FILE is empty; returns immediately if it is.
#   2. Gets the current timestamp.
#   3. Uses `printf` to format and append the log entry (Timestamp - PID - Level - Message).
_log_base() {
    # Only log if LOG_FILE is set (not empty)
    [ -z "$LOG_FILE" ] && return 0 # Exit if LOG_FILE wasn't successfully configured
    local type="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Use printf for safer handling of potentially weird characters in msg
    printf "%s - %s - %s - %s\n" "$timestamp" "$$" "$type" "$msg" >> "$LOG_FILE"
} # END _log_base

# Function: log_info, log_error, log_warn, log_debug
# Purpose: Convenience wrappers around _log_base for specific standard log levels.
#          `log_debug` includes an additional check for the `_sa_IS_VERBOSE` flag.
#
# Inputs:
#   - Arguments: $1=LogMessage
#   - Global Variables: _sa_IS_VERBOSE (for log_debug only)
#
# Outputs: (Via _log_base)
#   - Files Modified: Appends the formatted log message to $LOG_FILE.

_log_info() { _log_base "INFO" "$1"; }
_log_error() { _log_base "ERROR" "$1"; }
_log_warn() { _log_base "WARN" "$1"; }
_log_debug() { [ "$_saIS_QUIET" = "true" ] && _log_base "DEBUG" "$1"; }

# --- _log_marker ---
# Internal helper to write markers, ensuring they are written even if logging is disabled initially
_log_marker() {
    local marker_text="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Use printf to stderr if LOG_FILE is /dev/null or empty during early stages
    if [[ "$LOG_FILE" == "/dev/null" || -z "$LOG_FILE" ]]; then # Use double brackets and check for empty
        # Also check for empty LOG_FILE as it might not be set to /dev/null
        printf "%s - %s - MARKER: %s\n" "$timestamp" "$$" "$marker_text" >&2
    else
        echo "$timestamp - $$ - MARKER: $marker_text" >> "$LOG_FILE"
    fi
}

# --- Library Sourcing ---
# Define the script's directory using a robust, portable symlink resolution method.

declare SCRIPT_DIR
declare LIB_DIR

# --- Function to determine the script directory ---
# This encapsulates the logic and uses local variables.
# It echoes the directory path on success and returns 0.
# It prints an error and returns 1 on failure.
_determine_script_dir() {
    local source_path=""
    local script_dir=""

    if [ -n "$ZSH_VERSION" ]; then
        # Zsh: Use :A modifier for realpath, :h for dirname
        # %x is preferred over %N as a BASH_SOURCE equivalent
        source_path="${(%):-%x}"
        # Check if we got a path before applying modifiers
        _log_info "source_path: $source_path"
        if [[ -n "$source_path" ]]; then
            # :A resolves symlinks and makes absolute, :h gets the directory
            script_dir="${source_path:A:h}"
        fi
    elif [ -n "$BASH_VERSION" ]; then
        # Bash: Use BASH_SOURCE and readlink -f (GNU extension) + dirname
        if [[ -n "${BASH_SOURCE[0]}" ]]; then
            source_path="${BASH_SOURCE[0]}"
            local real_path
            # Use readlink -f for robustness (requires GNU coreutils or compatible)
            # Capture stdout and check exit status
            if real_path=$(readlink -f -- "$source_path" 2>/dev/null); then
                 script_dir=$(dirname -- "$real_path")
            fi
            # Fallback if readlink -f fails but path exists (e.g., non-GNU readlink)
             if [[ -z "$script_dir" && -e "$source_path" ]]; then
                 # Basic dirname might work if not a symlink needing resolution
                 script_dir=$(cd -P "$(dirname -- "$source_path")" &>/dev/null && pwd)
             fi
        fi
    else
        # Fallback for other shells (less reliable, especially when sourced)
        # Try resolving $0 using readlink -f if possible
        if [[ -n "$0" ]]; then
             source_path="$0"
             local real_path
             if real_path=$(readlink -f -- "$source_path" 2>/dev/null); then
                 script_dir=$(dirname -- "$real_path")
             # Basic fallback if $0 has a slash (might be relative/absolute path)
             elif [[ "$source_path" == */* ]]; then
                 script_dir=$(cd -P "$(dirname -- "$source_path")" &>/dev/null && pwd)
             fi
        fi
    fi

    # Check if SCRIPT_DIR was successfully determined
    if [[ -z "$script_dir" || ! -d "$script_dir" ]]; then
        echo "Error: Could not determine the script's real directory." >&2
        return 1
    fi

    # Echo the result for assignment
    echo "$script_dir"
    return 0
}

# --- Call the function and assign the result ---
# Use command substitution to capture the echoed path
# Check the return status ($?) for success
if ! SCRIPT_DIR=$(_determine_script_dir); then
    # Error message already printed by the function
    # Exit/return based on execution context (sourcing vs direct execution)
    (return 0 2>/dev/null) && return 1 || exit 1
fi

# Define the library directory relative to the script directory
LIB_DIR="$SCRIPT_DIR/lib"

# Source required library files
# Use '.' (source) and check existence for robustness
if [ -f "$LIB_DIR/logging.sh" ]; then
    . "$LIB_DIR/logging.sh"
else
    echo "Error: Library file not found: $LIB_DIR/logging.sh" >&2
    return 1 # Use return as this script is sourced
fi

if [ -f "$LIB_DIR/agent.sh" ]; then
    . "$LIB_DIR/agent.sh"
else
    echo "Error: Library file not found: $LIB_DIR/agent.sh" >&2
    return 1
fi

if [ -f "$LIB_DIR/key_ops.sh" ]; then
    . "$LIB_DIR/key_ops.sh"
else
    echo "Error: Library file not found: $LIB_DIR/key_ops.sh" >&2
    return 1
fi

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
} # END _sa_write_valid_key_basenames_to_file

# Function: _sa_count_keys_in_agent
# Purpose: Uses `ssh-add -l` to count the number of keys currently loaded in the agent.
#          Returns the count or 1 if the command fails (indicating the agent is not accessible).
#
# Inputs: None.
#
# Outputs:
#   - Return Value: The number of keys loaded in the agent, or 1 if the agent is inaccessible.
#   - Log Output: Debug messages about the process.
#
# Core Logic:
#   1. Executes `ssh-add -l` and captures its output.
#   2. Parses the output to count the number of keys.
#   3. Returns the count.
#   4. If `ssh-add` fails, returns 1.
_sa_count_keys_in_agent() {
    set -u # Enable strict mode for this function

    log_debug "_sa_count_keys_in_agent: Executing ssh-add -l to count keys..."
    local ssh_add_output
    ssh_add_output=$(ssh-add -l 2>&1)
    local ssh_add_status=$?
    log_debug "_sa_count_keys_in_agent: ssh-add -l finished with status: $ssh_add_status"

    if [ $ssh_add_status -ne 0 ]; then
        log_error "_sa_count_keys_in_agent: ssh-add failed with status $ssh_add_status. Assuming agent is inaccessible."
        set +u # Disable strict mode before returning
        return 1
    fi

    # Parse the output to count keys
    local key_count=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue # Skip empty lines
        ((key_count++))
    done <<< "$ssh_add_output"

    log_debug "_sa_count_keys_in_agent: Found $key_count keys in agent."
    set +u # Disable strict mode before returning
    return $key_count
} # END _sa_count_keys_in_agent

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
#   - Global Variables: Uses SSH_DIR, VALID_KEY_LIST_FILE, and modifies _sa_IS_VERBOSE.
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
#   2. Parses arguments to check for verbose flag (`-v`/`--verbose`) and sets `_sa_IS_VERBOSE`.
#   3. Calls `_sa_ensure_ssh_agent` to start/reuse agent and export variables. Exits on failure.
#   4. Determines key loading method (`scan` or `file`) based on remaining arguments.
#   5. If method is `file`, validates the input file and copies its contents (basenames)
#      to VALID_KEY_LIST_FILE.
#   6. If method is `scan`, calls `_sa_write_valid_key_basenames_to_file` to populate
#      VALID_KEY_LIST_FILE by scanning $SSH_DIR.
#   7. Checks if VALID_KEY_LIST_FILE is usable.
#   8. Compares key count in agent (`ssh-add -l`) with count in VALID_KEY_LIST_FILE.
#   9. If counts differ or agent check failed, calls `add_keys_to_agent --bulk --quiet`.
#  10. If counts match, skips calling `add_keys_to_agent`.
#  11. Calls `_sa_log_execution_time`.
#  12. Disables `set -u` and returns status.
sa_setup() {
    set -u # Enable strict mode for this function

    log_debug "sa_setup: Main setup function invoked."

    # --- Log Script Start --- 
    # Must be called *after* logging functions are defined and LOG_FILE is potentially set.    

    # --- Argument Parsing ---
    local key_list_source_file=""
    local quiet_mode=false # Add quiet_mode flag
    # Process arguments manually (safer for sourcing)
    local arg
    for arg in "$@"; do
        case "$arg" in
            -v|--verbose)
                _sa_IS_VERBOSE="true"
                log_debug "Verbose logging enabled by argument."
                shift # Consume the argument
                ;;
            -q|--quiet) # Add quiet flag parsing
                _sa_IS_QUIET="true"
                log_debug "Quiet mode enabled by argument."
                shift # Consume the argument
                ;;
            -*)
                log_warn "Unknown option ignored: $arg"
                shift # Consume the argument
                ;;
            *)
                # Assume the first non-option argument is the key list file
                if [ -z "$key_list_source_file" ]; then
                    key_list_source_file="$arg"
                    log_info "Key list source file specified: $key_list_source_file"
                else
                    log_warn "Ignoring additional argument: $arg"
                fi
                shift # Consume the argument
                ;;
        esac
    done

    # --- Agent Check / Start ---
    log_info "Checking/starting SSH agent..."
    # Pass quiet_mode status to ensure_ssh_agent
    if ! ensure_ssh_agent "load" "$quiet_mode"; then 
        log_error "Failed to ensure SSH agent is running. Aborting setup."
        set +u # Disable strict mode before returning
        _log_marker "_______<=:EXIT:=> SSH Agent Setup Script (Agent Ensure Failed)______"
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
    add_keys_to_agent --bulk 
    # --- Finalization ---
    log_debug "SSH agent setup process completed."
    _sa_log_execution_time # Log execution time
    set +u # Disable strict mode before returning
    _log_marker "_______<=:EXIT:=> SSH Agent Setup Script (Agent Ensure Success)______"
    return 0
} # END sa_setup

# --- Auto-Execution Trigger ---
# Call the main setup function, passing any arguments provided during sourcing.
sa_setup "$@" 