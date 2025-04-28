#!/usr/bin/env bash
# Library for argument parsing helper functions for sshkeymanager.sh

# Ensure this script is sourced, not executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "This script should be sourced, not executed directly." >&2
    exit 1
fi

# --- Argument Parsing Helpers ---

# Depends on logging functions (log_debug, log_info)
# Sets global variable: GNU_GETOPT_CMD

# --- _check_gnu_getopt ---
# ... (description omitted for brevity)
_check_gnu_getopt() {
    # Try standard getopt first, test for GNU compatibility
    if getopt --test > /dev/null 2>&1; then
        if [ $? -eq 4 ]; then
            log_debug "Found compatible GNU getopt at: $(command -v getopt)"
            GNU_GETOPT_CMD=$(command -v getopt)
            return 0
        fi
    fi

    local brew_getopt
    for brew_getopt in "/opt/homebrew/opt/gnu-getopt/bin/getopt" "/usr/local/opt/gnu-getopt/bin/getopt"; do
         if [ -x "$brew_getopt" ]; then
             log_debug "Found compatible GNU getopt at: $brew_getopt"
             GNU_GETOPT_CMD="$brew_getopt"
             return 0
         fi
    done

    if command -v gnu-getopt >/dev/null 2>&1; then
        log_debug "Found compatible GNU getopt via command: gnu-getopt"
        GNU_GETOPT_CMD=$(command -v gnu-getopt)
        return 0
    fi

    log_info "GNU getopt not found or incompatible. Simple parser will be used. Recommendation: Install GNU getopt for full argument support (e.g., 'brew install gnu-getopt')."
    return 1
} 