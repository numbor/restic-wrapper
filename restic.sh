#!/bin/bash

# Restic wrapper script
# This script provides a simplified interface for Restic commands

# Configuration
CONFIG_DIR="$HOME/.config"
CONFIG_FILE="$CONFIG_DIR/restic.ini"
REPOS_FILE="$CONFIG_DIR/backup-repos.json"
LOG_FILE="/var/log/restic-backup.log"

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
		echo -e "📦 Repository: \033[1;36m$name\033[0m"
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

# Function to select schedule with arrow keys
select_schedule()
{
	local options=(
		"0 2 * * *|Ogni giorno alle 2:00"
		"0 */6 * * *|Ogni 6 ore"
		"0 */12 * * *|Ogni 12 ore"
		"0 2 * * 0|Ogni domenica alle 2:00"
		"0 2 1 * *|Il primo del mese alle 2:00"
		"0 2 */2 * *|Ogni 2 giorni alle 2:00"
		"0 2 * * 1-5|Dal lunedì al venerdì alle 2:00"
		"custom|Schedulazione personalizzata"
	)
	local selected=0
	local key
	schedule=""

	# Nascondi il cursore
	echo -e "\e[?25l"

	while true; do
		# Mostra header
		echo
		echo "🕒 Seleziona la schedulazione con ↑↓ e premi INVIO per confermare"
		echo "=================================================="

		# Mostra le opzioni con descrizioni più chiare
		echo
		for i in "${!options[@]}"; do
			if [ $i -eq $selected ]; then
				printf "\033[1;36m▶ %-40s\033[0m\n" "${options[$i]#*|}"
			else
				printf "  %-40s\n" "${options[$i]#*|}"
			fi
		done
		echo
		echo "Usa ↑↓ per muoverti e premi INVIO per selezionare"

		# Leggi il tasto premuto
		read -rsn1 key
		case "$key" in
			$'\x1B') # ESC sequence
				read -rsn2 key
				case "$key" in
					"[A") # Up arrow
						[ $selected -gt 0 ] && selected=$((selected - 1))
						;;
					"[B") # Down arrow
						[ $selected -lt $((${#options[@]} - 1)) ] && selected=$((selected + 1))
						;;
				esac
				;;
			"") # Enter key
				schedule="${options[$selected]%|*}"
				break
				;;
		esac
	done

	# Mostra il cursore
	echo -e "\e[?25h"

	# Se è stata selezionata l'opzione personalizzata
	if [ "$schedule" = "custom" ]; then
		echo
		echo "Inserisci la schedulazione personalizzata (formato crontab):"
		echo -n "> "
		read -r schedule
	fi
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
	local log_cmd='date "+[%Y-%m-%d %H:%M:%S]" >> '"$LOG_FILE"' 2>&1 && '
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

# Function to show usage help
show_usage()
{
	echo "Utilizzo: restic.sh <comando> [opzioni]"
	echo
	echo "Comandi:"
	echo "  install              Installa lo script e i file di configurazione"
	echo "  config [-s]         Configura i repository in modo interattivo"
	echo "                      (-s per mostrare la configurazione attuale)"
	echo "  init                Inizializza un nuovo repository"
	echo "  backup              Esegue il backup secondo la configurazione"
	echo "  restore [file]      Ripristina i file da un backup"
	echo "  list [-v]           Mostra gli snapshot (-v per dettagli)"
	echo "  crontab [-s|-d]     Gestisce la schedulazione dei backup"
	echo "                      (-s per mostrare le schedulazioni attuali)"
	echo "                      (-d per rimuovere tutte le schedulazioni)"
	echo "  -h, --help         Mostra questo messaggio"
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
						}
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

					# Create updated repository JSON
					local updated_repo=$(jq -n \
						--arg name "$name" \
						--arg dest "$destination" \
						--arg pwd "$password" \
						--argjson paths "$(printf '%s\n' "${paths[@]}" | jq -R . | jq -s .)" \
						--argjson excludes "$(printf '%s\n' "${excludes[@]}" | jq -R . | jq -s .)" \
						--arg last "$keep_last" \
						--arg daily "$keep_daily" \
						--arg weekly "$keep_weekly" \
						--arg monthly "$keep_monthly" \
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
							}
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

# Main command handler
case "$1" in
	"install")
		install_script
		;;
	"config")
		read_repos
		configure_repos "$2"
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
	"crontab")
		manage_crontab "$2"
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
	*)
		show_usage
		;;
esac
