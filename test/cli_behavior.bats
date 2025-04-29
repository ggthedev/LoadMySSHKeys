#!/usr/bin/env bats

# Bats test file for sshkeymanager.sh CLI behavior

# --- Global Test Setup ---

# Path to the script under test (relative to this test file)
SCRIPT_UNDER_TEST="$BATS_TEST_DIRNAME/../sshkeymanager.sh"
TEST_TEMP_DIR=""              # Will be set in setup
MOCK_BIN_DIR=""               # Path to mock executables
MOCK_HOME_DIR=""              # Path to mock home directory
MOCK_SSH_DIR=""               # Path to mock .ssh directory
MOCK_AGENT_KEYS_STATE_FILE="" # Path to file tracking mock agent keys

# Store agent PID globally for teardown
AGENT_PID_FILE=""
AGENT_SOCK_FILE="" # Store sock path for run_script

# --- Helper Functions ---

# Helper to run the script with specific args and environment
run_script() {
    # Ensure the script is executable
    chmod +x "$SCRIPT_UNDER_TEST"

    # Agent variables (SSH_AUTH_SOCK, SSH_AGENT_PID) should be exported
    # by setup() and inherited by the 'run' subshell environment.

    # Execute script with other env vars via env/run
    run env \
        PATH="$MOCK_BIN_DIR:$PATH" \
        HOME="$MOCK_HOME_DIR" \
        SKM_LOG_DIR="$TEST_TEMP_DIR/logs" \
        SKM_AGENT_ENV_FILE="$TEST_TEMP_DIR/config/agent.env" \
        SKM_VALID_KEYS_FILE="$TEST_TEMP_DIR/config/ssh_keys_list" \
        bash "$SCRIPT_UNDER_TEST" "$@"
    # The 'run' command populates $status and $output
}

# --- Test Suite Setup/Teardown ---

setup() {
    # Create a unique temporary directory for this test run
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sshkeymanager-test.XXXXXX")
    MOCK_BIN_DIR="$TEST_TEMP_DIR/bin" # Keep mock bin for potential future mocks
    MOCK_HOME_DIR="$TEST_TEMP_DIR/home"
    MOCK_SSH_DIR="$MOCK_HOME_DIR/.ssh"
    AGENT_PID_FILE="$TEST_TEMP_DIR/agent.pid"
    AGENT_SOCK_FILE="$TEST_TEMP_DIR/agent.sock" # File to store sock path
    local agent_env_file="$TEST_TEMP_DIR/config/agent.env"

    # Create directories
    mkdir -p "$MOCK_BIN_DIR"
    mkdir -p "$MOCK_HOME_DIR/.config/sshkeymanager" # For SKM_VALID_KEYS_FILE dir
    mkdir -p "$MOCK_SSH_DIR"
    mkdir -p "$TEST_TEMP_DIR/logs"
    mkdir -p "$TEST_TEMP_DIR/config"

    # Start a real ssh-agent
    echo "Starting real ssh-agent for test suite..." >&3 # Bats debug stream
    agent_output=$(ssh-agent -s)
    if [ $? -ne 0 ]; then
        echo "Failed to start ssh-agent for tests!" >&3
        exit 1
    fi

    # --- Manually parse output instead of eval ---
    local sock_line pid_line parsed_agent_sock parsed_agent_pid
    sock_line=$(echo "$agent_output" | grep '^SSH_AUTH_SOCK=')
    pid_line=$(echo "$agent_output" | grep '^SSH_AGENT_PID=')

    # Extract values carefully (handles paths with spaces if quoted)
    # Example: SSH_AUTH_SOCK=/path/to/socket; export SSH_AUTH_SOCK;
    # Use sed for robust SOCK path extraction (handles potential lack of quotes)
    parsed_agent_sock=$(echo "$sock_line" | sed -n 's/^SSH_AUTH_SOCK=\([^;]*\);.*$/\1/p')

    # Example: SSH_AGENT_PID=12345; export SSH_AGENT_PID;
    # Use parameter expansion for PID to avoid issues with semicolon in cut
    temp_pid="${pid_line#SSH_AGENT_PID=}" # Remove prefix 'SSH_AGENT_PID='
    parsed_agent_pid="${temp_pid%%;*}"    # Remove the first semicolon and everything after it

    if [ -z "$parsed_agent_sock" ] || [ -z "$parsed_agent_pid" ]; then
        echo "Failed to parse ssh-agent output! Output was:" >&3
        echo "$agent_output" >&3
        exit 1
    fi
    echo "Agent parsed: PID=$parsed_agent_pid SOCK=$parsed_agent_sock" >&3

    # Save PID and SOCK path for teardown / run_script
    echo "$parsed_agent_pid" >"$AGENT_PID_FILE"
    echo "$parsed_agent_sock" >"$AGENT_SOCK_FILE"

    # Save agent env file for the script to potentially source
    {
        echo "SSH_AUTH_SOCK='$parsed_agent_sock'; export SSH_AUTH_SOCK;"
        echo "SSH_AGENT_PID=$parsed_agent_pid; export SSH_AGENT_PID;"
    } >"$agent_env_file"

    # Generate test key files dynamically in mock SSH dir
    echo "Generating test keys in $MOCK_SSH_DIR..." >&3
    ssh-keygen -t rsa -b 2048 -N '' -f "$MOCK_SSH_DIR/test_rsa" -q <<<y || {
        echo "Failed to generate test_rsa key" >&3
        exit 1
    }
    ssh-keygen -t ed25519 -N '' -f "$MOCK_SSH_DIR/test_ed25519" -q <<<y || {
        echo "Failed to generate test_ed25519 key" >&3
        exit 1
    }

    # Add some other files to test filtering logic
    echo "some other file" >"$MOCK_SSH_DIR/known_hosts"
    echo "key without pub" >"$MOCK_SSH_DIR/no_pub_key"

    # Export agent vars for subsequent 'run' commands within tests
    # Note: export in setup applies to the main bats process env
    export SSH_AUTH_SOCK="$parsed_agent_sock"
    export SSH_AGENT_PID="$parsed_agent_pid"
}

