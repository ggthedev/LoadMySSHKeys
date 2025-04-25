# SSH Key Manager

A comprehensive SSH key management tool that provides a menu-driven interface for managing SSH keys in the ssh-agent. This tool is designed to simplify the process of managing SSH keys across different platforms while providing robust error handling and logging capabilities.

## Features

- **Menu-Driven Interface**: Easy-to-use command-line interface for managing SSH keys
- **Cross-Platform Support**: Works on both macOS and Linux systems
- **Automatic SSH Agent Management**:
  - Automatically starts ssh-agent if not running
  - Manages agent environment variables
  - Handles key loading and unloading
- **Key Management**:
  - Load keys from SSH directory
  - List currently loaded keys
  - Delete individual keys
  - Delete all keys at once
- **Directory Management**:
  - Validate SSH directory permissions
  - Support for custom SSH directories
  - Automatic directory creation with correct permissions
- **Comprehensive Logging**:
  - Platform-specific log locations
  - Log rotation (1MB max size, 5 files)
  - Detailed operation logging
  - Error and warning tracking

## Requirements

- Bash shell (version 4.0 or higher)
- SSH tools installed (ssh-add, ssh-agent)
- Write permissions to log directory
- Read/Write permissions to SSH directory

## Installation

Download the script:

   ```bash
   curl -O https://raw.githubusercontent.com/ggthedev/ssh-key-manager/main/load_ssh_keys.sh
   ```

Make the script executable:

```bash
chmod +x load_ssh_keys.sh
```

(Optional) Move to a directory in your PATH:

```bash
sudo mv load_ssh_keys.sh /usr/local/bin/sshkeymanager
```

## Usage

### Basic Usage

Run the script:

```bash
./load_ssh_keys.sh
```

### Menu Options

The script provides the following menu options:

1. **Set SSH Directory**: Configure the directory where SSH keys are stored
   - Default: `~/.ssh`
   - Custom paths supported
   - Validates permissions automatically

2. **List Current Keys**: Display all keys currently loaded in ssh-agent
   - Shows key fingerprints
   - Displays key types and comments
   - Handles empty key lists gracefully

3. **Reload All Keys**: Clear and reload all keys from the SSH directory
   - Removes existing keys
   - Loads all valid keys from directory
   - Provides loading status

4. **Display Log File Location**: Show where log files are stored
   - Platform-specific locations
   - Current log file size
   - Log rotation status

5. **Delete Single Key**: Remove a specific key from ssh-agent
   - Interactive key selection
   - Confirmation prompt
   - Success/failure feedback

6. **Delete All Keys**: Remove all keys from ssh-agent
   - Confirmation required
   - Bulk removal
   - Status reporting

7. **Quit**: Exit the program
   - Graceful exit
   - Cleanup of temporary files
   - Log final status

### Example Workflows

#### 1. Initial Setup

```bash
# Start the script
./load_ssh_keys.sh

# Set custom SSH directory (Option 1)
Enter choice [1-6, q]: 1
Current SSH directory: /Users/user/.ssh
Select SSH directory:
  1) Use standard location (/Users/user/.ssh)
  2) Enter custom directory path
  c) Cancel
Enter choice [1-2, c]: 2
Enter full path to directory: /path/to/ssh/keys
Working directory set to: /path/to/ssh/keys

# Load keys (Option 3)
Enter choice [1-6, q]: 3
Reloading all keys...
Found 3 SSH key(s) in /path/to/ssh/keys
Adding SSH keys to agent...
Adding key: id_rsa
  ✓ Successfully added
Adding key: github_key
  ✓ Successfully added
Adding key: bitbucket_key
  ✗ Failed to add (status: 1)

Summary: 2 key(s) added, 1 key(s) failed
```

#### 2. Key Management

