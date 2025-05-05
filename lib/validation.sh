#!/usr/bin/env bash
# ==============================================================================
# Library: validation.sh
# Description: Provides directory validation functions for sshkeymanager.sh.
# Dependencies: Relies on functions from lib/logging.sh (log_debug, log_error,
#               log_warn, log_info).
#               Relies on global variable SSH_DIR set by the main script.
# ==============================================================================

# --- Safety Check ---
# Ensure this script is sourced, not executed directly.
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "Error: This script (validation.sh) should be sourced, not executed directly." >&2
    exit 1
fi

# ==============================================================================
# --- Validation Functions ---
# ==============================================================================

# --- validate_directory ---
#
# @description Checks if a given directory path exists and has the necessary
#              read, write, and execute permissions.
# @arg         $1 String Path to the directory to validate.
# @arg         $2 String A descriptive name for the directory type (e.g., "SSH", "Log")
#             used in log messages.
# @return     0 If the directory exists and has read, write, and execute permissions.
# @return     1 If the directory does not exist or lacks any of the required permissions.
# @stdout     None
# @stderr     None (Errors are logged using logging functions).
# @depends    Functions: log_debug, log_error.
# ---
validate_directory() {
    # Log function entry with arguments for easier debugging.
    log_debug "Entering function: ${FUNCNAME[0]} (Dir: '$1', Desc: '$2')"

    # Assign arguments to local variables for clarity.
    local dir="$1"
    local description="$2"
    local return_status=0 # Initialize return status to 0 (success).

    # Check if the path exists and is a directory.
    if [ ! -d "$dir" ]; then
        # If not a directory, log an error and set return status to failure.
        log_error "Validation failed: $description directory '$dir' does not exist."
        return_status=1
    else
        # If it is a directory, proceed to check permissions.
        # Check for read permission.
        if [ ! -r "$dir" ]; then
            log_error "Validation failed: $description directory '$dir' is not readable."
            return_status=1
        fi
        # Check for write permission.
        # Note: Write permission might not always be strictly necessary for all calling functions,
        # but is included here for a general-purpose directory validation.
        if [ ! -w "$dir" ]; then
            log_error "Validation failed: $description directory '$dir' is not writable."
            return_status=1
        fi
        # Check for execute permission (required to access/traverse the directory).
        if [ ! -x "$dir" ]; then
            log_error "Validation failed: $description directory '$dir' is not accessible (execute permission missing)."
            return_status=1
        fi
    fi

    # Log success message if all checks passed.
    if [ "$return_status" -eq 0 ]; then
        log_debug "Validation successful for '$dir' ($description)."
    fi

    # Log function exit with the final status.
    log_debug "Exiting function: ${FUNCNAME[0]} (Dir: '$1', Status: $return_status)"
    return $return_status # Return the final status code.
}

# --- validate_ssh_dir ---
#
# @description Validates the primary SSH directory specified by the global $SSH_DIR.
#              If the directory doesn't exist, it attempts to create it and set
#              appropriate permissions (700).
# @arg        None
# @uses       Global variable: SSH_DIR.
# @return     0 If the SSH directory exists (or is successfully created) and is valid.
# @return     1 If the directory is invalid and cannot be created.
# @prints     Status messages to stdout/stderr regarding directory creation attempt.
# @stdout     Informational message if directory is created.
# @stderr     Error message if directory creation fails.
# @depends    Functions: validate_directory, log_debug, log_info, log_warn, log_error.
#             External commands: mkdir, chmod, printf.
# ---
validate_ssh_dir() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Validating SSH directory: $SSH_DIR"

    # Call the general validate_directory function to check the SSH directory.
    if ! validate_directory "$SSH_DIR" "SSH"; then
        # If validation fails (e.g., doesn't exist or bad permissions), attempt creation.
        log_warn "SSH directory '$SSH_DIR' validation failed. Attempting to create..."
        printf "Attempting to create SSH directory '%s'...\n" "$SSH_DIR"

        # Try creating the directory, including parent directories if needed (-p).
        if ! mkdir -p "$SSH_DIR"; then
            # If creation fails, log and print an error, then return failure status.
            log_error "Failed to create SSH directory '$SSH_DIR'. Check parent directory permissions."
            printf "Error: Failed to create SSH directory '%s'. Check permissions.\n" "$SSH_DIR" >&2
            return 1 # Indicate failure.
        fi

        # If creation succeeds, log and print success message.
        log_info "Successfully created SSH directory '$SSH_DIR'."
        printf "Successfully created SSH directory '%s'.\n" "$SSH_DIR"

        # Set restrictive permissions (owner read/write/execute only) on the new directory.
        chmod 700 "$SSH_DIR"
        log_debug "Set permissions (700) on newly created '$SSH_DIR'."
        # If creation and chmod succeed, proceed as if validation passed.
    fi

    # If validation passed initially or creation succeeded, log exit and return success.
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0 # Indicate success.
}
# ==============================================================================
# --- End of Library ---
# ==============================================================================
