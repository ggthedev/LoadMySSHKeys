#!/usr/bin/env bash
# ==============================================================================
# Library: menu.sh
# Description: Provides interactive menu functions for sshkeymanager.sh,
#              allowing users to manage SSH keys and settings through a
#              text-based interface.
# Dependencies: Relies on functions from several other libraries:
#                 - lib/logging.sh (log_debug, log_info, log_error, log_warn)
#                 - lib/agent.sh (ensure_ssh_agent)
#                 - lib/key_ops.sh (update_keys_list_file, delete_keys_from_agent,
#                   add_keys_to_agent, list_current_keys, delete_single_key,
#                   delete_all_keys, load_specific_keys)
#                 - lib/validation.sh (validate_ssh_dir)
#               Relies on global variables set by the main script:
#                 - PLATFORM: OS type ("Darwin", "Linux", etc.).
#                 - SSH_DIR: Path to the user's SSH directory.
#                 - HOME: Path to the user's home directory.
#                 - LOG_FILE: Full path to the current log file (or /dev/null).
#                 - KEYS_LIST_TMP: Path to a temporary file for listing discovered keys.
#                 - VALID_KEY_LIST_FILE: Path to the persistent list of keys to load.
# ==============================================================================

# --- Safety Check ---
# Ensure this script is sourced, not executed directly. Protects against unintended execution.
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "Error: This script (menu.sh) should be sourced, not executed directly." >&2
    exit 1
fi

# ==============================================================================
# --- Interactive Menu Functions ---
# ==============================================================================

# --- display_main_menu ---
#
# @description Clears the screen and displays the main menu options to the user.
#              Includes information about the current platform and SSH directory.
# @arg        None
# @stdout     Formatted main menu text.
# @stderr     None
# @depends    Global variables: PLATFORM, SSH_DIR.
#             Functions: log_debug.
#             External command: clear, printf.
# ---
display_main_menu() {
    log_debug "Displaying main menu..."
    # Clear the terminal screen for a clean menu display.
    clear
    # Print the menu header and current settings.
    printf "\n======= SSH Key Manager Menu =======\n"
    printf " Platform: %s\n" "$PLATFORM"
    printf " SSH Directory: %s\n" "$SSH_DIR"
    printf "+++++++++++++++++++++++++++++++++++\n"
    # List the available menu options.
    printf " Please choose an option:\n"
    printf "   1) Set SSH Directory\n"
    printf "   2) List Current Loaded Keys\n"
    printf "   3) Load Specific Key(s)\n"
    printf "   4) Delete Single Key from Agent\n"
    printf "   5) Delete All Keys from Agent\n"
    printf "   6) Reload All Keys (from selected dir)\n" # Changed description for clarity
    printf "   7) Display Log File Info\n"
    printf "   q) Quit\n"
    printf "+++++++++++++++++++++++++++++++++++\n"
}

# --- get_menu_choice ---
#
# @description Prompts the user to enter a menu choice and validates the input.
#              Loops until a valid choice (1-7 or q/Q) is entered.
# @arg        None
# @return     0 If a valid choice is entered.
# @echoes     The valid user choice to stdout.
# @stdout     The valid menu choice character ('1' through '7', 'q', or 'Q').
# @stderr     Error message for invalid choices.
# @reads      User input from /dev/tty.
# @depends    Functions: log_debug, log_warn.
#             External command: read, printf, echo.
# ---
get_menu_choice() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    local choice
    while true; do
        # Prompt user for input, reading directly from the terminal.
        read -r -p "Enter choice [1-7, q]: " choice < /dev/tty
        log_debug "User entered selection: '$choice'"
        # Validate the input against allowed choices.
        case "$choice" in
            [1-7]|q|Q)
                # Valid choice entered. Echo it for command substitution and return success.
                echo "$choice"
                return 0
                ;;
            *)
                # Invalid choice. Print error message and log warning. Loop continues.
                printf "Invalid choice '%s'. Please try again.\n" "$choice" >&2
                log_warn "Invalid menu choice: '$choice'"
                ;;
        esac
    done
}

# --- wait_for_key ---
#
# @description Pauses execution and waits for the user to press the Enter key.
#              Used after menu actions to allow the user to see the output before
#              the menu is redisplayed.
# @arg        None
# @stdout     Prompt message "Press Enter to return to the main menu...".
# @reads      User input (Enter key press) from stdin.
# @depends    External command: printf, read.
# ---
wait_for_key() {
    printf "\nPress Enter to return to the main menu...\n"
    # Read and discard a line of input (effectively waiting for Enter).
    read -r
}

