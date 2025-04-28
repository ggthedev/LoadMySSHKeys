#!/usr/bin/env bash
# ==============================================================================
# Library: key_ops.sh
# Description: Provides core functions for managing SSH keys and interacting
#              with the ssh-agent (adding, listing, deleting keys).
# Dependencies: Relies on functions from lib/logging.sh (log_debug, log_info, log_error, log_warn)
#               Relies on functions from lib/agent.sh (ensure_ssh_agent)
#               Relies on global variables set by the main script:
#                 - VALID_KEY_LIST_FILE: Path to the persistent list of keys to load.
#                 - SSH_DIR: Path to the user's SSH directory.
#                 - PLATFORM: OS type ("Darwin", "Linux", etc.) - used indirectly via `uname`.
#                 - KEYS_LIST_TMP: Path to a temporary file for listing discovered keys.
#                 - ACTION: (Used by list_current_keys) Current script action for context hints.
# ==============================================================================

# --- Safety Check ---
# Ensure this script is sourced, not executed directly.
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "Error: This script (key_ops.sh) should be sourced, not executed directly." >&2
    exit 1
fi

# ==============================================================================
# --- Core Key Management Functions ---
# ==============================================================================

# --- add_keys_to_agent ---
#
# @description Reads a list of key file basenames from the persistent key list
#              file ($VALID_KEY_LIST_FILE) and attempts to add each corresponding
#              key file (located in $SSH_DIR) to the ssh-agent using `ssh-add`.
#              Handles platform differences (macOS Keychain integration).
# @arg        None
# @requires   Global variable $VALID_KEY_LIST_FILE must point to a readable file
#             containing one key basename per line.
# @requires   Global variable $SSH_DIR must point to the directory containing the keys.
# @requires   An accessible ssh-agent must be running (implicitly required by ssh-add).
# @return     0 If at least one key was successfully added to the agent.
# @return     1 If the key list file is missing/empty, if reading the file fails,
#               OR if all attempts to add keys failed (keys not found, passphrase issues,
#               agent connection errors).
# @prints     Status messages to stdout indicating success/failure for each key attempt
#             and a final summary.
# @stdout     Progress messages (key adding attempts) and summary message.
# @stderr     None (Errors are logged using logging functions).
# @depends    Global variables: VALID_KEY_LIST_FILE, SSH_DIR.
#             Functions: log_debug, log_info, log_error, log_warn.
#             External command: ssh-add, printf, read, uname.
# ---
add_keys_to_agent() {
    log_debug "Entering function: ${FUNCNAME[0]} (Version using list file: $VALID_KEY_LIST_FILE)"
    log_info "Attempting to add keys to agent based on list file: $VALID_KEY_LIST_FILE..."

    # --- Validate Input File ---
    # Check if the specified key list file exists and is not empty (-s).
    if [ ! -s "$VALID_KEY_LIST_FILE" ]; then
        log_error "Key list file '$VALID_KEY_LIST_FILE' is empty or does not exist."
        printf "Error: Key list file '%s' is empty or does not exist. Cannot add keys.\\n" "$VALID_KEY_LIST_FILE" >&2
        return 1 # Failure: Cannot proceed without the key list.
    fi

    printf "Adding SSH keys to agent (using list: %s)...\\n" "$VALID_KEY_LIST_FILE"

    # --- Initialization ---
    local platform_local
    platform_local=$(uname -s) # Detect OS for platform-specific commands.
    local keyfile key_path added_count=0 failed_count=0 ssh_add_output ssh_add_status

    # --- Process Keys from List ---
    # Use `set +e` to prevent the script from exiting if `ssh-add` fails within the loop.
    # We need to manually check the exit status of `ssh-add` for each key.
    set +e
    # Read the key list file line by line.
    while IFS= read -r keyfile; do
        # Skip empty lines in the key list file.
        [ -z "$keyfile" ] && continue

        # Construct the full path to the private key file.
        key_path="$SSH_DIR/$keyfile"
        log_debug "Processing key entry from list: '$keyfile' (Full path: '$key_path')"

        # Check if the corresponding private key file actually exists.
        if [ -f "$key_path" ]; then
            log_info "Attempting to add key file: $key_path"
            # --- Platform-Specific ssh-add Command ---
            if [[ "$platform_local" == "Darwin" ]]; then
                # On macOS, use --apple-use-keychain to integrate with macOS Keychain for passphrase management.
                # Capture both stdout and stderr (2>&1) and allow failure (|| true).
                ssh_add_output=$(ssh-add --apple-use-keychain "$key_path" 2>&1 || true)
                # Get the exit status of the ssh-add command (robustly handling pipes if they were used).
                ssh_add_status=${PIPESTATUS[0]:-$?}
            else
                # On Linux and other systems, use standard ssh-add.
                ssh_add_output=$(ssh-add "$key_path" 2>&1 || true)
                ssh_add_status=${PIPESTATUS[0]:-$?}
            fi

            log_debug "ssh-add command status for '$keyfile': $ssh_add_status"
            # Log the output/error from ssh-add only if the command failed, to avoid clutter.
            if [ "$ssh_add_status" -ne 0 ]; then
                log_debug "ssh-add output/error was: $ssh_add_output"
            fi

            # --- Handle ssh-add Exit Status ---
            if [ "$ssh_add_status" -eq 0 ]; then
                # Status 0: Success.
                log_info "Successfully added key '$keyfile' to agent."
                printf "  ✓ Added key '%s'\\n" "$keyfile"
                ((added_count++)) # Increment success counter.
            elif [ "$ssh_add_status" -eq 1 ]; then
                 # Status 1: Failure, often requires passphrase or permission issue.
                 printf "  ✗ Failed to add key '%s' (status: %d - passphrase needed or other issue?)\\n" "$keyfile" "$ssh_add_status"
                 log_warn "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status). Check passphrase or permissions."
                 ((failed_count++)) # Increment failure counter.
            elif [ "$ssh_add_status" -eq 2 ]; then
                 # Status 2: Cannot connect to the agent.
                 printf "  ✗ Failed to add key '%s' (status: %d - cannot connect to agent)\\n" "$keyfile" "$ssh_add_status"
                 log_error "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status - Cannot connect to agent)."
                 ((failed_count++))
                 # Consider adding a 'break' here if agent connection fails repeatedly?
            else
                 # Other unexpected errors.
                 printf "  ✗ Failed to add key '%s' (status: %d - unexpected error)\\n" "$keyfile" "$ssh_add_status"
                 log_error "Failed to add key '$keyfile' (Path: $key_path, Status: $ssh_add_status - Unexpected error)."
                ((failed_count++))
            fi
        else
            # Key file listed in $VALID_KEY_LIST_FILE does not exist in $SSH_DIR.
            printf "  ✗ Key file '%s' listed but not found at '%s' (skipped)\\n" "$keyfile" "$key_path"
            log_warn "Key file '$keyfile' listed in '$VALID_KEY_LIST_FILE' but not found at '$key_path'."
            ((failed_count++)) # Increment failure counter.
        fi
    # Read from the specified list file.
    done < "$VALID_KEY_LIST_FILE"
    # Capture the exit status of the `while read` loop itself (important for detecting read errors).
    local read_status=$?
    # Re-enable exit-on-error now that the loop is finished.
    set -e

    # --- Check Read Status ---
    # If `read` exited with non-zero status (and not 1 which can mean EOF), log an error.
    if [ $read_status -ne 0 ] && [ $read_status -ne 1 ]; then
        log_error "add_keys_to_agent: Error occurred while reading key list file '$VALID_KEY_LIST_FILE' (read exit status: $read_status)."
        return 1 # Indicate failure reading the list.
    fi

    # --- Print Summary ---
    printf "\\nSummary: %d key(s) added, %d key(s) failed/skipped.\\n" "$added_count" "$failed_count"
    log_info "Finished adding keys from list. Added: $added_count, Failed/Skipped: $failed_count"

    # --- Return Status ---
    # Return success (0) if at least one key was added, otherwise failure (1).
    [ "$added_count" -gt 0 ] && return 0 || return 1

} # END add_keys_to_agent