teardown() {
    # Kill the test-specific ssh-agent
    if [ -f "$AGENT_PID_FILE" ]; then
        local pid_to_kill
        pid_to_kill=$(cat "$AGENT_PID_FILE")
        if [ -n "$pid_to_kill" ]; then
            echo "Killing test agent PID: $pid_to_kill" >&3
            kill "$pid_to_kill" 2>/dev/null || echo "Agent $pid_to_kill already gone?" >&3
        fi
    fi

    # Clean up the temporary directory
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    TEST_TEMP_DIR=""
    AGENT_PID_FILE=""
    AGENT_SOCK_FILE=""

    # Unset global vars? Usually subshell isolation is enough.
    # unset SSH_AUTH_SOCK SSH_AGENT_PID
}

# --- Test Cases ---

@test "1. CLI: No arguments should display help and exit 0" {
    run_script          # No arguments
    [ "$status" -eq 0 ] # Check exit status using $status
    # Check for key phrases in the output using $output
    [[ "$output" == *"Usage: sshkeymanager.sh [OPTIONS]"* ]]
    [[ "$output" == *"-l, --list"* ]]
    [[ "$output" == *"-h, --help"* ]]
    [[ "$output" == *"Log File Target:"* ]]
}

@test "2. CLI: -v (verbose) with no action should display help, exit 0, and enable debug logging" {
    run_script -v
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: sshkeymanager.sh [OPTIONS]"* ]]

    # Check the log file for DEBUG entries
    local log_file="$TEST_TEMP_DIR/logs/sshkeymanager.log"
    [ -f "$log_file" ] # Check file existence directly
    # Use standard grep on the log file
    grep -q "DEBUG: Verbose Logging: 'true'" "$log_file"
    grep -q "DEBUG:" "$log_file" # Check for any DEBUG line
}