# --- set_ssh_directory ---
#
# @description Prompts the user to enter a new path for the SSH directory ($SSH_DIR).
#              Validates the entered path (must exist, be a directory, readable, executable).
#              Updates the global $SSH_DIR variable if the new path is valid.
#              Handles tilde (~) expansion for paths starting with '~/' or just '~'.
# @arg        None
# @modifies   Global variable: SSH_DIR (if validation passes).
# @return     0 If the directory is successfully updated or the operation is cancelled.
# @return     1 If the entered path is invalid (not a directory, permissions issue).
# @prints     Prompts and status messages to stdout/stderr.
# @reads      User input (new path) from /dev/tty.
# @stdout     Prompts, success message.
# @stderr     Error messages for invalid paths.
# @depends    Global variables: SSH_DIR, HOME.
#             Functions: log_debug, log_info, log_error.
#             External command: read, printf.
# ---
set_ssh_directory() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Set SSH Directory +++\n"
    printf "Current SSH Directory: %s\n" "$SSH_DIR"
    printf "Enter the new path for the SSH directory (leave blank to cancel):\n"

    local new_dir_input new_dir_resolved
    # Read user input directly from TTY.
    read -r -p "> " new_dir_input < /dev/tty

    # Handle cancellation (empty input).
    if [ -z "$new_dir_input" ]; then
        printf "Operation cancelled. SSH directory remains: %s\n" "$SSH_DIR"
        log_info "User cancelled setting SSH directory."
        return 0 # Cancellation is success.
    fi

    log_debug "User entered path: '$new_dir_input'"

    # --- Resolve Path with Tilde Expansion ---
    # Check if path starts with '~/'
    if [[ "$new_dir_input" == "~/"* ]]; then
        # Replace '~/' with the value of $HOME/.
        new_dir_resolved="$HOME/${new_dir_input:2}"
        log_debug "Resolved path from '~/' to: '$new_dir_resolved'"
    # Check if path is exactly '~'
    elif [[ "$new_dir_input" == "~" ]]; then
         # Replace '~' with the value of $HOME.
         new_dir_resolved="$HOME"
         log_debug "Resolved path from '~' to: '$new_dir_resolved'"
    else
        # Path does not start with tilde, use it as is.
        new_dir_resolved="$new_dir_input"
        log_debug "Path does not start with '~', using as is: '$new_dir_resolved'"
    fi

    # --- Validate Resolved Path ---
    log_info "Validating proposed SSH directory: $new_dir_resolved"
    local validation_passed=1 # Assume failure initially.

    # Check if it exists and is a directory.
    if [ ! -d "$new_dir_resolved" ]; then
        log_error "Validation failed: '$new_dir_resolved' is not a directory."
        printf "Error: '%s' is not a valid directory.\n" "$new_dir_resolved" >&2
    # Check if it's readable.
    elif [ ! -r "$new_dir_resolved" ]; then
        log_error "Validation failed: Directory '$new_dir_resolved' is not readable."
        printf "Error: Directory '%s' is not readable.\n" "$new_dir_resolved" >&2
    # Check if it's executable (needed to list contents/access files).
    elif [ ! -x "$new_dir_resolved" ]; then
        log_error "Validation failed: Directory '$new_dir_resolved' is not accessible (execute permission needed)."
        printf "Error: Directory '%s' is not accessible.\n" "$new_dir_resolved" >&2
    else
        # All checks passed.
        log_info "Validation successful for '$new_dir_resolved'."
        validation_passed=0 # Mark as success.
    fi

    # --- Update Global Variable if Valid ---
    if [ "$validation_passed" -eq 0 ]; then
        SSH_DIR="$new_dir_resolved" # Update the global variable.
        printf "SSH directory successfully updated to: %s\n" "$SSH_DIR"
        log_info "SSH_DIR updated to: $SSH_DIR"
        return 0 # Success.
    else
        # Validation failed. Inform user and return failure.
        printf "SSH directory remains unchanged: %s\n" "$SSH_DIR"
        return 1 # Failure.
    fi
} # END set_ssh_directory

