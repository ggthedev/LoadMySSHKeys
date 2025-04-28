#!/usr/bin/env bash
# Library for core SSH key operations for sshkeymanager.sh

# Ensure this script is sourced, not executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "This script should be sourced, not executed directly." >&2
    exit 1
fi

# --- Core Key Management Functions ---

# Depends on logging functions (log_debug, log_info, log_error, log_warn)
# Depends on agent functions (ensure_ssh_agent)
# Depends on global variables: VALID_KEY_LIST_FILE, SSH_DIR, PLATFORM, KEYS_LIST_TMP

# --- add_keys_to_agent ---
# ... (description omitted for brevity)
add_keys_to_agent() {
    log_debug "Entering function: ${FUNCNAME[0]} (loop version)"
    log_info "Adding keys listed in $VALID_KEY_LIST_FILE..."

    if [ ! -s "$VALID_KEY_LIST_FILE" ]; then
        log_error "Key list file '$VALID_KEY_LIST_FILE' is empty or missing."
        printf "Key list file '%s' is empty or does not exist. Cannot add keys.\\n" "$VALID_KEY_LIST_FILE"
        return 1
    fi

    printf "Adding SSH keys to agent (using list: %s)...\n" "$VALID_KEY_LIST_FILE"
    local platform_local
    platform_local=$(uname -s)
    local keyfile key_path added_count=0 failed_count=0 ssh_add_output ssh_add_status cmd_to_run

    set +e
    while IFS= read -r keyfile; do
        [ -z "$keyfile" ] && continue
        key_path="$SSH_DIR/$keyfile"
        log_debug "Processing key entry: '$keyfile' (Path: '$key_path')"

        if [ -f "$key_path" ]; then
            log_info "Attempting to add key: $key_path"
            if [[ "$platform_local" == "Darwin" ]]; then
                ssh_add_output=$(ssh-add --apple-use-keychain "$key_path" 2>&1 || true)
                ssh_add_status=${PIPESTATUS[0]:-$?}
            else
                ssh_add_output=$(ssh-add "$key_path" 2>&1 || true)
                ssh_add_status=${PIPESTATUS[0]:-$?}
            fi

            log_debug "ssh-add command status for '$keyfile': $ssh_add_status"
            if [ "$ssh_add_status" -ne 0 ]; then log_debug "ssh-add output/error: $ssh_add_output"; fi

            if [ "$ssh_add_status" -eq 0 ]; then
                log_info "Successfully added '$keyfile'"
                printf "  ✓ Added key '%s'\\n" "$keyfile"
                ((added_count++))
            elif [ "$ssh_add_status" -eq 1 ]; then
                 printf "  ✗ Failed to add key '%s' (status: %d - passphrase needed or other issue?)\\n" "$keyfile" "$ssh_add_status"
                 log_warn "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status). Check passphrase or permissions."
                 ((failed_count++))
            elif [ "$ssh_add_status" -eq 2 ]; then
                 printf "  ✗ Failed to add key '%s' (status: %d - cannot connect to agent)\\n" "$keyfile" "$ssh_add_status"
                 log_error "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status - Cannot connect to agent)."
                 ((failed_count++))
            else
                 printf "  ✗ Failed to add key '%s' (status: %d - unexpected error)\\n" "$keyfile" "$ssh_add_status"
                 log_error "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status - Unexpected)."
                ((failed_count++))
            fi
        else
            printf "  ✗ Key file '%s' not found at '%s' (skipped)\\n" "$keyfile" "$key_path"
            log_warn "Key file '$keyfile' listed in '$VALID_KEY_LIST_FILE' but not found at '$key_path'."
            ((failed_count++))
        fi
    done < "$VALID_KEY_LIST_FILE"
    local read_status=$?
    set -e

    if [ $read_status -ne 0 ] && [ $read_status -ne 1 ]; then
        log_error "add_keys_to_agent: Error reading key list file '$VALID_KEY_LIST_FILE' (status: $read_status)."
        return 1
    fi

    printf "\\nSummary: %d key(s) added, %d key(s) failed/skipped.\\n" "$added_count" "$failed_count"
    log_info "Finished adding keys. Added: $added_count, Failed/Skipped: $failed_count"
    [ "$added_count" -gt 0 ] && return 0 || return 1
} # END add_keys_to_agent

