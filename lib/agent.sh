# ==============================================================================
# Library: agent.sh
# Description: Provides functions for managing the SSH agent process.
#              Ensures a *dedicated* agent (tracked via AGENT_ENV_FILE) is
#              running and its environment variables are loaded.
# Dependencies: Relies on functions from lib/logging.sh (log_debug, log_info,
#               log_error, log_warn).
#               Relies on global variables AGENT_ENV_FILE, HOME set by the main script.
# ==============================================================================

# --- Safety Check ---
# Ensure this script is sourced, not executed directly.
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "Error: This script (agent.sh) should be sourced, not executed directly." >&2
    exit 1
fi

# ==============================================================================
# --- SSH Agent Management Functions ---
# ==============================================================================

# --- _is_agent_live ---
#
# @description Checks if an SSH agent, identified by its PID and socket path,
#              appears to be running and accessible.
# @arg $1 String The SSH_AGENT_PID to check.
# @arg $2 String The SSH_AUTH_SOCK path to check.
# @return 0 If the PID is running (kill -0 succeeds) AND the socket file exists.
# @return 1 If either the PID is not running or the socket file does not exist.
# @stdout None
# @stderr None (status logged via log_debug).
# @depends Function: log_debug. External command: kill.
# ---
_is_agent_live() {
    local pid="$1"
    local sock="$2"
    log_debug "_is_agent_live: Checking PID='$pid', SOCK='$sock'"

    if [ -z "$pid" ] || [ -z "$sock" ]; then
        log_debug "_is_agent_live: Missing PID or SOCK argument."
        return 1
    # 1. Check if the process with the given PID is running.
    #    `kill -0 $pid` sends signal 0, which checks process existence without killing it.
    #    Redirect stderr to suppress "No such process" messages.
    elif ! kill -0 "$pid" >/dev/null 2>&1; then
        log_debug "_is_agent_live: Agent process PID '$pid' is not running."
        return 1
    # 2. Check if the socket file exists.
    #    Allow regular file (-f) for test mocks, otherwise check for socket (-S).
    elif ! { [ -S "$sock" ] || [ -f "$sock" ]; }; then
        log_debug "_is_agent_live: Agent socket/file '$sock' does not exist."
        return 1
    fi

    # If we reach here, all checks passed
    log_debug "_is_agent_live: Agent PID '$pid' is running and socket/file '$sock' exists."
    return 0
}

# --- _ensure_directory ---
#
# @description Ensures a directory exists and has the specified permissions.
# @arg $1 String Directory path to ensure.
# @arg $2 String Octal permissions (e.g., 700, 600).
# @return 0 If directory exists/created and permissions set successfully.
# @return 1 If creating directory or setting permissions fails.
# @depends Functions: log_error, log_warn. External commands: mkdir, chmod.
# ---
_ensure_directory() {
    local dir_path="$1"
    local permissions="$2"

    if [ -z "$dir_path" ] || [ -z "$permissions" ]; then
        log_error "_ensure_directory: Missing directory path or permissions argument."
        return 1
    fi

    # Create directory if it doesn't exist
    if ! mkdir -p "$dir_path"; then
        log_error "_ensure_directory: Failed to create directory '$dir_path'."
        return 1
    fi

    # Set permissions
    if ! chmod "$permissions" "$dir_path"; then
        # Log warning but don't necessarily fail, maybe it's already correct
        log_warn "_ensure_directory: Failed to set permissions '$permissions' on '$dir_path'."
        # Optionally add a check here if strict permission enforcement is required
    fi

    return 0
}

