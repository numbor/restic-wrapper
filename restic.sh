#!/bin/bash

# Restic wrapper script
# This script provides a simplified interface for Restic commands

# Configuration
CONFIG_DIR="$HOME/.config"
CONFIG_FILE="$CONFIG_DIR/restic.ini"

# Function to check and install restic binary
check_restic_binary() {
    if ! command -v restic &> /dev/null; then
        echo "Restic is not installed. Installing..."
        
        # Check the package manager and install accordingly
        if command -v apt-get &> /dev/null; then
            # Debian/Ubuntu
            sudo apt-get update
            sudo apt-get install -y restic
        elif command -v dnf &> /dev/null; then
            # Fedora/RHEL
            sudo dnf install -y restic
        elif command -v pacman &> /dev/null; then
            # Arch Linux
            sudo pacman -S --noconfirm restic
        else
            echo "Error: Could not determine package manager. Please install restic manually."
            exit 1
        fi
        
        # Verify installation
        if ! command -v restic &> /dev/null; then
            echo "Error: Failed to install restic"
            exit 1
        fi
        echo "Restic installed successfully"
    else
        echo "Restic is already installed"
    fi
}

# Function to read the configuration file
read_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file not found at $CONFIG_FILE"
        exit 1
    fi

    # Read the dst variable from the config file
    dst=$(grep "^dst=" "$CONFIG_FILE" | cut -d'=' -f2)
    
    if [ -z "$dst" ]; then
        echo "Error: 'dst' variable not found in config file"
        exit 1
    fi
}

# example usage:
# export RESTIC_PASSWORD="290569"
# restic -r sftp:marcomicheletti@192.168.1.47:backup  init
# restic -r sftp:marcomicheletti@192.168.1.47:backup  backup tmpmail/
# restic -r sftp:marcomicheletti@192.168.1.47:backup  snapshots
# restic -r sftp:marcomicheletti@192.168.1.47:backup  restore 56074bf7 --target .
# restic -r sftp:marcomicheletti@192.168.1.47:backup  forget --prune   --keep-last "24"   --keep-daily 7   --keep-weekly 4   --keep-monthly 12
# restic -r sftp:marcomicheletti@192.168.1.47:backup  stats --mode restore-size latest



# Install command: copies the script to /usr/local/bin
install_script() {
    # First check if restic is installed
    check_restic_binary
    
    sudo cp "$0" /usr/local/bin/restic.sh
    sudo chmod +x /usr/local/bin/restic.sh
    echo "Script installed successfully in /usr/local/bin/restic.sh"
    
    # Create config directory if it doesn't exist
    mkdir -p "$CONFIG_DIR"
    
    # If config file doesn't exist in the destination, create it
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[restic]" > "$CONFIG_FILE"
        echo "# The destination for the backup in the format protocol:user@host:path" >> "$CONFIG_FILE"
        echo "dst=sftp:user@host:backup" >> "$CONFIG_FILE"
        echo "Created default configuration file at $CONFIG_FILE"
        echo "Please edit the file and set your backup destination"
    fi
}

# Main command handler
case "$1" in
    "install")
        install_script
        ;;
    *)
        # Read configuration before executing any command
        read_config
        echo "Usage: $0 [command]"
        echo "Available commands:"
        echo "  install    - Install this script in /usr/local/bin"
        echo ""
        echo "Current configuration:"
        echo "Backup destination: $dst"
        exit 1
        ;;
esac
