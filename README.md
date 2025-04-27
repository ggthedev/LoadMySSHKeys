# SSH Key Manager

A comprehensive SSH key management tool that provides a menu-driven interface for managing SSH keys in the ssh-agent. This tool is designed to simplify the process of managing SSH keys across different platforms while providing robust error handling and logging capabilities.

## Features

- **Menu-Driven Interface**: Easy-to-use command-line interface for managing SSH keys.
- **Cross-Platform Support**: Works on both macOS and Linux systems.
- **Automatic SSH Agent Management**:
  - Automatically starts ssh-agent if not running.
  - Manages agent environment variables via a persistent file (`~/.config/agent.env` by default).
  - Handles key loading and unloading.
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

## Requirements

- Bash shell (version 4.0 or higher recommended for `mapfile`).
- Standard Unix utilities (`find`, `basename`, `wc`, `mkdir`, `touch`, `chmod`, `grep`, `date`, `ps`, `rm`, `mv`, `seq`, `sleep`, `dirname`).
- SSH tools installed (`ssh-add`, `ssh-agent`).
- Write permissions to log directory.
- Read/Execute permissions to the target SSH directory.

## Installation

1. Download the script:

   ```bash
   curl -o sshkeymanager.sh https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/sshkeymanager.sh # Replace with the actual raw URL
   # OR clone the repository
   # git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
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

### Command-Line Options

```
sshkeymanager [OPTIONS]

Options:
  -l, --list          List keys currently loaded in the ssh-agent.
  -a, --add           Finds potential private key files (with matching .pub)
                      in the SSH directory, deletes all existing keys
                      from the agent, then adds the found keys.
  -f <file>, --file <file>
                      Deletes all existing keys from the agent, then adds keys whose
                      basenames are listed in the specified <file>.
  -D, --delete-all    Delete all keys currently loaded in the ssh-agent.
  -m, --menu          Show the interactive text-based menu interface.
  -v, --verbose       Enable verbose (DEBUG level) logging.
  -h, --help          Display help message and exit.
```

### Interactive Menu Mode (`sshkeymanager -m`)

The script provides the following menu options:

1.  **Set SSH Directory**: Interactively change the directory to scan for keys during the current menu session.
2.  **List Current Loaded Keys**: Display a numbered list of keys currently loaded in ssh-agent (shows fingerprints).
3.  **Load Key(s)**: Presents a numbered list of potential private keys (found via `.pub` check) and allows selecting one or more keys to add to the agent.
4.  **Delete Single Key from Agent**: Presents a numbered list of potential private keys and allows selecting one to remove from the agent (`ssh-add -d`).
5.  **Delete All Keys from Agent**: Remove all keys currently loaded in ssh-agent (`ssh-add -D`), after confirmation.
6.  **Display Log File Info**: Show the location and size of the current log file.
7.  **Reload Keys**: Deletes all keys from the agent (`ssh-add -D`) and then loads all potential private keys found (via `.pub` check) in the current SSH directory.
8.  **Quit**: Exit the program.

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

- 1.0.0 (2024-03-14)
  - Initial release
  - Basic key management functionality
  - Cross-platform support
  - Logging system

## `ssh_agent_setup.sh` - Automated Agent Setup (for Sourcing)

This script is designed to be **sourced** by your shell's startup files (preferably `.zprofile` or `.profile`) to ensure a single `ssh-agent` is running per login session and that necessary environment variables (`SSH_AUTH_SOCK`, `SSH_AGENT_PID`) are exported correctly for process inheritance.

### Purpose

- Ensures a single `ssh-agent` is running per login session.
- Exports `SSH_AUTH_SOCK` and `SSH_AGENT_PID` for use by subsequent processes.