# --- _parse_agent_output ---
#
# @description Parses the output of 'ssh-agent -s' and exports variables.
# @arg $1 String The output string from 'ssh-agent -s'.
# @modifies Exports SSH_AUTH_SOCK and SSH_AGENT_PID environment variables.
# @return 0 If parsing and export are successful.
# @return 1 If parsing fails or output is missing expected lines.
# @depends Functions: log_info, log_error, log_debug. External commands: echo, grep.
# ---
_parse_agent_output() {
    local agent_output="$1"
    local parsed_agent_sock parsed_agent_pid
    local sock_line pid_line temp_sock temp_pid

    if [ -z "$agent_output" ]; then
        log_error "_parse_agent_output: Received empty agent output."
        return 1
    fi

    # Use parameter expansion for safer parsing
    sock_line=$(echo "$agent_output" | grep '^SSH_AUTH_SOCK=')
    pid_line=$(echo "$agent_output" | grep '^SSH_AGENT_PID=')

    if [ -z "$sock_line" ] || [ -z "$pid_line" ]; then
        log_error "_parse_agent_output: Could not find SSH_AUTH_SOCK or SSH_AGENT_PID lines in output."
        log_debug "ssh-agent output was: $agent_output"
        return 1
    fi

    temp_sock="${sock_line#SSH_AUTH_SOCK=}" ; parsed_agent_sock="${temp_sock%%;*}"
    parsed_agent_sock="${parsed_agent_sock#\'}" ; parsed_agent_sock="${parsed_agent_sock%\'}"

    temp_pid="${pid_line#SSH_AGENT_PID=}" ; parsed_agent_pid="${temp_pid%%;*}"

    # --- Export Parsed Variables ---
    if [ -n "$parsed_agent_sock" ] && [ -n "$parsed_agent_pid" ]; then
        export SSH_AUTH_SOCK="$parsed_agent_sock"
        export SSH_AGENT_PID="$parsed_agent_pid"
        log_info "Extracted and exported new agent details: SOCK=$SSH_AUTH_SOCK PID=$SSH_AGENT_PID"
        return 0
    else
        log_error "Failed to parse SSH_AUTH_SOCK or SSH_AGENT_PID from ssh-agent output."
        log_debug "ssh-agent output was: $agent_output"
        # Unset potentially partially set vars
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        return 1 # Failure: Parsing failed.
    fi
}

# --- _save_agent_env ---
#
# @description Saves the current SSH agent environment variables to a file.
# @arg $1 String The SSH_AUTH_SOCK value.
# @arg $2 String The SSH_AGENT_PID value.
# @arg $3 String The full path to the agent environment file ($AGENT_ENV_FILE).
# @return 0 If saving and setting permissions are successful.
# @return 1 If directory creation or file writing fails.
# @depends Functions: log_debug, log_info, log_error, log_warn, _ensure_directory. External commands: dirname, date, echo, chmod.
# ---
_save_agent_env() {
    local sock="$1"
    local pid="$2"
    local env_file="$3"
    local agent_env_dir

    if [ -z "$sock" ] || [ -z "$pid" ] || [ -z "$env_file" ]; then
        log_error "_save_agent_env: Missing sock, pid, or env_file argument."
        return 1
    fi

    log_debug "Saving agent environment to persistent file: $env_file"
    agent_env_dir=$(dirname "$env_file") # Get the directory part of the path.

    # Ensure the directory exists with user-only permissions (700)
    if ! _ensure_directory "$agent_env_dir" "700"; then
        log_error "Could not ensure directory '$agent_env_dir' for agent environment file '$env_file'. Cannot persist agent."
        # Failure here prevents saving, critical.
        return 1
    fi

    # Write the export commands to the persistent file.
    # Quoting SSH_AUTH_SOCK is good practice.
    if ! {
        echo "# SSH Key Manager Agent Environment"
        echo "# Saved on $(date)"
        echo "SSH_AUTH_SOCK='$sock'; export SSH_AUTH_SOCK;"
        echo "SSH_AGENT_PID=$pid; export SSH_AGENT_PID;"
    } > "$env_file"; then
        log_error "Failed to write agent environment to '$env_file'. Check permissions."
        return 1 # Failure: Writing failed.
    fi

    # Set permissions on the environment file (owner read/write only).
    if ! chmod 600 "$env_file"; then
        log_warn "Failed to set permissions (600) on $env_file"
        # Continue even if chmod fails, maybe permissions are already okay.
    fi

    log_info "Agent environment saved to $env_file."
    return 0
}

