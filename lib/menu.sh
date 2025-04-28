#!/usr/bin/env bash
# Library for interactive menu functions for sshkeymanager.sh

# Ensure this script is sourced, not executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "This script should be sourced, not executed directly." >&2
    exit 1
fi

# --- Interactive Menu Helper Functions ---

# Depends on logging functions (log_debug, log_info, log_error, log_warn)
# Depends on agent functions (ensure_ssh_agent)
# Depends on key_ops functions (update_keys_list_file, delete_keys_from_agent, add_keys_to_agent, list_current_keys, delete_single_key, delete_all_keys, load_specific_keys)
# Depends on validation functions (validate_ssh_dir, validate_directory)
# Depends on internal helper functions (_perform_list_keys_check)
# Depends on global variables: PLATFORM, SSH_DIR, HOME, LOG_FILE, KEYS_LIST_TMP, VALID_KEY_LIST_FILE

# --- display_main_menu ---
# ... (description omitted for brevity)
display_main_menu() {
    log_debug "Displaying main menu..."
    clear
    printf "\n======= SSH Key Manager Menu =======\n"
    printf " Platform: %s\n" "$PLATFORM"
    printf " SSH Directory: %s\n" "$SSH_DIR"
    printf "+++++++++++++++++++++++++++++++++++\n"
    printf " Please choose an option:\n"
    printf "   1) Set SSH Directory\n"
    printf "   2) List Current Loaded Keys\n"
    printf "   3) Load Specific Key(s)\n"
    printf "   4) Delete Single Key from Agent\n"
    printf "   5) Delete All Keys from Agent\n"
    printf "   6) Reload All Keys (using find)\n"
    printf "   7) Display Log File Info\n"
    printf "   q) Quit\n"
    printf "+++++++++++++++++++++++++++++++++++\n"
}

# --- get_menu_choice ---
# ... (description omitted for brevity)
get_menu_choice() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local choice
    while true; do
        read -r -p "Enter choice [1-7, q]: " choice < /dev/tty
        log_debug "User entered selection: '$choice'"
        case "$choice" in
            [1-7]|q|Q) echo "$choice"; return 0 ;; # Updated range
            *) printf "Invalid choice '%s'. Please try again.\n" "$choice"; log_warn "Invalid menu choice: '$choice'" ;;
        esac
    done
}

# --- wait_for_key ---
# ... (description omitted for brevity)
wait_for_key() {
    printf "\nPress Enter to return to the main menu...\n"
    read -r 
}

# --- set_ssh_directory ---
# ... (description omitted for brevity)
set_ssh_directory() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Set SSH Directory +++\n"
    printf "Current SSH Directory: %s\n" "$SSH_DIR"
    printf "Enter the new path for the SSH directory (leave blank to cancel):\n"

    local new_dir_input new_dir_resolved
    read -r -p "> " new_dir_input < /dev/tty

    if [ -z "$new_dir_input" ]; then
        printf "Operation cancelled. SSH directory remains: %s\n" "$SSH_DIR"
        log_info "User cancelled setting SSH directory."
        return 0
    fi

    log_debug "User entered path: '$new_dir_input'"

    if [[ "$new_dir_input" == "~/"* ]]; then
        new_dir_resolved="$HOME/${new_dir_input:2}"
        log_debug "Resolved path from '~' to: '$new_dir_resolved'"
    elif [[ "$new_dir_input" == "~" ]]; then
         new_dir_resolved="$HOME"
         log_debug "Resolved path from '~' to: '$new_dir_resolved'"
    else
        new_dir_resolved="$new_dir_input"
        log_debug "Path does not start with '~', using as is: '$new_dir_resolved'"
    fi

    log_info "Validating proposed SSH directory: $new_dir_resolved"
    local validation_passed=1 # Assume failure initially

    if [ ! -d "$new_dir_resolved" ]; then
        log_error "Validation failed: '$new_dir_resolved' is not a directory."
        printf "Error: '%s' is not a valid directory.\n" "$new_dir_resolved" >&2
    elif [ ! -r "$new_dir_resolved" ]; then
        log_error "Validation failed: Directory '$new_dir_resolved' is not readable."
        printf "Error: Directory '%s' is not readable.\n" "$new_dir_resolved" >&2
    elif [ ! -x "$new_dir_resolved" ]; then
        log_error "Validation failed: Directory '$new_dir_resolved' is not accessible (executable permission needed)."
        printf "Error: Directory '%s' is not accessible.\n" "$new_dir_resolved" >&2
    else
        log_info "Validation successful for '$new_dir_resolved'."
        validation_passed=0 # Success!
    fi

    if [ "$validation_passed" -eq 0 ]; then
        SSH_DIR="$new_dir_resolved" # Update the global variable
        printf "SSH directory successfully updated to: %s\n" "$SSH_DIR"
        log_info "SSH_DIR updated to: $SSH_DIR"
        return 0
    else
        printf "SSH directory remains unchanged: %s\n" "$SSH_DIR"
        return 1 # Indicate failure
    fi
} # END set_ssh_directory

