#!/usr/bin/env bats

# Extended BATS Tests for sshkeymanager.sh
# Usage: bats extended_cli_behavior.bats

# --- Test Setup ---

# Define the path to the main script
SSH_KEY_MANAGER_SCRIPT="./sshkeymanager.sh"
# Define a temporary directory for test artifacts (keys, lists, logs)
TEST_TEMP_DIR=""
# Define mock directory
MOCK_DIR="${BATS_TEST_DIRNAME}/mocks"

setup() {
    # Runs before each test
    # Create a temporary directory for this test
    TEST_TEMP_DIR=$(mktemp -d -t sshkeymanager_bats_XXXXXX)
    export HOME="$TEST_TEMP_DIR" # Isolate tests by setting HOME
    export SSH_DIR="$HOME/.ssh"
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # Create mock control files directory
    export MOCK_CONTROL_DIR="$TEST_TEMP_DIR/mock_control"
    mkdir -p "$MOCK_CONTROL_DIR"

    # Ensure mocks are used by prepending mock dir to PATH
    export PATH="$MOCK_DIR:$PATH"

    # Reset mock command trackers before each test
    rm -f "$MOCK_CONTROL_DIR"/*_called

    # Common mock setup can go here if needed
    # e.g., mock 'ps' to show agent not running by default
    echo "no_agent" >"$MOCK_CONTROL_DIR/ps_behavior"
    # e.g., mock 'ssh-add -l' to fail by default (agent not running)
    echo "fail_connect" >"$MOCK_CONTROL_DIR/ssh-add_behavior"

    # Ensure library path is correct if script relies on relative paths
    # Assuming libs are ../lib relative to the script's location
    # This might need adjustment based on actual script execution context
}

teardown() {
    # Runs after each test
    # Clean up temporary directory
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    # Restore PATH? Usually not necessary as it's per-process.
}

# --- Helper Functions ---

# Helper to set mock ssh-agent state
mock_agent_running() {
    local pid=${1:-12345}
    local sock=${2:-"$TEST_TEMP_DIR/agent.sock"}
    echo "running $pid" >"$MOCK_CONTROL_DIR/ps_behavior"
    # Set environment variables that the script might check
    export SSH_AGENT_PID="$pid"
    export SSH_AUTH_SOCK="$sock"
    # Configure ssh-add mock based on desired state
}

# --- Test Cases ---

@test "[list] Agent not running" {
    # Setup: ps mock shows no agent (default setup)
    # Setup: ssh-add mock fails to connect (default setup)
    mock_agent_running                # Set vars initially, but ps/ssh-add mocks override
    unset SSH_AGENT_PID SSH_AUTH_SOCK # Start clean env

    run "$SSH_KEY_MANAGER_SCRIPT" list
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -ne 0 ] # Expect failure or specific non-zero status
    [[ "$output" == *"ERROR: ssh-agent does not appear to be running"* ]] ||
        [[ "$output" == *"ERROR: Could not connect to ssh-agent"* ]] # Match expected error
}

@test "[list] Agent running, no keys" {
    mock_agent_running "1234" "$TEST_TEMP_DIR/agent.1234.sock"
    echo "list_no_keys" >"$MOCK_CONTROL_DIR/ssh-add_behavior" # Mock ssh-add -l returns 1

    run "$SSH_KEY_MANAGER_SCRIPT" list
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent has no identities"* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-add_called" ]              # Verify mock was called
    [[ $(<"$MOCK_CONTROL_DIR/ssh-add_called") == *"-l"* ]] # Verify '-l' arg
}

@test "[list] Agent running, with keys" {
    mock_agent_running "5678" "$TEST_TEMP_DIR/agent.5678.sock"
    echo "list_has_keys" >"$MOCK_CONTROL_DIR/ssh-add_behavior" # Mock ssh-add -l returns 0 with key info

    run "$SSH_KEY_MANAGER_SCRIPT" list
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2048 SHA256: MOCKKEYSIG1 /tmp/mock/id_rsa (RSA)"* ]]
    [[ "$output" == *"256 SHA256: MOCKKEYSIG2 user@host (ED25519)"* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-add_called" ]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-add_called") == *"-l"* ]]
}

@test "[add] Specific key, success" {
    mock_agent_running
    echo "add_success" >"$MOCK_CONTROL_DIR/ssh-add_behavior"
    # Create a dummy key file
    touch "$SSH_DIR/test_key"
    touch "$SSH_DIR/test_key.pub"

    run "$SSH_KEY_MANAGER_SCRIPT" add "$SSH_DIR/test_key"
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO: Added key: $SSH_DIR/test_key"* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-add_called" ]
    # Check arguments passed to mock ssh-add
    [[ $(<"$MOCK_CONTROL_DIR/ssh-add_called") == *"$SSH_DIR/test_key"* ]]
    # Check if Darwin flag was added (adjust based on your test environment)
    # [[ "$(< "$MOCK_CONTROL_DIR/ssh-add_called")" == *"--apple-use-keychain"* ]]
}

@test "[add] Specific key, file not found" {
    mock_agent_running
    run "$SSH_KEY_MANAGER_SCRIPT" add "$SSH_DIR/nonexistent_key"
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: Key file not found: $SSH_DIR/nonexistent_key"* ]]
    [ ! -f "$MOCK_CONTROL_DIR/ssh-add_called" ] # Ensure ssh-add wasn't called
}

@test "[add] Specific key, requires passphrase (partial failure)" {
    mock_agent_running
    echo "add_fail_passphrase" >"$MOCK_CONTROL_DIR/ssh-add_behavior" # Mock ssh-add returns 1
    touch "$SSH_DIR/needs_pass"
    touch "$SSH_DIR/needs_pass.pub"

    run "$SSH_KEY_MANAGER_SCRIPT" add "$SSH_DIR/needs_pass"
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ] # Treat partial failure as OK for the command itself
    [[ "$output" == *"WARN: ssh-add reported partial failure (status 1)"* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-add_called" ]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-add_called") == *"$SSH_DIR/needs_pass"* ]]
}

@test "[add] Default keys (scan directory)" {
    mock_agent_running
    echo "add_success" >"$MOCK_CONTROL_DIR/ssh-add_behavior"
    # Create some dummy keys
    touch "$SSH_DIR/id_rsa" && touch "$SSH_DIR/id_rsa.pub"
    touch "$SSH_DIR/id_ed25519" && touch "$SSH_DIR/id_ed25519.pub"
    touch "$SSH_DIR/only_private"    # No pub key
    touch "$SSH_DIR/only_public.pub" # No private key

    run "$SSH_KEY_MANAGER_SCRIPT" add
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO: Found 2 potential key file(s) in $SSH_DIR"* ]]
    [[ "$output" == *"INFO: Attempting to add keys..."* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-add_called" ]
    # Verify both valid keys were passed to mock ssh-add
    [[ $(<"$MOCK_CONTROL_DIR/ssh-add_called") == *"$SSH_DIR/id_rsa"* ]]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-add_called") == *"$SSH_DIR/id_ed25519"* ]]
    # Ensure invalid ones weren't passed
    [[ $(<"$MOCK_CONTROL_DIR/ssh-add_called") != *"$SSH_DIR/only_private"* ]]
}

@test "[delete] Specific key, success" {
    mock_agent_running
    echo "delete_success" >"$MOCK_CONTROL_DIR/ssh-add_behavior"
    # Mock ssh-add -l needs to list the key first for delete logic maybe?
    # Assume delete logic directly calls ssh-add -d path/to/pubkey
    # Need to know how delete finds the pubkey path or fingerprint
    # For simplicity, assume it finds it and calls ssh-add -d pubkey_path
    touch "$SSH_DIR/key_to_delete.pub" # Mock needs pubkey path

    run "$SSH_KEY_MANAGER_SCRIPT" delete "$SSH_DIR/key_to_delete" # User gives private key path
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO: Successfully removed key: $SSH_DIR/key_to_delete"* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-add_called" ]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-add_called") == *"-d $SSH_DIR/key_to_delete.pub"* ]] # Check -d and pubkey path
}

@test "[delete] Specific key, not found in agent" {
    mock_agent_running
    echo "delete_not_found" >"$MOCK_CONTROL_DIR/ssh-add_behavior" # Mock ssh-add -d fails
    touch "$SSH_DIR/key_not_in_agent.pub"

    run "$SSH_KEY_MANAGER_SCRIPT" delete "$SSH_DIR/key_not_in_agent"
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: Failed to remove key: $SSH_DIR/key_not_in_agent"* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-add_called" ]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-add_called") == *"-d $SSH_DIR/key_not_in_agent.pub"* ]]
}

@test "[generate] Default key (id_rsa)" {
    echo "generate_success" >"$MOCK_CONTROL_DIR/ssh-keygen_behavior"

    run "$SSH_KEY_MANAGER_SCRIPT" generate
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO: Generating RSA key pair"* ]]
    [[ "$output" == *"INFO: Key generated: $SSH_DIR/id_rsa"* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-keygen_called" ]
    # Check default args passed to mock ssh-keygen
    [[ $(<"$MOCK_CONTROL_DIR/ssh-keygen_called") == *" -t rsa "* ]]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-keygen_called") == *" -f $SSH_DIR/id_rsa "* ]]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-keygen_called") == *" -N '' "* ]] # Assuming empty passphrase default
}

@test "[generate] Custom key type and file" {
    echo "generate_success" >"$MOCK_CONTROL_DIR/ssh-keygen_behavior"

    run "$SSH_KEY_MANAGER_SCRIPT" generate -t ed25519 -f "$SSH_DIR/my_custom_key" -C "my_comment"
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO: Generating ED25519 key pair"* ]]
    [[ "$output" == *"INFO: Key generated: $SSH_DIR/my_custom_key"* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-keygen_called" ]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-keygen_called") == *" -t ed25519 "* ]]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-keygen_called") == *" -f $SSH_DIR/my_custom_key "* ]]
    [[ $(<"$MOCK_CONTROL_DIR/ssh-keygen_called") == *" -C my_comment "* ]]
}

@test "[generate] Key file already exists (no --force)" {
    touch "$SSH_DIR/id_rsa"                                          # Simulate existing file
    echo "generate_success" >"$MOCK_CONTROL_DIR/ssh-keygen_behavior" # Mock would succeed if called

    run "$SSH_KEY_MANAGER_SCRIPT" generate
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: Key file $SSH_DIR/id_rsa already exists. Use --force to overwrite."* ]]
    [ ! -f "$MOCK_CONTROL_DIR/ssh-keygen_called" ] # Ensure mock wasn't called
}

@test "[generate] Key file already exists (with --force)" {
    touch "$SSH_DIR/id_rsa" # Simulate existing file
    echo "generate_success" >"$MOCK_CONTROL_DIR/ssh-keygen_behavior"

    run "$SSH_KEY_MANAGER_SCRIPT" generate --force
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INFO: Generating RSA key pair"* ]]
    [[ "$output" == *"WARN: Overwriting existing key file: $SSH_DIR/id_rsa"* ]]
    [[ "$output" == *"INFO: Key generated: $SSH_DIR/id_rsa"* ]]
    [ -f "$MOCK_CONTROL_DIR/ssh-keygen_called" ] # Ensure mock *was* called
}

@test "[invalid command] Show usage" {
    run "$SSH_KEY_MANAGER_SCRIPT" nonexistentcommand
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: Unknown command: nonexistentcommand"* ]]
    [[ "$output" == *"Usage: sshkeymanager.sh [options] <command> [command-options]"* ]] # Check for usage info
}

@test "[help command] Show general help" {
    run "$SSH_KEY_MANAGER_SCRIPT" --help
    echo "Output: $output"
    echo "Status: $status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: sshkeymanager.sh [options] <command> [command-options]"* ]]
    [[ "$output" == *"Available commands:"* ]]
    [[ "$output" == *"list"* ]]
    [[ "$output" == *"add"* ]]
    # Add checks for other commands listed in help
}

# Add more tests for other commands, options, verbose flag, edge cases etc.
