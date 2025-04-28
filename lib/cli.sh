#!/usr/bin/env bash
# ==============================================================================
# Library: cli.sh
# Description: Provides command-line interface (CLI) related functions for
#              sshkeymanager.sh, including argument parsing, help display,
#              and dispatching actions based on CLI options.
# Dependencies: Relies on functions from other libraries:
#                 - lib/logging.sh (log_debug, log_info, log_error, log_warn)
#                 - lib/validation.sh (validate_ssh_dir)
#                 - lib/agent.sh (check_ssh_agent, ensure_ssh_agent)
#                 - lib/key_ops.sh (list_current_keys, update_keys_list_file,
#                   delete_keys_from_agent, add_keys_to_agent, delete_all_keys)
#                 - lib/arg_helpers.sh (_check_gnu_getopt)
#               Relies on global variables set by the main script:
#                 - ACTION, source_key_file, IS_VERBOSE (set by parse_args)
#                 - GNU_GETOPT_CMD (set by _check_gnu_getopt)
#                 - AGENT_ENV_FILE, SSH_DIR, VALID_KEY_LIST_FILE, KEYS_LIST_TMP
#                 - LOG_DIR, LOG_FILENAME
# ==============================================================================

# --- Safety Check ---
# Ensure this script is sourced, not executed directly.
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    echo "Error: This script (cli.sh) should be sourced, not executed directly." >&2
    exit 1
fi

# ==============================================================================
# --- Help / Usage Function ---
# ==============================================================================

# --- usage ---
#
# @description Displays the help message (usage instructions) for the script.
#              Renamed from display_help. Uses a heredoc for easy formatting.
#              Shows dynamically determined paths where possible.
# @arg        None
# @prints     The help text to stdout.
# @stdout     Formatted help message.
# @stderr     None
# @depends    Global variables: SSH_DIR, LOG_DIR (potentially unset), LOG_FILENAME (potentially unset),
#             AGENT_ENV_FILE, VALID_KEY_LIST_FILE.
#             External command: basename, cat.
# ---
usage() {
    # Use cat heredoc for easier formatting.
    # Show default/determined paths. Use :-<unavailable> if variables might not be set yet
    # (e.g., if called due to early argument parse error before setup_logging).
    cat << EOF
SSH Key Manager - $(basename "$0")

Manages SSH keys in the ssh-agent via command-line options or an interactive menu.

Usage: $(basename "$0") [OPTIONS]

Options:
  -l, --list          List keys currently loaded in the ssh-agent. Checks current
                      environment and persisted agent file ($AGENT_ENV_FILE).
  -a, --add           Finds potential private key files (no extension, not known_hosts, etc.)
                      in the SSH directory ($SSH_DIR), deletes all existing keys
                      from the agent, then adds the found keys. Passphrases may be
                      prompted if keys are protected.
  -f <file>, --file <file>
                      Deletes all existing keys from the agent, then adds keys whose
                      basenames are listed (one per line) in the specified <file>.
                      Lines starting with '#' and blank lines in <file> are ignored.
                      Keys must reside in $SSH_DIR.
  -D, --delete-all    Delete all keys currently loaded in the ssh-agent. Prompts for
                      confirmation before proceeding.
  -m, --menu          Show the interactive text-based menu interface for managing keys.
  -g, --generate [type] [bits] [comment] [filename]
                      Generate a new SSH key pair (interactive prompts if args missing).
  -X, --delete-pair <key_basename>
                      Delete an SSH key pair (both private and public files) from disk.
                      Prompts for confirmation. <key_basename> is the name without .pub.
  -v, --verbose       Enable verbose (DEBUG level) logging to the log file. Useful
                      for troubleshooting.
  -h, --help          Display this help message and exit.

Default Behavior:
  If run without any options, this help message is displayed.

Examples:
  $(basename "$0") --list          # List loaded keys
  $(basename "$0") --add           # Reload keys based on 'find' in $SSH_DIR
  $(basename "$0") --file my_keys.txt # Load keys listed in my_keys.txt
  $(basename "$0") --delete-all    # Delete all loaded keys (prompts)
  $(basename "$0") --menu          # Start the interactive menu
  $(basename "$0") --generate      # Generate key interactively
  $(basename "$0") --delete-pair id_rsa # Delete id_rsa and id_rsa.pub
  $(basename "$0")                 # Show this help message

Configuration Files & Paths:
  SSH Directory:       ${SSH_DIR:-$HOME/.ssh}
  Agent Env File:    ${AGENT_ENV_FILE:-$HOME/.config/agent.env}
  Internal Key List: ${VALID_KEY_LIST_FILE:-$HOME/.config/sshkeymanager/ssh_keys_list} (Used by -f, -a, menu reload)
  Log File Target:   ${LOG_DIR:-<determined_at_runtime>}/${LOG_FILENAME:-sshkeymanager.log}
                     (Actual path depends on permissions/environment variables like SKM_LOG_DIR)

EOF
}

