# Restic Backup Manager

A comprehensive wrapper script for [Restic](https://restic.net) backup management with advanced features and integrations.

## Features

- 🚀 Easy repository configuration and management
- ⏱️ Automated backup scheduling with cron
- 🔄 Backup retention policy management
- 📊 Progress tracking and colored output
- 📝 Detailed logging and error handling
- 🎯 Interactive configuration interface
- 📱 Telegram notifications for backup status
- 🖥️ Support for multiple backup repositories
- 📂 File selection UI for restores
- 🔒 Secure password management

## Prerequisites

- restic: The backup tool
- jq: JSON processor for configuration management
- crontab: For backup scheduling (usually pre-installed)
- curl: For Telegram notifications (optional)

## Installation

```bash
# Clone the repository
git clone https://github.com/numbor/restic-wrapper.git
cd restic-wrapper/

# Make the script executable
chmod +x restic.sh

# Install the script
./restic.sh install
```

## Usage

```bash
restic.sh <command> [options]
```

### Available Commands

- `install`: Install and initialize configuration files
- `config [-s]`: Configure backup repositories interactively
- `init [repo-name]`: Initialize repositories
- `backup [repo-name]`: Perform backups
- `restore <repo-name> <snapshot-id>`: Restore files from backup
- `list [repo-name] [-v]`: List snapshots
- `crontab [-s|-d]`: Manage backup scheduling
- `update`: Update script to latest version

### Examples

```bash
# Initial setup
restic.sh install
restic.sh config

# Perform backups
restic.sh init
restic.sh backup

# Backup with pre/post scripts
restic.sh backup -pre-backup /path/to/pre.sh -post-backup /path/to/post.sh

# Restore specific files
restic.sh list myrepo -v
restic.sh restore myrepo 1a2b3c -f /path/to/file1 /path/to/file2

# Schedule automatic backups
restic.sh crontab
```

## Configuration

Configuration files are stored in `~/.config`:
- Repository settings: `backup-repos.json`
- Backup logs: `/var/log/restic-backup.log`

## Features in Detail

### Telegram Notifications
Get instant notifications about your backup status through Telegram:
- Backup completion status
- Error notifications
- Detailed error logs
- Easy setup during installation

### Retention Policy
Flexible retention policies for each repository:
- Keep last N snapshots
- Keep daily snapshots for N days
- Keep weekly snapshots for N weeks
- Keep monthly snapshots for N months

### Interactive UI
- Colored terminal output
- Progress bars and spinners
- File selection interface for restores
- Repository management interface

## Support and Contributing

If you find this tool useful, consider supporting its development:

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-Support-yellow.svg)](https://buymeacoffee.com/numbor)

