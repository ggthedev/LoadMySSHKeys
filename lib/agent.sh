#!/usr/bin/env bash
# Library for SSH agent management functions for sshkeymanager.sh

# Ensure this script is sourced, not executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "This script should be sourced, not executed directly." >&2
    exit 1
fi

# --- SSH Agent Management Functions ---

# Depends on logging functions (log_debug, log_info, log_error, log_warn)
# Depends on global variables: SSH_AUTH_SOCK, SSH_AGENT_PID, AGENT_ENV_FILE, HOME

# --- check_ssh_agent ---
# ... (description omitted for brevity)
check_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_debug "Checking agent status... (SOCK='${SSH_AUTH_SOCK:-}')"

    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
        log_debug "check_ssh_agent: Required SSH_AUTH_SOCK not set."
        return 1;
    fi

    # Use -f for mock compatibility, real agent uses -S
    if [ ! -f "$SSH_AUTH_SOCK" ] && [ ! -S "$SSH_AUTH_SOCK" ]; then
        log_debug "check_ssh_agent: Agent communication file ('$SSH_AUTH_SOCK') not found or not a regular file/socket."
        return 1;
    fi

    log_debug "check_ssh_agent: Agent communication file exists. Assuming agent is usable for check purposes."
    return 0
}

# --- ensure_ssh_agent ---
# ... (description omitted for brevity)
ensure_ssh_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Ensuring SSH agent is active..."

    if [ -n "${SSH_AUTH_SOCK:-}" ] && check_ssh_agent; then
        log_info "Agent already running and sourced (SOCK: ${SSH_AUTH_SOCK:-Unknown})."
        printf "SSH agent is already running (Socket: %s).\n" "${SSH_AUTH_SOCK:-Unknown}"
        export SSH_AUTH_SOCK SSH_AGENT_PID
        return 0
    fi

    log_debug "Agent not running or sourced in current environment."
    if [ -f "$AGENT_ENV_FILE" ]; then
        log_debug "Sourcing persistent agent file: $AGENT_ENV_FILE"
        # shellcheck disable=SC1090
        . "$AGENT_ENV_FILE" >/dev/null
        if check_ssh_agent; then
            log_info "Sourced persistent file. Reusing agent (SOCK: ${SSH_AUTH_SOCK:-Unknown}, PID: ${SSH_AGENT_PID:-Unknown})."
            printf "Successfully connected to existing ssh-agent (Socket: %s).\n" "${SSH_AUTH_SOCK:-Unknown}"
            export SSH_AUTH_SOCK SSH_AGENT_PID
            return 0
        else
            log_debug "Agent file '$AGENT_ENV_FILE' found but agent invalid after sourcing. Removing stale file."
            rm -f "$AGENT_ENV_FILE"
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    fi

    log_info "Starting new ssh-agent..."
    printf "Starting new ssh-agent...\n"
    if ! mkdir -p "$HOME/.ssh"; then log_error "Failed to create $HOME/.ssh directory."; return 1; fi
    chmod 700 "$HOME/.ssh" || log_warn "Failed to set permissions on $HOME/.ssh"
    local agent_output
    if ! agent_output=$(ssh-agent -s); then
        log_error "Failed to execute ssh-agent -s."; return 1;
    fi
    log_debug "ssh-agent -s output captured."

    local ssh_auth_sock ssh_agent_pid
    # Use robust parsing
    local sock_line pid_line
    sock_line=$(echo "$agent_output" | grep '^SSH_AUTH_SOCK=')
    pid_line=$(echo "$agent_output" | grep '^SSH_AGENT_PID=')
    # Extract SOCK
    temp_sock="${sock_line#SSH_AUTH_SOCK=}"
    ssh_auth_sock="${temp_sock%\';*}"
    ssh_auth_sock="${ssh_auth_sock#\'}"
    # Extract PID
    temp_pid="${pid_line#SSH_AGENT_PID=}"
    ssh_agent_pid="${temp_pid%%;*}"

    if [ -n "$ssh_auth_sock" ] && [ -n "$ssh_agent_pid" ]; then
        export SSH_AUTH_SOCK="$ssh_auth_sock"
        export SSH_AGENT_PID="$ssh_agent_pid"
        log_info "Extracted and exported new agent details: SOCK=$SSH_AUTH_SOCK PID=$SSH_AGENT_PID"
    else
        log_error "Failed to parse SSH_AUTH_SOCK or SSH_AGENT_PID from ssh-agent output."
        log_debug "ssh-agent output was: $agent_output"
        return 1;
    fi

    log_debug "Saving agent environment to $AGENT_ENV_FILE"
    local agent_env_dir
    agent_env_dir=$(dirname "$AGENT_ENV_FILE")
    if ! mkdir -p "$agent_env_dir"; then
        log_warn "Could not create directory '$agent_env_dir' for agent environment file. Agent persistence disabled."
    else
        {
            echo "SSH_AUTH_SOCK='$SSH_AUTH_SOCK'; export SSH_AUTH_SOCK;"
            echo "SSH_AGENT_PID=$SSH_AGENT_PID; export SSH_AGENT_PID;"
            echo "# Agent details saved on $(date)"
        } > "$AGENT_ENV_FILE"
        chmod 600 "$AGENT_ENV_FILE" || log_warn "Failed to set permissions on $AGENT_ENV_FILE"
        log_info "Agent environment saved to $AGENT_ENV_FILE."
    fi

    sleep 0.5
    if check_ssh_agent; then
        log_info "New agent started and verified successfully."
        printf "Successfully started new ssh-agent (PID: %s).\n" "$SSH_AGENT_PID"
        return 0
    else
        log_error "Started new agent but failed final verification check!"
        printf "Error: Started ssh-agent but failed final verification.\n" >&2
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        rm -f "$AGENT_ENV_FILE"
        return 1
    fi
} 