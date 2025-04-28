#!/usr/bin/env bash
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
    fi

    # 1. Check if the process with the given PID is running.
    #    `kill -0 $pid` sends signal 0, which checks process existence without killing it.
    #    Redirect stderr to suppress "No such process" messages.
    if ! kill -0 "$pid" >/dev/null 2>&1; then
        log_debug "_is_agent_live: Agent process PID '$pid' is not running."
        return 1
    fi

    # 2. Check if the socket file exists.
    #    Allow regular file (-f) for test mocks, otherwise check for socket (-S).
    if [ ! -S "$sock" ] && [ ! -f "$sock" ]; then
        log_debug "_is_agent_live: Agent socket '$sock' does not exist or is not a socket/file."
        return 1
    fi

    log_debug "_is_agent_live: Agent PID '$pid' is running and socket '$sock' exists."
    return 0 # Both checks passed.
}

# --- _start_new_agent ---
#
# @description Starts a new ssh-agent, parses its output, exports the variables,
#              and saves them to the persistent file $AGENT_ENV_FILE.
# @arg None
# @uses Global variable AGENT_ENV_FILE, HOME.
# @modifies Exports SSH_AUTH_SOCK and SSH_AGENT_PID environment variables.
# @modifies Creates or overwrites the $AGENT_ENV_FILE with 600 permissions.
# @modifies Creates $HOME/.ssh directory if it doesn't exist.
# @return 0 If agent starts successfully, variables are exported, and file is saved.
# @return 1 If starting agent, parsing output, or saving file fails.
# @prints Status messages to stdout/stderr.
# @stdout Message indicating agent start.
# @stderr Error messages on failure.
# @depends Functions: log_debug, log_info, log_error, log_warn.
#             External commands: ssh-agent, mkdir, chmod, echo, grep, sed (or parameter expansion), dirname, date.
# ---
_start_new_agent() {
    log_info "Starting new ssh-agent..."
    printf "Starting new ssh-agent...\n"

    # Ensure the ~/.ssh directory exists, as ssh-agent might need it.
    if ! mkdir -p "$HOME/.ssh"; then
        log_error "Failed to create $HOME/.ssh directory. Cannot start agent."
        return 1 # Failure: Cannot create essential directory.
    fi
    # Set permissions on ~/.ssh directory (owner read/write/execute only).
    chmod 700 "$HOME/.ssh" || log_warn "Failed to set permissions (700) on $HOME/.ssh"

    # Execute ssh-agent in evaluation mode (-s) to get export commands.
    local agent_output
    # Temporarily disable exit-on-error for the agent command itself
    set +e
    agent_output=$(ssh-agent -s)
    local agent_status=$?
    set -e # Re-enable exit on error

    if [ $agent_status -ne 0 ]; then
        log_error "Failed to execute ssh-agent -s (Status: $agent_status). Cannot start agent."
        return 1 # Failure: ssh-agent command failed.
    fi
    log_debug "ssh-agent -s output captured."

    # --- Parse ssh-agent output --- 
    local parsed_agent_sock parsed_agent_pid
    local sock_line pid_line temp_sock temp_pid

    # Use parameter expansion for safer parsing
    sock_line=$(echo "$agent_output" | grep '^SSH_AUTH_SOCK=')
    pid_line=$(echo "$agent_output" | grep '^SSH_AGENT_PID=')

    temp_sock="${sock_line#SSH_AUTH_SOCK=}" ; parsed_agent_sock="${temp_sock%%;*}"
    parsed_agent_sock="${parsed_agent_sock#\'}" ; parsed_agent_sock="${parsed_agent_sock%\'}"

    temp_pid="${pid_line#SSH_AGENT_PID=}" ; parsed_agent_pid="${temp_pid%%;*}"

    # --- Export Parsed Variables --- 
    if [ -n "$parsed_agent_sock" ] && [ -n "$parsed_agent_pid" ]; then
        export SSH_AUTH_SOCK="$parsed_agent_sock"
        export SSH_AGENT_PID="$parsed_agent_pid"
        log_info "Extracted and exported new agent details: SOCK=$SSH_AUTH_SOCK PID=$SSH_AGENT_PID"
    else
        log_error "Failed to parse SSH_AUTH_SOCK or SSH_AGENT_PID from ssh-agent output."
        log_debug "ssh-agent output was: $agent_output"
        # Unset potentially partially set vars
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        return 1 # Failure: Parsing failed.
    fi

    # --- Save Agent Environment to File ---
    log_debug "Saving agent environment to persistent file: $AGENT_ENV_FILE"
    local agent_env_dir
    agent_env_dir=$(dirname "$AGENT_ENV_FILE") # Get the directory part of the path.
    if ! mkdir -p "$agent_env_dir"; then
        log_error "Could not create directory '$agent_env_dir' for agent environment file '$AGENT_ENV_FILE'. Cannot persist agent."
        # Agent is running, but persistence failed. Return success but log error.
        return 0 # Still usable for this session, but log the error.
    fi

    # Write the export commands to the persistent file.
    # Quoting SSH_AUTH_SOCK is good practice.
    if ! {
        echo "# SSH Key Manager Agent Environment"
        echo "# Saved on $(date)"
        echo "SSH_AUTH_SOCK='$SSH_AUTH_SOCK'; export SSH_AUTH_SOCK;"
        echo "SSH_AGENT_PID=$SSH_AGENT_PID; export SSH_AGENT_PID;"
    } > "$AGENT_ENV_FILE"; then
        log_error "Failed to write agent environment to '$AGENT_ENV_FILE'. Check permissions."
        # Agent is running, but persistence failed. Return success but log error.
        return 0 # Still usable for this session, but log the error.
    fi

    # Set permissions on the environment file (owner read/write only).
    chmod 600 "$AGENT_ENV_FILE" || log_warn "Failed to set permissions (600) on $AGENT_ENV_FILE"
    log_info "Agent environment saved to $AGENT_ENV_FILE."

    printf "Successfully started new ssh-agent (PID: %s).\n" "$SSH_AGENT_PID"
    return 0 # Success: New agent started and saved.
}

