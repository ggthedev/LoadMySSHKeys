# SSH Key Manager Script Control Flow

**Scenario:** User executes `./sshkeymanager.sh -m`, selects option `6` (Delete All Keys), confirms, and then selects `q` (Quit).

1.  **Script Invocation:**
    *   User runs `./sshkeymanager.sh -m` in the terminal.
    *   The script starts execution.
    *   The global `_script_start_time` is recorded.
    *   `set -euo pipefail` is applied (unless commented out).
    *   Global variables are declared.
    *   The `EXIT` and `ERR` traps are set to call `_script_exit_handler` upon script termination.

2.  **`main()` Function Execution:**
    *   The script enters the `main()` function with `-m` as an argument.
    *   **Argument Parsing:**
        *   The `while` loop processes arguments.
        *   `case $arg in` matches `-m|--menu)`.
        *   Global `ACTION` is set to `"menu"`.
        *   `FIRST_ACTION_SET` flag is set to `1`.
        *   Argument parsing completes without error (`parse_error=0`).
    *   **Runtime Initialization:**
        *   `setup_logging()` is called:
            *   Determines log directory (`LOG_DIR`).
            *   Creates log directory if needed.
            *   Sets `LOG_FILE` path.
            *   Touches log file.
            *   Performs log rotation if necessary.
            *   Sets log file permissions (600).
            *   Logs initial debug messages (if `IS_VERBOSE` is true).
        *   `mktemp` creates a temporary file path and assigns it to `KEYS_LIST_TMP`.
    *   **Action Dispatch:**
        *   `case $ACTION in` evaluates the `ACTION` variable.
        *   It matches `menu)`.
        *   The `run_interactive_menu()` function is called.

3.  **`run_interactive_menu()` Function Execution (Loop 1):**
    *   Logs "Starting SSH Key Manager in Interactive Mode...".
    *   `validate_ssh_dir()` is called to check `$SSH_DIR`. (Assumed success).
    *   The `while true` loop starts.
    *   `display_main_menu()` is called:
        *   Clears the screen (`clear`).
        *   Prints the menu options using `printf`.
    *   `get_menu_choice()` is called:
        *   Prints prompt "Enter choice [1-6, q]: " to `/dev/tty`.
        *   Reads user input (user enters `6`).
        *   Validates the input.
        *   Returns the choice `"6"`.
    *   `choice` variable is set to `"6"`.
    *   Logs "User selected menu option: [6]".
    *   `case "$choice"` matches `6)`.
    *   Logs "Main loop - Case 6: Calling delete_all_keys...".
    *   Logs "Menu Delete All Keys: Ensuring agent is running...".
    *   `ensure_ssh_agent()` is called:
        *   Checks if `SSH_AUTH_SOCK` and `SSH_AGENT_PID` are set and valid via `check_ssh_agent()`.
        *   If not valid, checks if `AGENT_ENV_FILE` exists and sources it.
        *   Re-checks agent validity via `check_ssh_agent()`.
        *   If still not valid or file doesn't exist, starts a new `ssh-agent -s`.
        *   Parses and exports new `SSH_AUTH_SOCK` and `SSH_AGENT_PID`.
        *   Saves the new environment to `AGENT_ENV_FILE`.
        *   Performs a final `check_ssh_agent()`.
        *   (Assumed success, returns 0).
    *   `if ! ensure_ssh_agent` condition is false, script continues.
    *   `delete_all_keys()` is called.

4.  **`delete_all_keys()` Function Execution:**
    *   Logs "Entering function: delete_all_keys".
    *   Prints "+++ Delete All Keys from Agent +++".
    *   Checks agent status using `if list_output=$(ssh-add -l 2>&1); then ... else ... fi`:
        *   Runs `ssh-add -l`. (Assume keys *are* loaded, command succeeds, `exit_code=0`).
        *   `agent_check_status` is set to `0`.
    *   `if [ "$agent_check_status" -eq 0 ]` is true.
    *   `key_count` is calculated using `echo "$list_output" | wc -l`. (Assume `key_count` > 0).
    *   `has_keys` is set to `1`.
    *   `if [ "$has_keys" -eq 0 ]` condition is false.
    *   Prints "This will delete all X keys from ssh-agent." (where X is `key_count`).
    *   Prompts the user "Are you sure you want to continue? (y/N): " using `read < /dev/tty`.
    *   User enters `y`.
    *   `case "$confirm"` matches `y|Y)`.
    *   Logs "User confirmed deletion of all keys.".
    *   `delete_keys_from_agent()` is called.

