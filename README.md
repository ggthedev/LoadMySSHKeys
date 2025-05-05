# SSH Key Manager

A comprehensive SSH key management tool that provides a menu-driven interface for managing SSH keys in the ssh-agent. This tool is designed to simplify the process of managing SSH keys across different platforms while providing robust error handling and logging capabilities.

## Features

- **Menu-Driven Interface**: Easy-to-use command-line interface for managing SSH keys.
- **Cross-Platform Support**: Works on both macOS and Linux systems.
- **Automatic SSH Agent Management**:
  - **Dedicated Agent Tracking:** The script primarily tracks the agent it should use via a persistent environment file (default: `~/.config/agent.env`, override with `SKM_AGENT_ENV_FILE`). This file stores the `SSH_AUTH_SOCK` and `SSH_AGENT_PID` of the agent managed by this script.
  - **Agent Validation:** Before performing actions, the script checks the details in the environment file. It verifies that the agent process (PID) is running and the communication socket exists.
  - **Stale File Handling:** If the environment file exists but the agent it points to is no longer running (stale), the script removes the file.
  - **Conditional Agent Start:** If the environment file is missing or was stale, a *new* `ssh-agent` process is started *only* if the requested action involves loading keys (e.g., `-a`, `-f`, menu options 3 or 6). The details of this new agent are then saved to the environment file.
  - **Check-Only Actions:** For actions that *don't* load keys (e.g., `-l`, `-D`, menu options 2, 4, 5), if no valid agent is found via the environment file, the script will report that no agent is available and will *not* start a new one.
  - **Isolation:** This approach ensures the script manages its own agent state via the file, minimizing interference with other `ssh-agent` processes that might be running on the system for other purposes.
- **Key Management**:
  - Load keys based on finding files with matching `.pub` counterparts in the SSH directory.
  - Load specific key(s) interactively from the list of found keys.
  - List currently loaded keys (numbered list).
  - Delete individual keys from the agent interactively.
  - Delete all keys at once.
- **Directory Management**:
  - Interactively set the SSH directory to use during a menu session.
  - Validate SSH directory permissions.
  - Support for custom SSH directories via environment variable (`SKM_SSH_DIR`).
  - Automatic creation of the default SSH directory (`~/.ssh`) if it doesn't exist.
- **Comprehensive Logging**:
  - Platform-specific log locations.
  - Log rotation (1MB max size, 5 files).
  - Detailed operation logging.
  - Error and warning tracking.

## Code Structure

The script has been refactored for better maintainability and organization. Core functionalities are now separated into library files located in the `lib/` directory relative to the main `sshkeymanager.sh` script. These libraries handle specific tasks such as:

- `logging.sh`: Logging setup and functions.
- `validation.sh`: Directory validation checks.
- `agent.sh`: SSH agent management logic (checking, starting, validating).
- `key_ops.sh`: Core operations for adding, listing, and deleting keys.
- `cli.sh`: Command-line argument parsing and action dispatching.
- `menu.sh`: Interactive menu display and logic.
- `arg_helpers.sh`: Helper for checking `getopt`.
- `helpers.sh`: Miscellaneous helpers (e.g., platform detection).

The main `sshkeymanager.sh` script now primarily acts as an entry point that sources these libraries and orchestrates the overall execution flow.

## Requirements

- Bash shell (version 4.0 or higher recommended for `mapfile`). **IMPORTANT: This script relies on features available in Bash 4.0 and later. Ensure your environment uses a compatible Bash version.**
- Standard Unix utilities (`find`, `basename`, `wc`, `mkdir`, `touch`, `chmod`, `grep`, `date`, `ps`, `rm`, `mv`, `seq`, `sleep`, `dirname`).
- SSH tools installed (`ssh-add`, `ssh-agent`).
- Write permissions to log directory.
- Read/Execute permissions to the target SSH directory.

## Installation

1. Download the script:

   ```bash
   curl -o sshkeymanager.sh https://raw.githubusercontent.com/ggthedev/SSHKEYSMANAGER/refs/heads/main/sshkeymanager.sh # Replace with the actual raw URL
   # OR clone the repository
   # git clone https://github.com/ggthedev/SSHKEYSMANAGER.git
   # cd YOUR_REPO
   ```

2. Make the script executable:

   ```bash
   chmod +x sshkeymanager.sh
   ```

3. (Optional) Move to a directory in your PATH for global access:

   ```bash
   sudo mv sshkeymanager.sh /usr/local/bin/sshkeymanager
   ```

## Usage

The script can be run with various command-line options or using an interactive menu.

```bash
./sshkeymanager.sh [OPTIONS]
```

**Options:**

- `-l`, `--list`: List keys currently loaded in the ssh-agent.
- `-a`, `--add`: Find potential keys, clear agent, add found keys.
- `-f <file>`, `--file <file>`: Load keys listed in `<file>` after clearing agent.
- `-D`, `--delete-all`: Delete all keys from agent (prompts for confirmation).
- `-m`, `--menu`: Show the interactive text-based menu interface.
- `-v`, `--verbose`: Enable verbose (DEBUG level) logging.
- `-h`, `--help`: Display the help message.

**macOS Argument Parsing Note:**

While the script functions on macOS without extra dependencies, installing `gnu-getopt` is recommended for the best command-line experience:

