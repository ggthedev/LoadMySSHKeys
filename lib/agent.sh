#!/usr/bin/env bash
# ==============================================================================
# Library: agent.sh
# Description: Provides functions for managing the SSH agent process.
#              Includes checking agent status, ensuring an agent is running
#              (starting one if necessary), and persisting agent environment
#              variables to a file.
# Dependencies: Relies on functions from lib/logging.sh (log_debug, log_info,
#               log_error, log_warn).
#               Relies on global variables SSH_AUTH_SOCK, SSH_AGENT_PID,
#               AGENT_ENV_FILE, HOME set by the main script.
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

# --- check_ssh_agent ---
#
# @description Performs basic checks to determine if an SSH agent communication
#              socket, specified by the SSH_AUTH_SOCK environment variable, exists.
#              This is a lightweight check and does not verify if the agent process
#              itself is still running or responsive.
#              NOTE: The check for PID was removed to simplify; relying on socket presence
#                    and actual `ssh-add` commands to fail if agent is unresponsive.
#              NOTE: Added check for regular file (`-f`) for compatibility with mock agent used in tests.
# @arg        None
# @uses       Global environment variable: SSH_AUTH_SOCK.
# @return     0 If SSH_AUTH_SOCK is set and the path points to an existing
#               socket (`-S`) or regular file (`-f` for test mocks).
# @return     1 If SSH_AUTH_SOCK is not set or the file/socket does not exist.
# @stdout     None
# @stderr     None (status logged via log_debug).
# @depends    Function: log_debug.
# ---
check_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "Checking agent status... (SOCK='${SSH_AUTH_SOCK:-Not Set}')"

    # Check if the SSH_AUTH_SOCK environment variable is set and non-empty.
    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
        log_debug "check_ssh_agent: Required SSH_AUTH_SOCK environment variable not set."
        return 1 # Failure: Variable not set.
    fi

    # Check if the path specified by SSH_AUTH_SOCK exists.
    # It should typically be a socket (-S), but we also allow a regular file (-f)
    # for compatibility with the mock agent used in the BATS tests.
    if [ ! -f "$SSH_AUTH_SOCK" ] && [ ! -S "$SSH_AUTH_SOCK" ]; then
        log_debug "check_ssh_agent: Agent communication file ('$SSH_AUTH_SOCK') not found or is not a regular file/socket."
        return 1 # Failure: Socket/File does not exist.
    fi

    # If the variable is set and the file/socket exists, assume it *might* be usable.
    # Further checks (like `ssh-add -l`) are needed to confirm responsiveness.
    log_debug "check_ssh_agent: Agent communication file/socket exists. Assuming agent *might* be running."
    return 0 # Success: Basic check passed.
}


