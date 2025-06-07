#!/bin/bash

# Restic Backup Manager
# A comprehensive wrapper script for Restic backup management
#
# Features:
# - Easy repository configuration and management
# - Automated backup scheduling with cron
# - Backup retention policy management
# - Progress tracking and colored output
# - Detailed logging and error handling
# - Interactive configuration interface
#
# Dependencies:
# - restic: The backup tool (https://restic.net)
# - jq: JSON processor for configuration management
# - crontab: For backup scheduling (usually pre-installed)

# Configuration
CONFIG_DIR="$HOME/.config"
REPOS_FILE="$CONFIG_DIR/restic.json"
LOG_FILE="/var/log/restic.log"

# Load Telegram configuration from JSON
load_telegram_config() {
    if [ -f "$REPOS_FILE" ]; then
        TELEGRAM_BOT_TOKEN=$(jq -r '.config.telegram.bot_token // empty' "$REPOS_FILE")
        TELEGRAM_CHAT_ID=$(jq -r '.config.telegram.chat_id // empty' "$REPOS_FILE")
    fi
}

# Initialize telegram configuration variables
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
load_telegram_config

# ANSI color codes (disabled)
COLOR_RED=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_BLUE=''
COLOR_PURPLE=''
COLOR_CYAN=''
COLOR_RESET=''

# Print messages without colors
log_info() { echo "[INFO] $1"; }
log_success() { echo "[SUCCESS] $1"; }
log_warning() { echo "[WARNING] $1"; }
log_error() { echo "[ERROR] $1"; }

# Check if jq is installed
check_jq_binary()
{
	if ! command -v jq &> /dev/null; then
		echo "jq is not installed. Installing..."
		if command -v apt-get &> /dev/null; then
			sudo apt-get update && sudo apt-get install -y jq
		elif command -v dnf &> /dev/null; then
			sudo dnf install -y jq
		elif command -v pacman &> /dev/null; then
			sudo pacman -S --noconfirm jq
		else
			echo "Error: Could not install jq. Please install it manually."
			exit 1
		fi
	fi
}

# Function to check and install restic binary
check_restic_binary()
{
	if ! command -v restic &> /dev/null; then
		echo "Restic is not installed. Installing..."

		# Check the package manager and install accordingly
		if command -v apt-get &> /dev/null; then
			# Debian/Ubuntu
			sudo apt-get update
			sudo apt-get install -y restic fuse3 whiptail
		elif command -v dnf &> /dev/null; then
			# Fedora/RHEL
			sudo dnf install -y restic whiptail
		elif command -v pacman &> /dev/null; then
			# Arch Linux
			sudo pacman -S --noconfirm restic libnewt
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
	fi

	# Check if fuse3 is installed on Debian/Ubuntu systems
	if command -v apt-get &> /dev/null && ! dpkg -l | grep -q "fuse3"; then
		echo "Installing fuse3 package..."
		sudo apt-get update
		sudo apt-get install -y fuse3
	fi

	# Check if whiptail is installed
	if ! command -v whiptail &> /dev/null; then
		echo "Installing whiptail..."
		if command -v apt-get &> /dev/null; then
			sudo apt-get update
			sudo apt-get install -y whiptail
		elif command -v dnf &> /dev/null; then
			sudo dnf install -y whiptail
		elif command -v pacman &> /dev/null; then
			sudo pacman -S --noconfirm libnewt
		else
			echo "Warning: Could not install whiptail. Graphical file selection will not be available."
		fi
	fi
}

# Function to read repositories from JSON
read_repos()
{
	if [ ! -f "$REPOS_FILE" ]; then
		echo "Error: Repositories file not found at $REPOS_FILE"
		exit 1
	fi

	if ! jq empty "$REPOS_FILE" 2> /dev/null; then
		echo "Error: Invalid JSON in $REPOS_FILE"
		exit 1
	fi
}

