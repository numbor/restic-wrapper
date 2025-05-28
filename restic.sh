#!/bin/bash

# Restic wrapper script
# This script provides a simplified interface for Restic commands

# Configuration
CONFIG_DIR="$HOME/.config"
CONFIG_FILE="$CONFIG_DIR/restic.ini"
REPOS_FILE="$CONFIG_DIR/backup-repos.json"

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
	local paths
	local excludes

	destination=$(echo "$repo_config" | jq -r '.destination')
	password=$(echo "$repo_config" | jq -r '.password')
	paths=$(echo "$repo_config" | jq -r '.paths[]')
	excludes=$(echo "$repo_config" | jq -r '.exclude[]')

	# Create exclude parameters
	local exclude_params=""
	while IFS= read -r exclude; do
		exclude_params="$exclude_params --exclude '$exclude'"
	done < <(echo "$excludes")

	# Set password
	export RESTIC_PASSWORD="$password"

	# Create backup command
	local backup_cmd="restic -r $destination backup $exclude_params"

	# Add paths
	while IFS= read -r path; do
		# Expand ~ to $HOME
		path="${path/#\~/$HOME}"
		backup_cmd="$backup_cmd '$path'"
	done < <(echo "$paths")

	# Execute backup
	echo "Starting backup for repository: $repo_name"
	eval "$backup_cmd"

	# Apply retention policy if specified
	if echo "$repo_config" | jq -e '.retention' > /dev/null; then
		local last daily weekly monthly
		last=$(echo "$repo_config" | jq -r '.retention.last')
		daily=$(echo "$repo_config" | jq -r '.retention.daily')
		weekly=$(echo "$repo_config" | jq -r '.retention.weekly')
		monthly=$(echo "$repo_config" | jq -r '.retention.monthly')

		echo "Applying retention policy..."
		restic -r "$destination" forget --prune \
			--keep-last "$last" \
			--keep-daily "$daily" \
			--keep-weekly "$weekly" \
			--keep-monthly "$monthly"
	fi
}

# Function to backup all repositories
backup_all()
{
	echo "🔄 Starting backup of all repositories..."
	echo "========================================="
	echo

	local total_repos=$(jq -r '.repositories | length' "$REPOS_FILE")
	local current=0

	# Iterate through all repositories
	jq -r '.repositories[] | .name' "$REPOS_FILE" | while read -r repo_name; do
		current=$((current + 1))
		echo "📦 Processing repository ($current/$total_repos): \033[1;36m$repo_name\033[0m"
		echo "-------------------------------------------"
		backup_repo "$repo_name"
		echo
	done

	echo "✅ Backup of all repositories completed!"
}

# Function to list all repositories
show_repos()
{
	echo
	echo "🗄️  Configured Backup Repositories"
	echo "=================================="
	echo

	# Get all repositories and iterate through them
	jq -r '.repositories[] | @base64' "$REPOS_FILE" | while read -r repo_b64; do
		repo=$(echo "$repo_b64" | base64 -d)

		# Extract repository details
		name=$(echo "$repo" | jq -r '.name')
		dest=$(echo "$repo" | jq -r '.destination')

		# Print repository header
		echo "📦 Repository: \033[1;36m$name\033[0m"
		echo "   └─ 🔗 Destination: $dest"

		# Print paths
		echo "   └─ 📂 Backup paths:"
		echo "$repo" | jq -r '.paths[]' | while read -r path; do
			echo "      └─ $path"
		done

		# Print excludes if any
		if echo "$repo" | jq -e '.exclude' > /dev/null && [ "$(echo "$repo" | jq -r '.exclude | length')" -gt 0 ]; then
			echo "   └─ ❌ Excludes:"
			echo "$repo" | jq -r '.exclude[]' | while read -r excl; do
				echo "      └─ $excl"
			done
		fi

		# Print retention policy if exists
		if echo "$repo" | jq -e '.retention' > /dev/null; then
			echo "   └─ ⏱️  Retention policy:"
			echo "      └─ Keep last: $(echo "$repo" | jq -r '.retention.last') snapshots"
			echo "      └─ Keep daily: $(echo "$repo" | jq -r '.retention.daily') days"
			echo "      └─ Keep weekly: $(echo "$repo" | jq -r '.retention.weekly') weeks"
			echo "      └─ Keep monthly: $(echo "$repo" | jq -r '.retention.monthly') months"
		fi

		echo
	done
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
            }
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
		echo "📦 Processing repository ($current/$total_repos): \033[1;36m$repo_name\033[0m"
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
	echo "📦 Repository: \033[1;36m$repo_name\033[0m"
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
	local files=("${@:3}") # Get all remaining arguments as files array

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

	# Add target directory (current directory by default)
	restore_cmd="$restore_cmd --target ."

	echo
	echo "Starting restore operation..."
	if ! eval "$restore_cmd"; then
		echo "❌ Failed to restore from repository: $repo_name"
		return 1
	fi

	echo "✅ Restore completed successfully"
	return 0
}

# Main command handler
case "$1" in
	"install")
		install_script
		;;
	"init")
		read_repos
		if [ -z "$2" ]; then
			init_all
		else
			init_repo "$2"
		fi
		;;
	"backup")
		read_repos
		if [ -z "$2" ]; then
			backup_all
		else
			backup_repo "$2"
		fi
		;;
	"restore")
		read_repos
		repo_name=""
		snapshot_id=""
		files=()

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
			echo "Usage: $0 restore <repo-name> <snapshot-id> [-f file1 file2 ...]"
			exit 1
		fi

		restore_repo "$repo_name" "$snapshot_id" "${files[@]}"
		;;
	"list")
		read_repos
		verbose="false"
		repo_name=""

		# Parse arguments
		shift # skip the 'list' command
		while [[ $# -gt 0 ]]; do
			case "$1" in
				-v | --verbose)
					verbose="true"
					shift
					;;
				*)
					repo_name="$1"
					shift
					;;
			esac
		done

		if [ -z "$repo_name" ]; then
			list_all_snapshots "$verbose"
		else
			list_repo_snapshots "$repo_name" "$verbose"
		fi
		;;
	"show")
		read_repos
		show_repos
		;;
	*)
		echo "Usage: $0 [command]"
		echo "Available commands:"
		echo "  install                    - Install this script and create config files"
		echo "  init [repo-name]           - Initialize all repositories or a specific one if name provided"
		echo "  backup [repo-name]         - Backup all repositories or a specific one if name provided"
		echo "  restore <repo-name> <snapshot-id> [-f file1 file2 ...]"
		echo "                             - Restore entire snapshot or specific files from a repository"
		echo "  list [-v] [repo-name]      - List snapshots from all repositories or a specific one"
		echo "                               Use -v for verbose output including contents"
		echo "  show                       - Show all configured repositories"
		exit 1
		;;
esac