# --- _start_new_agent ---
#
# @description Starts a new ssh-agent, parses its output, exports the variables,
#              and saves them to the persistent file $AGENT_ENV_FILE.
# @arg [$1] Boolean Optional quiet mode flag (true/false). Defaults to false.
# @uses Global variable AGENT_ENV_FILE, HOME.
# @modifies Exports SSH_AUTH_SOCK and SSH_AGENT_PID environment variables.
# @modifies Creates or overwrites the $AGENT_ENV_FILE with 600 permissions.
# @modifies Creates $HOME/.ssh directory if it doesn't exist.
# @return 0 If agent starts successfully, variables are exported, and file is saved.
# @return 1 If starting agent, parsing output, or saving file fails.
# @prints Status messages to stdout/stderr unless quiet mode is true.
# @stdout Message indicating agent start (unless quiet).
# @stderr Error messages on failure.
# @depends Functions: log_debug, log_info, log_error, log_warn, _ensure_directory, _parse_agent_output, _save_agent_env.
#             External commands: ssh-agent, mkdir, chmod, echo, grep, sed (or parameter expansion), dirname, date.
# ---
_start_new_agent() {
    local quiet_mode="${1:-false}" # Accept quiet mode flag, default false
    log_info "Starting new ssh-agent..."
    # Only print status if not in quiet mode
    if [[ "$quiet_mode" != true ]]; then
        printf "Starting new ssh-agent...\n"
    fi

    # Ensure the ~/.ssh directory exists with secure permissions.
    if ! _ensure_directory "$HOME/.ssh" "700"; then
        log_error "Failed to ensure $HOME/.ssh directory exists. Cannot start agent reliably."
        return 1 # Failure: Cannot ensure essential directory.
    fi

    # Execute ssh-agent in evaluation mode (-s) to get export commands.
    local agent_output
    set +e # Temporarily disable exit-on-error for the agent command itself
    agent_output=$(ssh-agent -s)
    local agent_exit_code=$?
    set -e # Re-enable exit-on-error

    if [ $agent_exit_code -ne 0 ] || [ -z "$agent_output" ]; then
        log_error "ssh-agent command failed or produced no output (Exit code: $agent_exit_code)."
        return 1 # Failure: ssh-agent command failed.
    fi

    log_debug "ssh-agent raw output: $agent_output"

    # Parse the output and export variables
    if ! _parse_agent_output "$agent_output"; then
        log_error "Failed to parse agent output. Agent start aborted."
        # _parse_agent_output logs details and unsets vars on failure
        return 1 # Failure: Parsing failed.
    fi

    # Save the exported variables to the persistent file
    # SSH_AUTH_SOCK and SSH_AGENT_PID are now exported environment variables
    if ! _save_agent_env "$SSH_AUTH_SOCK" "$SSH_AGENT_PID" "$AGENT_ENV_FILE"; then
        log_error "Failed to save agent environment to '$AGENT_ENV_FILE'."
        # Agent is running and variables are exported, but persistence failed.
        # We consider this a partial success, usable for the current session.
        # Only print warning if not in quiet mode
        if [[ "$quiet_mode" != true ]]; then
            printf "WARNING: Successfully started agent (PID: %s), but failed to save environment to %s\n" \
                   "$SSH_AGENT_PID" "$AGENT_ENV_FILE"
        fi
        return 0 # Return success for session use, despite persistence failure.
    fi

    # All steps successful
    # Only print success message if not in quiet mode
    if [[ "$quiet_mode" != true ]]; then
        printf "Successfully started new ssh-agent (PID: %s) and saved environment.\n" "$SSH_AGENT_PID"
    fi
    return 0 # Success: New agent started, exported, and saved.
}