5.  **`delete_keys_from_agent()` Function Execution:**
    *   Logs "Entering function: delete_keys_from_agent".
    *   Logs "Attempting to delete all keys from ssh-agent (ssh-add -D)...".
    *   Runs `ssh-add -D >/dev/null 2>&1 || true`.
    *   Captures the exit status in `del_status`. (Assume success, `del_status=0`).
    *   `case "$del_status"` matches `0)`.
    *   Logs "All keys successfully deleted from agent.".
    *   Prints "All keys successfully deleted from agent.".
    *   Returns `0`.

6.  **`delete_all_keys()` Function Execution (Continued):**
    *   `if delete_keys_from_agent` condition is true (returned 0).
    *   `return_status` is set to `0`.
    *   Logs "Exiting function: delete_all_keys (status: 0)".
    *   Returns `0`.

7.  **`run_interactive_menu()` Function Execution (Loop 1 Continued):**
    *   `wait_for_key()` is called:
        *   Prints "Press Enter to return to the main menu...".
        *   Waits for user to press Enter using `read`.
    *   Logs "Main loop - End of iteration for choice: 6".
    *   The `while true` loop continues.

8.  **`run_interactive_menu()` Function Execution (Loop 2):**
    *   `display_main_menu()` is called (prints menu again).
    *   `get_menu_choice()` is called:
        *   Prompts user.
        *   User enters `q`.
        *   Returns `"q"`.
    *   `choice` variable is set to `"q"`.
    *   Logs "User selected menu option: [q]".
    *   `case "$choice"` matches `q|Q)`.
    *   Logs "User selected Quit from menu.".
    *   Prints "\nThank you for using SSH Key Manager. Goodbye!\n".
    *   `exit 0` is executed.

9.  **Script Exit Handling:**
    *   The `exit 0` command triggers the `EXIT` trap.
    *   `_script_exit_handler()` is called.
        *   The exit status `0` is captured in `exit_status`.
        *   Logs "_script_exit_handler triggered (Script Exit Status: 0)".
        *   `_cleanup_temp_file()` is called:
            *   Removes the temporary file pointed to by `KEYS_LIST_TMP` using `rm -f`.
        *   `log_execution_time()` is called:
            *   Calculates script duration using current time and `_script_start_time`.
            *   Logs the total execution time.
        *   Logs "_script_exit_handler finished.".
    *   The script terminates with exit code `0`.

```text
./sshkeymanager.sh -m
 |
 V
main()
 |
 +--> Parse Args (-m -> ACTION="menu")
 |
 +--> setup_logging()
 |
 +--> Create Temp File
 |
 +--> Dispatch (ACTION="menu")
 |
 V
run_interactive_menu() [LOOP START]
 |
 +--> validate_ssh_dir()
 |
 +--> display_main_menu()
 |
 +--> get_menu_choice() -> '6'
 |
 +--> ensure_ssh_agent()
 |
 V
delete_all_keys()
 |
 +--> ssh-add -l (Check Status)
 |     |
 |     +-- Status 0 (Keys Found) --> Calculate Count
 |     |                              |
 |     |                              +--> Prompt Confirm ('y/N')
 |     |                              |
 |     |                              +--> User Enters 'y'
 |     |                              |
 |     |                              V
 |     |                           delete_keys_from_agent()
 |     |                              |
 |     |                              +--> ssh-add -D
 |     |                              |
 |     |                              +--> Return 0 (Success)
 |     |                              |
 |     |                              V
 |     |                           Return 0 (Success)
 |     |
 |     +-- Status 1 (No Keys) ----> Print "No Keys Loaded"
 |     |                              |
 |     |                              V
 |     |                           Return 0 (Success)
 |     |
 |     +-- Status 2 (No Agent) ---> Print "Error: No Agent"
 |                                    |
 |                                    V
 |                                 Return 1 (Failure)
 |
 V
(Returns 0 from delete_all_keys)
 |
 +--> wait_for_key() (User presses Enter)
 |
 V
run_interactive_menu() [LOOP RESTART]
 |
 +--> display_main_menu()
 |
 +--> get_menu_choice() -> 'q'
 |
 +--> Print "Goodbye!"
 |
 +--> exit 0
 |
 V
[EXIT TRAP] -> _script_exit_handler()
 |
 +--> cleanup_temp_file()
 |
 +--> log_execution_time()
 |
 V
[SCRIPT ENDS (Status 0)]
```
