#!/bin/bash

# Restic wrapper script
# This script provides a simplified interface for Restic commands

# Check if script is run as root for install command
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo "Please run with sudo for the install command"
        exit 1
    fi
}

# Install command: copies the script to /usr/local/bin
install_script() {
    check_root
    cp "$0" /usr/local/bin/restic.sh
    chmod +x /usr/local/bin/restic.sh
    echo "Script installed successfully in /usr/local/bin/restic.sh"
}

# Main command handler
case "$1" in
    "install")
        install_script
        ;;
    *)
        echo "Usage: $0 [command]"
        echo "Available commands:"
        echo "  install    - Install this script in /usr/local/bin"
        exit 1
        ;;
esac