```bash
brew install gnu-getopt
```

This enables support for features like combined short options (e.g., `-lv`) and long options (e.g., `--list`) which the default macOS `getopt` does not handle. If `gnu-getopt` is not installed, the script will fall back to a simpler parser, and only single short options (e.g., `-l -v`) will work.

### Interactive Menu Mode (`sshkeymanager -m`)

The script provides the following menu options:

1. **Set SSH Directory**: Interactively change the directory to scan for keys during the current menu session.
2. **List Current Loaded Keys**: Display a numbered list of keys currently loaded in ssh-agent (shows fingerprints).
3. **Load Key(s)**: Presents a numbered list of potential private keys (found via `.pub` check) and allows selecting one or more keys to add to the agent.
4. **Delete Single Key from Agent**: Presents a numbered list of potential private keys and allows selecting one to remove from the agent (`ssh-add -d`).
5. **Delete All Keys from Agent**: Remove all keys currently loaded in ssh-agent (`ssh-add -D`), after confirmation.
6. **Display Log File Info**: Show the location and size of the current log file.
7. **Reload Keys**: Deletes all keys from the agent (`ssh-add -D`) and then loads all potential private keys found (via `.pub` check) in the current SSH directory.
8. **Quit**: Exit the program.

## Configuration via Environment Variables

Certain paths used by the script can be overridden by setting environment variables before running the script:

- `SKM_SSH_DIR`: Overrides the default SSH directory (`~/.ssh`).
- `SKM_LOG_DIR`: Overrides the auto-detected log directory.
- `SKM_LOG_FILENAME`: Overrides the default log filename (`sshkeymanager.log`).
- `SKM_VALID_KEYS_FILE`: Overrides the path to the internal list used by `-f` / Reload (`~/.config/sshkeymanager/ssh_keys_list`).
- `SKM_AGENT_ENV_FILE`: Overrides the path for the persistent agent environment file (`~/.config/agent.env`).

## Logging

The script maintains detailed logs of all operations.

- **Default macOS**: `~/Library/Logs/sshkeymanager/sshkeymanager.log`
- **Default Linux**: `/var/log/sshkeymanager/sshkeymanager.log` (if writable) or `~/.local/log/sshkeymanager/sshkeymanager.log`
- **Fallback**: `~/.ssh/logs/sshkeymanager.log`

Log files are rotated when they reach 1MB in size, keeping up to 5 backup files.

## Troubleshooting

- Ensure you have the necessary permissions for your SSH directory and the log directory.
- Use the `-v` (verbose) flag to enable debug logging for more detailed information.
- Check the log file specified by option `6` in the menu.

## Testing

This project uses [Bats-core](https://github.com/bats-core/bats-core) for testing the `sshkeymanager.sh` script's behavior.

### Dependencies

- **Bats-core:** You need `bats` installed to run the tests. You can typically install it using a package manager:
  - **Homebrew (macOS/Linux):** `brew install bats-core`
  - **npm:** `npm install -g bats`
  - Refer to the [Bats-core documentation](https://github.com/bats-core/bats-core#installation) for other installation methods.

### Running Tests

All test commands should be run from the root directory of this project.

#### Running All Tests

To execute the entire test suite located in the `test/` directory:

```bash
bats test/cli_behavior.bats
```

#### Running Specific Tests

You can run individual tests or groups of tests using the `-f` or `--filter` flag, which matches the provided regular expression against test names.

For example, to run only Test 5, named `"5. CLI: -l (list keys) after -a should show keys added by real ssh-add"`:

```bash
bats -f "5\. CLI: -l \(list keys\) after -a should show keys added by real ssh-add" test/cli_behavior.bats
```

**Important:** Notice the backslashes (`\`) before the `.` and `()`. These are necessary because the filter uses regular expressions, and these characters have special meaning in regex. Escaping them ensures they are matched literally as part of the test name.

#### Verbose Output

To see more detailed output during test execution, add the `--verbose-run` flag to any `bats` command:

```bash
bats --verbose-run test/cli_behavior.bats
```

## `ssh_agent_setup.sh` - Automated Agent Setup (for Sourcing)

This script is designed to be **sourced** by your shell's startup files (preferably `.zprofile` or `.profile`) to ensure a single `ssh-agent` is running per login session and that necessary environment variables (`SSH_AUTH_SOCK`, `SSH_AGENT_PID`) are exported correctly for process inheritance.

### Purpose

- Ensures a single `ssh-agent` is running per login session.
- Exports `SSH_AUTH_SOCK` and `SSH_AGENT_PID` for use by subsequent processes.

## Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

### Development Guidelines

- Follow the existing code style
- Add comprehensive comments
- Include tests for new features
- Update documentation
- Handle errors gracefully

## License

This project is licensed under the BSD 3-Clause License - see the [LICENSE](LICENSE) file for details.

## Author

[Gaurav Gupta](https://github.com/ggthedev)

## Version History

- 0.0.1.2 (2025-04-28)
  - Refactored code into modular library files (`lib/*.sh`).
  - Added Bats testing framework (`test/cli_behavior.bats`).
  - Updated test suite to use real `ssh-agent` and dynamic key generation.
- 0.0.1 (2024-03-14)
  - Initial release
  - Basic key management functionality
  - Cross-platform support
  - Logging system
