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

# Determine script directory to source libraries relative to the script itself
declare SCRIPT_DIR
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# --- Source Libraries ---
source "$SCRIPT_DIR/lib/logging.sh" || { echo "Error: Failed to source logging library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/validation.sh" || { echo "Error: Failed to source validation library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/arg_helpers.sh" || { echo "Error: Failed to source argument helper library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/agent.sh" || { echo "Error: Failed to source agent library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/key_ops.sh" || { echo "Error: Failed to source key operations library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/menu.sh" || { echo "Error: Failed to source menu library." >&2; exit 1; }

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

# Command path for GNU getopt (set by _check_gnu_getopt)
declare GNU_GETOPT_CMD=""

# ==============================================================================
# --- Function Definitions ---
# ==============================================================================

# ------------------------------------------------------------------------------
# --- Dependency Check Functions ---
# ------------------------------------------------------------------------------

# --- _check_gnu_getopt ---
# Removed - Now in lib/arg_helpers.sh

# ------------------------------------------------------------------------------
# --- Validation Functions ---
# ------------------------------------------------------------------------------

# --- validate_directory ---
# Removed - Now in lib/validation.sh

# --- validate_ssh_dir ---
# Removed - Now in lib/validation.sh

# ------------------------------------------------------------------------------
# --- SSH Agent Management Functions ---
# ------------------------------------------------------------------------------

# --- check_ssh_agent ---
# Removed - Now in lib/agent.sh

# --- ensure_ssh_agent ---
# Removed - Now in lib/agent.sh

# --- add_keys_to_agent ---
# Removed - Now in lib/key_ops.sh

# --- delete_keys_from_agent ---
# Removed - Now in lib/key_ops.sh

# --- load_specific_keys ---
# Removed - Now in lib/key_ops.sh

# ------------------------------------------------------------------------------
# --- Core Key Management Functions ---
# ------------------------------------------------------------------------------

# --- update_keys_list_file ---
# Removed - Now in lib/key_ops.sh

# --- delete_keys_from_agent ---
# Removed - Now in lib/key_ops.sh

# --- load_specific_keys ---
# Removed - Now in lib/key_ops.sh

# ------------------------------------------------------------------------------
# --- Interactive Menu Helper Functions ---
# ------------------------------------------------------------------------------

# --- display_main_menu ---
# Removed - Now in lib/menu.sh

# --- get_menu_choice ---
# Removed - Now in lib/menu.sh

# --- wait_for_key ---
# Removed - Now in lib/menu.sh

# --- set_ssh_directory ---
# Removed - Now in lib/menu.sh

# ------------------------------------------------------------------------------
# --- Interactive Menu Core Logic Functions ---
# ------------------------------------------------------------------------------

# --- list_current_keys ---
# Removed - Now in lib/key_ops.sh

# --- display_log_location ---
# Removed - Now in lib/menu.sh

# --- delete_single_key ---
# Removed - Now in lib/key_ops.sh

# --- delete_all_keys ---
# Removed - Now in lib/key_ops.sh

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
    # Do NOT ensure agent here. Let delete_all_keys handle the check.
    # if ! ensure_ssh_agent; then exit 1; fi # Agent required for deletion.

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

    # Log script end marker
    _log_marker "_______<=:END:=> SSH Key Manager Script______"

    # No need to explicitly exit here; the trap handler finishes and script exit proceeds.
    log_debug "_script_exit_handler finished."
    _log_marker "_______<=:EXIT:=> SSH Key Manager Script______"
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
    local parse_error=0 # Initialize parse_error to handle unbound variable with set -u
    local FIRST_ACTION_SET=0 # Initialize flag for simple parser action tracking

    # --- Setup Logging FIRST ---
if ! setup_logging; then
        printf "Warning: Logging setup failed. Continuing with logging disabled.\n" >&2
    fi
    # Log script start marker *after* setup_logging attempt
    _log_marker "_______<=:START:=> SSH Key Manager Script______"

    # --- Check for GNU getopt and Select Parsing Strategy --- 
    if _check_gnu_getopt; then 
        # --- Use GNU Getopt Parsing --- (GNU getopt found on this system)
        log_debug "Using GNU getopt ($GNU_GETOPT_CMD) for argument parsing."
        local short_opts="laf:Dmhv"
        local long_opts="list,add,file:,delete-all,menu,help,verbose"
        local ARGS
        if ! ARGS=$($GNU_GETOPT_CMD -o "$short_opts" --long "$long_opts" -n "$(basename "$0")" -- "$@"); then
            log_error "Argument parsing error ($GNU_GETOPT_CMD failed)."
            exit 1 # Exit here, as getopt failed unexpectedly
        fi
        eval set -- "$ARGS"
        while true; do
            case "$1" in
        -l|--list)
            ACTION="list"
                    shift ;;
        -a|--add)
            ACTION="add"
                    shift ;;
        -f|--file)
                    ACTION="file"; source_key_file="$2"
                    shift 2 ;;
        -D|--delete-all)
            ACTION="delete-all"
                    shift ;;
        -m|--menu)
            ACTION="menu"
                    shift ;;
        -v|--verbose)
            IS_VERBOSE="true"
                    shift ;;
        -h|--help)
            ACTION="help"
                    parse_error=0
                    shift ;;
                --)
                    shift
                    break ;;
                *)
                    log_error "Internal error during getopt argument processing near '$1'"
                    ACTION="help"; parse_error=1; break ;;
            esac
        done
    else
        # --- Use Simple Parsing Fallback --- (GNU getopt not found or check failed)
        # _check_gnu_getopt already logged the error
        # Log this as info, as fallback works but lacks features. Avoids user-facing warning.
        log_info "GNU getopt not found or incompatible. Using simple parser. Combined/long options unsupported. Recommendation: Install GNU getopt (e.g., 'brew install gnu-getopt' on macOS) for full argument support."

        local args_copy=("$@")
        local i=0
        while [ $i -lt ${#args_copy[@]} ]; do
            local arg="${args_copy[$i]}"
            case $arg in
            -l)
                    if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="list"; FIRST_ACTION_SET=1; fi
                    i=$((i + 1)) ;;
            -a)
                    if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="add"; FIRST_ACTION_SET=1; fi
                    i=$((i + 1)) ;;
            -f)
                     local next_arg_index=$((i + 1))
                     local next_arg="${args_copy[$next_arg_index]:-}"
                     if [[ -z "$next_arg" || "${next_arg:0:1}" == "-" ]]; then
                         printf "Error: Option '%s' requires a filename argument.\n\n" "$arg" >&2
                         ACTION="help"; parse_error=1; break
                     fi
                     if [ "$FIRST_ACTION_SET" -eq 0 ]; then
                         ACTION="file"; source_key_file="$next_arg"; FIRST_ACTION_SET=1
                     else
                          log_warn "Ignoring subsequent action flag '%s' after action '%s' was already set (simple parser)." "$arg" "$ACTION"
                     fi
                     i=$((i + 2)) ;;
            -D)
                    if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="delete-all"; FIRST_ACTION_SET=1; fi
                    i=$((i + 1)) ;;
            -m)
                    if [ "$FIRST_ACTION_SET" -eq 0 ]; then ACTION="menu"; FIRST_ACTION_SET=1; fi
                    i=$((i + 1)) ;;
            -v)
                    IS_VERBOSE="true"
                    i=$((i + 1)) ;;
            -h)
                    ACTION="help"; FIRST_ACTION_SET=1; parse_error=0
                    i=$((i + 1)) ;;
                *) # Unknown option or combined options like -lv with simple parser
                    if [[ "$arg" == -* && ${#arg} -gt 2 ]]; then
                         # This condition likely won't be hit often now, but keep for clarity
                        printf "Error: Combined options like '%s' not supported by simple parser.\n" "$arg" >&2
                    else
                        printf "Error: Unknown option '%s'\n\n" "$arg" >&2
                    fi
                    ACTION="help"; parse_error=1; break
            ;;
    esac
done
    fi

    # --- Runtime Initialization (Post-Parsing) ---
    log_debug "--- Script Start Checkpoint (Post-Parsing) ---"
    log_debug "Timestamp: $_script_start_time"
    log_debug "Parsed Action: '$ACTION'"
    log_debug "Verbose Logging: '$IS_VERBOSE'"
    log_debug "Source Key File: '${source_key_file:-N/A}'"
    log_debug "Argument Parse Error: ${parse_error:-UNKNOWN}" # Use parameter expansion default
    log_debug "Platform: $PLATFORM"
    log_debug "Stat Command: $STAT_CMD"
    log_debug "SSH Directory: $SSH_DIR"
    log_debug "Agent Env File: $AGENT_ENV_FILE"
    log_debug "Valid Key List File: $VALID_KEY_LIST_FILE"
    log_debug "Log Directory: $LOG_DIR"
    log_debug "Log Filename: $LOG_FILENAME"
    log_debug "Log File Path: $LOG_FILE"

    if ! KEYS_LIST_TMP=$(mktemp "${TMPDIR:-/tmp}/ssh_keys_list.XXXXXX"); then
        log_error "Fatal: Failed to create temporary file using mktemp. Check permissions in '${TMPDIR:-/tmp}'."
        printf "Error: Could not create required temporary file. Exiting.\n" >&2
        exit 1
    fi
    log_debug "Temporary file created: $KEYS_LIST_TMP"

    # --- Dispatch Action ---
    log_info "Selected action: $ACTION"

case $ACTION in
    list)
             run_list_keys ;;
    add)
             run_load_keys ;;
    file)
            run_load_keys_from_file "$source_key_file" ;;
    delete-all)
            run_delete_all_cli ;;
    menu)
            run_interactive_menu ;;
    help|*)
        display_help
            if [ "$parse_error" -eq 1 ]; then
                exit 1
            else
                exit 0
            fi
        ;;
esac

    # This point should ideally not be reached
    log_error "Critical Error: Script main function reached end unexpectedly after dispatching action: $ACTION."
    printf "Error: Unexpected script termination. Please check logs: %s\n" "${LOG_FILE:-N/A}" >&2
    exit 1
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