# --- update_keys_list_file ---
# ... (description omitted for brevity)
update_keys_list_file() {
    log_debug "Entering function: ${FUNCNAME[0]} (Pub Check Logic)"
    log_info "Finding potential private key files in $SSH_DIR by checking for matching .pub files..."

    if [ -z "$KEYS_LIST_TMP" ] || ! > "$KEYS_LIST_TMP"; then
        log_error "Temporary key list file ($KEYS_LIST_TMP) is not set or not writable."
        printf "Error: Cannot prepare temporary file for key list.\n" >&2
        return 1
    fi
    log_debug "Cleared temporary key list file: $KEYS_LIST_TMP"

    local keyfile_path key_basename key_count=0

    for keyfile_path in "$SSH_DIR"/*; do
        if [ -f "$keyfile_path" ] && [[ "$keyfile_path" != *.pub ]] && [ -f "${keyfile_path}.pub" ]; then
            key_basename=$(basename "$keyfile_path")
            log_debug "Found potential private key: '$key_basename' (matched '${key_basename}.pub')"
            printf '%s\n' "$key_basename"
            ((key_count++))
        fi
    done > "$KEYS_LIST_TMP"

    key_count=$(wc -l < "$KEYS_LIST_TMP")
    key_count=${key_count##* }

    log_info "Found $key_count potential key entries in temp file $KEYS_LIST_TMP using .pub check logic."

    if [ "$key_count" -eq 0 ]; then
        printf "No potential SSH private key files (with matching .pub files) found in %s.\n" "$SSH_DIR"
        log_info "No potential SSH key files found in $SSH_DIR using .pub check logic."
        return 1
    else
        printf "Found %d potential key file(s) in %s (checked for .pub, written to temp list %s).\n" "$key_count" "$SSH_DIR" "$KEYS_LIST_TMP"
        return 0
    fi
}

# --- delete_keys_from_agent ---
# ... (description omitted for brevity)
delete_keys_from_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Attempting to delete all keys from ssh-agent (ssh-add -D)..."

    ssh-add -D >/dev/null 2>&1 || true
    local del_status=${PIPESTATUS[0]:-$?}

    log_debug "ssh-add -D exit status: $del_status"
    case "$del_status" in
        0) # Success: Keys were deleted (or none existed).
            log_info "All keys successfully deleted from agent (or agent was empty)."
            printf "All keys successfully deleted from agent.\n"
            return 0
            ;;
        1) # Failure: Often means agent unreachable.
            log_warn "Could not delete keys (ssh-add -D status: 1). Agent might not be running."
            printf "Warning: Could not delete keys. Agent might not be running (ssh-add -D status: 1).\n" >&2
            return 1
            ;;
        2) # Error: More specific connection error.
            log_error "Failed to delete keys: Could not connect to agent (ssh-add -D status: 2)."
            printf "Error: Could not connect to the SSH agent.\n" >&2
            return 1
            ;;
        *) # Other unexpected errors.
            log_error "Failed to delete keys from agent (ssh-add -D status: $del_status)."
            printf "Error: Failed to delete keys from agent (Code: %s).\n" "$del_status" >&2
            return 1
            ;;
    esac
}

# --- load_specific_keys ---
# ... (description omitted for brevity)
load_specific_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Load Specific Key(s) into Agent +++\n"

    if ! ensure_ssh_agent; then
        log_error "load_specific_keys: Cannot proceed, failed to ensure SSH agent is running."
        printf "Error: SSH Agent not available. Cannot load keys.\n" >&2
        return 1
    fi
    log_info "Agent confirmed running."

    log_info "Listing potential key files..."
    if ! update_keys_list_file; then
        log_error "load_specific_keys: Failed to get list of key files."
        return 1
    fi
    if [ ! -s "$KEYS_LIST_TMP" ]; then
        log_error "load_specific_keys: update_keys_list_file succeeded but temp file list is empty."
        printf "Error: No potential key files found in %s to select from.\n" "$SSH_DIR" >&2
        return 1
    fi

    local key_files=()
    mapfile -t key_files < "$KEYS_LIST_TMP" || { log_error "Failed to read keys into array."; printf "Error reading key list file.\n" >&2; return 1; }

    if [ ${#key_files[@]} -eq 0 ]; then
        log_error "load_specific_keys: Read 0 keys into array."
        printf "Error reading key file list or list is empty.\n" >&2
        return 1
    fi

    printf "Available potential key files in %s:\n" "$SSH_DIR"
    local i
    for i in "${!key_files[@]}"; do
        printf "  %2d) %s\n" "$((i + 1))" "${key_files[i]}"
    done

    local user_input selected_numbers=() valid_indices=() choice key_index
    printf "\nEnter numbers of keys to load (space-separated), or 'a' for all, 'c' to cancel:\n"
    read -r -p "> " user_input < /dev/tty
    log_debug "User entered selection: '$user_input'"

    case "$user_input" in
        c|C)
            printf "Operation cancelled.\n"
            log_info "User cancelled specific key loading."
            return 0 ;;
        a|A)
            log_info "User selected 'all' keys."
            for i in "${!key_files[@]}"; do valid_indices+=("$i"); done
            ;;
        *)
            read -r -a selected_numbers <<< "$user_input"
            log_debug "Parsed selection numbers: ${selected_numbers[*]}"
            local num max_index=$(( ${#key_files[@]} - 1 )) invalid_found=0 temp_indices=()
            max_index_user=$(( ${#key_files[@]} ))
            for num in "${selected_numbers[@]}"; do
                 if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$max_index_user" ]; then
                     key_index=$((num - 1))
                     local found_dup=0
                     for existing_idx in "${temp_indices[@]}"; do if [[ "$existing_idx" -eq "$key_index" ]]; then found_dup=1; break; fi; done
                     if [[ "$found_dup" -eq 0 ]]; then temp_indices+=("$key_index"); log_debug "Validated selection: $num (index $key_index)"; else log_warn "Duplicate selection ignored: $num"; fi
                 else
                    printf "Invalid selection: '%s'. Entry must be a number between 1 and %d.\n" "$num" "$max_index_user" >&2
                    log_warn "Invalid user selection ignored: '$num'"
                    invalid_found=1
                 fi
            done
            if [ "$invalid_found" -eq 1 ] && [ ${#temp_indices[@]} -eq 0 ]; then printf "No valid key numbers entered. Aborting.\n" >&2; log_error "load_specific_keys: User input contained only invalid selections."; return 1; elif [ "$invalid_found" -eq 1 ]; then printf "Proceeding with valid selections only.\n"; fi
            valid_indices=("${temp_indices[@]}")
            ;;
    esac

    if [ ${#valid_indices[@]} -eq 0 ]; then
        printf "No keys selected to load.\n"
        log_info "No valid keys were selected by the user."
        return 0
    fi

    log_info "Attempting to load ${#valid_indices[@]} selected key(s)."
    printf "\n--- Attempting to load selected keys ---\n"

    local platform_local key_idx selected_filename key_path added_count=0 failed_count=0 ssh_add_output ssh_add_status
    platform_local=$(uname -s)

    set +e
    for key_idx in "${valid_indices[@]}"; do
        selected_filename="${key_files[$key_idx]}"
        key_path="$SSH_DIR/$selected_filename"
        log_debug "Processing selected key: '$selected_filename' (Index: $key_idx, Path: '$key_path')"

        if [ ! -f "$key_path" ]; then
            printf "  ✗ Error: Key file '%s' selected but not found at '%s'.\n" "$selected_filename" "$key_path" >&2
            log_error "Key file disappeared after listing: '$key_path'"
            ((failed_count++))
            continue
        fi

        log_info "Attempting to add key: $key_path"
        if [[ "$platform_local" == "Darwin" ]]; then
            ssh_add_output=$(ssh-add --apple-use-keychain "$key_path" 2>&1)
            ssh_add_status=$?
        else
            ssh_add_output=$(ssh-add "$key_path" 2>&1)
            ssh_add_status=$?
        fi

        log_debug "ssh-add command status for '$selected_filename': $ssh_add_status"
        if [ "$ssh_add_status" -ne 0 ]; then log_debug "ssh-add output/error: $ssh_add_output"; fi

        if [ "$ssh_add_status" -eq 0 ]; then
            log_info "Successfully added '$selected_filename'"
            printf "  ✓ Added key '%s'\n" "$selected_filename"
            ((added_count++))
        elif [ "$ssh_add_status" -eq 1 ]; then
             printf "  ✗ Failed to add key '%s' (Passphrase needed or other issue?)\n" "$selected_filename"
             log_warn "Failed to add key '$selected_filename' (Path: $key_path, Status: $ssh_add_status). Check passphrase or permissions."
             ((failed_count++))
        elif [ "$ssh_add_status" -eq 2 ]; then
             printf "  ✗ Failed to add key '%s' (Cannot connect to agent)\n" "$selected_filename"
             log_error "Failed to add key '$selected_filename' (Path: $key_path, Status: $ssh_add_status - Cannot connect to agent)."
             ((failed_count++))
        else
             printf "  ✗ Failed to add key '%s' (Unexpected error status: %d)\n" "$selected_filename" "$ssh_add_status"
             log_error "Failed to add key '$selected_filename' (Path: $key_path, Status: $ssh_add_status - Unexpected)."
            ((failed_count++))
        fi
    done
    set -e

    printf "\nSummary: %d key(s) added, %d key(s) failed/skipped.\n" "$added_count" "$failed_count"
    log_info "Finished loading specific keys. Added: $added_count, Failed/Skipped: $failed_count"
    [ "$added_count" -gt 0 ] && return 0 || return 1
} # END load_specific_keys

# --- list_current_keys ---
# ... (description omitted for brevity)
list_current_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Listing current keys in agent (ssh-add -l)..."

    local key_list_output exit_code
    if key_list_output=$(ssh-add -l 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi
    log_debug "ssh-add -l status check: $exit_code"

    case $exit_code in
        0)
            printf "Keys currently loaded in the agent:\n"
            log_info "Keys currently loaded in the agent:"
            local key_lines=()
            mapfile -t key_lines <<< "$key_list_output"
            if [ ${#key_lines[@]} -gt 0 ]; then
                local i
                for i in "${!key_lines[@]}"; do printf "  %2d) %s\n" "$((i + 1))" "${key_lines[i]}"; log_info "  $((i + 1))) ${key_lines[i]}"; done
            else
                printf "Agent reported success (status 0), but no key lines found.\n"
                log_warn "list_current_keys: ssh-add -l status 0 but mapfile found no lines."
            fi
            ;;
        1)
            printf "No keys currently loaded in the agent.\n"
            if [ "$ACTION" == "list" ]; then printf "Hint: Use -a to add keys found in '%s'.\n" "$SSH_DIR"; else printf "Hint: Use option 3 (in menu) to load keys from '%s'.\n" "$SSH_DIR"; fi
            log_info "No keys currently loaded (status 1)."
            ;;
        2)
            log_error "Could not connect to the SSH agent (ssh-add -l exit code 2)."
            printf "Error: Could not connect to the SSH agent. Is it running?\n" >&2
            return 1
            ;;
        *)
            log_error "Unknown error occurred from ssh-add -l check (Exit code: $exit_code)."
            printf "Error: An unexpected error occurred checking keys (Code: %s).\n" "$exit_code" >&2
            return 1
            ;;
    esac
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0
}


# --- delete_single_key ---
# ... (description omitted for brevity)
delete_single_key() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Delete Single Key from Agent +++\n"

    local agent_check_status list_output return_status=1
    if list_output=$(ssh-add -l 2>&1); then
        agent_check_status=0
    else
        agent_check_status=$?
    fi
    log_debug "ssh-add -l status check: $agent_check_status"

    if [ "$agent_check_status" -eq 1 ]; then
        log_info "delete_single_key: Could not query agent (ssh-add -l status: 1). Agent might not be running or contains no keys."
        printf "No active agent found to delete keys from.\n" >&2
        return_status=1
    elif [ "$agent_check_status" -ne 0 ]; then
        log_warn "delete_single_key: Cannot query agent (ssh-add -l status: $agent_check_status)."
        printf "Error: Could not query the SSH agent (status: %d).\n" "$agent_check_status" >&2
        return_status=1
    else
        key_count=$(echo "$list_output" | wc -l)
        key_count=${key_count##* }
        if [ "$key_count" -eq 0 ]; then
             log_warn "delete_single_key: ssh-add -l status 0 but no keys listed."
             printf "No keys currently loaded in ssh-agent to delete.\n"
             return_status=0
        else
            log_info "Agent has keys. Listing potential key files..."
            if ! update_keys_list_file; then
                log_error "delete_single_key: Failed to get list of key files."
                return 1
            fi
            if [ ! -s "$KEYS_LIST_TMP" ]; then
                log_error "delete_single_key: Inconsistency - agent has keys, but temp file list is empty."
                printf "Error: Inconsistency detected - agent reports keys, but no key files found.\n" >&2
                return 1
            fi
            local key_files=()
            mapfile -t key_files < "$KEYS_LIST_TMP" || { log_error "Failed to read keys into array."; return 1; }
            if [ ${#key_files[@]} -eq 0 ]; then
                log_error "delete_single_key: Read 0 keys into array."
                printf "Error reading key file list.\n" >&2
                return 1
            fi
            printf "Select a key file to remove from the agent:\n"
            local i choice selected_index selected_filename key_path del_status
            for i in "${!key_files[@]}"; do
                printf "  %2d) %s\n" "$((i + 1))" "${key_files[i]}"
            done
            while true; do
                read -r -p "Enter key number to delete (or 'c' to cancel): " choice < /dev/tty
                log_debug "User entered selection: '$choice'"
                case "$choice" in
                    c|C) printf "Operation cancelled.\n"; log_info "User cancelled deletion."; return_status=0; break ;;
                    *) 
                        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#key_files[@]}" ]; then
                            selected_index=$((choice - 1))
                            selected_filename="${key_files[$selected_index]}"
                            key_path="$SSH_DIR/$selected_filename"
                            log_info "User selected: $choice ($selected_filename)"
                            printf "Attempting to delete key file: %s\n" "$selected_filename"
                            log_info "Attempting: ssh-add -d '$key_path'"
                            ssh-add -d "$key_path" 2>/dev/null || true
                            del_status=${PIPESTATUS[0]:-$?}
                            log_debug "ssh-add -d exited with status: $del_status"
                            if [ "$del_status" -eq 0 ]; then
                                printf "Key '%s' successfully deleted from agent.\n" "$selected_filename"
                                log_info "Successfully deleted '$key_path' from agent."
                                return_status=0
                            else
                                printf "Error: Failed to delete key '%s' from agent (status: %d).\n" "$selected_filename" "$del_status" >&2
                                log_error "Failed to delete key '$key_path' (status: $del_status)."
                                if [ "$del_status" -eq 1 ]; then printf "       (This often means the key wasn't loaded.)\n" >&2; fi
                                return_status=1
                            fi
                            break
                        else
                            printf "Invalid selection. Please enter 1-%d or 'c'.\n" "${#key_files[@]}"
                        fi ;;
                esac
            done
        fi
    fi

    log_debug "Exiting function: ${FUNCNAME[0]} (status: $return_status)"
    return $return_status
}

# --- delete_all_keys ---
# ... (description omitted for brevity)
delete_all_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Delete All Keys from Agent +++\n"

    local agent_check_status key_count=0 list_output="" return_status=1

    if list_output=$(ssh-add -l 2>&1); then
        agent_check_status=0
    else
        agent_check_status=$?
    fi
    log_debug "ssh-add -l status check: $agent_check_status"

    if [ "$agent_check_status" -eq 0 ]; then
        key_count=$(echo "$list_output" | wc -l)
        key_count=${key_count##* }
        log_debug "Agent query successful (status 0), counted $key_count keys."

        if [ "$key_count" -eq 0 ]; then
            printf "No keys currently loaded in ssh-agent.\n"
            log_info "delete_all_keys: No keys loaded, nothing to do."
            return_status=0
        else
            printf "This will delete all %d keys from ssh-agent.\n" "$key_count"
            local confirm
            read -r -p "Are you sure you want to continue? (y/N): " confirm < /dev/tty
            log_debug "User confirmation: '$confirm'"

            case "$confirm" in
                y|Y)
                    log_info "User confirmed deletion of all keys."
                    if delete_keys_from_agent; then
                        return_status=0
                    else
                        return_status=1
                    fi
                    ;;
                *)
                    printf "Operation cancelled.\n"
                    log_info "User cancelled deletion."
                    return_status=0
                    ;;
            esac
        fi

    elif [ "$agent_check_status" -eq 1 ]; then
        log_info "delete_all_keys: Could not query agent (ssh-add -l status: 1). Agent might not be running or contains no keys." # Log as info
        printf "Either no active agent exists OR active agent contains no keys to delete.\n" >&2 # Specific user message
        return_status=1
    elif [ "$agent_check_status" -eq 2 ]; then
        log_warn "delete_all_keys: Cannot connect to agent (ssh-add -l status: 2)." # Log as warn
        printf "Error: Could not connect to the SSH agent (ssh-add -l status: 2).\n" >&2 # Specific user message
        return_status=1
    else
        log_warn "delete_all_keys: Error querying agent (ssh-add -l status: $agent_check_status)." # Log as warn
        printf "Error: Could not query the SSH agent (Status: %d).\n" "$agent_check_status" >&2 # Specific user message
        return_status=1
    fi

    log_debug "Exiting function: ${FUNCNAME[0]} (status: $return_status)"
    return $return_status
} 