# --- _parse_agent_env_file ---
#
# @description Reads and parses an agent environment file.
# @arg $1 String Path to the agent environment file.
# @return 0 If parsing is successful. PID and SOCK printed to stdout (PID first, then SOCK).
# @return 1 If file not found, cannot be read, or parsing fails.
# @stdout The parsed PID and SOCK, each on a new line.
# @stderr Error messages via log_debug/log_error.
# @depends Functions: log_debug, log_error. External commands: grep, head, echo, tail.
# ---
_parse_agent_env_file() {
    local env_file="$1"
    local sock_line pid_line temp_sock temp_pid parsed_agent_sock parsed_agent_pid

    if [ ! -f "$env_file" ] || [ ! -r "$env_file" ]; then
        log_debug "_parse_agent_env_file: File not found or not readable: $env_file"
        return 1
    fi

    # Read only the relevant lines to avoid issues with extra content
    # Use head -n 1 in case the variable is somehow defined multiple times
    sock_line=$(grep '^SSH_AUTH_SOCK=' "$env_file" | head -n 1)
    pid_line=$(grep '^SSH_AGENT_PID=' "$env_file" | head -n 1)

    if [ -z "$sock_line" ] || [ -z "$pid_line" ]; then
        log_error "_parse_agent_env_file: Could not find required lines in '$env_file'."
        return 1
    fi

    # Parse SOCK, removing prefix, suffix ';', and potential quotes
    temp_sock="${sock_line#SSH_AUTH_SOCK=}" ; parsed_agent_sock="${temp_sock%%;*}"
    parsed_agent_sock="${parsed_agent_sock#\'}" ; parsed_agent_sock="${parsed_agent_sock%\'}"

    # Parse PID, removing prefix and suffix ';', handling potential quotes is less common but safe
    temp_pid="${pid_line#SSH_AGENT_PID=}" ; parsed_agent_pid="${temp_pid%%;*}"
    parsed_agent_pid="${parsed_agent_pid#\'}" ; parsed_agent_pid="${parsed_agent_pid%\'}"

    if [ -z "$parsed_agent_pid" ] || [ -z "$parsed_agent_sock" ]; then
        log_error "_parse_agent_env_file: Failed to extract valid PID or SOCK from '$env_file'."
        log_debug "SOCK Line: $sock_line | PID Line: $pid_line"
        return 1
    fi

    # Output PID then SOCK, separated by newline
    printf "%s\n%s\n" "$parsed_agent_pid" "$parsed_agent_sock"
    return 0
}

# --- _validate_and_export_agent ---
#
# @description Checks if given PID/SOCK correspond to a live agent and exports them.
# @arg $1 String PID to check.
# @arg $2 String SOCK to check.
# @modifies Exports SSH_AUTH_SOCK and SSH_AGENT_PID if valid.
# @return 0 If agent is live and variables exported.
# @return 1 If arguments missing, invalid, or agent not live.
# @depends Functions: log_debug, log_info, _is_agent_live.
# ---
_validate_and_export_agent() {
    local pid="$1"
    local sock="$2"

    log_debug "_validate_and_export_agent: Validating PID='$pid', SOCK='$sock'"

    # Check if arguments are non-empty and agent is live
    if [ -n "$pid" ] && [ -n "$sock" ] && _is_agent_live "$pid" "$sock"; then
        log_debug "Agent details are valid and agent is live (PID: $pid, SOCK: $sock). Exporting."
        export SSH_AUTH_SOCK="$sock"
        export SSH_AGENT_PID="$pid"
        return 0 # Success
    else
        # Log why it failed (handled by _is_agent_live or implicitly by empty args)
        log_debug "_validate_and_export_agent: Validation failed for PID='$pid', SOCK='$sock'."
        return 1 # Failure
    fi
}

