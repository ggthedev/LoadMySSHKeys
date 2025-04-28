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
# Author: Gaurav Gupta
# Version: 0.0.1.2
# License: BSD 3-Clause
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
source "$SCRIPT_DIR/lib/helpers.sh" || { echo "Error: Failed to source helpers library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/arg_helpers.sh" || { echo "Error: Failed to source argument helper library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/agent.sh" || { echo "Error: Failed to source agent library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/key_ops.sh" || { echo "Error: Failed to source key operations library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/menu.sh" || { echo "Error: Failed to source menu library." >&2; exit 1; }
source "$SCRIPT_DIR/lib/cli.sh" || { echo "Error: Failed to source cli library." >&2; exit 1; }

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

# --- _perform_list_keys_check --- REMOVED ---
# Logic moved/simplified into run_list_keys in lib/cli.sh

# ------------------------------------------------------------------------------
# --- CLI Action Functions --- REMOVED ---
# Now in lib/cli.sh
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# --- Help Function --- REMOVED ---
# Now in lib/cli.sh (as 'usage')
# ------------------------------------------------------------------------------

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
    _log_marker "_______<=:START:=> SSH Key Manager Script______"

    # --- Setup Platform Variables ---
    # Call the function sourced from lib/helpers.sh
    setup_platform_vars # Sets $PLATFORM and $STAT_CMD

    # --- Create Temporary File ---
    # This needs to happen *before* parsing arguments, as some actions might use it immediately.
    # However, some argument parsing errors might occur before this, so cleanup trap must handle $KEYS_LIST_TMP potentially being unset.
    if ! KEYS_LIST_TMP=$(mktemp "${TMPDIR:-/tmp}/ssh_keys_list.XXXXXX"); then
        log_error "Fatal: Failed to create temporary file using mktemp. Check permissions in '${TMPDIR:-/tmp}'."
        printf "Error: Could not create required temporary file. Exiting.\n" >&2
         exit 1
    fi
    log_debug "Temporary file created: $KEYS_LIST_TMP"

    # --- Argument Parsing ---
    # Call the argument parsing function from lib/cli.sh
    # It will populate the global ACTION and source_key_file variables.
    # It will also handle --help internally and exit if needed.
    # It returns 0 on success, 1 on parsing error (which should trigger help).
    if ! parse_args "$@"; then
        usage # Show help message on parsing error
         exit 1
    fi

    # --- Runtime Initialization Check (Post-Parsing) ---
    log_debug "--- Script Start Checkpoint (Post-Parsing) ---"
    log_debug "Timestamp: $_script_start_time"
    log_debug "Parsed Action: '$ACTION'"
    log_debug "Verbose Logging: '$IS_VERBOSE'"
    log_debug "Source Key File: '${source_key_file:-N/A}'"
    log_debug "Platform: $PLATFORM"
    log_debug "Stat Command: $STAT_CMD"
    log_debug "SSH Directory: $SSH_DIR"
    log_debug "Agent Env File: $AGENT_ENV_FILE"
    log_debug "Valid Key List File: $VALID_KEY_LIST_FILE"
    log_debug "Log Directory: $LOG_DIR"
    log_debug "Log Filename: $LOG_FILENAME"
    log_debug "Log File Path: $LOG_FILE"
    log_debug "Temporary file: $KEYS_LIST_TMP"


    # --- Dispatch Action ---
    log_info "Selected action: $ACTION"

    case $ACTION in
        list)       run_list_keys ;; # Now defined in lib/cli.sh
        add)        run_load_keys ;; # Now defined in lib/cli.sh
        file)       run_load_keys_from_file "$source_key_file" ;; # Now defined in lib/cli.sh
        delete-all) run_delete_all_cli ;; # Now defined in lib/cli.sh
        menu)       run_interactive_menu ;; # Now defined in lib/menu.sh
        help|*)     # Should not be reached if parse_args handles help correctly
                    usage
                    exit 0 ;;
    esac

    # The dispatched action function should handle exiting.
    # If we reach here, something went wrong.
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