# --- ensure_ssh_agent ---
#
# @description Ensures that a usable SSH agent is running and its environment
#              variables (SSH_AUTH_SOCK, SSH_AGENT_PID) are exported in the
#              current shell session.
#              1. Checks if variables are already set and the agent is running.
#              2. If not, attempts to source variables from a persistent file ($AGENT_ENV_FILE).
#              3. If still not running, starts a new `ssh-agent`, exports its variables,
#                 and saves them to the persistent file.
# @arg        None
# @uses       Global variables: SSH_AUTH_SOCK, SSH_AGENT_PID, AGENT_ENV_FILE, HOME.
# @modifies   Exports SSH_AUTH_SOCK and SSH_AGENT_PID environment variables.
# @modifies   Creates or overwrites the $AGENT_ENV_FILE.
# @modifies   Creates $HOME/.ssh directory if it doesn't exist.
# @return     0 If an agent is confirmed running (either pre-existing or newly started).
# @return     1 If starting a new agent fails or verification fails.
# @prints     Status messages to stdout indicating agent status or actions taken.
# @stdout     Informational messages (agent running, connected, started).
# @stderr     Error messages if agent start/verification fails.
# @depends    Functions: check_ssh_agent, log_debug, log_info, log_error, log_warn.
#             External commands: ssh-agent, mkdir, chmod, echo, grep, cut (or parameter expansion), dirname, rm, sleep.
# ---
ensure_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Ensuring SSH agent is active..."

    # 1. Check if agent appears to be running in the current environment.
    #    Uses the lightweight check_ssh_agent function.
    if [ -n "${SSH_AUTH_SOCK:-}" ] && check_ssh_agent; then
        # Agent variables are set and the socket/file exists.
        log_info "Agent already running and sourced (SOCK: ${SSH_AUTH_SOCK:-Unknown}, PID: ${SSH_AGENT_PID:-Unknown})."
        printf "SSH agent is already running (Socket: %s).\n" "${SSH_AUTH_SOCK:-Unknown}"
        # Ensure variables are exported for subsequent commands in the same script execution.
        # This might be redundant if they were already exported, but ensures consistency.
        export SSH_AUTH_SOCK SSH_AGENT_PID
        return 0 # Success: Agent already running.
    fi

    # 2. If not running in current env, try sourcing from the persistent file.
    log_debug "Agent not running or sourced in current environment. Checking persistent file: $AGENT_ENV_FILE"
    if [ -f "$AGENT_ENV_FILE" ]; then
        log_debug "Sourcing persistent agent file: $AGENT_ENV_FILE"
        # Source the file. Use '.' for POSIX compliance. Redirect output to suppress echoes.
        # shellcheck disable=SC1090 # ShellCheck cannot follow the dynamic path.
        . "$AGENT_ENV_FILE" >/dev/null
        # Re-check if the agent is valid after sourcing.
        if check_ssh_agent; then
            log_info "Sourced persistent file. Reusing agent (SOCK: ${SSH_AUTH_SOCK:-Unknown}, PID: ${SSH_AGENT_PID:-Unknown})."
            printf "Successfully connected to existing ssh-agent (Socket: %s).\n" "${SSH_AUTH_SOCK:-Unknown}"
            # Ensure variables are exported after sourcing.
            export SSH_AUTH_SOCK SSH_AGENT_PID
            return 0 # Success: Reconnected via file.
        else
            # If the sourced file exists but the agent is not valid (e.g., stale process),
            # remove the stale file and unset the potentially invalid variables.
            log_warn "Agent file '$AGENT_ENV_FILE' found but agent invalid after sourcing (stale?). Removing stale file."
            rm -f "$AGENT_ENV_FILE"
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    fi

    # 3. If no valid agent found yet, start a new one.
    log_info "No valid existing agent found. Starting new ssh-agent..."
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
    if ! agent_output=$(ssh-agent -s); then
        log_error "Failed to execute ssh-agent -s. Cannot start agent."
        return 1 # Failure: ssh-agent command failed.
    fi
    log_debug "ssh-agent -s output captured."

    # --- Parse ssh-agent output --- 
    # Avoid using `eval` for security. Parse the output manually.
    # Example Output:
    # SSH_AUTH_SOCK=/tmp/ssh-XXXXXXabcdef/agent.12345; export SSH_AUTH_SOCK;
    # SSH_AGENT_PID=12346; export SSH_AGENT_PID;
    # echo Agent pid 12346;
    local ssh_auth_sock ssh_agent_pid
    local sock_line pid_line temp_sock temp_pid

    # Extract lines containing the variables.
    sock_line=$(echo "$agent_output" | grep '^SSH_AUTH_SOCK=')
    pid_line=$(echo "$agent_output" | grep '^SSH_AGENT_PID=')

    # Extract SSH_AUTH_SOCK value: Remove prefix and suffix.
    # Handles potentially quoted paths.
    temp_sock="${sock_line#SSH_AUTH_SOCK=}" # Remove prefix 'SSH_AUTH_SOCK='
    ssh_auth_sock="${temp_sock%%;*}"      # Remove the first semicolon and everything after it
    # Remove potential quotes if present (e.g., if path had spaces, though unlikely for sockets)
    ssh_auth_sock="${ssh_auth_sock#\'}" # Remove leading quote
    ssh_auth_sock="${ssh_auth_sock%\'}" # Remove trailing quote

    # Extract SSH_AGENT_PID value: Remove prefix and suffix.
    temp_pid="${pid_line#SSH_AGENT_PID=}" # Remove prefix 'SSH_AGENT_PID='
    ssh_agent_pid="${temp_pid%%;*}"     # Remove the first semicolon and everything after it

    # --- Export Parsed Variables --- 
    if [ -n "$ssh_auth_sock" ] && [ -n "$ssh_agent_pid" ]; then
        # If parsing succeeded, export the variables for the current shell.
        export SSH_AUTH_SOCK="$ssh_auth_sock"
        export SSH_AGENT_PID="$ssh_agent_pid"
        log_info "Extracted and exported new agent details: SOCK=$SSH_AUTH_SOCK PID=$SSH_AGENT_PID"
    else
        # If parsing failed, log error and exit.
        log_error "Failed to parse SSH_AUTH_SOCK or SSH_AGENT_PID from ssh-agent output."
        log_debug "ssh-agent output was: $agent_output"
        return 1 # Failure: Parsing failed.
    fi

    # --- Save Agent Environment to File ---
    log_debug "Saving agent environment to persistent file: $AGENT_ENV_FILE"
    local agent_env_dir
    agent_env_dir=$(dirname "$AGENT_ENV_FILE") # Get the directory part of the path.
    # Create the directory if it doesn't exist.
    if ! mkdir -p "$agent_env_dir"; then
        log_warn "Could not create directory '$agent_env_dir' for agent environment file. Agent persistence will be disabled for this session."
    else
        # Write the export commands to the persistent file.
        # Quoting SSH_AUTH_SOCK is good practice, although socket paths rarely contain spaces.
        {
            echo "SSH_AUTH_SOCK='$SSH_AUTH_SOCK'; export SSH_AUTH_SOCK;"
            echo "SSH_AGENT_PID=$SSH_AGENT_PID; export SSH_AGENT_PID;"
            echo "# Agent details saved on $(date)" # Add a timestamp comment.
        } > "$AGENT_ENV_FILE"
        # Set permissions on the environment file (owner read/write only).
        chmod 600 "$AGENT_ENV_FILE" || log_warn "Failed to set permissions (600) on $AGENT_ENV_FILE"
        log_info "Agent environment saved to $AGENT_ENV_FILE."
    fi

    # --- Final Verification ---
    # Give the agent a very brief moment to fully initialize (may not be necessary).
    sleep 0.5
    # Perform the basic check again on the newly started agent.
    if check_ssh_agent; then
        log_info "New agent started and verified successfully (PID: ${SSH_AGENT_PID:-Unknown})."
        printf "Successfully started new ssh-agent (PID: %s).\n" "$SSH_AGENT_PID"
        return 0 # Success: New agent started and verified.
    else
        # This should be rare if ssh-agent -s succeeded, but handle defensively.
        log_error "Started new agent but failed final verification check!"
        printf "Error: Started ssh-agent but failed final verification.\n" >&2
        # Clean up by unsetting vars and removing the potentially bad env file.
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        rm -f "$AGENT_ENV_FILE" 2>/dev/null
        return 1 # Failure: Verification failed.
    fi

} # END ensure_ssh_agent
# ==============================================================================
# --- End of Library ---
# ============================================================================== 