# --- ensure_ssh_agent ---
#
# @description Ensures that a usable SSH agent, managed via $AGENT_ENV_FILE,
#              is running and its environment variables are exported.
#              The behavior depends on the requested mode.
# @arg        $1 String Mode: "load" or "check". (Default: "load")
#                 - "load": If no valid agent is found, start a new one.
#                 - "check": If no valid agent is found, report failure without starting.
# @arg        [$2] Boolean Optional quiet mode flag (true/false). Affects _start_new_agent printf output.
# @uses       Global variables: AGENT_ENV_FILE, SSH_AUTH_SOCK, SSH_AGENT_PID.
# @modifies   Exports SSH_AUTH_SOCK and SSH_AGENT_PID environment variables.
# @modifies   May create or overwrite $AGENT_ENV_FILE (if mode is "load").
# @return     0 If an agent is confirmed running and variables exported.
# @return     1 If mode is "check" and no valid agent found, OR if mode is "load"
#               and starting a new agent fails, OR if mode argument is invalid.
# @prints     Status messages to stdout/stderr (some suppressed by quiet mode).
# @stdout     Informational messages (agent running, connected, started) - some suppressed by quiet mode.
# @stderr     Error messages if agent validation/start fails or mode invalid.
# @depends    Functions: log_info, log_debug, log_warn, log_error, _is_agent_live,
#              _start_new_agent, _parse_agent_env_file, _validate_and_export_agent.
#              External commands: rm, printf, head, tail, echo.
# ---
ensure_ssh_agent() {
    local mode="${1:-load}" # Default to 'load' mode if not specified
    local quiet_mode="${2:-false}" # Accept quiet mode flag, default false
    local agent_found_valid=false
    local file_agent_pid file_agent_sock parsed_output parse_status

    log_debug "ensure_ssh_agent: Starting check in mode '$mode'."

    # --- Validate Mode ---
    if [[ "$mode" != "load" ]] && [[ "$mode" != "check" ]]; then
        log_error "Invalid mode specified for ensure_ssh_agent: '$mode'. Must be 'load' or 'check'."
        printf "Error: Invalid mode '%s' for ensure_ssh_agent.\n" "$mode" >&2
        return 1
    fi

    # --- 1. Check if current environment variables point to a live agent ---
    log_debug "ensure_ssh_agent: Checking current environment variables (PID='${SSH_AGENT_PID:-}', SOCK='${SSH_AUTH_SOCK:-}')."
    if [ -n "${SSH_AGENT_PID:-}" ] && [ -n "${SSH_AUTH_SOCK:-}" ] && _validate_and_export_agent "$SSH_AGENT_PID" "$SSH_AUTH_SOCK"; then
        # Both PID and SOCK are set and validation passed
        log_info "Found live agent via current environment variables."
        agent_found_valid=true
    elif [ -z "${SSH_AGENT_PID:-}" ] && [ -n "${SSH_AUTH_SOCK:-}" ]; then
        # Only SOCK is set, PID is missing
        log_debug "ensure_ssh_agent: Found SSH_AUTH_SOCK ('${SSH_AUTH_SOCK:-}') in environment, but SSH_AGENT_PID is missing. Cannot validate with PID."
        log_debug "ensure_ssh_agent: Unsetting potentially stale environment variables and proceeding."
        unset SSH_AUTH_SOCK SSH_AGENT_PID # Unset both for consistency
    else
        # Covers: Both unset initially, OR both were set but _validate_and_export_agent failed.
        log_debug "ensure_ssh_agent: Current environment variables (PID='${SSH_AGENT_PID:-}', SOCK='${SSH_AUTH_SOCK:-}') are unset or do not point to a live agent."
        # Ensure vars are unset if validation failed or they were incomplete/missing
        unset SSH_AUTH_SOCK SSH_AGENT_PID
    fi

    # --- 2. If no live agent from env, check the persistent file ---
    if [[ "$agent_found_valid" == false ]]; then
        log_debug "ensure_ssh_agent: Checking persistent file '$AGENT_ENV_FILE'."
        # Use command substitution to capture output (PID\nSOCK)
        parsed_output=$(_parse_agent_env_file "$AGENT_ENV_FILE")
        parse_status=$? # Capture exit status of the parsing function

        if [ $parse_status -eq 0 ] && [ -n "$parsed_output" ]; then
            # Extract PID and SOCK (PID is first line, SOCK is second)
            file_agent_pid=$(echo "$parsed_output" | head -n 1)
            file_agent_sock=$(echo "$parsed_output" | tail -n 1)
            log_debug "ensure_ssh_agent: Parsed from file: PID='$file_agent_pid', SOCK='$file_agent_sock'."

            # Validate the parsed details
            if _validate_and_export_agent "$file_agent_pid" "$file_agent_sock"; then
                log_info "Found live agent via persistent file '$AGENT_ENV_FILE'."
                agent_found_valid=true
            else
                log_warn "Agent details in '$AGENT_ENV_FILE' are invalid or agent is not live. Removing stale file."
                rm -f "$AGENT_ENV_FILE" 2>/dev/null || log_warn "Failed to remove stale agent file: $AGENT_ENV_FILE"
                # Ensure vars are unset if they came from the stale file
                unset SSH_AUTH_SOCK SSH_AGENT_PID
            fi
        elif [ -f "$AGENT_ENV_FILE" ]; then
            # Parsing failed, but file existed - likely corrupt, remove it.
             log_warn "Failed to parse existing agent file '$AGENT_ENV_FILE'. Removing potentially corrupt file."
             rm -f "$AGENT_ENV_FILE" 2>/dev/null || log_warn "Failed to remove corrupt agent file: $AGENT_ENV_FILE"
             unset SSH_AUTH_SOCK SSH_AGENT_PID
        else
             log_info "Persistent agent file '$AGENT_ENV_FILE' not found."
             unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    fi

    # --- 3. Action based on validation result and mode ---
    if [[ "$agent_found_valid" == true ]]; then
        log_debug "ensure_ssh_agent: Existing valid agent confirmed. Returning success."
        # Only print success message if not in quiet mode
        if [[ "$quiet_mode" != true ]]; then
            printf "SSH Agent ready (PID: %s)\n" "$SSH_AGENT_PID" # Consistent user feedback
        fi
        return 0 # Success: Valid agent found and loaded.
    fi

    # If we get here, no valid agent was found.
    log_info "No valid existing agent found."

    case "$mode" in
        load)
            # Mode requires loading/starting an agent.
            log_info "Mode is 'load', attempting to start a new agent..."
            # Pass the quiet_mode flag to _start_new_agent
            if _start_new_agent "$quiet_mode"; then
                # _start_new_agent already exported vars, saved file, and potentially printed success
                log_info "New agent started and environment configured successfully."
                return 0 # Success: New agent started.
            else
                log_error "Failed to start and configure a new SSH agent."
                printf "Error: Failed to start or configure ssh-agent.\n" >&2
                return 1 # Failure: Could not start agent.
            fi
            ;;

        check)
            # Mode only requires checking; no valid agent found, so report failure.
            log_info "Mode is 'check', no valid agent found. Reporting agent unavailable."
            # Only print failure message if not in quiet mode
            if [[ "$quiet_mode" != true ]]; then
                printf "No active SSH Agent found.\n" >&2 # Inform user in check mode
            fi
            return 1 # Failure: No agent available for check.
            ;;

        *)
            # Should be unreachable due to initial mode validation, but handle defensively.
            log_error "Internal error: Reached action block with unexpected mode '$mode'."
            printf "Internal Error: Invalid mode '%s' encountered processing action.\n" "$mode" >&2
            return 1
            ;;
    esac # End of case statement

} # END ensure_ssh_agent

# ==============================================================================
# --- End of Library ---
# ==============================================================================