# --- display_log_location ---
#
# @description Displays the location and current size of the log file, or indicates
#              if logging is disabled.
# @arg        None
# @uses       Global variable: LOG_FILE.
# @return     0 Always returns success.
# @prints     Log file path and size, or disabled message, to stdout.
# @stdout     Log file information.
# @stderr     None (Warnings logged if size check fails).
# @depends    Global variable: LOG_FILE.
#             Functions: log_debug, log_info, log_warn.
#             External commands: printf, ls, awk.
# ---
display_log_location() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n+++ Log File Information +++\n"
    # Check if logging is disabled (LOG_FILE set to /dev/null).
    if [ "$LOG_FILE" = "/dev/null" ]; then
        printf "Logging is currently disabled.\n"
        log_info "User requested log location: Logging is disabled."
    else
        # Logging is enabled. Display the path.
        printf "Current log file location: %s\n" "$LOG_FILE"
        local log_size_human="-"
        # Attempt to get human-readable size using `ls -lh`.
        if [ -f "$LOG_FILE" ]; then
            # Extract the size field (typically 5th field) from ls output.
            # Redirect stderr of ls to hide "No such file or directory" if it disappears racefully.
            log_size_human=$(ls -lh "$LOG_FILE" 2>/dev/null | awk '{print $5}')
             # If awk fails or ls fails, log_size_human might be empty or invalid.
            if [ -z "$log_size_human" ]; then
                 log_warn "Could not parse size from ls -lh output for $LOG_FILE"
                 log_size_human="(Size unavailable)"
            fi
        else
             log_warn "Log file $LOG_FILE not found when trying to get size."
             log_size_human="(File not found)"
        fi
        # Display the determined size.
        printf "Current log file size: %s\n" "$log_size_human"
        log_info "Displaying log file location: $LOG_FILE (Size: $log_size_human)"
    fi
    printf "+++++++++++++++++++++++++++++++++++\n"
    log_debug "Exiting function: ${FUNCNAME[0]} (Status: 0)"
    return 0 # Always successful from menu perspective.
}

# --- _perform_list_keys_check ---
#
# @description Internal helper function called by the menu's "List Keys" option.
#              Ensures the SSH agent is running before attempting to list keys.
#              Calls the `list_current_keys` function from key_ops library.
# @arg        None
# @return     0 If agent is running and key listing succeeds (or reports no keys).
# @return     1 If ensuring the agent fails.
# @prints     Status messages to stdout/stderr (handled by ensure_ssh_agent and list_current_keys).
# @stdout     Output from list_current_keys.
# @stderr     Errors from ensure_ssh_agent or list_current_keys.
# @depends    Functions: ensure_ssh_agent, list_current_keys, log_debug, log_error.
# ---
_perform_list_keys_check() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    printf "\n--- Listing Keys Currently in Agent ---\n"
    # First, ensure the agent is available.
    if ! ensure_ssh_agent; then
        log_error "_perform_list_keys_check: Cannot list keys, ensure_ssh_agent failed."
        # ensure_ssh_agent already prints error messages.
        return 1 # Failure: Agent not available.
    fi
    # Agent is running, proceed to list keys.
    log_debug "_perform_list_keys_check: Agent confirmed. Calling list_current_keys..."
    # list_current_keys handles printing the list or "no keys" message.
    # It returns 0 for success/no keys, 1 for agent connection errors.
    list_current_keys
    local list_status=$?
    log_debug "list_current_keys finished with status: $list_status"
    return $list_status # Return the status from list_current_keys.
}