# ==============================================================================
# --- Argument Parsing Function ---
# ==============================================================================

# --- parse_args ---
#
# @description Parses command-line arguments using GNU getopt if available,
#              otherwise uses a simple fallback parser. Sets global variables
#              ACTION, source_key_file, and IS_VERBOSE based on the parsed arguments.
#              Handles --help directly by calling usage() and exiting.
# @arg        $@ All command-line arguments passed to the script from main().
# @set        ACTION Global variable indicating the primary action to perform (e.g., "list", "add", "menu").
# @set        source_key_file Global variable storing the filename provided with -f/--file.
# @set        IS_VERBOSE Global variable set to "true" if -v/--verbose is present.
# @return     0 If parsing is successful or --help is invoked.
# @return     1 If a parsing error occurs (e.g., unknown option, missing argument).
# @prints     Error messages to stderr for parsing failures.
# @exits      With status 0 if --help is provided.
# @stdout     None.
# @stderr     Error messages from getopt or the simple parser.
# @depends    Global variables: ACTION, source_key_file, IS_VERBOSE, GNU_GETOPT_CMD.
#             Functions: usage, _check_gnu_getopt, log_debug, log_info, log_error, log_warn.
#             External commands: getopt (optional), basename, printf.
# ---
parse_args() {
    # Initialize/Reset global state variables modified by parsing
    ACTION="help"       # Default action
    source_key_file=""
    IS_VERBOSE="false"  # Default verbosity
    local parse_error=0 # Flag for parsing errors

    # Check for GNU getopt and select parsing strategy
    if _check_gnu_getopt; then
        # --- Use GNU Getopt Parsing ---
        log_debug "Using GNU getopt ($GNU_GETOPT_CMD) for argument parsing."
        # Note: Added g, X options
        local short_opts="la:f:DmgX:hv"
        local long_opts="list,add,file:,delete-all,menu,generate:,delete-pair:,help,verbose"
        local ARGS
        # We need to handle optional arguments for --generate and --delete-pair carefully.
        # getopt doesn't directly support optional arguments in the way we might want
        # (e.g., --generate without args vs --generate type bits...).
        # We'll capture the argument presence and value, then validate in the run_* function.
        if ! ARGS=$($GNU_GETOPT_CMD -o "$short_opts" --long "$long_opts" -n "$(basename "$0")" -- "$@"); then
            log_error "Argument parsing error ($GNU_GETOPT_CMD failed). See usage below."
            return 1 # Indicate parsing failure
        fi
        eval set -- "$ARGS"
        while true; do
            case "$1" in
                -l|--list)
                    ACTION="list"; shift ;;
                -a|--add) # Simple --add flag
                    ACTION="add"; shift ;;
                -f|--file)
                    ACTION="file"; source_key_file="$2"; shift 2 ;;
                -D|--delete-all)
                    ACTION="delete-all"; shift ;;
                -m|--menu)
                    ACTION="menu"; shift ;;
                -g|--generate)
                    ACTION="generate"
                    # Capture potential argument, let run_generate_key handle parsing/validation
                    source_key_file="$2" # Reusing source_key_file for simplicity, maybe rename later
                    shift 2 ;;
                 -X|--delete-pair)
                     ACTION="delete-pair"
                     # Capture potential argument
                     source_key_file="$2" # Reusing source_key_file
                     shift 2 ;;
                -v|--verbose)
                    IS_VERBOSE="true"; shift ;;
                -h|--help)
                    usage; exit 0 ;; # Handle help directly and exit successfully
                --)
                    shift; break ;;
                *)
                    log_error "Internal error during getopt argument processing near '$1'"
                    parse_error=1; break ;;
            esac
        done

        # Handle potential errors from getopt processing loop
        if [ "$parse_error" -ne 0 ]; then
            log_error "Argument parsing failed."
            return 1
        fi

        # Handle any remaining non-option arguments (currently ignored)
        if [ $# -gt 0 ]; then
             log_warn "Ignoring non-option arguments: $*"
        fi

    else
        # --- Use Simple Parsing Fallback ---
        log_info "GNU getopt not found or incompatible. Using simple parser. Combined/long options and options with optional args may not work as expected."

        local args_copy=("$@")
        local i=0
        local FIRST_ACTION_SET=0 # Track if an action flag was already encountered

        while [ $i -lt ${#args_copy[@]} ]; do
            local arg="${args_copy[$i]}"
            # Only process flags if an action hasn't been set, except for -v and -h
            if [ "$FIRST_ACTION_SET" -eq 1 ] && [[ "$arg" != "-v" && "$arg" != "-h" ]]; then
                 log_warn "Simple parser: Ignoring argument '$arg' after action '$ACTION' was already set."
                 i=$((i + 1))
                 continue
            fi

            case $arg in
                -l) ACTION="list"; FIRST_ACTION_SET=1; i=$((i + 1)) ;;
                -a) ACTION="add"; FIRST_ACTION_SET=1; i=$((i + 1)) ;;
                -f)
                    local next_arg_index=$((i + 1))
                    local next_arg="${args_copy[$next_arg_index]:-}"
                    if [[ -z "$next_arg" || "${next_arg:0:1}" == "-" ]]; then
                        printf "Error: Simple parser: Option '%s' requires a filename argument.\\n\\n" "$arg" >&2
                        parse_error=1; break
                    fi
                    ACTION="file"; source_key_file="$next_arg"; FIRST_ACTION_SET=1
                    i=$((i + 2)) ;;
                -D) ACTION="delete-all"; FIRST_ACTION_SET=1; i=$((i + 1)) ;;
                -m) ACTION="menu"; FIRST_ACTION_SET=1; i=$((i + 1)) ;;
                -g) ACTION="generate"; FIRST_ACTION_SET=1; i=$((i + 1)) ;; # Simple parser: No arguments handled
                -X)
                     local next_arg_index=$((i + 1))
                     local next_arg="${args_copy[$next_arg_index]:-}"
                     if [[ -z "$next_arg" || "${next_arg:0:1}" == "-" ]]; then
                          printf "Error: Simple parser: Option '%s' requires a key basename argument.\\n\\n" "$arg" >&2
                          parse_error=1; break
                     fi
                     ACTION="delete-pair"; source_key_file="$next_arg"; FIRST_ACTION_SET=1
                     i=$((i + 2)) ;;
                -v) IS_VERBOSE="true"; i=$((i + 1)) ;;
                -h) usage; exit 0 ;; # Handle help directly
                *)
                    if [[ "$arg" == -* ]]; then
                         printf "Error: Simple parser: Unknown or unsupported option '%s'\\n\\n" "$arg" >&2
                    else
                         printf "Error: Simple parser: Unexpected argument '%s'\\n\\n" "$arg" >&2
                    fi
                    parse_error=1; break ;;
            esac
        done
        if [ "$parse_error" -ne 0 ]; then return 1; fi # Indicate failure
    fi

    # If no action was specified (and not help), default to help.
    # This condition should be less likely now that ACTION defaults to 'help',
    # but keep it as a safeguard.
    if [[ "$ACTION" == "help" ]] && [[ $# -eq 0 ]] && [[ "$FIRST_ACTION_SET" -eq 0 ]]; then
         usage
         exit 0
    fi


    log_debug "parse_args completed. ACTION='$ACTION', IS_VERBOSE='$IS_VERBOSE', source_key_file='$source_key_file'"
    return 0 # Success
}


# ==============================================================================
# --- CLI Action Functions ---
# ==============================================================================
# These functions implement the command-line argument actions (e.g., -l, -a).
# They typically perform validation, ensure the agent is running (if needed),
# call the appropriate core logic function from another library, and then exit.

# --- run_list_keys ---
#
# @description Handler for the `-l` or `--list` CLI option.
#              Validates the SSH directory, ensures the dedicated agent is running
#              using ensure_ssh_agent, then calls list_current_keys.
#              Exits with the status code of list_current_keys or 1 if agent setup fails.
# @arg        None
# @exits      With status 0 or 1 based on validation, agent setup, or the outcome
#             of `list_current_keys`.
# @depends    Functions: validate_ssh_dir, ensure_ssh_agent, list_current_keys,
#             log_info, log_debug.
# ---
run_list_keys() {
    log_info "CLI Action: Listing keys (--list)..."
    log_debug "Entering function: ${FUNCNAME[0]}"

    log_debug "Validating SSH dir..."
    if ! validate_ssh_dir; then exit 1; fi

    log_debug "Ensuring agent is running..."
    if ! ensure_ssh_agent; then
        log_error "Failed to ensure SSH agent is running. Cannot list keys."
        # ensure_ssh_agent prints detailed errors
        printf "Error: Agent not available. Cannot list keys.\n" >&2
        exit 1
    fi

    # Agent is confirmed running and environment variables are set.
    log_debug "Agent confirmed. Calling list_current_keys..."
    list_current_keys
    exit $? # Exit with the status returned by list_current_keys
}

# --- run_load_keys ---
#
# @description Handler for the `-a` or `--add` CLI option.
#              Validates SSH dir, ensures agent is running, finds potential keys
#              in $SSH_DIR using `update_keys_list_file`, copies the list to
#              $VALID_KEY_LIST_FILE, deletes existing keys from agent, then adds
#              the keys from the list using `add_keys_to_agent`.
#              Exits with the status code of `add_keys_to_agent`.
# @arg        None
# @exits      With status 0 or 1 based on validation, agent setup, key finding,
#             or the final outcome of `add_keys_to_agent`.
# @depends    Global variables: KEYS_LIST_TMP, VALID_KEY_LIST_FILE. Functions:
#             validate_ssh_dir, ensure_ssh_agent, update_keys_list_file,
#             delete_keys_from_agent, add_keys_to_agent, log_info, log_debug, log_error.
#             External command: cp, chmod.
# ---
run_load_keys() {
    log_info "CLI Action: Loading keys found in $SSH_DIR (--add)..."
    log_debug "Entering function: ${FUNCNAME[0]}"

    # Initial checks.
    if ! validate_ssh_dir; then exit 1; fi
    if ! ensure_ssh_agent; then exit 1; fi

    # Find potential keys and populate the temporary list file.
    log_debug "run_load_keys: Updating temporary key list file '$KEYS_LIST_TMP'..."
    set +e # Temporarily disable exit on error for update_keys_list_file
    update_keys_list_file
    local update_status=$?
    set -e # Re-enable exit on error

    if [ "$update_status" -ne 0 ]; then
        # update_keys_list_file returns 1 if no keys found, >1 for other errors.
        if [ "$update_status" -eq 1 ]; then
            log_info "run_load_keys: No keys found by update_keys_list_file. Clearing agent."
            # Ensure the persistent list is empty if no keys were found
             > "$VALID_KEY_LIST_FILE" || log_warn "Could not clear persistent key list file $VALID_KEY_LIST_FILE"
        else
            log_error "run_load_keys: Failed to find keys using update_keys_list_file (status $update_status)."
             # update_keys_list_file should log specific errors
            exit 1 # Exit on other errors finding keys
        fi
    else
        # Keys found, copy temp list to the persistent list file that add_keys_to_agent uses
        log_debug "Copying found keys from temp file '$KEYS_LIST_TMP' to '$VALID_KEY_LIST_FILE'"
        cp "$KEYS_LIST_TMP" "$VALID_KEY_LIST_FILE" || { log_error "Failed to copy temp key list."; exit 1; }
        chmod 600 "$VALID_KEY_LIST_FILE" 2>/dev/null || log_warn "Could not set permissions on $VALID_KEY_LIST_FILE"
    fi

    log_info "Deleting existing keys from agent before loading..."
    delete_keys_from_agent || true # Ignore failure, attempt add anyway.

    # Only attempt to add if the list file exists and is non-empty
    if [ -s "$VALID_KEY_LIST_FILE" ]; then
        log_info "Adding keys listed in '$VALID_KEY_LIST_FILE'..."
        add_keys_to_agent
        exit $? # Exit with the status of add_keys_to_agent
    else
        log_info "No keys found or list file empty. Agent cleared. Nothing to add."
        # If we cleared the agent and found no new keys, that's a success state.
        exit 0
    fi
}

# --- run_delete_all_cli ---
#
# @description Handler for the `-D` or `--delete-all` CLI option.
#              Validates SSH dir, ensures agent is running, and calls
#              `delete_all_keys` which handles confirmation and deletion.
#              Exits with the status code of `delete_all_keys`.
# @arg        None
# @exits      With status 0 or 1 based on validation, agent setup, or the outcome
#             of `delete_all_keys` (including user cancellation).
# @depends    Functions: validate_ssh_dir, ensure_ssh_agent, delete_all_keys,
#             log_info, log_debug.
# ---
run_delete_all_cli() {
    log_info "CLI Action: Deleting all keys (--delete-all)..."
    log_debug "Entering function: ${FUNCNAME[0]}"

    # Initial checks.
    if ! validate_ssh_dir; then exit 1; fi
    # Do NOT ensure agent here. Let delete_all_keys handle the check.
    # if ! ensure_ssh_agent; then exit 1; fi # Agent required for deletion.

    # Call the function that handles confirmation and deletion.
    delete_all_keys
    local delete_status=$?
    log_debug "Exiting function: ${FUNCNAME[0]} with status $delete_status"
    exit $delete_status # Exit with the status of delete_all_keys.
}

# --- run_load_keys_from_file ---
#
# @description Handler for the `-f <file>` or `--file <file>` CLI option.
#              Validates the source key list file, target list directory, SSH dir,
#              ensures agent is running, prepares the $VALID_KEY_LIST_FILE by
#              copying/filtering the source file (removing comments/blanks),
#              deletes existing keys, then calls `add_keys_to_agent` to load the keys.
#              Exits with the status code of `add_keys_to_agent`.
# @arg        $1 String Path to the source file containing key basenames. Passed from main().
# @exits      With status 0 or 1 based on validation, agent setup, file processing,
#             or the final outcome of `add_keys_to_agent`.
# @depends    Global variable: VALID_KEY_LIST_FILE. Functions: validate_ssh_dir,
#             ensure_ssh_agent, add_keys_to_agent, delete_keys_from_agent,
#             log_info, log_debug, log_error, log_warn.
#             External commands: dirname, mkdir, grep, chmod.
# ---
run_load_keys_from_file() {
    local source_key_file="$1" # Arg passed from main()
    log_info "CLI Action: Loading keys from specified file (--file '$source_key_file')..."
    log_debug "Entering function: ${FUNCNAME[0]} (Source File: $source_key_file)"

    # Validate the source key list file.
    if [ ! -f "$source_key_file" ] || [ ! -r "$source_key_file" ]; then
        log_error "Source key list file not found or not readable: '$source_key_file'"
        exit 1
    fi

    # Ensure the *directory* for the internal persistent key list file exists.
    local target_list_dir
    target_list_dir=$(dirname "$VALID_KEY_LIST_FILE")
    if ! mkdir -p "$target_list_dir"; then
        log_error "Could not create directory '$target_list_dir' for internal key list."
        exit 1
    fi
    # Validate SSH dir and agent
    if ! validate_ssh_dir; then exit 1; fi
    if ! ensure_ssh_agent; then exit 1; fi

    # Prepare VALID_KEY_LIST_FILE by copying from source, removing comments/blanks
    log_debug "Preparing target list file $VALID_KEY_LIST_FILE from source $source_key_file"
    grep -vE '^\s*(#|$)' "$source_key_file" > "$VALID_KEY_LIST_FILE" || { log_error "Failed to process source key file '$source_key_file'."; exit 1; }
    chmod 600 "$VALID_KEY_LIST_FILE" 2>/dev/null || log_warn "Could not set permissions on $VALID_KEY_LIST_FILE"

    # Delete existing keys before adding from file
    log_info "Deleting existing keys from agent before loading from file..."
    delete_keys_from_agent || true # Ignore failure, proceed to add anyway.

    # Only attempt to add if the prepared list file exists and is non-empty
    if [ -s "$VALID_KEY_LIST_FILE" ]; then
        log_info "Adding keys listed in '$source_key_file' (via '$VALID_KEY_LIST_FILE')..."
        add_keys_to_agent
        exit $? # Exit with the status of add_keys_to_agent
    else
        log_info "List file '$source_key_file' was empty or only contained comments/blanks. Agent cleared. Nothing to add."
        exit 0 # Success, agent cleared, no keys to add.
    fi
}

# --- run_generate_key ---
#
# @description Placeholder handler for the `-g` or `--generate` CLI option.
#              (Actual implementation should be in lib/key_ops.sh)
# @arg         Potentially arguments for type, bits, comment, filename captured
#              in global $source_key_file by parse_args (needs refinement).
# @exits      Currently exits with status 1 (not implemented).
# @depends    Functions: log_info, log_error.
# ---
run_generate_key() {
    log_info "CLI Action: Generate new key (--generate)..."
    log_error "Feature not yet fully implemented in CLI mode."
    # TODO: Call handle_generate_new_key (from lib/key_ops.sh) here.
    #       Need to parse arguments potentially captured in $source_key_file
    #       or prompt interactively if none were given via CLI.
    printf "Error: Key generation via CLI not yet implemented.\n" >&2
    exit 1
}

# --- run_delete_key_pair ---
#
# @description Placeholder handler for the `-X` or `--delete-pair` CLI option.
#              (Actual implementation should be in lib/key_ops.sh)
# @arg         Key basename captured in global $source_key_file by parse_args.
# @exits       Currently exits with status 1 (not implemented).
# @depends     Functions: log_info, log_error.
# ---
run_delete_key_pair() {
    local key_basename="$1" # Get argument from main dispatch
    log_info "CLI Action: Delete key pair (--delete-pair '$key_basename')..."
    log_error "Feature not yet fully implemented in CLI mode."
    # TODO: Call delete_ssh_key_pair (from lib/key_ops.sh) here, passing $key_basename.
    printf "Error: Key pair deletion via CLI not yet implemented.\n" >&2
    exit 1
}

# ==============================================================================
# --- End of Library ---
# ============================================================================== 