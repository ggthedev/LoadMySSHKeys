#!/usr/bin/env bash
# ==============================================================================
# Library: helpers.sh
# Description: Provides miscellaneous helper functions for sshkeymanager.sh.
# ==============================================================================

# --- Safety Check ---
# Ensure this script is sourced, not executed directly.
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "Error: This script (helpers.sh) should be sourced, not executed directly." >&2
    exit 1
fi

# ==============================================================================
# --- Helper Functions ---
# ==============================================================================

# --- setup_platform_vars ---
#
# @description Detects the operating system and sets platform-specific global variables.
#              Currently sets PLATFORM (e.g., "Darwin", "Linux") and STAT_CMD
#              (the command to get file size in bytes).
# @arg        None
# @modifies   Global variables: PLATFORM, STAT_CMD.
# @prints     Nothing.
# @stdout     None.
# @stderr     None.
# @depends    External command: uname, stat.
#             Functions: log_debug.
# ---
setup_platform_vars() {
    log_debug "Detecting platform and setting platform-specific variables..."
    # Detect Operating System (e.g., "Darwin", "Linux").
    PLATFORM=$(uname -s)
    log_debug "Detected PLATFORM: $PLATFORM"

    # Set platform-specific command for getting file size.
    case "$PLATFORM" in
        "Darwin")
            STAT_CMD="stat -f %z" # macOS stat command for size in bytes.
            log_debug "Setting STAT_CMD for Darwin: '$STAT_CMD'"
            ;;
        "Linux")
            STAT_CMD="stat -c %s" # Linux stat command for size in bytes.
            log_debug "Setting STAT_CMD for Linux: '$STAT_CMD'"
            ;;
        *)
            # Default to Linux style for other *nix systems, might need adjustment.
            STAT_CMD="stat -c %s"
            log_warn "Unsupported platform '$PLATFORM'. Defaulting STAT_CMD to Linux style: '$STAT_CMD'"
            ;;
    esac
}
# ==============================================================================
# --- End of Library ---
# ============================================================================== 