# --- run_interactive_menu ---
#
# @description Main loop for the interactive menu mode. Displays the menu,
#              gets user input, and calls the appropriate function based on the choice.
#              Continues looping until the user chooses to quit.
# @arg        None
# @uses       Global variables: KEYS_LIST_TMP, VALID_KEY_LIST_FILE, SSH_DIR.
# @exits      With status 0 when the user selects 'q' or 'Q'.
# @exits      With status 1 if initial SSH directory validation fails.
# @stdout     Menu display, prompts, and output from called functions.
# @stderr     Error messages from called functions.
# @depends    Functions: display_main_menu, get_menu_choice, wait_for_key,
#             set_ssh_directory, _perform_list_keys_check, load_specific_keys,
#             delete_single_key, delete_all_keys, ensure_ssh_agent, update_keys_list_file,
#             add_keys_to_agent, delete_keys_from_agent, display_log_location,
#             validate_ssh_dir, log_debug, log_info, log_error, log_warn.
#             External commands: cp, chmod, printf, sleep.
# ---
run_interactive_menu() {
    log_debug "Entering function: ${FUNCNAME[0]}"
    log_info "Starting SSH Key Manager in Interactive Mode..."
    # Perform initial validation of the SSH directory before starting the loop.
    if ! validate_ssh_dir; then
        log_error "Exiting interactive mode: Initial SSH directory validation failed."
        # validate_ssh_dir prints specific errors.
        exit 1 # Exit script if essential directory is bad.
    fi

    local choice list_rc delete_rc
    # Main menu loop.
    while true; do
        display_main_menu
        choice=$(get_menu_choice) # Get validated user choice.
        log_info "User selected menu option: [$choice]"

        # Handle the user's choice.
        case "$choice" in
            1)  # Set SSH Directory
                log_debug "Main loop - Case 1: Calling set_ssh_directory..."
                # Call function, ignore return status (|| true) for menu flow.
                set_ssh_directory || true
                wait_for_key # Pause before redisplaying menu.
                ;;
            2)  # List Keys
                log_debug "Main loop - Case 2: Calling _perform_list_keys_check..."
                # Calls helper which ensures agent then lists.
                _perform_list_keys_check || true
                wait_for_key
                ;;
            3)  # Load Specific Key(s)
                log_debug "Main loop - Case 3: Calling load_specific_keys..."
                load_specific_keys || true
                wait_for_key
                ;;
            4)  # Delete Single Key
                log_debug "Main loop - Case 4: Calling delete_single_key..."
                delete_single_key || true
                wait_for_key
                ;;
            5)  # Delete All Keys
                log_debug "Main loop - Case 5: Calling delete_all_keys..."
                # Asks for confirmation internally.
                delete_all_keys || true
                wait_for_key
                ;;
            6)  # Reload All Keys (from selected dir)
                printf "\n--- Reload All Keys (from selected dir) ---\n"
                log_info "Menu: Reloading all keys selected (uses find -> delete -> add)."

                # Ensure agent is running first.
                if ! ensure_ssh_agent; then
                    log_error "Cannot reload keys: Failed to ensure SSH agent is running."
                    printf "Error: Agent not available. Cannot reload keys.\n" >&2
                    wait_for_key; continue # Go back to menu start.
                fi

                # Temporarily disable exit on error to handle update_keys_list_file status.
                set +e
                log_debug "Menu Reload Keys: Agent confirmed. Updating key list using update_keys_list_file..."
                local update_status=0
                # Run update_keys_list_file to find keys in SSH_DIR and write to temp file.
                update_keys_list_file
                update_status=$? # Capture status.

                # Check the result of finding keys.
                if [ "$update_status" -ne 0 ]; then
                    log_error "Menu Reload Keys: update_keys_list_file failed (status: $update_status)."
                    # Status 1 means no keys found, which is okay for reload (just means we clear agent).
                    if [ "$update_status" -eq 1 ]; then
                        log_info "Menu Reload Keys: No keys found by update_keys_list_file. Will proceed to clear agent keys."
                        # update_keys_list_file already printed "No keys found".
                        # Ensure the persistent list file is empty.
                        > "$VALID_KEY_LIST_FILE" || log_warn "Could not clear persistent key list file $VALID_KEY_LIST_FILE"
                    else
                        # Other error during update_keys_list_file (e.g., temp file not writable).
                        printf "Error finding keys in directory. Reload aborted.\n" >&2
                        set -e # Re-enable exit on error.
                        wait_for_key; continue # Back to menu.
                    fi
                else
                    # Keys were found (status 0). Copy the list from temp to persistent file.
                    log_debug "Copying found keys from temp file '$KEYS_LIST_TMP' to '$VALID_KEY_LIST_FILE'"
                    if ! cp "$KEYS_LIST_TMP" "$VALID_KEY_LIST_FILE"; then
                        log_error "Failed to copy temp key list '$KEYS_LIST_TMP' to '$VALID_KEY_LIST_FILE'. Reload aborted."
                        printf "Error copying key list. Reload aborted.\n" >&2
                        set -e # Re-enable exit on error.
                        wait_for_key; continue # Back to menu.
                    fi
                    # Secure the persistent key list file.
                    chmod 600 "$VALID_KEY_LIST_FILE" 2>/dev/null || log_warn "Could not set permissions on $VALID_KEY_LIST_FILE"
                fi

                # Delete existing keys from the agent *before* adding the new list.
                log_info "Deleting existing keys from agent before adding..."
                delete_keys_from_agent || true # Ignore failure here, proceed to add anyway.

                # Add keys based on the (potentially updated or cleared) persistent list file.
                log_info "Adding keys found in directory (from list $VALID_KEY_LIST_FILE)..."
                if [ -s "$VALID_KEY_LIST_FILE" ]; then
                    # If the list file exists and is not empty, add keys.
                    add_keys_to_agent
                    local add_status=$? # Capture status.
                    log_debug "add_keys_to_agent finished with status: $add_status"
                    # add_keys_to_agent prints its own summary.
                else
                    # If the list file is empty (either no keys found or cp failed earlier).
                    log_info "No keys found in the persistent list to add."
                    printf "No keys were found in the directory to add (or list was empty).\n"
                fi

                set -e # Re-enable exit on error.
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
                exit 0 # Exit the script cleanly.
                ;;
            *) # Should not be reachable due to get_menu_choice validation.
                log_error "Main loop - Reached unexpected default case for choice: $choice"
                printf "Error: Unexpected menu choice processed!\n" >&2
                sleep 2 # Pause briefly in case of error loop.
                ;;
        esac
        log_debug "Main loop - End of iteration for choice: $choice"
    done
} # END run_interactive_menu
# ==============================================================================
# --- End of Library ---
# ============================================================================== 