# Function to backup a specific repository
backup_repo()
{
    local repo_name="$1"
    local pre_script="$2"
    local post_script="$3"

    if [ -z "$repo_name" ]; then
        log_error "Repository name not provided"
        return 1
    fi

    # Extract repository configuration
    local repo_config
    repo_config=$(jq -r --arg name "$repo_name" '.repositories[] | select(.name == $name)' "$REPOS_FILE")

    if [ -z "$repo_config" ]; then
        log_error "Repository '$repo_name' not found"
        return 1
    fi

    # Extract values from repo configuration
    local destination password paths excludes
    destination=$(echo "$repo_config" | jq -r '.destination')
    password=$(echo "$repo_config" | jq -r '.password')
    paths=$(echo "$repo_config" | jq -r '.paths[]')
    excludes=$(echo "$repo_config" | jq -r '.exclude[]')

    # Get pre/post backup scripts from config if not provided as parameters
    if [ -z "$pre_script" ]; then
        pre_script=$(echo "$repo_config" | jq -r '.pre_backup // empty')
    fi
    if [ -z "$post_script" ]; then
        post_script=$(echo "$repo_config" | jq -r '.post_backup // empty')
    fi

    # Run pre-backup script if provided
    if [ -n "$pre_script" ]; then
        if [ -x "$pre_script" ]; then
            log_info "Running pre-backup script: $pre_script"
            if ! "$pre_script" "$repo_name"; then
                log_error "Pre-backup script failed"
                return 1
            fi
        else
            log_error "Pre-backup script is not executable: $pre_script"
            return 1
        fi
    fi

	# Validate backup paths
	local invalid_paths=0
	while IFS= read -r path; do
		# Expand ~ to $HOME
		path="${path/#\~/$HOME}"
		if [ ! -e "$path" ]; then
			log_warning "Path does not exist: $path"
			invalid_paths=1
		fi
	done < <(echo "$paths")

	if [ $invalid_paths -eq 1 ]; then
		log_error "Some backup paths are invalid. Please check your configuration."
		return 1
	fi

	# Create exclude parameters
	local exclude_params=""
	while IFS= read -r exclude; do
		exclude_params="$exclude_params --exclude '$exclude'"
	done < <(echo "$excludes")

	# Set password
	export RESTIC_PASSWORD="$password"

	# Create backup tag with timestamp
	local datetime_tag="backup-$(date +"%Y%m%d-%H%M%S")"

	# Create backup command with JSON output
	local backup_cmd="restic -r $destination backup --tag $datetime_tag $exclude_params --json"

	# Add paths
	while IFS= read -r path; do
		# Expand ~ to $HOME
		path="${path/#\~/$HOME}"
		backup_cmd="$backup_cmd '$path'"
	done < <(echo "$paths")

	# Execute backup with progress spinner
	log_info "Starting backup for repository: $repo_name"
	log_info "Destination: $destination"
	
	local pid
	eval "$backup_cmd" > /tmp/restic-backup-$$.json 2>&1 & pid=$!
	
	local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
	local i=0
	while kill -0 $pid 2>/dev/null; do
		echo -ne "\r${spinner[i]} Backing up...   "
		i=$(( (i+1) % ${#spinner[@]} ))
		sleep 0.1
	done
	
	# Check backup status
	wait $pid
	local backup_status=$?
	echo -ne "\r"
	
	if [ $backup_status -eq 0 ]; then
		log_success "Backup completed successfully"
		
		# Parse backup statistics
		local stats
		stats=$(jq -r '.summary' $( tail -1 /tmp/restic-backup-$$.json ) 2>/dev/null)
		if [ -n "$stats" ]; then
			echo -e "\nBackup Statistics:"
			echo "$stats" | jq -r 'to_entries | .[] | "  " + (.key | gsub("_"; " ") | ascii_upcase) + ": " + (.value | tostring)'
		fi
	else
		log_error "Backup failed"
		local error_output=$(cat /tmp/restic-backup-$$.json)
		rm -f /tmp/restic-backup-$$.json

		# Send Telegram notification for backup failure
		local telegram_message="❌ <b>Backup Failed</b>\n"
		telegram_message+="📦 Repository: <code>${repo_name}</code>\n"
		telegram_message+="🔗 Destination: <code>${destination}</code>\n\n"
		telegram_message+="⚠️ Error output:\n<pre>${error_output}</pre>"
		send_telegram "$telegram_message"

		return 1
	fi
	
	rm -f /tmp/restic-backup-$$.json

	# Apply retention policy if specified
	if echo "$repo_config" | jq -e '.retention' > /dev/null; then
		local last daily weekly monthly
		last=$(echo "$repo_config" | jq -r '.retention.last')
		daily=$(echo "$repo_config" | jq -r '.retention.daily')
		weekly=$(echo "$repo_config" | jq -r '.retention.weekly')
		monthly=$(echo "$repo_config" | jq -r '.retention.monthly')

		log_info "Applying retention policy..."
		if restic -r "$destination" forget --prune \
			--keep-last "$last" \
			--keep-daily "$daily" \
			--keep-weekly "$weekly" \
			--keep-monthly "$monthly"; then
			log_success "Retention policy applied successfully"
		else
			log_error "Failed to apply retention policy"
			return 1
		fi
	fi

    # Run post-backup script if provided
    if [ -n "$post_script" ]; then
        if [ -x "$post_script" ]; then
            log_info "Running post-backup script: $post_script"
            if ! "$post_script" "$repo_name"; then
                log_warning "Post-backup script failed"
            fi
        else
            log_error "Post-backup script is not executable: $post_script"
            return 1
        fi
    fi
}

# Function to backup all repositories
backup_all() {
    local pre_script="$1"
    local post_script="$2"

    log_info "Starting backup of all repositories..."
    echo "=========================================="
    echo

    local total_repos failed_repos=0
    total_repos=$(jq -r '.repositories | length' "$REPOS_FILE")
    
    if [ "$total_repos" -eq 0 ]; then
        log_warning "No repositories configured. Please add repositories using 'config' command."
        return 1
    fi

    # Get start time for total duration calculation
    local start_time=$(date +%s)
    local failed_repos_list=()

    # Iterate through all repositories
    local current=0
    while IFS= read -r repo_name; do
        current=$((current + 1))
        echo "\n[$current/$total_repos] Processing repository: $repo_name"
        echo "-------------------------------------------"

        if ! backup_repo "$repo_name" "$pre_script" "$post_script"; then
            failed_repos=$((failed_repos + 1))
            failed_repos_list+=("$repo_name")
        fi

        # Show progress bar
        local progress=$((current * 100 / total_repos))
        printf "\nOverall Progress: [%3d%%] " "$progress"
        local bar_size=40
        local completed=$((progress * bar_size / 100))
        local remaining=$((bar_size - completed))
        printf "#%.0s" $(seq 1 $completed)
        printf "%.0s-" $(seq 1 $remaining)
        echo
    done < <(jq -r '.repositories[] | .name' "$REPOS_FILE")

    # Calculate total duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))

    echo -e "\n=========================================="
    if [ $failed_repos -eq 0 ]; then
        log_success "All repositories backed up successfully!"
    else
        log_warning "$failed_repos out of $total_repos repositories failed:"
        for repo in "${failed_repos_list[@]}"; do
            echo "  ✗ $repo"
        done
    fi

    echo -e "\nTotal time: "
    [ $hours -gt 0 ] && echo -n "$hours hours "
    [ $minutes -gt 0 ] && echo -n "$minutes minutes "
    echo "$seconds seconds"

    return $failed_repos
}

# Function to list all repositories
show_repos()
{
    echo
    echo "📦 Configured Backup Repositories"
    echo "=================================="

    # Get total number of repositories
    local total_repos=$(jq -r '.repositories | length' "$REPOS_FILE")
    if [ "$total_repos" -eq 0 ]; then
        echo "\nNo repositories configured"
        echo "Use 'config' command to add repositories"
        return 0
    fi

    echo "\nFound $total_repos configured repositories\n"

    # Get all repositories and iterate through them
    local index=0
    jq -r '.repositories[] | @base64' "$REPOS_FILE" | while read -r repo_b64; do
        repo=$(echo "$repo_b64" | base64 -d)

        # Extract repository details
        name=$(echo "$repo" | jq -r '.name')
        dest=$(echo "$repo" | jq -r '.destination')

        # Print repository header with index
        echo "[$index] Repository: $name"
        echo "    └─ 🔗 Destination: $dest"

        # Get and print latest backup info
        if [ -n "$RESTIC_PASSWORD" ]; then
            unset RESTIC_PASSWORD
        fi
        export RESTIC_PASSWORD=$(echo "$repo" | jq -r '.password')
        latest_snap=$(restic -r "$dest" snapshots --json latest 2>/dev/null | jq -r '.[0].time // "No backups yet"')
        if [ "$latest_snap" != "No backups yet" ]; then
            echo "    └─ 🕒 Latest backup: $latest_snap"
        else
            echo "    └─ 🕒 Latest backup: No backups yet"
        fi

        # Print paths with status
        echo "    └─ 📂 Backup paths:"
        echo "$repo" | jq -r '.paths[]' | while read -r path; do
            path="${path/#\~/$HOME}"
            if [ -e "$path" ]; then
                echo "       └─ ✓ $path"
            else
                echo "       └─ ✗ $path (not found)"
            fi
        done

        # Print excludes if any
        if echo "$repo" | jq -e '.exclude' > /dev/null && [ "$(echo "$repo" | jq -r '.exclude | length')" -gt 0 ]; then
            echo "    └─ 🚫 Excludes:"
            echo "$repo" | jq -r '.exclude[]' | while read -r excl; do
                echo "       └─ $excl"
            done
        fi

        # Print retention policy if exists
        if echo "$repo" | jq -e '.retention' > /dev/null; then
            echo "    └─ ⏱️  Retention policy:"
            echo "       └─ Last: $(echo "$repo" | jq -r '.retention.last') snapshots"
            echo "       └─ Daily: $(echo "$repo" | jq -r '.retention.daily') days"
            echo "       └─ Weekly: $(echo "$repo" | jq -r '.retention.weekly') weeks"
            echo "       └─ Monthly: $(echo "$repo" | jq -r '.retention.monthly') months"
        fi

        # Print pre and post backup scripts if configured
        local pre_script=$(echo "$repo" | jq -r '.pre_backup // empty')
        local post_script=$(echo "$repo" | jq -r '.post_backup // empty')
        if [ -n "$pre_script" ] || [ -n "$post_script" ]; then
            echo "    └─ 📜 Backup scripts:"
            [ -n "$pre_script" ] && echo "       └─ Pre-backup: $pre_script"
            [ -n "$post_script" ] && echo "       └─ Post-backup: $post_script"
        fi

        # Print separator between repositories
        if [ $((index + 1)) -lt "$total_repos" ]; then
            echo "\n────────────────────────────────────\n"
        fi

        index=$((index + 1))
    done
    echo
}

# Install command: copies the script to /usr/local/bin
install_script()
{
	# First check if restic and jq are installed
	check_restic_binary
	check_jq_binary

	sudo cp "$0" /usr/local/bin/restic.sh
	sudo chmod +x /usr/local/bin/restic.sh
	echo "Script installed successfully in /usr/local/bin/restic.sh"

	# Create config directory if it doesn't exist
	mkdir -p "$CONFIG_DIR"

	# Configure Telegram notifications
	read -r -p "Enter Telegram Bot Token for notifications (leave empty to skip): " bot_token
	if [ -n "$bot_token" ]; then
		read -r -p "Enter Telegram Chat ID: " chat_id
		if [ -n "$chat_id" ]; then
			if ! command -v curl &> /dev/null; then
				echo "Installing curl for Telegram notifications..."
				if command -v apt-get &> /dev/null; then
					sudo apt-get update && sudo apt-get install -y curl
				elif command -v dnf &> /dev/null; then
					sudo dnf install -y curl
				elif command -v pacman &> /dev/null; then
					sudo pacman -S --noconfirm curl
				else
					echo "Warning: Could not install curl. Telegram notifications will not work."
				fi
			fi

			# If repos file doesn't exist, create it with default structure
			if [ ! -f "$REPOS_FILE" ]; then
				cat > "$REPOS_FILE" << 'EOL'
{
  "config": {
    "telegram": {
      "bot_token": "",
      "chat_id": ""
    }
  },
  "repositories": []
}
EOL
			fi

			# Update Telegram configuration in JSON file
			local json_content
			json_content=$(jq --arg token "$bot_token" --arg chat "$chat_id" '.config.telegram.bot_token = $token | .config.telegram.chat_id = $chat' "$REPOS_FILE")
			echo "$json_content" > "$REPOS_FILE"
			
			# Load the new configuration
			load_telegram_config
			
			echo "Telegram notifications configured successfully"

			# Test Telegram configuration
			local test_message="🔔 <b>Restic Backup Test</b>\n\nNotification system is working correctly!"
			if send_telegram "$test_message"; then
				echo "✅ Test notification sent successfully"
			else
				echo "❌ Failed to send test notification. Please check your Telegram configuration."
			fi
		fi
	fi

	# If repos file doesn't exist in the destination, create it
	if [ ! -f "$REPOS_FILE" ]; then
		cat > "$REPOS_FILE" << 'EOL'
{
    "repositories": [
        {
            "name": "example",
            "destination": "sftp:user@host:backup",
            "password": "your-password-here",
            "paths": [
                "~/Documents"
            ],
            "exclude": [
                "*.tmp"
            ],
            "retention": {
                "last": 24,
                "daily": 7,
                "weekly": 4,
                "monthly": 12
            },
            "pre_backup": "",
            "post_backup": ""
        }
    ]
}
EOL
		echo "Created default repositories file at $REPOS_FILE"
		echo "Please edit the file and set your backup configurations"
	fi
}

# Function to initialize a specific repository
init_repo()
{
	local repo_name="$1"
	if [ -z "$repo_name" ]; then
		echo "Error: Repository name not provided"
		exit 1
	fi

	# Extract repository configuration
	local repo_config
	repo_config=$(jq -r --arg name "$repo_name" '.repositories[] | select(.name == $name)' "$REPOS_FILE")

	if [ -z "$repo_config" ]; then
		echo "Error: Repository '$repo_name' not found"
		exit 1
	fi

	# Extract values from repo configuration
	local destination
	local password

	destination=$(echo "$repo_config" | jq -r '.destination')
	password=$(echo "$repo_config" | jq -r '.password')

	# Set password
	export RESTIC_PASSWORD="$password"

	# Initialize repository
	echo "Initializing repository: $repo_name"
	if ! restic -r "$destination" init; then
		echo "❌ Failed to initialize repository: $repo_name"
		return 1
	fi
	echo "✅ Repository initialized successfully: $repo_name"
	return 0
}

# Function to initialize all repositories
init_all()
{
	echo "🔄 Initializing all repositories..."
	echo "=================================="
	echo

	local total_repos=$(jq -r '.repositories | length' "$REPOS_FILE")
	local current=0
	local failed=0

	# Iterate through all repositories
	jq -r '.repositories[] | .name' "$REPOS_FILE" | while read -r repo_name; do
		current=$((current + 1))
		echo -e "📦 Processing repository ($current/$total_repos): \033[1;36m$repo_name\033[0m"
		echo "-------------------------------------------"
		if ! init_repo "$repo_name"; then
			failed=$((failed + 1))
		fi
		echo
	done

	if [ $failed -eq 0 ]; then
		echo "✅ All repositories initialized successfully!"
	else
		echo "⚠️  Initialization completed with $failed failures."
		return 1
	fi
}

# Function to list snapshots of a specific repository
list_repo_snapshots()
{
	local repo_name="$1"
	local verbose="$2"

	if [ -z "$repo_name" ]; then
		echo "Error: Repository name not provided"
		exit 1
	fi

	# Extract repository configuration
	local repo_config
	repo_config=$(jq -r --arg name "$repo_name" '.repositories[] | select(.name == $name)' "$REPOS_FILE")

	if [ -z "$repo_config" ]; then
		echo "Error: Repository '$repo_name' not found"
		exit 1
	fi

	# Extract values from repo configuration
	local destination
	local password

	destination=$(echo "$repo_config" | jq -r '.destination')
	password=$(echo "$repo_config" | jq -r '.password')

	# Set password
	export RESTIC_PASSWORD="$password"

	# Print repository header
	echo -e "📦 Repository: \033[1;36m$repo_name\033[0m"
	echo "   └─ 🔗 Destination: $destination"
	echo "   └─ 📊 Snapshots:"
	echo

	# List snapshots with different detail levels
	if [ "$verbose" = "true" ]; then
		echo "🔍 Detailed snapshot list:"
		if ! restic -r "$destination" snapshots --verbose; then
			echo "❌ Failed to list snapshots for repository: $repo_name"
			return 1
		fi

		echo -e "\n📋 Latest snapshot contents:"
		if ! restic -r "$destination" ls latest; then
			echo "❌ Failed to list contents for repository: $repo_name"
			return 1
		fi

		echo -e "\n📊 Repository statistics:"
		if ! restic -r "$destination" stats; then
			echo "❌ Failed to get statistics for repository: $repo_name"
			return 1
		fi
	else
		if ! restic -r "$destination" snapshots; then
			echo "❌ Failed to list snapshots for repository: $repo_name"
			return 1
		fi
	fi
	echo
	return 0
}

# Function to list snapshots of all repositories
list_all_snapshots()
{
	local verbose="$1"

	echo "🔄 Listing snapshots from all repositories..."
	echo "==========================================="
	echo

	local total_repos=$(jq -r '.repositories | length' "$REPOS_FILE")
	local current=0
	local failed=0

	# Iterate through all repositories
	jq -r '.repositories[] | .name' "$REPOS_FILE" | while read -r repo_name; do
		current=$((current + 1))
		if ! list_repo_snapshots "$repo_name" "$verbose"; then
			failed=$((failed + 1))
		fi
	done

	if [ $failed -eq 0 ]; then
		echo "✅ Successfully listed all snapshots!"
	else
		echo "⚠️  Listing completed with $failed failures."
		return 1
	fi
}

# Function to restore a specific repository
restore_repo()
{
	local repo_name="$1"
	local snapshot_id="$2"
	local restore_path="$3"
	local files=("${@:4}") # Get all remaining arguments as files array

	if [ -z "$repo_name" ]; then
		echo "Error: Repository name not provided"
		exit 1
	fi

	if [ -z "$snapshot_id" ]; then
		echo "Error: Snapshot ID not provided"
		exit 1
	fi

	# Extract repository configuration
	local repo_config
	repo_config=$(jq -r --arg name "$repo_name" '.repositories[] | select(.name == $name)' "$REPOS_FILE")

	if [ -z "$repo_config" ]; then
		echo "Error: Repository '$repo_name' not found"
		exit 1
	fi

	# Extract values from repo configuration
	local destination
	local password

	destination=$(echo "$repo_config" | jq -r '.destination')
	password=$(echo "$repo_config" | jq -r '.password')

	# Set password
	export RESTIC_PASSWORD="$password"

	# Create restore command
	local restore_cmd="restic -r $destination restore $snapshot_id"

	# If files are specified, add them to the command
	if [ ${#files[@]} -gt 0 ]; then
		echo "🔄 Restoring specific files from repository: \033[1;36m$repo_name\033[0m"
		echo "   └─ 🔗 Destination: $destination"
		echo "   └─ 📊 Snapshot ID: $snapshot_id"
		echo "   └─ 📂 Files to restore:"
		for file in "${files[@]}"; do
			echo "      └─ $file"
			restore_cmd="$restore_cmd --include '$file'"
		done
	else
		echo "🔄 Restoring entire snapshot from repository: \033[1;36m$repo_name\033[0m"
		echo "   └─ 🔗 Destination: $destination"
		echo "   └─ 📊 Snapshot ID: $snapshot_id"
	fi

	# Add target directory
	echo "   └─ 🎯 Target path: $restore_path"
	restore_cmd="$restore_cmd --target '$restore_path'"

	echo
	echo "Starting restore operation..."
	if ! eval "$restore_cmd"; then
		echo "❌ Failed to restore from repository: $repo_name"
		return 1
	fi

	echo "✅ Restore completed successfully"
	return 0
}

# Function to handle restore command
handle_restore_command() {
    local repo_name=""
    local snapshot_id=""
    local files=()
    local use_gui=false
    local restore_path="."  # Default to current directory

    # Parse arguments
    shift # skip the 'restore' command
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f | --file)
                shift
                while [[ $# -gt 0 ]] && [[ $1 != -* ]]; do
                    files+=("$1")
                    shift
                done
                ;;
            -g | --gui)
                use_gui=true
                shift
                ;;
            -p | --path)
                shift
                if [[ $# -gt 0 ]]; then
                    restore_path="$1"
                    shift
                else
                    echo "Error: -p option requires a path argument"
                    return 1
                fi
                ;;
            *)
                if [ -z "$repo_name" ]; then
                    repo_name="$1"
                elif [ -z "$snapshot_id" ]; then
                    snapshot_id="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$repo_name" ] || [ -z "$snapshot_id" ]; then
        echo "Error: Repository name and snapshot ID are required"
        echo "Usage: $0 restore <repo-name> <snapshot-id> [-f file1 file2 ...] [-g] [-p path]"
        echo "Options:"
        echo "  -f, --file  Specify files to restore"
        echo "  -g, --gui   Use graphical interface to select files"
        echo "  -p, --path  Target path for restoring files (default: current directory)"
        return 1
    fi

    # Extract repository configuration for graphical selection
    if [ "$use_gui" = true ]; then
        if ! command -v whiptail &> /dev/null; then
            log_error "whiptail is not installed. Cannot use graphical file selection."
            return 1
        fi

        # Get repository configuration
        repo_config=$(jq -r --arg name "$repo_name" '.repositories[] | select(.name == $name)' "$REPOS_FILE")
        if [ -z "$repo_config" ]; then
            log_error "Repository '$repo_name' not found"
            return 1
        fi

        destination=$(echo "$repo_config" | jq -r '.destination')
        password=$(echo "$repo_config" | jq -r '.password')

        # Get files through graphical selection
        if selected_files=($(select_files_graphically "$repo_name" "$snapshot_id" "$destination" "$password")); then
            if [ ${#selected_files[@]} -gt 0 ]; then
                files=("${selected_files[@]}")
            else
                log_error "No files selected"
                return 1
            fi
        else
            return 1
        fi
    fi

    restore_repo "$repo_name" "$snapshot_id" "$restore_path" "${files[@]}"
}

# Function to select files graphically using whiptail
select_files_graphically() {
    local repo_name="$1"
    local snapshot_id="$2"
    local destination="$3"
    local temp_file="/tmp/restic-files-$$.txt"
    local selected_files=()

    # List all files in the snapshot and save to temporary file
    if ! RESTIC_PASSWORD="$4" restic -r "$destination" ls "$snapshot_id" > "$temp_file"; then
        log_error "Failed to list files in snapshot"
        rm -f "$temp_file"
        return 1
    fi

    # Create array of files with their selection status (initially OFF)
    local file_list=()
    while IFS= read -r file; do
        # Skip empty lines and directory entries
        [[ -z "$file" || "$file" =~ /$ ]] && continue
        file_list+=("$file" "" "OFF")
    done < "$temp_file"

    if [ ${#file_list[@]} -eq 0 ]; then
        log_error "No files found in snapshot"
        rm -f "$temp_file"
        return 1
    fi

    # Show checklist dialog
    if selected=$(whiptail --title "Select Files to Restore" \
                          --checklist "Use space to select/deselect files" \
                          $((LINES-8)) $((COLUMNS-10)) $((LINES-15)) \
                          "${file_list[@]}" \
                          3>&1 1>&2 2>&3); then
        # Convert selected files string to array
        eval "selected_files=($selected)"
    else
        log_info "File selection cancelled"
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"
    
    # Print selected files to stdout (one per line)
    printf "%s\n" "${selected_files[@]}"
    return 0
}

# Function to manage crontab scheduling
manage_crontab()
{
	local script_path="/usr/local/bin/restic.sh"
	local schedule
	local mode="$1"

	echo "🕒 Configurazione Backup Automatico"
	echo "=================================="
	echo

	if [ "$mode" = "-s" ]; then
		echo "📋 Schedulazioni di backup attuali:"
		echo

		# Leggi il crontab attuale
		local current_crontab
		current_crontab=$(crontab -l 2> /dev/null || echo "")

		# Filtra e mostra solo le righe relative a restic.sh
		local restic_schedules
		restic_schedules=$(echo "$current_crontab" | grep "restic\.sh backup" || echo "")

		if [ -z "$restic_schedules" ]; then
			echo "Nessuna schedulazione di backup configurata."
		else
			echo "$restic_schedules" | while IFS= read -r line; do
				local schedule_part=${line%restic.sh*}
				echo "🔄 $schedule_part"
				echo "   └─ Comando: $line"
				echo
			done
		fi
		return 0
	elif [ "$mode" = "-d" ]; then
		echo "⚠️  Rimozione delle schedulazioni di backup"
		echo
		echo "Vuoi rimuovere tutte le schedulazioni di backup? [s/N]"
		read -r remove_cron

		if [[ "$remove_cron" =~ ^[Ss]$ ]]; then
			# Leggi il crontab attuale
			local current_crontab
			current_crontab=$(crontab -l 2> /dev/null || echo "")

			# Rimuovi tutte le pianificazioni di restic.sh
			local new_crontab
			new_crontab=$(echo "$current_crontab" | grep -v "restic\.sh backup")

			# Installa il nuovo crontab
			echo "$new_crontab" | crontab -

			if [ $? -eq 0 ]; then
				echo "✅ Schedulazioni rimosse con successo!"
			else
				echo "❌ Errore durante la rimozione delle schedulazioni"
				return 1
			fi
		else
			echo "Rimozione annullata"
		fi
		return 0
	fi

	# Seleziona la schedulazione
	select_schedule

	# Crea il comando crontab con logging
	# Aggiungiamo data e ora all'inizio di ogni log entry
	# local log_cmd='date "+[%Y-%m-%d %H:%M:%S]" >> '"$LOG_FILE"' 2>&1 && '
	local log_cmd=''
	log_cmd+="$script_path backup >> $LOG_FILE 2>&1"
	local cron_cmd="$schedule $log_cmd"

	echo
	echo "Il seguente comando verrà aggiunto al crontab:"
	echo "📅 $cron_cmd"
	echo
	echo "L'output del backup verrà salvato in: $LOG_FILE"
	echo
	echo "Vuoi installare questa schedulazione? [s/N]"
	read -r install_cron

	if [[ "$install_cron" =~ ^[Ss]$ ]]; then
		# Assicurati che il file di log esista e abbia i permessi corretti
		if [ ! -f "$LOG_FILE" ]; then
			sudo touch "$LOG_FILE"
			sudo chown "$(whoami)" "$LOG_FILE"
			sudo chmod 644 "$LOG_FILE"
			echo "✅ File di log creato: $LOG_FILE"
		fi

		# Leggi il crontab attuale
		local current_crontab
		current_crontab=$(crontab -l 2> /dev/null || echo "")

		# Rimuovi eventuali pianificazioni esistenti di restic.sh
		local new_crontab
		new_crontab=$(echo "$current_crontab" | grep -v "restic\.sh backup")

		# Aggiungi la nuova pianificazione
		new_crontab="${new_crontab}${cron_cmd}"

		# Installa il nuovo crontab
		echo "$new_crontab" | crontab -

		if [ $? -eq 0 ]; then
			echo "✅ Schedulazione installata con successo!"
			echo "📝 I log verranno salvati in: $LOG_FILE"
		else
			echo "❌ Errore durante l'installazione della schedulazione"
			return 1
		fi
	else
		echo "Installazione annullata"
	fi
}

# Function to update the script from remote repository
update_script() {
    local remote_url="http://git.home.lan:3000/marco/restic/raw/branch/main/restic.sh"
    local temp_file="/tmp/restic.sh.new"
    local script_path="$0"
    local backup_path="${script_path}.backup"

    # Download new version
    log_info "Downloading latest version from $remote_url..."
    if ! curl -s -o "$temp_file" "$remote_url"; then
        log_error "Failed to download the script"
        rm -f "$temp_file"
        return 1
    fi

    # Check if download was successful and file is not empty
    if [ ! -s "$temp_file" ]; then
        log_error "Downloaded file is empty"
        rm -f "$temp_file"
        return 1
    fi

    # Check if the downloaded file is different
    if diff -q "$script_path" "$temp_file" >/dev/null; then
        log_info "Script is already up to date"
        rm -f "$temp_file"
        return 0
    fi

    # Show differences
    echo -e "\nChanges to be applied:"
    echo "========================="
    diff -u "$script_path" "$temp_file"
    echo "========================="

    # Ask for confirmation
    read -r -p "Do you want to update the script? [y/N] " response
    if [[ ! "$response" =~ ^[yY]$ ]]; then
        log_info "Update cancelled"
        rm -f "$temp_file"
        return 0
    fi

    # Create backup
    log_info "Creating backup of current script..."
    if ! cp -p "$script_path" "$backup_path"; then
        log_error "Failed to create backup"
        rm -f "$temp_file"
        return 1
    fi

    # Get current permissions
    local current_perms
    current_perms=$(stat -c %a "$script_path")

    # Update script
    log_info "Installing new version..."
    if ! mv "$temp_file" "$script_path"; then
        log_error "Failed to install new version"
        rm -f "$temp_file"
        return 1
    fi

    # Restore permissions
    chmod "$current_perms" "$script_path"

    log_success "Script updated successfully"
    log_info "Backup saved as: $backup_path"
    return 0
}

# Function to show usage help
show_usage() {
    echo "Restic Backup Manager - A comprehensive wrapper for Restic backup management"
    echo -e "Version: 1.0.0\n"

    echo "USAGE:"
    echo "  restic.sh <command> [options]"
    echo

    echo "COMMANDS:"
    echo "  install"
    echo "    Install the script and initialize configuration files"
    echo "    This will create default config files in $CONFIG_DIR"
    echo

    echo "  config [-s]"
    echo "    Configure backup repositories interactively"
    echo "    Options:"
    echo "      -s  Show current configuration"
    echo

    echo "  init [repo-name]"
    echo "    Initialize a new repository or all repositories"
    echo "    Arguments:"
    echo "      repo-name  Optional: Initialize specific repository"
    echo "                If omitted, initializes all repositories"
    echo

    echo "  backup [repo-name] [-pre-backup script] [-post-backup script]"
    echo "    Perform backup according to configuration"
    echo "    Arguments:"
    echo "      repo-name        Optional: Backup specific repository"
    echo "                       If omitted, backs up all repositories"
    echo "    Options:"
    echo "      -pre-backup     Optional: Script to run before backup"
    echo "                      Script will receive repository name as parameter"
    echo "      -post-backup    Optional: Script to run after backup"
    echo "                      Script will receive repository name as parameter"
    echo "    Features:"
    echo "      - Automatic timestamp tags (backup-YYYYMMDD-HHMMSS)"
    echo "      - Progress tracking with status bar"
    echo "      - Detailed backup statistics"
    echo

    echo "  restore <repo-name> <snapshot-id> [-f file1 file2 ...] [-g] [-p path]"
    echo "    Restore files from a backup"
    echo "    Arguments:"
    echo "      repo-name    Name of the repository to restore from"
    echo "      snapshot-id  ID of the snapshot to restore"
    echo "    Options:"
    echo "      -f  Specify files to restore (optional)"
    echo "          If omitted, restores entire snapshot"
    echo "      -g  Use graphical interface to select files"
    echo "      -p  Target path for restoring files (default: current directory)"
    echo

    echo "  list [repo-name] [-v]"
    echo "    List snapshots from repositories"
    echo "    Arguments:"
    echo "      repo-name  Optional: List snapshots from specific repository"
    echo "    Options:"
    echo "      -v  Show detailed information including statistics"
    echo

    echo "  update"
    echo "    Update this script to the latest version"
    echo "    Downloads the latest version from the Git repository and"
    echo "    creates a backup of the current version before updating"
    echo

    echo "  crontab [-s|-d]"
    echo "    Manage backup scheduling"
    echo "    Options:"
    echo "      -s  Show current backup schedules"
    echo "      -d  Delete all backup schedules"
    echo

    echo "  -h, --help"
    echo "    Show this help message"
    echo

    echo "EXAMPLES:"
    echo "  # Install and configure"
    echo "  restic.sh install"
    echo "  restic.sh config"
    echo
    echo "  # Initialize and perform backup"
    echo "  restic.sh init"
    echo "  restic.sh backup"
    echo
    echo "  # Backup with pre/post scripts"
    echo "  restic.sh backup -pre-backup /path/to/pre.sh -post-backup /path/to/post.sh"
    echo "  restic.sh backup myrepo -pre-backup /path/to/pre.sh"
    echo
    echo "  # Restore specific files"
    echo "  restic.sh list myrepo -v"
    echo "  restic.sh restore myrepo 1a2b3c -f /path/to/file1 /path/to/file2"
    echo
    echo "  # Schedule automatic backups"
    echo "  restic.sh crontab"
    echo

    echo "CONFIGURATION:"
    echo "  Config files are stored in: $CONFIG_DIR"
    echo "  - Repository settings: $REPOS_FILE"
    echo "  - Backup logs: $LOG_FILE"
    echo

    exit 1
}

# Function to configure repositories interactively
configure_repos()
{
	local show_only="$1"

	if [ "$show_only" = "-s" ]; then
		echo
		echo "🗄️  Configured Backup Repositories"
		echo "=================================="
		echo
		show_repos
		return 0
	fi

	echo "📝 Configurazione Repository Restic"
	echo "================================="
	echo

	# Create config directory if it doesn't exist
	mkdir -p "$CONFIG_DIR"

	# Initialize or load existing repositories
	local repositories=()
	if [ -f "$REPOS_FILE" ]; then
		echo "File di configurazione esistente trovato."
		echo "Vuoi modificare la configurazione esistente? [s/N]"
		read -r modify_config

		if [[ "$modify_config" =~ ^[Ss]$ ]]; then
			repositories=$(jq -r '.repositories' "$REPOS_FILE")
		else
			echo "Configurazione annullata"
			return 0
		fi
	fi

	while true; do
		echo
		echo "Seleziona un'azione:"
		echo "1) Aggiungi repository"
		echo "2) Modifica repository"
		echo "3) Rimuovi repository"
		echo "4) Mostra configurazione attuale"
		echo "5) Salva ed esci"
		echo "6) Esci senza salvare"
		echo
		read -r -p "Scelta [1-6]: " choice

		case "$choice" in
			1)
				echo
				echo "➕ Aggiunta nuovo repository"
				echo "-------------------------"

				read -r -p "Nome del repository: " name
				read -r -p "Destinazione (es: sftp:user@host:backup): " destination
				read -r -s -p "Password: " password
				echo

				echo "Percorsi da includere nel backup (uno per riga, lascia vuoto per terminare):"
				paths=()
				while true; do
					read -r -p "Percorso: " path
					[ -z "$path" ] && break
					paths+=("$path")
				done

				echo "Pattern da escludere (uno per riga, lascia vuoto per terminare):"
				excludes=()
				while true; do
					read -r -p "Pattern: " exclude
					[ -z "$exclude" ] && break
					excludes+=("$exclude")
				done

				echo "Configurazione policy di retention:"
				read -r -p "Numero di snapshot recenti da mantenere: " keep_last
				read -r -p "Numero di snapshot giornalieri da mantenere: " keep_daily
				read -r -p "Numero di snapshot settimanali da mantenere: " keep_weekly
				read -r -p "Numero di snapshot mensili da mantenere: " keep_monthly

				echo "Script di pre/post backup (opzionali):"
				read -r -p "Script da eseguire prima del backup (lascia vuoto per saltare): " pre_script
				read -r -p "Script da eseguire dopo il backup (lascia vuoto per saltare): " post_script

				# Create new repository JSON
				new_repo=$(jq -n \
					--arg name "$name" \
					--arg dest "$destination" \
					--arg pwd "$password" \
					--argjson paths "$(printf '%s\n' "${paths[@]}" | jq -R . | jq -s .)" \
					--argjson excludes "$(printf '%s\n' "${excludes[@]}" | jq -R . | jq -s .)" \
					--arg last "${keep_last:-7}" \
					--arg daily "${keep_daily:-7}" \
					--arg weekly "${keep_weekly:-4}" \
					--arg monthly "${keep_monthly:-12}" \
					--arg pre_script "$pre_script" \
					--arg post_script "$post_script" \
					'{
						"name": $name,
						"destination": $dest,
						"password": $pwd,
						"paths": $paths,
						"exclude": $excludes,
						"retention": {
							"last": ($last|tonumber),
							"daily": ($daily|tonumber),
							"weekly": ($weekly|tonumber),
							"monthly": ($monthly|tonumber)
						},
						"pre_backup": $pre_script,
						"post_backup": $post_script
					}')

				# Add to repositories array
				repositories=$(echo "$repositories" | jq '. += ['"$new_repo"']')
				echo "✅ Repository aggiunto con successo!"
				;;
			2)
				if [ -z "$repositories" ] || [ "$(echo "$repositories" | jq '. | length')" -eq 0 ]; then
					echo "❌ Nessun repository configurato"
					continue
				fi

				echo
				echo "✏️  Modifica repository"
				echo "------------------"
				echo "Repository disponibili:"

				echo "$repositories" | jq -r '.[].name' | nl -v 0
				read -r -p "Seleziona il numero del repository da modificare: " index

				if [[ "$index" =~ ^[0-9]+$ ]]; then
					# Ottieni il repository corrente
					local current_repo=$(echo "$repositories" | jq ".[$index]")
					if [ -z "$current_repo" ] || [ "$current_repo" = "null" ]; then
						echo "❌ Repository non trovato"
						continue
					fi

					echo
					echo "Repository selezionato:"
					echo "$current_repo" | jq .
					echo
					echo "Inserisci i nuovi valori (lascia vuoto per mantenere il valore attuale)"

					# Nome
					local current_name=$(echo "$current_repo" | jq -r '.name')
					read -r -p "Nome del repository [$current_name]: " name
					name=${name:-$current_name}

					# Destinazione
					local current_dest=$(echo "$current_repo" | jq -r '.destination')
					read -r -p "Destinazione [$current_dest]: " destination
					destination=${destination:-$current_dest}

					# Password
					local current_pwd=$(echo "$current_repo" | jq -r '.password')
					read -r -s -p "Password (premi invio per mantenere quella attuale): " password
					echo
					password=${password:-$current_pwd}

					# Percorsi
					echo "Percorsi attuali:"
					echo "$current_repo" | jq -r '.paths[]' | nl
					echo "Inserisci i nuovi percorsi (uno per riga, lascia vuoto per terminare):"
					echo "Lascia vuoto e premi invio subito per mantenere i percorsi attuali"
					paths=()
					while true; do
						read -r -p "Percorso: " path
						[ -z "$path" ] && break
						paths+=("$path")
					done
					if [ ${#paths[@]} -eq 0 ]; then
						paths=($(echo "$current_repo" | jq -r '.paths[]'))
					fi

					# Esclusioni
					echo "Pattern di esclusione attuali:"
					echo "$current_repo" | jq -r '.exclude[]' | nl
					echo "Inserisci i nuovi pattern (uno per riga, lascia vuoto per terminare):"
					echo "Lascia vuoto e premi invio subito per mantenere i pattern attuali"
					excludes=()
					while true; do
						read -r -p "Pattern: " exclude
						[ -z "$exclude" ] && break
						excludes+=("$exclude")
					done
					if [ ${#excludes[@]} -eq 0 ]; then
						excludes=($(echo "$current_repo" | jq -r '.exclude[]'))
					fi

					# Policy di retention
					echo "Policy di retention attuale:"
					echo "$current_repo" | jq '.retention'
					echo "Inserisci i nuovi valori (invio per mantenere il valore attuale):"

					local current_last=$(echo "$current_repo" | jq -r '.retention.last')
					read -r -p "Numero di snapshot recenti da mantenere [$current_last]: " keep_last
					keep_last=${keep_last:-$current_last}

					local current_daily=$(echo "$current_repo" | jq -r '.retention.daily')
					read -r -p "Numero di snapshot giornalieri da mantenere [$current_daily]: " keep_daily
					keep_daily=${keep_daily:-$current_daily}

					local current_weekly=$(echo "$current_repo" | jq -r '.retention.weekly')
					read -r -p "Numero di snapshot settimanali da mantenere [$current_weekly]: " keep_weekly
					keep_weekly=${keep_weekly:-$current_weekly}

					local current_monthly=$(echo "$current_repo" | jq -r '.retention.monthly')
					read -r -p "Numero di snapshot mensili da mantenere [$current_monthly]: " keep_monthly
					keep_monthly=${keep_monthly:-$current_monthly}

					# Script di pre/post backup
					local current_pre_script=$(echo "$current_repo" | jq -r '.pre_backup // empty')
					read -r -p "Script pre-backup [$current_pre_script]: " pre_script
					pre_script=${pre_script:-$current_pre_script}

					local current_post_script=$(echo "$current_repo" | jq -r '.post_backup // empty')
					read -r -p "Script post-backup [$current_post_script]: " post_script
					post_script=${post_script:-$current_post_script}

					# Create updated repository JSON
					# Validate numeric values before JSON construction
					local retention_values=(
						"$keep_last" "$keep_daily" "$keep_weekly" "$keep_monthly"
					)
					for value in "${retention_values[@]}"; do
						if [[ -n "$value" ]] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
							echo "❌ Error: Retention values must be positive numbers"
							return 1
						fi
					done

					local updated_repo=$(jq -n \
						--arg name "$name" \
						--arg dest "$destination" \
						--arg pwd "$password" \
						--argjson paths "$(printf '%s\n' "${paths[@]}" | jq -R . | jq -s .)" \
						--argjson excludes "$(printf '%s\n' "${excludes[@]}" | jq -R . | jq -s .)" \
						--arg last "${keep_last:-0}" \
						--arg daily "${keep_daily:-0}" \
						--arg weekly "${keep_weekly:-0}" \
						--arg monthly "${keep_monthly:-0}" \
						--arg pre_script "$pre_script" \
						--arg post_script "$post_script" \
						'{
							"name": $name,
							"destination": $dest,
							"password": $pwd,
							"paths": $paths,
							"exclude": $excludes,
							"retention": {
								"last": ($last|tonumber),
								"daily": ($daily|tonumber),
								"weekly": ($weekly|tonumber),
								"monthly": ($monthly|tonumber)
							},
							"pre_backup": ($pre_script // null),
							"post_backup": ($post_script // null)
						}')

					# Update repository in the array
					repositories=$(echo "$repositories" | jq ".[$index] = $updated_repo")
					echo "✅ Repository aggiornato con successo!"
				else
					echo "❌ Selezione non valida"
				fi
				;;
			3)
				if [ -z "$repositories" ] || [ "$(echo "$repositories" | jq '. | length')" -eq 0 ]; then
					echo "❌ Nessun repository configurato"
					continue
				fi

				echo
				echo "➖ Rimozione repository"
				echo "---------------------"
				echo "Repository disponibili:"

				echo "$repositories" | jq -r '.[].name' | nl -v 0
				read -r -p "Seleziona il numero del repository da rimuovere: " index

				if [[ "$index" =~ ^[0-9]+$ ]]; then
					repositories=$(echo "$repositories" | jq "del(.[$index])")
					echo "✅ Repository rimosso con successo!"
				else
					echo "❌ Selezione non valida"
				fi
				;;
			4)
				echo
				echo "👀 Configurazione attuale"
				echo "----------------------"
				echo "$repositories" | jq .
				;;
			5)
				echo
				echo "💾 Salvataggio configurazione..."
				echo '{"repositories":'"$repositories"'}' | jq . > "$REPOS_FILE"
				echo "✅ Configurazione salvata in $REPOS_FILE"
				return 0
				;;
			6)
				echo
				echo "⚠️  Uscita senza salvare"
				return 0
				;;
			*)
				echo "❌ Scelta non valida"
				;;
		esac
	done
}

# Function to send Telegram notifications
send_telegram() {
    local message="$1"

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        log_warning "Telegram notification skipped: Bot token or Chat ID not configured"
        return 1
    fi

    if ! command -v curl &> /dev/null; then
        log_warning "Telegram notification skipped: 'curl' command not available"
        return 1
    fi

    # Debug info
    log_info "Sending Telegram notification with:"
    log_info "Bot Token: ${TELEGRAM_BOT_TOKEN:0:20}... (truncated)"
    log_info "Chat ID: $TELEGRAM_CHAT_ID"

    # Verify bot token format
    if [[ ! "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        log_error "Invalid bot token format. Should be like '123456789:ABCdefGHIjklMNOPqrstuvwxyz'"
        return 1
    fi

    # Escape special characters for JSON
    message=$(echo "$message" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')

    # First, test if the bot is valid
    local bot_info
    bot_info=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe")
    if ! echo "$bot_info" | grep -q '"ok":true'; then
        log_error "Invalid bot token. Bot info request failed: $bot_info"
        return 1
    fi

    local response
    response=$(curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"HTML\"}")

    if echo "$response" | grep -q '"ok":true'; then
        log_info "Telegram notification sent successfully"
        return 0
    else
        log_error "Failed to send Telegram notification: $response"
        return 1
    fi
}

# Load email configuration if exists

# Main entry point
main() {
    # Check for help command
    case "$1" in
        -h|--help|"")
            show_usage
            ;;
    esac

    # Get command (first argument)
    local command="$1"
    shift  # Remove first argument

    case "$command" in
        install)
            install_script
            ;;
        config)
            configure_repos "$1"
            ;;
        init)
            if [ $# -eq 0 ]; then
                init_all
            else
                init_repo "$1"
            fi
            ;;
        backup)
            # Parse additional arguments for pre/post scripts
            local pre_script=""
            local post_script=""
            local repo_name=""

            while [ $# -gt 0 ]; do
                case "$1" in
                    -pre-backup)
                        shift
                        pre_script="$1"
                        ;;
                    -post-backup)
                        shift
                        post_script="$1"
                        ;;
                    *)
                        if [ -z "$repo_name" ]; then
                            repo_name="$1"
                        fi
                        ;;
                esac
                shift
            done

            if [ -z "$repo_name" ]; then
                backup_all "$pre_script" "$post_script"
            else
                backup_repo "$repo_name" "$pre_script" "$post_script"
            fi
            ;;
        restore)
            handle_restore_command "$@"
            ;;
        list)
            local verbose=false
            local repo_name=""

            while [ $# -gt 0 ]; do
                case "$1" in
                    -v)
                        verbose=true
                        ;;
                    *)
                        if [ -z "$repo_name" ]; then
                            repo_name="$1"
                        fi
                        ;;
                esac
                shift
            done

            if [ -z "$repo_name" ]; then
                list_all_snapshots "$verbose"
            else
                list_repo_snapshots "$repo_name" "$verbose"
            fi
            ;;
        crontab)
            manage_crontab "$1"
            ;;
        update)
            update_script
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            ;;
    esac
}

# Execute main function with all arguments
main "$@"