# --- update_keys_list_file ---
#
# @description Scans the $SSH_DIR for potential private key files.
#              Identifies potential private keys by looking for files that do *not*
#              end in `.pub` and *do* have a corresponding file with the same
#              basename plus `.pub` extension existing alongside them.
#              Writes the basenames (filenames only) of the identified potential
#              private keys to the temporary file specified by $KEYS_LIST_TMP.
# @arg        None
# @requires   Global variable $SSH_DIR must point to a readable directory.
# @requires   Global variable $KEYS_LIST_TMP must point to a writable temporary file path.
# @modifies   Overwrites the temporary file $KEYS_LIST_TMP with found key basenames.
# @return     0 If at least one potential private key file (matching the criteria) is found.
# @return     1 If no potential key files are found or if the temporary file cannot be written.
# @prints     Status messages to stdout indicating the number of keys found.
# @stdout     Message indicating count of potential key files found and temp file path.
# @stderr     Error message if temporary file is not writable.
# @depends    Global variables: SSH_DIR, KEYS_LIST_TMP.
#             Functions: log_debug, log_info, log_error.
#             External commands: printf, basename, wc.
# ---
update_keys_list_file() {
    log_debug "Entering function: ${FUNCNAME[0]} (Method: Public Key Check Logic)"
    log_info "Scanning for potential private key files in '$SSH_DIR' by checking for matching '.pub' files..."

    # --- Prepare Temporary File ---
    # Check if the temporary file variable is set and if the file can be created/truncated (>).
    if [ -z "$KEYS_LIST_TMP" ] || ! > "$KEYS_LIST_TMP"; then
        log_error "Temporary key list file path ($KEYS_LIST_TMP) is not set or the file is not writable."
        printf "Error: Cannot prepare temporary file ('%s') for key list.\\n" "${KEYS_LIST_TMP:-unset}" >&2
        return 1 # Failure: Cannot write to temp file.
    fi
    log_debug "Cleared/prepared temporary key list file: $KEYS_LIST_TMP"

    # --- Scan for Keys ---
    local keyfile_path key_basename key_count=0

    # Iterate through all items in the SSH directory.
    # Redirect stdout of the loop to the temporary file for efficiency.
    for keyfile_path in "$SSH_DIR"/*; do
        # Check criteria for a potential private key:
        # 1. Is it a regular file? (-f)
        # 2. Does its name NOT end with .pub? (!= *.pub)
        # 3. Does a file with the same name PLUS .pub exist? (-f "${keyfile_path}.pub")
        if [ -f "$keyfile_path" ] && [[ "$keyfile_path" != *.pub ]] && [ -f "${keyfile_path}.pub" ]; then
            # If all criteria match, extract the basename.
            key_basename=$(basename "$keyfile_path")
            log_debug "Found potential private key: '$key_basename' (matched '.pub' file: '${key_basename}.pub')"
            # Print the basename to stdout (which is redirected to $KEYS_LIST_TMP).
            printf '%s\n' "$key_basename"
            # Increment counter (note: this happens in a subshell due to redirection).
            ((key_count++))
        fi
    done > "$KEYS_LIST_TMP"
    # The `key_count` variable incremented inside the loop subshell is lost.
    # Recount the lines written to the file to get the accurate count.
    key_count=$(wc -l < "$KEYS_LIST_TMP")
    key_count=${key_count##* } # Remove leading whitespace from wc output.

    log_info "Found $key_count potential key entries written to temp file '$KEYS_LIST_TMP' (using .pub check logic)."

    # --- Return Status Based on Count ---
    if [ "$key_count" -eq 0 ]; then
        printf "No potential SSH private key files (with matching .pub files) found in %s.\\n" "$SSH_DIR"
        log_info "Scan complete: No potential SSH key files found in '$SSH_DIR' using .pub check logic."
        return 1 # Indicate no keys found.
    else
        printf "Found %d potential key file(s) in %s (checked for .pub, written to temp list %s).\\n" "$key_count" "$SSH_DIR" "$KEYS_LIST_TMP"
        return 0 # Indicate keys were found.
    fi
}


# --- delete_keys_from_agent ---
#
# @description Attempts to delete all keys (identities) currently loaded in the
#              ssh-agent using the `ssh-add -D` command.
# @arg        None
# @requires   An accessible ssh-agent (implicitly required by ssh-add).
# @return     0 If `ssh-add -D` succeeds (exit status 0), meaning keys were deleted
#               or no keys were present.
# @return     1 If `ssh-add -D` fails (exit status 1, 2, or other), indicating an
#               issue like agent not running, connection error, or other problem.
# @prints     Status messages to stdout/stderr indicating success or failure.
# @stdout     Success message.
# @stderr     Warning or Error message on failure.
# @depends    Functions: log_debug, log_info, log_warn, log_error.
#             External command: ssh-add.
# ---
delete_keys_from_agent() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Attempting to delete all keys from ssh-agent using \`ssh-add -D\`..."

    # Execute ssh-add -D. Redirect stdout and stderr to /dev/null to suppress direct output.
    # Use `|| true` to prevent script exit if `set -e` is active and ssh-add fails.
    ssh-add -D >/dev/null 2>&1 || true
    # Capture the exit status of ssh-add immediately.
    local del_status=${PIPESTATUS[0]:-$?}

    log_debug "\`ssh-add -D\` command finished with exit status: $del_status"

    # --- Handle Exit Status ---
    case "$del_status" in
        0) # Success: Keys were deleted, or the agent was empty.
            log_info "\`ssh-add -D\` succeeded. All keys successfully deleted from agent (or agent was empty)."
            printf "All keys successfully deleted from agent.\\n"
            return 0 # Success.
            ;;
        1) # Failure: Often indicates the agent is not running or has no keys (though status 0 handles empty).
            log_warn "\`ssh-add -D\` failed (status: 1). Could not delete keys. Agent might not be running or accessible."
            printf "Warning: Could not delete keys from agent. Agent might not be running (ssh-add -D status: 1).\\n" >&2
            return 1 # Failure.
            ;;
        2) # Error: Specific error indicating failure to connect to the agent.
            log_error "\`ssh-add -D\` failed (status: 2). Could not connect to the SSH agent."
            printf "Error: Could not connect to the SSH agent to delete keys.\\n" >&2
            return 1 # Failure.
            ;;
        *) # Other unexpected errors.
            log_error "\`ssh-add -D\` failed with unexpected status: $del_status."
            printf "Error: Failed to delete keys from agent (Unexpected code: %s).\\n" "$del_status" >&2
            return 1 # Failure.
            ;;
    esac
}


# --- load_specific_keys ---
#
# @description Interactively prompts the user to select one or more key files
#              from a list of potential keys found in $SSH_DIR and attempts
#              to add the selected keys to the ssh-agent using `ssh-add`.
# @arg        None
# @requires   Global variable $SSH_DIR must point to a readable directory.
# @requires   Global variable $KEYS_LIST_TMP must be a writable path for temp file.
# @requires   An accessible ssh-agent must be running (ensured via ensure_ssh_agent).
# @modifies   Adds selected keys to the running ssh-agent.
# @modifies   Overwrites the temporary file $KEYS_LIST_TMP via update_keys_list_file.
# @return     0 If the operation was cancelled by the user OR if at least one selected key
#               was successfully added to the agent.
# @return     1 If there's an error ensuring the agent is running, finding/listing key files,
#               reading user input, validating selection, or if *all* attempts to add
#               selected keys failed.
# @prints     A numbered list of potential key files, prompts for user input,
#             and status messages about the addition attempts to stdout/stderr.
# @reads      User input from /dev/tty for selection.
# @stdout     Menu/list of keys, prompts, success/failure messages per key, summary.
# @stderr     Error messages (e.g., agent unavailable, no keys found, invalid input).
# @depends    Global variables: SSH_DIR, KEYS_LIST_TMP.
#             Functions: ensure_ssh_agent, update_keys_list_file, log_debug, log_info,
#             log_error, log_warn.
#             External command: ssh-add, mapfile (bash 4+), read, printf, uname, wc.
# ---
load_specific_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"

    # Ensure the agent is running before proceeding
    if ! ensure_ssh_agent; then
        log_error "Cannot load specific keys: Failed to ensure SSH agent is running."
        # ensure_ssh_agent prints detailed errors
        printf "Error: Agent not available. Cannot load keys.\n" >&2
        return 1
    fi

    printf "\n+++ Load Specific Key(s) into Agent +++\n"

    # 1. Get List of Potential Keys
    #    Scan the SSH directory and populate the temporary list file.
    log_info "Scanning '$SSH_DIR' for potential key files..."
    if ! update_keys_list_file; then
        # update_keys_list_file logs errors and prints messages if no keys found or error occurs.
        log_error "load_specific_keys: Failed to get list of key files from '$SSH_DIR'."
        return 1 # Failure: Cannot list keys.
    fi
    # Double-check if the temporary file is actually non-empty after update_keys_list_file reported success (status 0).
    if [ ! -s "$KEYS_LIST_TMP" ]; then
        log_error "load_specific_keys: update_keys_list_file succeeded but the temp file '$KEYS_LIST_TMP' is empty. Cannot proceed."
        printf "Error: No potential key files were found in %s to select from.\n" "$SSH_DIR" >&2
        return 1 # Failure: No keys available to select.
    fi

    # 2. Read Key List into Array
    #    Use mapfile (bash 4+) for safer reading of filenames (handles spaces, etc.)
    local key_files=()
    mapfile -t key_files < "$KEYS_LIST_TMP" || {
        log_error "Failed to read key filenames from temporary file '$KEYS_LIST_TMP' into array.";
        printf "Error reading temporary key list file.\n" >&2;
        return 1; # Failure: Cannot read temp file.
    }

    # Check if mapfile actually read any keys.
    if [ ${#key_files[@]} -eq 0 ]; then
        log_error "load_specific_keys: Read 0 keys into array from '$KEYS_LIST_TMP'."
        printf "Error reading key file list or list was unexpectedly empty after read.\n" >&2
        return 1 # Failure: Array is empty.
    fi
    log_debug "Read ${#key_files[@]} key basenames into array."

    # 3. Display List and Get User Selection
    printf "Available potential key files in %s:\n" "$SSH_DIR"
    local i
    # Loop through the array indices to print a numbered list.
    for i in "${!key_files[@]}"; do
        # Print index+1 (1-based for user) and the filename.
        printf "  %2d) %s\n" "$((i + 1))" "${key_files[i]}"
    done

    local user_input selected_numbers=() valid_indices=() choice key_index
    printf "\nEnter numbers of keys to load (space-separated), or 'a' for all, 'c' to cancel:\n"
    # Read directly from terminal (/dev/tty) to avoid issues if stdin is redirected.
    read -r -p "> " user_input < /dev/tty
    log_debug "User entered selection string: '$user_input'"

    # 4. Process User Input
    case "$user_input" in
        c|C)
            # User chose to cancel.
            printf "Operation cancelled.\n"
            log_info "User cancelled loading specific keys."
            return 0 # Treat cancellation as success (no error).
            ;;
        a|A)
            # User chose to load all available keys.
            log_info "User selected 'all' keys. Preparing to load all ${#key_files[@]} keys."
            # Populate valid_indices with all indices from the key_files array (0 to N-1).
            for i in "${!key_files[@]}"; do
                valid_indices+=("$i")
            done
            ;;
        *)
            # User entered specific numbers (potentially space-separated).
            # Read the input string into an array, splitting on spaces.
            read -r -a selected_numbers <<< "$user_input"
            log_debug "Parsed selection numbers into array: [${selected_numbers[*]}]"
            local num max_index=$(( ${#key_files[@]} - 1 )) # Max 0-based index.
            local invalid_found=0 temp_indices=() # Track invalid inputs and build list of valid 0-based indices.
            local max_index_user=$(( ${#key_files[@]} )) # Max 1-based index for user messages.

            # Loop through each number entered by the user.
            for num in "${selected_numbers[@]}"; do
                 # Validate: must be a number (regex) and within the 1-based range.
                 if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$max_index_user" ]; then
                     key_index=$((num - 1)) # Convert valid 1-based number to 0-based index.
                     # Check for duplicate selections before adding to temp_indices.
                     local found_dup=0
                     local existing_idx
                     for existing_idx in "${temp_indices[@]}"; do
                         if [[ "$existing_idx" -eq "$key_index" ]]; then
                             found_dup=1
                             break
                         fi
                     done
                     # If not a duplicate, add the 0-based index to the temporary list.
                     if [[ "$found_dup" -eq 0 ]]; then
                         temp_indices+=("$key_index")
                         log_debug "Validated user selection: '$num' (maps to 0-based index $key_index)"
                     else
                         log_warn "Duplicate selection number ignored: '$num'"
                     fi
                 else
                    # Input was not a number or out of range.
                    printf "Invalid selection: '%s'. Entry must be a number between 1 and %d.\n" "$num" "$max_index_user" >&2
                    log_warn "Invalid user selection ignored: '$num'"
                    invalid_found=1 # Flag that at least one invalid entry was found.
                 fi
            done

            # Handle cases with invalid input.
            if [ "$invalid_found" -eq 1 ] && [ ${#temp_indices[@]} -eq 0 ]; then
                 # If invalid entries were found AND no valid entries remain, abort.
                 printf "No valid key numbers were entered. Aborting load operation.\n" >&2
                 log_error "load_specific_keys: User input contained only invalid or duplicate selections."
                 return 1 # Failure: Invalid input.
            elif [ "$invalid_found" -eq 1 ]; then
                 # If some invalid entries were found but valid ones remain, inform user and proceed.
                 printf "Warning: Invalid entries ignored. Proceeding with valid selections only.\n"
            fi
            # Assign the validated, unique, 0-based indices to the final list.
            valid_indices=("${temp_indices[@]}")
            ;;
    esac

    # --- Check if Any Keys Were Selected ---
    if [ ${#valid_indices[@]} -eq 0 ]; then
        # This can happen if user entered only duplicates or 'c', or if 'a' resulted in empty list (unlikely).
        printf "No keys selected to load.\n"
        log_info "Processing complete: No valid keys were ultimately selected by the user."
        return 0 # Success: No action needed.
    fi

    log_info "Attempting to load ${#valid_indices[@]} selected key(s)..."
    printf "\n--- Attempting to load selected keys ---\n"

    # 5. Add Selected Keys to Agent
    local platform_local key_idx selected_filename key_path added_count=0 failed_count=0 ssh_add_output ssh_add_status
    platform_local=$(uname -s) # Detect OS for platform-specific commands.

    # Use `set +e` to handle potential `ssh-add` failures individually.
    set +e
    # Loop through the array of validated 0-based indices.
    for key_idx in "${valid_indices[@]}"; do
        selected_filename="${key_files[$key_idx]}" # Get filename from key_files array.
        key_path="$SSH_DIR/$selected_filename"     # Construct full path.
        log_debug "Processing selected key to load: '$selected_filename' (Index: $key_idx, Path: '$key_path')"

        # Double-check file existence (in case it was deleted between listing and adding).
        if [ ! -f "$key_path" ]; then
            printf "  ✗ Error: Key file '%s' selected but was not found at '%s' (Skipped).\n" "$selected_filename" "$key_path" >&2
            log_error "Key file '$key_path' disappeared after listing and selection."
            ((failed_count++))
            continue # Skip to the next selected key.
        fi

        log_info "Attempting to add selected key file to agent: $key_path"
        # --- Platform-Specific ssh-add Command ---
        if [[ "$platform_local" == "Darwin" ]]; then
            ssh_add_output=$(ssh-add --apple-use-keychain "$key_path" 2>&1)
            ssh_add_status=$? # Capture exit status immediately.
        else
            ssh_add_output=$(ssh-add "$key_path" 2>&1)
            ssh_add_status=$?
        fi

        log_debug "ssh-add command status for '$selected_filename': $ssh_add_status"
        if [ "$ssh_add_status" -ne 0 ]; then
            log_debug "ssh-add output/error was: $ssh_add_output"
        fi

        # --- Handle ssh-add Exit Status ---
        # Same logic as in add_keys_to_agent.
        if [ "$ssh_add_status" -eq 0 ]; then
            log_info "Successfully added selected key '$selected_filename' to agent."
            printf "  ✓ Added key '%s'\n" "$selected_filename"
            ((added_count++))
        elif [ "$ssh_add_status" -eq 1 ]; then
             printf "  ✗ Failed to add key '%s' (Passphrase needed or other issue?)\n" "$selected_filename"
             log_warn "Failed to add selected key '$selected_filename' (Path: $key_path, Status: $ssh_add_status). Check passphrase or permissions."
             ((failed_count++))
        elif [ "$ssh_add_status" -eq 2 ]; then
             printf "  ✗ Failed to add key '%s' (Cannot connect to agent)\n" "$selected_filename"
             log_error "Failed to add selected key '$selected_filename' (Path: $key_path, Status: $ssh_add_status - Cannot connect to agent)."
             ((failed_count++))
             # Consider breaking loop if agent connection fails?
        else
             printf "  ✗ Failed to add key '%s' (Unexpected error status: %d)\n" "$selected_filename" "$ssh_add_status"
             log_error "Failed to add selected key '$selected_filename' (Path: $key_path, Status: $ssh_add_status - Unexpected error)."
            ((failed_count++))
        fi
    done
    # Re-enable exit on error.
    set -e

    # 6. Print Summary
    printf "\nSummary: %d key(s) added, %d key(s) failed/skipped.\n" "$added_count" "$failed_count"
    log_info "Finished loading specific keys. Added: $added_count, Failed/Skipped: $failed_count"

    # --- Return Status ---
    # Return success (0) if at least one key was successfully added, otherwise failure (1).
    [ "$added_count" -gt 0 ] && return 0 || return 1
}


# --- list_current_keys ---
#
# @description Attempts to list the keys currently loaded in the ssh-agent
#              using `ssh-add -l`. Handles different exit codes and provides
#              user-friendly messages and context-specific hints.
# @arg        None
# @requires   An accessible ssh-agent (implicitly required by ssh-add -l).
# @return     0 If keys were listed successfully OR if the agent reported no keys
#               were loaded (status 1 from ssh-add -l is treated as success here).
# @return     1 If there was an error connecting to the agent (status 2) or another
#               unexpected error occurred during the listing attempt.
# @prints     The list of keys (if any) or messages indicating no keys or errors.
#             Context-specific hints are printed if no keys are loaded.
# @stdout     Formatted list of keys, or "No keys loaded" message.
# @stderr     Error messages (e.g., connection failure), Hint messages.
# @depends    Global variable: ACTION, SSH_DIR.
#             Functions: log_debug, log_info, log_error, log_warn.
#             External command: ssh-add, mapfile (bash 4+), printf.
# ---
list_current_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Attempting to list current keys in agent using \`ssh-add -l\`..."

    # Execute `ssh-add -l`. Capture stdout and stderr together (2>&1).
    # Use `if/else` with direct command execution to robustly capture exit status even with `set -e`.
    local key_list_output exit_code
    if key_list_output=$(ssh-add -l 2>&1); then
        exit_code=0 # Explicitly set success status.
    else
        exit_code=$? # Capture the actual failure exit status.
    fi
    log_debug "\`ssh-add -l\` command finished with exit status: $exit_code"

    # --- Handle ssh-add -l Exit Status ---
    case $exit_code in
        0) # Success: Keys are present and were listed.
            printf "Keys currently loaded in the agent:\n"
            log_info "Keys currently loaded in the agent according to \`ssh-add -l\`:\n$key_list_output"
            local key_lines=()
            # Read the output lines into an array using mapfile.
            mapfile -t key_lines <<< "$key_list_output"
            # Check if mapfile actually populated the array.
            if [ ${#key_lines[@]} -gt 0 ]; then
                local i
                # Print a numbered list of the keys.
                for i in "${!key_lines[@]}"; do
                    printf "  %2d) %s\n" "$((i + 1))" "${key_lines[i]}"
                    # No need to log each line again here, already logged the block above.
                done
            else
                # This case should ideally not happen if exit_code was 0, but handle defensively.
                printf "Warning: Agent reported success (status 0), but no key lines were parsed.\n"
                log_warn "list_current_keys: \`ssh-add -l\` status was 0, but mapfile found no lines in output: '$key_list_output'"
            fi
            ;;
        1) # Status 1: Standard exit code when the agent is running but contains no keys.
           # Treat this as a successful query, just reporting the state.
            printf "No keys currently loaded in the agent.\n"
            log_info "\`ssh-add -l\` reported no keys currently loaded (status 1)."
            # Provide a helpful hint based on the context (CLI action vs menu).
            if [ "${ACTION:-menu}" == "list" ]; then
                # Hint specific to the CLI `list` action.
                printf "Hint: Use '-a' to automatically find and add keys from '%s'.\n" "$SSH_DIR" >&2
            else
                # Default hint for menu or other contexts.
                printf "Hint: Use menu option 3 ('Load Specific Key(s)') to load keys from '%s'.\n" "$SSH_DIR" >&2
            fi
            ;;
        2) # Status 2: Error connecting to the agent.
            log_error "\`ssh-add -l\` failed (status 2): Could not connect to the SSH agent."
            printf "Error: Could not connect to the SSH agent. Is it running?\n" >&2
            return 1 # Indicate failure.
            ;;
        *) # Other unexpected errors.
            log_error "\`ssh-add -l\` failed with unexpected status: $exit_code."
            printf "Error: An unexpected error occurred while checking keys in agent (Code: %s).\n" "$exit_code" >&2
            return 1 # Indicate failure.
            ;;
    esac

    log_debug "Exiting function: ${FUNCNAME[0]} (Overall Status: 0 - Handled or Success)"
    return 0 # Return success (0) for status 0 and 1, failure (1) for others.
}


# --- delete_single_key ---
#
# @description Interactively prompts the user to select a key file (from a list
#              of potential keys found in $SSH_DIR) and attempts to delete that
#              specific key from the ssh-agent using `ssh-add -d <key_path>`.
# @arg        None
# @requires   Global variable $SSH_DIR must point to a readable directory.
# @requires   Global variable $KEYS_LIST_TMP must be a writable path for temp file.
# @requires   An accessible ssh-agent (checked via ssh-add -l).
# @modifies   Removes the selected key from the running ssh-agent.
# @modifies   Overwrites the temporary file $KEYS_LIST_TMP via update_keys_list_file.
# @return     0 If the operation was cancelled by the user OR if the selected key
#               was successfully deleted OR if there were no keys to delete initially.
# @return     1 If there's an error connecting to the agent, finding/listing key files,
#               reading user input, or if the `ssh-add -d` command fails.
# @prints     A numbered list of potential key files, prompts for user input,
#             and status messages about the deletion attempt to stdout/stderr.
# @reads      User input from /dev/tty for selection.
# @stdout     Menu/list of keys, prompts, success/failure/cancellation messages.
# @stderr     Error messages (e.g., connection failure, deletion failure).
# @depends    Global variables: SSH_DIR, KEYS_LIST_TMP.
#             Functions: update_keys_list_file, log_debug, log_info, log_error, log_warn.
#             External command: ssh-add, mapfile (bash 4+), read, printf, wc, echo.
# ---
delete_single_key() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n--- Delete Single Key from Agent ---\n"

    # Ensure the agent is running before proceeding
    if ! ensure_ssh_agent; then
        log_error "Cannot delete single key: Failed to ensure SSH agent is running."
        # ensure_ssh_agent prints detailed errors
        printf "Error: Agent not available. Cannot delete key.\n" >&2
        return 1
    fi

    # 1. Check Agent Status and Key Presence
    #    Use `ssh-add -l` to check if agent is running AND if it has keys.
    local agent_check_status list_output return_status=1 # Default to failure
    if list_output=$(ssh-add -l 2>&1); then
        agent_check_status=0 # Command succeeded (agent running, might have keys or be empty).
    else
        agent_check_status=$? # Capture failure status (1=no keys, 2=no agent, etc.)
    fi
    log_debug "Initial \`ssh-add -l\` check status: $agent_check_status"

    # --- Handle Initial Agent Check Result ---
    if [ "$agent_check_status" -eq 1 ]; then
        # Status 1: Agent running but no keys, or possibly agent not running (depends on ssh-add version).
        # Treat this consistently: inform user no keys/agent found for deletion.
        log_info "delete_single_key: \`ssh-add -l\` reported no keys or could not query agent (status: 1)."
        printf "No keys currently loaded in the agent (or agent not running) to delete from.\n" >&2
        return_status=0 # Consider this success (nothing to do).
    elif [ "$agent_check_status" -ne 0 ]; then
        # Status 2 or other error: Failed to connect to agent.
        log_warn "delete_single_key: Cannot query agent to list keys (\`ssh-add -l\` status: $agent_check_status)."
        printf "Error: Could not query the SSH agent (status: %d). Cannot proceed with deletion.\n" "$agent_check_status" >&2
        return_status=1 # Failure: Cannot connect.
    else
        # Status 0: Agent running and has keys. Proceed to list and prompt.
        # Count keys from the output.
        local key_count
        key_count=$(echo "$list_output" | wc -l)
        key_count=${key_count##* } # Trim whitespace.
        log_debug "Agent query successful (\`ssh-add -l\` status 0), found $key_count keys listed."

        if [ "$key_count" -eq 0 ]; then
             # Should not happen if status was 0, but handle defensively.
             log_warn "delete_single_key: \`ssh-add -l\` status 0 but no keys were counted from output: '$list_output'"
             printf "No keys currently loaded in ssh-agent to delete.\n"
             return_status=0 # Success: Nothing to do.
        else
            # Agent has keys, list potential *files* to allow user selection.
            # Note: We list files from disk, not directly keys from agent, as `ssh-add -d` needs the file path.
            log_info "Agent has $key_count key(s) loaded. Listing potential key *files* from '$SSH_DIR' for deletion selection..."
            # Regenerate the list of potential key files on disk.
            if ! update_keys_list_file; then
                log_error "delete_single_key: Failed to get list of potential key files from '$SSH_DIR'. Cannot proceed."
                # update_keys_list_file prints messages if no files found.
                return 1 # Failure: Cannot get file list.
            fi
            # Check if the temp file exists and is non-empty.
            if [ ! -s "$KEYS_LIST_TMP" ]; then
                # This indicates an inconsistency: agent has keys, but we found no matching files on disk?
                log_error "delete_single_key: Inconsistency - agent reports keys, but update_keys_list_file found no potential key files in '$SSH_DIR' (temp file '$KEYS_LIST_TMP' is empty)."
                printf "Error: Inconsistency detected - agent reports keys, but no potential key files found on disk.\n" >&2
                return 1 # Failure: Inconsistent state.
            fi

            # Read the list of potential key files into an array.
            local key_files=()
            mapfile -t key_files < "$KEYS_LIST_TMP" || {
                 log_error "Failed to read key filenames from temporary file '$KEYS_LIST_TMP' into array.";
                 printf "Error reading temporary key list file.\n" >&2;
                 return 1;
            }
            if [ ${#key_files[@]} -eq 0 ]; then
                log_error "delete_single_key: Read 0 keys into array from '$KEYS_LIST_TMP'."
                printf "Error reading key file list or list was unexpectedly empty after read.\n" >&2
                return 1
            fi

            # 2. Display List and Get User Selection
            printf "Select a key file to remove from the agent (corresponding identity will be removed):\n"
            local i choice selected_index selected_filename key_path del_status
            # Print numbered list of files found on disk.
            for i in "${!key_files[@]}"; do
                printf "  %2d) %s\n" "$((i + 1))" "${key_files[i]}"
            done

            # Loop until valid input or cancellation.
            while true; do
                read -r -p "Enter key number to delete (or 'c' to cancel): " choice < /dev/tty
                log_debug "User entered deletion selection: '$choice'"
                case "$choice" in
                    c|C)
                        # User cancelled.
                        printf "Operation cancelled.\n"
                        log_info "User cancelled single key deletion."
                        return_status=0 # Cancellation is considered success.
                        break ;; # Exit the while loop.
                    *)
                        # Validate the user's choice.
                        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#key_files[@]}" ]; then
                            # Valid number within range.
                            selected_index=$((choice - 1)) # Convert to 0-based index.
                            selected_filename="${key_files[$selected_index]}"
                            key_path="$SSH_DIR/$selected_filename"
                            log_info "User selected key file #$choice: '$selected_filename' for deletion from agent."
                            printf "Attempting to delete identity corresponding to key file: %s\n" "$selected_filename"

                            # 3. Attempt Deletion
                            log_info "Executing: ssh-add -d '$key_path'"
                            # Execute `ssh-add -d` with the key file path. Redirect stderr to /dev/null.
                            ssh-add -d "$key_path" 2>/dev/null || true
                            del_status=${PIPESTATUS[0]:-$?} # Capture exit status.
                            log_debug "\`ssh-add -d '$key_path'\` finished with status: $del_status"

                            # --- Handle ssh-add -d Exit Status ---
                            if [ "$del_status" -eq 0 ]; then
                                # Status 0: Success.
                                printf "Identity corresponding to key '%s' successfully deleted from agent.\n" "$selected_filename"
                                log_info "Successfully deleted identity for '$key_path' from agent."
                                return_status=0 # Success.
                            else
                                # Status non-zero: Failure.
                                printf "Error: Failed to delete identity for key '%s' from agent (ssh-add -d status: %d).\n" "$selected_filename" "$del_status" >&2
                                log_error "Failed to delete identity for key '$key_path' from agent (status: $del_status)."
                                # Provide hint for common failure cause (status 1).
                                if [ "$del_status" -eq 1 ]; then
                                    printf "       (This often means the identity wasn't loaded or the key file path is incorrect.)\n" >&2
                                    log_warn "ssh-add -d status 1 may indicate identity wasn't loaded."
                                fi
                                return_status=1 # Failure.
                            fi
                            break # Exit the while loop after attempt.
                        else
                            # Invalid input (not a number or out of range).
                            printf "Invalid selection. Please enter a number between 1 and %d, or 'c' to cancel.\n" "${#key_files[@]}"
                        fi ;;
                esac
            done # End while loop for user input.
        fi # End if key_count > 0.
    fi # End of initial agent status check.

    log_debug "Exiting function: ${FUNCNAME[0]} (Overall status: $return_status)"
    return $return_status
}


# --- delete_all_keys ---
#
# @description Deletes all keys currently loaded in the ssh-agent after prompting
#              the user for confirmation.
# @arg        None
# @requires   An accessible ssh-agent (checked via ssh-add -l).
# @modifies   Removes all identities from the running ssh-agent.
# @return     0 If the operation was cancelled by the user OR if all keys were
#               successfully deleted (or if no keys were present initially).
# @return     1 If there was an error connecting to the agent OR if the underlying
#               `delete_keys_from_agent` function failed unexpectedly after confirmation.
# @prints     Status messages about loaded keys, confirmation prompt, and success/failure
#             messages to stdout/stderr.
# @reads      User input ('y'/'Y') from /dev/tty for confirmation.
# @stdout     Messages about loaded keys, confirmation prompt, cancellation/success message.
# @stderr     Error messages (e.g., connection failure).
# @depends    Functions: delete_keys_from_agent, log_debug, log_info, log_error, log_warn.
#             External command: ssh-add, wc, read, printf, echo.
# ---
delete_all_keys() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Delete All Keys from Agent +++\n"

    # Ensure the agent is running before attempting deletion
    if ! ensure_ssh_agent; then
        log_error "Cannot delete all keys: Failed to ensure SSH agent is running."
        # ensure_ssh_agent prints detailed errors
        printf "Error: Agent not available. Cannot delete keys.\n" >&2
        return 1 # Return failure, don't proceed to confirmation
    fi

    # 1. Check Agent Status and Key Count
    local agent_check_status key_count=0 list_output="" return_status=1 # Default to failure

    # Use `ssh-add -l` to check agent status and get key list if present.
    if list_output=$(ssh-add -l 2>&1); then
        agent_check_status=0 # Command succeeded.
    else
        agent_check_status=$? # Capture failure status.
    fi
    log_debug "Initial \`ssh-add -l\` check status: $agent_check_status"

    # --- Handle Initial Agent Check Result ---
    if [ "$agent_check_status" -eq 0 ]; then
        # Status 0: Agent reachable. Count keys from the output.
        key_count=$(echo "$list_output" | wc -l)
        key_count=${key_count##* } # Trim whitespace.
        log_debug "Agent query successful (\`ssh-add -l\` status 0), counted $key_count keys."

        if [ "$key_count" -eq 0 ]; then
            # Agent is running but empty.
            printf "No keys currently loaded in ssh-agent. Nothing to delete.\n"
            log_info "delete_all_keys: No keys loaded, nothing to do."
            return_status=0 # Success (no action needed).
        else
            # Keys are present, proceed with confirmation.
            printf "This will attempt to delete all %d keys currently loaded in the ssh-agent.\n" "$key_count"
            local confirm
            # Prompt user for confirmation, reading from TTY.
            read -r -p "Are you sure you want to continue? (y/N): " confirm < /dev/tty
            log_debug "User confirmation input: '$confirm'"

            # Process confirmation.
            case "$confirm" in
                y|Y)
                    # User confirmed.
                    log_info "User confirmed deletion of all keys. Proceeding..."
                    # Call the underlying function that performs `ssh-add -D`.
                    if delete_keys_from_agent; then
                        # Underlying deletion succeeded.
                        return_status=0 # Success.
                    else
                        # Underlying deletion failed (already logged/printed by that function).
                        return_status=1 # Failure.
                    fi
                    ;;
                *)
                    # User did not confirm (entered 'n', nothing, or anything else).
                    printf "Operation cancelled by user.\n"
                    log_info "User cancelled deletion of all keys."
                    return_status=0 # Cancellation is considered success.
                    ;;
            esac
        fi

    elif [ "$agent_check_status" -eq 1 ]; then
        # Status 1: Agent might be running but empty, or agent might not be running.
        # Provide a clearer message than just "Error".
        log_info "delete_all_keys: Could not query agent or no keys loaded (\`ssh-add -l\` status: 1)." # Log as info.
        printf "No keys currently loaded in the agent (or agent not running). Cannot delete keys.\n" >&2 # User message.
        return_status=1 # Treat inability to query decisively as failure for delete operation.
    elif [ "$agent_check_status" -eq 2 ]; then
        # Status 2: Cannot connect to agent.
        log_warn "delete_all_keys: Cannot connect to agent (\`ssh-add -l\` status: 2)." # Log as warn.
        printf "Error: Could not connect to the SSH agent (Status: 2). Cannot delete keys.\n" >&2 # User message.
        return_status=1 # Failure.
    else
        # Other errors.
        log_warn "delete_all_keys: Error querying agent (\`ssh-add -l\` status: $agent_check_status)." # Log as warn.
        printf "Error: Could not query the SSH agent (Unexpected Status: %d). Cannot delete keys.\n" "$agent_check_status" >&2 # User message.
        return_status=1 # Failure.
    fi

    log_debug "Exiting function: ${FUNCNAME[0]} (Overall status: $return_status)"
    return $return_status
}
# ==============================================================================
# --- End of Library ---
# ==============================================================================
 