```bash
# List current keys (Option 2)
Enter choice [1-6, q]: 2
+++ Currently Loaded SSH Keys +++
  1) 2048 SHA256:abc123... user@host (RSA)
  2) 4096 SHA256:def456... user@host (RSA)

# Delete a specific key (Option 5)
Enter choice [1-6, q]: 5
+++ Delete Single Key +++
Select a key to delete:
  1) 2048 SHA256:abc123... user@host (RSA)
  2) 4096 SHA256:def456... user@host (RSA)
Enter key number to delete (or 'c' to cancel): 1
Deleting key: 2048 SHA256:abc123... user@host (RSA)
Key successfully deleted.
```

#### 3. Troubleshooting

```bash
# Check log location (Option 4)
Enter choice [1-6, q]: 4
----------------------
|Log File Information|
----------------------
Location: /Users/user/Library/Logs/sshkeymanager/sshkeymanager.log
Current Size: 45K

# View log contents
tail -f /Users/user/Library/Logs/sshkeymanager/sshkeymanager.log
```

## Logging

The script maintains detailed logs of all operations:

- **macOS**: `~/Library/Logs/sshkeymanager/sshkeymanager.log`
- **Linux**: `/var/log/sshkeymanager/sshkeymanager.log` or `~/.local/log/sshkeymanager/sshkeymanager.log`

Log files are rotated when they reach 1MB in size, keeping up to 5 backup files.

### Log Format

```
2024-03-14 10:30:45 - 12345 - INFO: Script starting
2024-03-14 10:30:45 - 12345 - INFO: Platform: Darwin
2024-03-14 10:30:45 - 12345 - INFO: User: user
2024-03-14 10:30:45 - 12345 - INFO: Host: hostname
```

## Error Handling

The script includes comprehensive error handling:

- Directory permission validation
- SSH agent status checking
- Key loading verification
- Operation confirmation for destructive actions
- Graceful handling of missing dependencies

### Common Error Messages

1. **SSH Agent Not Running**:

```
SSH agent is not running or not accessible.
Would you like to:
  1) Start SSH agent and load keys
  2) Return to main menu
```

2. **Permission Issues**:

```
Error: SSH directory '/path/to/ssh' is not writable
```

3. **Key Loading Failures**:

```
Failed to add key: id_rsa (status: 1)
```

## Limitations

1. **Platform Support**:
   - Primarily tested on macOS and Linux
   - Limited support for other Unix-like systems
   - No Windows support

2. **Key Types**:
   - Best support for RSA and ED25519 keys
   - Limited support for other key types

3. **Security**:
   - Requires proper permissions for SSH directory
   - Depends on system's SSH implementation
   - No built-in encryption for stored keys

4. **Performance**:
   - May be slow with large numbers of keys
   - Log rotation can be resource-intensive

## Troubleshooting

### Configuration via Environment Variables

Certain paths used by the script can be overridden by setting environment variables before running the script:

- `SKM_SSH_DIR`: Overrides the default SSH directory (`~/.ssh`).
- `SKM_LOG_DIR`: Overrides the default log directory (platform-specific).
- `SKM_LOG_FILENAME`: Overrides the default log filename (`sshkeygen.log`).
- `SKM_AGENT_ENV_FILE`: Overrides the default agent environment file path (`~/.ssh/agent.env`).
- `SKM_VALID_KEYS_FILE`: Overrides the default path for the cached list of valid key basenames (`~/.config/sshkeymanager/ssh_keys_list`).

Common issues and solutions:

1. **SSH Agent Not Starting**:
   - Check if SSH tools are installed
   - Verify system permissions
   - Check for existing agent processes

2. **Keys Not Loading**:
   - Verify key file permissions (should be 600)
   - Check SSH directory permissions (should be 700)
   - Ensure keys are in correct format

3. **Logging Issues**:
   - Check directory permissions
   - Verify disk space
   - Ensure write access to log location

### Debug Mode

To enable debug output, set the `IS_VERBOSE` variable to "true" in the script:

```bash
declare IS_VERBOSE="true"
```

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