# --- display_log_location ---
# ... (description omitted for brevity)
display_log_location() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Log File Information +++\n"
    if [ "$LOG_FILE" = "/dev/null" ]; then
        printf "Logging is currently disabled.\n"
        log_info "User requested log location: Logging is disabled."
    else
        printf "Current log file location: %s\n" "$LOG_FILE"
        local log_size_human="-"
        if [ -f "$LOG_FILE" ]; then
            log_size_human=$(ls -lh "$LOG_FILE" 2>/dev/null | awk '{print $5}')
        else
             log_warn "Log file $LOG_FILE not found when trying to get size."
             log_size_human="(File not found)"
        fi
        printf "Current log file size: %s\n" "$log_size_human"
        log_info "Displaying log file location: $LOG_FILE (Size: $log_size_human)"
    fi
    printf "+++++++++++++++++++++++++++++++++++\n"
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0
}

# --- run_interactive_menu ---
# ... (description omitted for brevity)
run_interactive_menu() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Starting SSH Key Manager in Interactive Mode..."
    if ! validate_ssh_dir; then log_error "Exiting: SSH directory validation failed."; exit 1; fi
    local choice list_rc delete_rc
    while true; do
        display_main_menu
        choice=$(get_menu_choice)
        log_info "User selected menu option: [$choice]"
        case "$choice" in
            1)  # Set SSH Directory
                log_debug "Main loop - Case 1: Calling set_ssh_directory..."
                set_ssh_directory || true
                wait_for_key ;;
            2)  # List Keys
                log_debug "Main loop - Case 2: Calling _perform_list_keys_check..."
                _perform_list_keys_check || true
                wait_for_key ;;
            3)  # Load Specific Key(s)
                log_debug "Main loop - Case 3: Calling load_specific_keys..."
                load_specific_keys || true
                wait_for_key ;;
            4)  # Delete Single Key
                log_debug "Main loop - Case 4: Calling delete_single_key..."
                delete_single_key || true
                wait_for_key ;;
            5)  # Delete All Keys
                log_debug "Main loop - Case 5: Calling delete_all_keys..."
                delete_all_keys || true
                wait_for_key ;;
            6)  # Reload All Keys (using find)
                printf "\n--- Reload All Keys (using find) ---\n"
                log_info "Menu: Reloading all keys selected (uses find -> delete -> add)."
                if ! ensure_ssh_agent; then
                    log_error "Cannot reload keys: Failed to ensure SSH agent is running."
                    printf "Error: Agent not available. Cannot reload keys.\n" >&2
                    wait_for_key; continue
                fi
                set +e
                log_debug "Menu Reload Keys: Agent confirmed. Updating key list..."
                local update_status=0
                update_keys_list_file || update_status=$?
                if [ "$update_status" -ne 0 ]; then
                    log_error "Menu Reload Keys: update_keys_list_file failed (status: $update_status)."
                    if [ "$update_status" -eq 1 ]; then
                        log_info "Menu Reload Keys: No keys found by 'find'. Will still clear agent keys."
                        printf "No potential key files found in %s.\n" "$SSH_DIR"
                        > "$VALID_KEY_LIST_FILE" || log_warn "Could not clear $VALID_KEY_LIST_FILE"
                    else
                        printf "Error finding keys. Reload aborted.\n" >&2
                        set -e
                        wait_for_key; continue
                    fi
                else
                    log_debug "Copying found keys from temp file '$KEYS_LIST_TMP' to '$VALID_KEY_LIST_FILE'"
                    if ! cp "$KEYS_LIST_TMP" "$VALID_KEY_LIST_FILE"; then
                        log_error "Failed to copy temp key list '$KEYS_LIST_TMP' to '$VALID_KEY_LIST_FILE'. Reload aborted."
                        printf "Error copying key list. Reload aborted.\n" >&2
                        set -e
                        wait_for_key; continue
                    fi
                    chmod 600 "$VALID_KEY_LIST_FILE" 2>/dev/null || log_warn "Could not set permissions on $VALID_KEY_LIST_FILE"
                fi
                log_info "Deleting existing keys before adding..."
                    delete_keys_from_agent
                log_info "Adding keys found by find (from list $VALID_KEY_LIST_FILE)..."
                if [ -s "$VALID_KEY_LIST_FILE" ]; then
                    add_keys_to_agent
                    local add_status=$?
                    log_debug "add_keys_to_agent finished with status: $add_status"
                else
                    log_info "No keys found to add after filtering/copying."
                    printf "No keys were found in the directory to add.\n"
                fi
                set -e
                wait_for_key 
                ;; 
            7)  # Display Log Location
                log_debug "Main loop - Case 7: Calling display_log_location..."
                display_log_location
                wait_for_key 
                ;;
            q|Q) # Quit
                log_info "User selected Quit from menu."
                printf "\nThank you for using SSH Key Manager. Goodbye!\n"
                exit 0 
                ;;
            *) # Should not happen
                log_error "Main loop - Reached unexpected default case for choice: $choice"
                printf "Error: Unexpected menu choice processed!\n" >&2
                sleep 2 ;;
        esac
        log_debug "Main loop - End of iteration for choice: $choice"
    done
} 