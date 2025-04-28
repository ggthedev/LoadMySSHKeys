#!/usr/bin/env bash
# ==============================================================================
# Library: arg_helpers.sh
# Description: Provides helper functions related to command-line argument parsing
#              for sshkeymanager.sh.
# Dependencies: Relies on functions from lib/logging.sh (log_debug, log_info).
#               Sets the global variable GNU_GETOPT_CMD used by the main script.
# ==============================================================================

# --- Safety Check ---
# Ensure this script is sourced, not executed directly.
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "Error: This script (arg_helpers.sh) should be sourced, not executed directly." >&2
    exit 1
fi

# ==============================================================================
# --- Argument Parsing Helper Functions ---
# ==============================================================================

# --- _check_gnu_getopt ---
#
# @description Checks for a compatible (GNU-enhanced) `getopt` command available
#              on the system. GNU `getopt` supports long options and option
#              permutation, which are desirable features for complex CLIs.
#              It sets the global `GNU_GETOPT_CMD` variable to the path of the
#              found command if successful.
# @arg        None
# @set        GNU_GETOPT_CMD Global variable containing the path to the compatible
#             `getopt` executable if found. Remains unset otherwise.
# @return     0 If a compatible GNU `getopt` is found.
# @return     1 If no compatible GNU `getopt` is found after checking standard
#               paths, Homebrew paths, and common alternative names.
# @prints     None
# @stdout     None
# @stderr     None (Info message logged if not found).
# @depends    Functions: log_debug, log_info.
#             External commands: getopt, command.
# ---
_check_gnu_getopt() {
    # Temporarily disable exit on error within this function
    # to prevent script termination if getopt tests fail.
    set +e
    log_debug "Entering function: _check_gnu_getopt"

    # Reset the global variable
    GNU_GETOPT_CMD=""

    local ret_status=1 # Default return status (failure)

    # 1. Try the standard `getopt` command first.
    #    GNU getopt has a specific test mode (`--test`) that exits with status 4.
    #    Redirect output/error streams to prevent clutter.
    if getopt --test > /dev/null 2>&1; then
        # Check the exit status ($?) immediately after the command.
        if [ $? -eq 4 ]; then
            # Exit status 4 indicates GNU getopt compatibility.
            local cmd_path
            cmd_path=$(command -v getopt) # Get the full path.
            log_debug "Found compatible GNU getopt via standard command: $cmd_path"
            GNU_GETOPT_CMD="$cmd_path" # Set the global variable.
            ret_status=0 # Mark as success.
        else
            # If exit status is not 4, the standard getopt is not GNU-compatible.
            log_debug "Standard 'getopt' command found but is not GNU-compatible (exit status: $?)"
        fi
    else
        log_debug "Standard 'getopt' command not found or '--test' failed"
    fi

    # 2. If standard `getopt` isn't GNU and we haven't succeeded yet, check common Homebrew paths.
    if [ "$ret_status" -ne 0 ]; then
        local brew_getopt_path
        local potential_paths=("/opt/homebrew/opt/gnu-getopt/bin/getopt" "/usr/local/opt/gnu-getopt/bin/getopt")
        for brew_getopt_path in "${potential_paths[@]}"; do
            # Check if the file exists and is executable (-x).
            if [ -x "$brew_getopt_path" ]; then
                log_debug "Found compatible GNU getopt at Homebrew path: $brew_getopt_path"
                GNU_GETOPT_CMD="$brew_getopt_path" # Set the global variable.
                ret_status=0 # Mark as success.
                break # Exit loop once found
            fi
        done
        if [ "$ret_status" -ne 0 ]; then
            log_debug "Checked standard Homebrew paths for gnu-getopt, none found or executable"
        fi
    fi

    # 3. If still not found, check if `gnu-getopt` is directly available in the PATH.
    if [ "$ret_status" -ne 0 ]; then
        if command -v gnu-getopt >/dev/null 2>&1; then
            local cmd_path
            cmd_path=$(command -v gnu-getopt)
            log_debug "Found compatible GNU getopt via command name: gnu-getopt (Path: $cmd_path)"
            GNU_GETOPT_CMD="$cmd_path" # Set the global variable.
            ret_status=0 # Mark as success.
        fi
    fi

    # 4. Log final status and restore set -e if it was originally set.
    if [ "$ret_status" -ne 0 ]; then
        log_info "Compatible GNU getopt command not found. The script will use a simpler fallback parser. Some advanced command-line features might be unavailable. Recommendation: Install GNU getopt for full argument support (e.g., 'brew install gnu-getopt' on macOS)."
    fi

    # Restore errexit. Assume the main script runs with set -e.
    set -e

    return "$ret_status"
} # END _check_gnu_getopt
# ==============================================================================
# --- End of Library ---
# ==============================================================================