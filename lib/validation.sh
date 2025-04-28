#!/usr/bin/env bash
# Library for validation functions for sshkeymanager.sh

# Ensure this script is sourced, not executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "This script should be sourced, not executed directly." >&2
    exit 1
fi

# --- Validation Functions ---

# Depends on logging functions (log_debug, log_error, log_warn, log_info)
# Depends on global variable: SSH_DIR

# --- validate_directory ---
# ... (description omitted for brevity)
validate_directory() {
    log_debug "Entering function: ${FUNCNAME[0]} (Dir: $1, Desc: $2)"
    local dir="$1"
    local description="$2"
    local return_status=0 # Assume success initially

    if [ ! -d "$dir" ]; then
        log_error "Validation failed: $description directory '$dir' does not exist."
        return_status=1
    else
        if [ ! -r "$dir" ]; then
            log_error "Validation failed: $description directory '$dir' is not readable."
        return_status=1
        fi
        if [ ! -w "$dir" ]; then
            log_error "Validation failed: $description directory '$dir' is not writable."
        return_status=1
        fi
        if [ ! -x "$dir" ]; then
            log_error "Validation failed: $description directory '$dir' is not accessible."
        return_status=1
        fi
    fi

    if [ "$return_status" -eq 0 ]; then
        log_debug "Validation successful for '$dir' ($description)."
    fi
    log_debug "Exiting function: ${FUNCNAME[0]} (Dir: $1, Status: $return_status)"
    return $return_status
}

# --- validate_ssh_dir ---
# ... (description omitted for brevity)
validate_ssh_dir() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Validating SSH directory: $SSH_DIR"
    if ! validate_directory "$SSH_DIR" "SSH"; then
        log_warn "SSH directory '$SSH_DIR' validation failed. Attempting to create..."
        printf "Attempting to create SSH directory '%s'...\n" "$SSH_DIR"
        if ! mkdir -p "$SSH_DIR"; then
            log_error "Failed to create SSH directory '$SSH_DIR'."
            printf "Error: Failed to create SSH directory '%s'. Check permissions.\n" "$SSH_DIR" >&2
            return 1 # Creation failed.
        fi
        log_info "Successfully created SSH directory '$SSH_DIR'."
        printf "Successfully created SSH directory '%s'.\n" "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        log_debug "Set permissions (700) on '$SSH_DIR'."
    fi
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0
} 