# --- ensure_ssh_agent ---
#
# @description Ensures that a usable SSH agent, managed via $AGENT_ENV_FILE,
#              is running and its environment variables are exported.
#              1. Checks if variables are set in current env AND agent is live.
#              2. If not, attempts to load from $AGENT_ENV_FILE and validate.
#              3. If file invalid/stale or doesn't exist, starts a new agent
#                 and saves its details to $AGENT_ENV_FILE.
# @arg        None
# @uses       Global variables: AGENT_ENV_FILE.
# @modifies   Exports SSH_AUTH_SOCK and SSH_AGENT_PID environment variables.
# @modifies   May create or overwrite $AGENT_ENV_FILE.
# @return     0 If an agent is confirmed running and variables exported.
# @return     1 If validating or starting an agent fails.
# @prints     Status messages to stdout/stderr.
# @stdout     Informational messages (agent running, connected, started).
# @stderr     Error messages if agent validation/start fails.
# @depends    Functions: _is_agent_live, _start_new_agent, log_debug, log_info, log_error, log_warn.
#             External commands: rm, echo, grep, sed (or parameter expansion).
# ---
ensure_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Ensuring dedicated SSH agent (via $AGENT_ENV_FILE) is active..."

    # 1. Check if agent appears live based on CURRENT environment variables.
    #    This handles the case where the script is run multiple times in the same
    #    shell where a previous invocation already exported the variables.
    if [ -n "${SSH_AGENT_PID:-}" ] && [ -n "${SSH_AUTH_SOCK:-}" ]; then
        log_debug "Found agent vars in current env (PID: $SSH_AGENT_PID, SOCK: $SSH_AUTH_SOCK). Validating liveness..."
        if _is_agent_live "$SSH_AGENT_PID" "$SSH_AUTH_SOCK"; then
            log_info "Agent from current environment is live and ready."
            printf "SSH agent is already running (PID: %s, Socket: %s).\n" "$SSH_AGENT_PID" "$SSH_AUTH_SOCK"
            # Ensure they are exported just in case
            export SSH_AUTH_SOCK SSH_AGENT_PID
            return 0 # Success: Agent from env is live.
        else
            log_info "Agent vars found in current env, but agent is not live (PID: $SSH_AGENT_PID, SOCK: $SSH_AUTH_SOCK). Will check/update file."
            # Unset stale vars from env before proceeding
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    fi

    # 2. If not live in current env, check the persistent file.
    log_debug "Checking persistent agent file: $AGENT_ENV_FILE"
    if [ -f "$AGENT_ENV_FILE" ]; then
        log_debug "Persistent file exists. Parsing and validating..."
        local file_agent_sock file_agent_pid

        # Parse variables directly from the file without fully sourcing
        # Use grep and parameter expansion for safety
        local sock_line pid_line temp_sock temp_pid
        sock_line=$(grep '^SSH_AUTH_SOCK=' "$AGENT_ENV_FILE")
        pid_line=$(grep '^SSH_AGENT_PID=' "$AGENT_ENV_FILE")

        temp_sock="${sock_line#SSH_AUTH_SOCK=}" ; file_agent_sock="${temp_sock%%;*}"
        file_agent_sock="${file_agent_sock#\'}" ; file_agent_sock="${file_agent_sock%\'}"

        temp_pid="${pid_line#SSH_AGENT_PID=}" ; file_agent_pid="${temp_pid%%;*}"

        log_debug "Parsed from file: PID='$file_agent_pid', SOCK='$file_agent_sock'"

        # Validate the agent details found in the file
        if [ -n "$file_agent_pid" ] && [ -n "$file_agent_sock" ] && _is_agent_live "$file_agent_pid" "$file_agent_sock"; then
            # Agent from file is live! Export vars and return.
            log_info "Agent details from file '$AGENT_ENV_FILE' are valid and agent is live."
            printf "Successfully connected to existing ssh-agent (PID: %s, Socket: %s).\n" "$file_agent_pid" "$file_agent_sock"
            export SSH_AUTH_SOCK="$file_agent_sock"
            export SSH_AGENT_PID="$file_agent_pid"
            return 0 # Success: Reconnected via file.
        else
            log_warn "Agent details in '$AGENT_ENV_FILE' are invalid or agent is not live (PID: '$file_agent_pid', SOCK: '$file_agent_sock'). Removing stale file."
            rm -f "$AGENT_ENV_FILE" 2>/dev/null || log_warn "Failed to remove stale agent file: $AGENT_ENV_FILE"
            # Ensure vars are unset if they came from the stale file
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    else
         log_info "Persistent agent file '$AGENT_ENV_FILE' not found."
    fi

    # 3. If no valid agent found yet (env or file), start a new one.
    if _start_new_agent; then
        # _start_new_agent already exported vars and saved file
        log_info "New agent started and environment configured successfully."
        return 0 # Success: New agent started.
    else
        log_error "Failed to start and configure a new SSH agent."
        printf "Error: Failed to start or configure ssh-agent.\n" >&2
        return 1 # Failure: Could not start agent.
    fi

} # END ensure_ssh_agent

# --- check_ssh_agent --- (Deprecated / Removed)
# The logic is now integrated into _is_agent_live and ensure_ssh_agent.

# ==============================================================================
# --- End of Library ---
# ============================================================================== 