@test "3. CLI: -l -v (list, verbose) with no agent should exit 1, print agent error, and log verbosely" {
    # Override setup: Unset agent variables AND remove the persisted env file
    # to truly simulate no agent being discoverable by the script.
    unset SSH_AUTH_SOCK
    unset SSH_AGENT_PID
    rm -f "$TEST_TEMP_DIR/config/agent.env"

    # Now run the script
    run_script -l -v
    [ "$status" -eq 1 ] # Expect specific exit status 1
    # Check console output
    [[ "$output" == *"No running SSH agent found"* ]]
    [[ "$output" == *"Hint: Start the menu with 'sshkeymanager.sh --menu'"* ]]

    # Check the log file
    local log_file="$TEST_TEMP_DIR/logs/sshkeymanager.log"
    [ -f "$log_file" ]
    grep -q "DEBUG: Verbose Logging: 'true'" "$log_file"
    # Check the updated log message for no agent found during list
    grep -q "INFO: No valid agent found.*Cannot list keys." "$log_file"
}

@test "4. CLI: -a (add all keys) should find keys, clear agent, add keys to real agent" {
    # Run with verbose flag for detailed logging
    run_script -a -v

    [ "$status" -eq 0 ] # Expect success
    # Check console output
    [[ "$output" == *"Found 2 potential key file(s)"* ]]
    [[ "$output" == *"All identities removed."* || "$output" == *"All keys successfully deleted from agent."* ]]
    [[ "$output" == *"Adding SSH keys to agent"* ]]
    [[ "$output" == *"✓ Added key 'test_rsa'"* ]]
    [[ "$output" == *"✓ Added key 'test_ed25519'"* ]]
    [[ "$output" == *"Summary: 2 key(s) added, 0 key(s) failed/skipped."* ]]

    # Check internal list file
    local internal_list="$TEST_TEMP_DIR/config/ssh_keys_list"
    [ -f "$internal_list" ]
    grep -q "^test_rsa$" "$internal_list"
    grep -q "^test_ed25519$" "$internal_list"
    [ $(wc -l <"$internal_list") -eq 2 ]

    # Check log file
    local log_file="$TEST_TEMP_DIR/logs/sshkeymanager.log"
    [ -f "$log_file" ]
    grep -q "INFO: CLI Action: Loading keys found in $MOCK_SSH_DIR (--add)" "$log_file"
    grep -q "INFO: Deleting existing keys from agent before loading" "$log_file"
    # Check updated success messages
    grep -q "INFO: Successfully added key 'test_rsa' to agent." "$log_file"
    grep -q "INFO: Successfully added key 'test_ed25519' to agent." "$log_file"
}

@test "5. CLI: -l (list keys) after -a should show keys added by real ssh-add" {
    # --- Setup specific state for this test ---
    # Run the '-a' command first to populate the real agent via ssh-add
    echo "Running prerequisite: sshkeymanager.sh -a" >&3
    run_script -a >/dev/null
    [ "$status" -eq 0 ] # Ensure prerequisite '-a' succeeded

    # --- Now run the actual test command ---
    echo "Running test command: sshkeymanager.sh -l" >&3
    run_script -l
    [ "$status" -eq 0 ] # Expect success

    # Check output matches real ssh-add -l format (check for key types)
    [[ "$output" == *"Keys currently loaded in the agent:"* ]]
    echo "$output" | grep -q "(RSA)"
    echo "$output" | grep -q "(ED25519)"

    # Check log file
    local log_file="$TEST_TEMP_DIR/logs/sshkeymanager.log"
    [ -f "$log_file" ]
    grep -q "INFO: CLI Action: Loading keys found.*(--add)" "$log_file"
    grep -q "INFO: CLI Action: Listing keys (--list)" "$log_file"
    # Check updated agent found message
    grep -q "INFO: Agent details from file .* are valid and agent is live." "$log_file"
    # Check updated message for listing keys
    grep -q "INFO: Keys currently loaded in the agent according to \`ssh-add -l\`" "$log_file"
}

# Add more test cases here...
