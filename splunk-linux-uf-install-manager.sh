#!/bin/bash
#################################################################
# Splunk Universal Forwarder Management Script
# Version: 4.0 - Generic RHEL-family Linux, no shared secret
#
# Modes:
#   --deploy          Fresh install or upgrade (auto-detected)
#   --upgrade         Force upgrade path
#   --simple-update   Binary-only update, preserves apps and configs
#   --repair          Repair a broken or partial installation
#   --remove          Uninstall the forwarder (with backup option)
#   --verify          Verify an existing installation only
#   (no args)         Interactive menu
#
# Behavioral changes from v3.3:
#   - NO shared splunk.secret import. Every host generates its own
#     per-host secret on first start. Plaintext pass4SymmKey is
#     pre-seeded into server.conf and splunkd encrypts it in place.
#   - Admin password is pre-seeded via user-seed.conf (mode 0600),
#     not via --seed-passwd on the command line. Not visible in ps.
#   - Sequencing reordered: configs are written BEFORE first start,
#     then chown, then restorecon, then systemctl start. splunkd
#     starts exactly once, with all config already in place.
#   - SELinux stays in Enforcing throughout; restorecon handles
#     contexts after file operations.
#   - Removed: shared-secret distribution, create-package mode,
#     embedded GPG verification, license-master stanzas, hardcoded
#     site-specific app names and IPs.
#   - Added: idempotent firewall rules, idempotent CAP_SYS_ADMIN
#     injection into the systemd unit.
#
# Directory structure expected in /tmp/splunkinstall:
#   splunkforwarder-*.tgz       OR     splunkforwarder-*.rpm
#   apps/                              (optional, any app dirs)
#################################################################

# --- Fail-fast on uncaught errors ---
set -e

# --- Color codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ==== Configuration (override via environment) ====
HOSTNAME=$(hostname -s)
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunkforwarder}"
SPLUNK_USER="${SPLUNK_USER:-splunkfwd}"

# Admin and DS-auth credentials. CHANGE THESE or set env vars before running.
ADMIN_PASSWORD="${ADMIN_PASSWORD:-CHANGE_ME_ADMIN}"
PASS4SYMMKEY="${PASS4SYMMKEY:-CHANGE_ME_PASS4SYMMKEY}"

# Network targets. Override via env for generic use.
DEPLOYMENT_SERVER="${DEPLOYMENT_SERVER:-deploymentserver.example.com:8089}"
INDEXER_01="${INDEXER_01:-indexer01.example.com}"
INDEXER_02="${INDEXER_02:-indexer02.example.com}"
INDEXER_PORT="${INDEXER_PORT:-9997}"

# Firewall ports to open (kept from prior scripts)
FIREWALL_PORTS=(9997 8089)

# Service unit name
SPLUNK_SVC="SplunkForwarder.service"
SPLUNK_SVC_SHORT="SplunkForwarder"
SYSTEMD_FILE="/etc/systemd/system/${SPLUNK_SVC}"

# --- Script variables ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/tmp/splunkinstall"
APPS_DIR="$BASE_DIR/apps"
INSTALL_METHOD=""
TGZ_FILE=""
RPM_FILE=""
INSTALLER_TYPE=""
SKIP_CONFIRMATION=false
FORCE_REINSTALL=false
FORCE_UPGRADE=false
VERIFY_ONLY=false
CURRENT_VERSION=""
NEW_VERSION=""
OS_TYPE=""
OS_VERSION=""
IS_ORACLE_LINUX=false

#################################################################
# UTILITY FUNCTIONS
#################################################################

print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "\n${CYAN}==== $1 ====${NC}"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Run a command as the splunkfwd user with timeout protection.
# Uses 'su' from root to avoid PAM/blank-password issues on service accounts.
run_as_splunkfwd() {
    local tout="$1"
    shift
    local cmd="$*"
    timeout "$tout" su -s /bin/bash "$SPLUNK_USER" -c "$cmd"
}

confirm_continue() {
    if [[ "$SKIP_CONFIRMATION" == true ]]; then
        return 0
    fi
    read -p "Continue? (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { print_error "Cancelled"; exit 1; }
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root or with sudo"
        exit 1
    fi
}

check_credentials_set() {
    local issues=0
    if [[ "$ADMIN_PASSWORD" == "CHANGE_ME_ADMIN" ]]; then
        print_warning "ADMIN_PASSWORD is still the placeholder. Set it via env var before running."
        issues=$((issues + 1))
    fi
    if [[ "$PASS4SYMMKEY" == "CHANGE_ME_PASS4SYMMKEY" ]]; then
        print_warning "PASS4SYMMKEY is still the placeholder. Set it via env var before running."
        issues=$((issues + 1))
    fi
    if (( issues > 0 )); then
        if [[ "$SKIP_CONFIRMATION" != true ]]; then
            confirm_continue
        fi
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
        case "$ID" in
            ol|oracle) IS_ORACLE_LINUX=true ;;
            *)         IS_ORACLE_LINUX=false ;;
        esac
    fi
    [[ -f /etc/oracle-release ]] && IS_ORACLE_LINUX=true
    print_status "OS: $OS_TYPE $OS_VERSION (Oracle: $IS_ORACLE_LINUX)"
}

show_banner() {
    clear
    cat << 'EOF'
================================================================
   Splunk UF Management Script v4.0
   Generic RHEL-family Linux
================================================================
EOF
}

#################################################################
# PREFLIGHT
#################################################################

show_initial_prompt() {
    print_header "Environment & File Placement"
    echo "Required directory: $BASE_DIR"
    echo "Place the following before running install/upgrade:"
    echo "  splunkforwarder-*.tgz  OR  splunkforwarder-*.rpm"
    echo "  apps/ (optional)"
    echo

    if [[ ! -d "$BASE_DIR" ]]; then
        print_warning "$BASE_DIR does not exist"
        read -p "Create it now? (Y/n): " cd
        if [[ ! "$cd" =~ ^[Nn]$ ]]; then
            mkdir -p "$BASE_DIR/apps"
            chmod 755 "$BASE_DIR"
            print_success "Created $BASE_DIR"
        fi
    fi

    print_header "Scanning $BASE_DIR"
    local tgz_count=0 rpm_count=0
    for f in "$BASE_DIR"/splunkforwarder*.tgz; do [[ -f "$f" ]] && tgz_count=$((tgz_count + 1)); done
    for f in "$BASE_DIR"/splunkforwarder*.rpm; do [[ -f "$f" ]] && rpm_count=$((rpm_count + 1)); done
    [[ $tgz_count -gt 0 ]] && print_success "TGZ installers: $tgz_count"
    [[ $rpm_count -gt 0 ]] && print_success "RPM installers: $rpm_count"
    if [[ $tgz_count -eq 0 ]] && [[ $rpm_count -eq 0 ]]; then
        print_warning "No installers present"
    fi

    if [[ -d "$BASE_DIR/apps" ]] && [[ -n "$(ls -A "$BASE_DIR/apps" 2>/dev/null)" ]]; then
        local n
        n=$(ls -1d "$BASE_DIR/apps"/*/ 2>/dev/null | wc -l)
        print_success "Apps: $n directory(s)"
    fi
}

preflight_permission_check() {
    print_header "Permission Checks"
    local fixed=0

    for installer in "$BASE_DIR"/splunkforwarder*.tgz "$BASE_DIR"/splunkforwarder*.rpm; do
        [[ -f "$installer" ]] || continue
        local fname
        fname=$(basename "$installer")
        if [[ ! -r "$installer" ]]; then
            print_warning "Not readable: $fname"
            chmod 644 "$installer" && fixed=$((fixed + 1))
        fi
    done

    [[ -w "/opt" ]] || print_warning "/opt is not writable"
    command_exists rpm || print_warning "rpm command not found — RPM installs not available"
    print_success "Permission checks complete ($fixed fixed)"
}

check_disk_space() {
    print_header "Disk Space"
    local min_tmp_mb=500 min_opt_mb=1000
    local space_ok=true

    # Size check using largest installer
    local installer_size_mb=0
    for f in "$BASE_DIR"/splunkforwarder*.tgz "$BASE_DIR"/splunkforwarder*.rpm; do
        [[ -f "$f" ]] || continue
        local mb
        mb=$(( $(du -k "$f" 2>/dev/null | cut -f1) / 1024 ))
        (( mb > installer_size_mb )) && installer_size_mb=$mb
    done
    if (( installer_size_mb > 0 )); then
        local adj=$(( installer_size_mb * 3 ))
        (( adj > min_tmp_mb )) && min_tmp_mb=$adj
    fi

    local tmp_avail_mb
    tmp_avail_mb=$(( $(df -P /tmp | tail -1 | awk '{print $4}') / 1024 ))
    if (( tmp_avail_mb < min_tmp_mb )); then
        print_error "/tmp: ${tmp_avail_mb}MB available, need ${min_tmp_mb}MB"
        space_ok=false
    else
        print_success "/tmp: ${tmp_avail_mb}MB available"
    fi

    local opt_avail_mb
    opt_avail_mb=$(( $(df -P /opt | tail -1 | awk '{print $4}') / 1024 ))
    if (( opt_avail_mb < min_opt_mb )); then
        print_error "/opt: ${opt_avail_mb}MB available, need ${min_opt_mb}MB"
        space_ok=false
    else
        print_success "/opt: ${opt_avail_mb}MB available"
    fi

    if [[ "$space_ok" == false ]]; then
        print_error "Insufficient disk space"
        [[ "$SKIP_CONFIRMATION" == true ]] && return 1
        read -p "Continue anyway? (y/N): " r
        [[ "$r" =~ ^[Yy]$ ]] || return 1
    fi
    return 0
}

#################################################################
# VERSION MANAGEMENT
#################################################################

get_installed_version() {
    if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
        local out
        out=$(timeout 10 "$SPLUNK_HOME/bin/splunk" version 2>/dev/null) || true
        if [[ -z "$out" ]] && [[ -f "$SPLUNK_HOME/etc/splunk.version" ]]; then
            grep -oP 'VERSION=\K[\d.]+' "$SPLUNK_HOME/etc/splunk.version" 2>/dev/null | head -1
            return
        fi
        echo "$out" | grep -oP 'Splunk (Universal )?Forwarder \K[\d.]+' | head -1
    fi
}

extract_version_from_installer() {
    local f="$1"
    if [[ "$f" == *.rpm ]] && command_exists rpm; then
        local v
        v=$(rpm -qp --queryformat '%{VERSION}' "$f" 2>/dev/null)
        [[ -n "$v" ]] && { echo "$v"; return; }
    fi
    basename "$f" | sed -E 's/splunkforwarder-([0-9.]+)-.*/\1/'
}

compare_versions() {
    printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1
}

detect_upgrade_scenario() {
    CURRENT_VERSION=$(get_installed_version)
    local f="${TGZ_FILE:-$RPM_FILE}"
    NEW_VERSION=$(extract_version_from_installer "$f")

    if [[ -z "$CURRENT_VERSION" ]]; then
        INSTALL_METHOD="FRESH"
        return
    fi
    print_status "Current: $CURRENT_VERSION / Package: $NEW_VERSION"

    if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
        if [[ "$FORCE_REINSTALL" == true ]]; then
            INSTALL_METHOD="REINSTALL"
        else
            print_warning "Same version; skipping"
            INSTALL_METHOD="SKIP"
        fi
    elif [[ $(compare_versions "$CURRENT_VERSION" "$NEW_VERSION") == "$CURRENT_VERSION" ]]; then
        INSTALL_METHOD="UPGRADE"
    else
        if [[ "$FORCE_REINSTALL" == true ]]; then
            INSTALL_METHOD="REINSTALL"
        else
            print_error "Downgrade detected; use --reinstall to force"
            INSTALL_METHOD="SKIP"
        fi
    fi
}

#################################################################
# INSTALLER DETECTION
#################################################################

find_splunk_installer() {
    print_header "Detecting Installer"
    local search_dirs=("$BASE_DIR" "/tmp/splunkinstall" "$SCRIPT_DIR" "/tmp")
    local all_installers=() all_types=() seen=()

    for d in "${search_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' f; do
            local rp
            rp=$(realpath "$f" 2>/dev/null || echo "$f")
            local dup=false
            for s in "${seen[@]}"; do [[ "$s" == "$rp" ]] && dup=true && break; done
            [[ "$dup" == true ]] && continue
            if file "$f" 2>/dev/null | grep -qi 'gzip\|tar'; then
                all_installers+=("$f"); all_types+=("tgz"); seen+=("$rp")
            fi
        done < <(find "$d" -maxdepth 1 -name 'splunkforwarder*.tgz' -print0 2>/dev/null | sort -zV)

        while IFS= read -r -d '' f; do
            local rp
            rp=$(realpath "$f" 2>/dev/null || echo "$f")
            local dup=false
            for s in "${seen[@]}"; do [[ "$s" == "$rp" ]] && dup=true && break; done
            [[ "$dup" == true ]] && continue
            local valid=false
            file "$f" 2>/dev/null | grep -qi 'rpm' && valid=true
            [[ "$valid" == false ]] && command_exists rpm && rpm -qp "$f" >/dev/null 2>&1 && valid=true
            if [[ "$valid" == true ]]; then
                all_installers+=("$f"); all_types+=("rpm"); seen+=("$rp")
            fi
        done < <(find "$d" -maxdepth 1 -name 'splunkforwarder*.rpm' -print0 2>/dev/null | sort -zV)
    done

    if [[ ${#all_installers[@]} -eq 0 ]]; then
        print_error "No installers found (splunkforwarder-*.tgz or *.rpm)"
        return 1
    fi

    local selected_idx=0
    if [[ ${#all_installers[@]} -eq 1 ]]; then
        print_success "Auto-selected: $(basename "${all_installers[0]}") [${all_types[0]^^}]"
    else
        echo "Found ${#all_installers[@]} installers:"
        for i in "${!all_installers[@]}"; do
            local v
            v=$(extract_version_from_installer "${all_installers[$i]}")
            echo "  $((i + 1))) $(basename "${all_installers[$i]}") [v${v}] [${all_types[$i]^^}]"
        done
        if [[ "$SKIP_CONFIRMATION" == true ]]; then
            selected_idx=$(( ${#all_installers[@]} - 1 ))
            print_status "Auto-selected latest (non-interactive mode)"
        else
            while true; do
                read -p "Select [1-${#all_installers[@]}] (default=latest): " sel
                [[ -z "$sel" ]] && sel=${#all_installers[@]}
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#all_installers[@]} )); then
                    selected_idx=$((sel - 1))
                    break
                fi
                print_error "Invalid"
            done
        fi
    fi

    local sel_file="${all_installers[$selected_idx]}"
    local sel_type="${all_types[$selected_idx]}"
    if [[ "$sel_type" == "tgz" ]]; then
        TGZ_FILE="$sel_file"; RPM_FILE=""; INSTALLER_TYPE="tgz"
    else
        RPM_FILE="$sel_file"; TGZ_FILE=""; INSTALLER_TYPE="rpm"
    fi
    NEW_VERSION=$(extract_version_from_installer "$sel_file")
    print_success "Using: $(basename "$sel_file") [v${NEW_VERSION}] [${INSTALLER_TYPE^^}]"
    return 0
}

#################################################################
# SELINUX — tightened (keep Enforcing, use restorecon)
#################################################################

apply_selinux_contexts() {
    if command_exists restorecon && command_exists getenforce; then
        local state
        state=$(getenforce)
        if [[ "$state" != "Disabled" ]]; then
            print_status "Restoring SELinux contexts on $SPLUNK_HOME..."
            restorecon -R "$SPLUNK_HOME" 2>/dev/null || print_warning "restorecon had issues (non-fatal)"
        fi
    fi
}

#################################################################
# FIREWALL
#################################################################

configure_firewall() {
    if ! command_exists firewall-cmd; then
        print_warning "firewall-cmd not available; skipping firewall setup"
        return 0
    fi
    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        print_warning "firewalld not active; skipping firewall setup"
        return 0
    fi
    print_header "Configuring Firewall"
    for port in "${FIREWALL_PORTS[@]}"; do
        if firewall-cmd --list-ports 2>/dev/null | grep -qw "${port}/tcp"; then
            print_success "Port ${port}/tcp already open"
        else
            firewall-cmd --add-port="${port}/tcp" --permanent >/dev/null && \
                print_success "Opened ${port}/tcp (permanent)"
        fi
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
}

#################################################################
# USER MANAGEMENT
#################################################################

ensure_splunkfwd_user() {
    print_header "User Account: $SPLUNK_USER"
    if id "$SPLUNK_USER" >/dev/null 2>&1; then
        print_success "User $SPLUNK_USER exists"
        # Unlock if locked, no expiration
        usermod -U "$SPLUNK_USER" 2>/dev/null || true
        chage -E -1 -M -1 "$SPLUNK_USER" 2>/dev/null || true
    else
        print_status "Creating user $SPLUNK_USER..."
        local useradd_args=(-r -s /sbin/nologin -d "$SPLUNK_HOME" -c "Splunk Forwarder" "$SPLUNK_USER")
        [[ "$IS_ORACLE_LINUX" == true ]] && useradd_args=(-r -m -s /sbin/nologin -d "$SPLUNK_HOME" -c "Splunk Forwarder" "$SPLUNK_USER")
        if useradd "${useradd_args[@]}"; then
            print_success "Created $SPLUNK_USER"
            chage -E -1 -M -1 "$SPLUNK_USER" 2>/dev/null || true
        else
            print_error "Failed to create user"
            exit 1
        fi
    fi

    if timeout 5 su -s /bin/bash "$SPLUNK_USER" -c "whoami" >/dev/null 2>&1; then
        print_success "User functional"
    else
        print_warning "User test failed; attempting repair..."
        usermod -U "$SPLUNK_USER" 2>/dev/null || true
        passwd -d "$SPLUNK_USER" 2>/dev/null || true
        chage -E -1 -M -1 "$SPLUNK_USER" 2>/dev/null || true
    fi
}

set_ownership() {
    print_header "Setting Ownership"
    chown -R "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME"
    print_success "$SPLUNK_HOME now owned by $SPLUNK_USER"
}

#################################################################
# CONFIG PRE-SEEDING (written BEFORE first service start)
#################################################################

preseed_configs() {
    print_header "Pre-seeding Configuration"

    local local_dir="$SPLUNK_HOME/etc/system/local"
    mkdir -p "$local_dir"

    # 1. user-seed.conf — splunkd consumes this on first start and deletes it
    #    Mode 0600 so the password is never visible in ps output.
    print_status "Writing user-seed.conf..."
    cat > "$local_dir/user-seed.conf" <<EOF
[user_info]
USERNAME = admin
PASSWORD = $ADMIN_PASSWORD
EOF
    chmod 600 "$local_dir/user-seed.conf"

    # 2. server.conf — plaintext pass4SymmKey; splunkd encrypts it in place
    #    on first start using the per-host splunk.secret it generates.
    print_status "Writing server.conf..."
    local server_conf="$local_dir/server.conf"
    if [[ ! -f "$server_conf" ]]; then
        cat > "$server_conf" <<EOF
[general]
serverName = $HOSTNAME
pass4SymmKey = $PASS4SYMMKEY
EOF
    else
        # Stanza-aware update. Only touch [general] pass4SymmKey; leave the rest alone.
        if grep -qE '^\s*pass4SymmKey\s*=' "$server_conf"; then
            print_status "  pass4SymmKey already present (possibly encrypted); leaving it"
        elif grep -qE '^\[general\]\s*$' "$server_conf"; then
            sed -i "/^\[general\][[:space:]]*$/a pass4SymmKey = $PASS4SYMMKEY" "$server_conf"
        else
            printf '\n[general]\nserverName = %s\npass4SymmKey = %s\n' "$HOSTNAME" "$PASS4SYMMKEY" >> "$server_conf"
        fi
    fi
    chmod 600 "$server_conf"

    # 3. deploymentclient.conf
    print_status "Writing deploymentclient.conf..."
    cat > "$local_dir/deploymentclient.conf" <<EOF
[deployment-client]

[target-broker:deploymentServer]
targetUri = $DEPLOYMENT_SERVER
EOF

    print_success "All configs pre-seeded"
}

copy_apps() {
    print_header "Deploying Apps"

    local src_dir=""
    for d in "$APPS_DIR" "/tmp/splunkinstall/apps" "$SCRIPT_DIR/apps"; do
        if [[ -d "$d" ]] && [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then
            src_dir="$d"
            break
        fi
    done

    if [[ -z "$src_dir" ]]; then
        print_status "No apps directory with content; skipping"
        return 0
    fi

    mkdir -p "$SPLUNK_HOME/etc/apps"
    local copied=0
    for app_dir in "$src_dir"/*; do
        [[ -d "$app_dir" ]] || continue
        local name
        name=$(basename "$app_dir")
        # Never clobber the bundled system forwarder app
        if [[ "$name" == "SplunkUniversalForwarder" ]]; then
            print_warning "Skipping bundled system app: $name"
            continue
        fi
        [[ -d "$SPLUNK_HOME/etc/apps/$name" ]] && rm -rf "$SPLUNK_HOME/etc/apps/$name"
        if cp -a "$app_dir" "$SPLUNK_HOME/etc/apps/"; then
            print_success "Deployed: $name"
            copied=$((copied + 1))
        else
            print_error "Failed: $name"
        fi
    done
    print_success "$copied app(s) deployed from $src_dir"
}

#################################################################
# INSTALL (fresh) / UPGRADE / SIMPLE-UPDATE
#################################################################

install_package() {
    # Installs the package binary only. No config, no service start.
    local installer_file="${TGZ_FILE:-$RPM_FILE}"
    if [[ -z "$installer_file" ]] || [[ ! -f "$installer_file" ]]; then
        print_error "No installer set"
        exit 1
    fi

    print_header "Installing Package"
    print_status "Installer: $(basename "$installer_file") [${INSTALLER_TYPE^^}]"

    if [[ "$INSTALLER_TYPE" == "rpm" ]]; then
        command_exists rpm || { print_error "rpm command not available"; exit 1; }
        if ! rpm -ivh "$installer_file"; then
            print_error "RPM install failed"; exit 1
        fi
    else
        if ! tar -xzf "$installer_file" -C /opt/; then
            print_error "TGZ extraction failed"; exit 1
        fi
    fi

    if [[ ! -d "$SPLUNK_HOME" ]]; then
        print_error "$SPLUNK_HOME missing after install"; exit 1
    fi
    print_success "Package installed"
}

reinstall_cleanup() {
    print_warning "Reinstall: removing existing installation"
    systemctl stop "$SPLUNK_SVC" 2>/dev/null || true
    pkill -9 -f splunkd 2>/dev/null || true
    sleep 3

    local backup_dir="/tmp/splunk_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    [[ -d "$SPLUNK_HOME/etc/system/local" ]] && cp -r "$SPLUNK_HOME/etc/system/local" "$backup_dir/" 2>/dev/null || true
    [[ -d "$SPLUNK_HOME/etc/apps" ]]         && cp -r "$SPLUNK_HOME/etc/apps"         "$backup_dir/" 2>/dev/null || true
    print_success "Backup: $backup_dir"

    rpm -qa 2>/dev/null | grep -q splunkforwarder && rpm -e splunkforwarder 2>/dev/null || true
    [[ -d "$SPLUNK_HOME" ]] && rm -rf "$SPLUNK_HOME"
    [[ -f "$SYSTEMD_FILE" ]] && rm -f "$SYSTEMD_FILE"
    systemctl daemon-reload 2>/dev/null || true
}

perform_upgrade() {
    print_header "In-Place Upgrade: $CURRENT_VERSION → $NEW_VERSION"

    # Back up the HOST'S OWN secret, configs, and apps. This is an in-place
    # upgrade on the same host, so preserving this host's own splunk.secret
    # is correct (no shared secret involved).
    local backup_dir="/tmp/splunk_upgrade_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    print_status "Backup dir: $backup_dir"
    [[ -d "$SPLUNK_HOME/etc/system/local" ]] && cp -r "$SPLUNK_HOME/etc/system/local" "$backup_dir/"
    [[ -d "$SPLUNK_HOME/etc/apps" ]]         && cp -r "$SPLUNK_HOME/etc/apps"         "$backup_dir/"
    [[ -f "$SPLUNK_HOME/etc/auth/splunk.secret" ]] && cp "$SPLUNK_HOME/etc/auth/splunk.secret" "$backup_dir/"

    # Stop the service cleanly
    print_status "Stopping service..."
    systemctl stop "$SPLUNK_SVC" 2>/dev/null || \
        run_as_splunkfwd 30 "$SPLUNK_HOME/bin/splunk stop" 2>/dev/null || true
    sleep 3
    pgrep -f splunkd >/dev/null && { pkill -9 -f splunkd; sleep 2; }

    # Install new binaries over existing
    local installer_file="${TGZ_FILE:-$RPM_FILE}"
    if [[ "$INSTALLER_TYPE" == "rpm" ]]; then
        if ! rpm -Uvh "$installer_file"; then
            print_error "RPM upgrade failed; restoring from backup"
            cp -r "$backup_dir"/* "$SPLUNK_HOME/etc/" 2>/dev/null || true
            exit 1
        fi
    else
        if ! tar -xzf "$installer_file" -C /opt/; then
            print_error "TGZ extraction failed; restoring from backup"
            cp -r "$backup_dir"/* "$SPLUNK_HOME/etc/" 2>/dev/null || true
            exit 1
        fi
    fi

    # Restore this host's own configs and own secret (NOT a shared secret)
    [[ -d "$backup_dir/local" ]] && cp -r "$backup_dir/local"/* "$SPLUNK_HOME/etc/system/local/" 2>/dev/null || true
    if [[ -f "$backup_dir/splunk.secret" ]]; then
        cp "$backup_dir/splunk.secret" "$SPLUNK_HOME/etc/auth/splunk.secret"
        chmod 600 "$SPLUNK_HOME/etc/auth/splunk.secret"
        print_success "Restored host's own splunk.secret"
    fi

    # Update apps from package (additive/overwriting)
    copy_apps

    # Re-enable boot-start (idempotent; writes/updates unit file)
    timeout 30 "$SPLUNK_HOME/bin/splunk" enable boot-start \
        -user "$SPLUNK_USER" -systemd-managed 1 \
        --accept-license --answer-yes --no-prompt >/dev/null 2>&1 || true

    patch_systemd_capabilities
    chown -R "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME"
    apply_selinux_contexts
    systemctl daemon-reload

    print_status "Starting service..."
    if ! systemctl start "$SPLUNK_SVC"; then
        print_error "Service failed to start"
        exit 1
    fi
    sleep 5
    print_success "Upgrade complete. Backup: $backup_dir"
}

perform_simple_update() {
    print_header "Simple Update (binary only)"
    detect_os
    [[ -x "$SPLUNK_HOME/bin/splunk" ]] || { print_error "No existing install"; return 1; }

    CURRENT_VERSION=$(get_installed_version)
    print_status "Current: $CURRENT_VERSION"

    find_splunk_installer || return 1
    if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
        print_warning "Already on $CURRENT_VERSION; nothing to do"
        return 0
    fi
    check_disk_space || return 1

    if [[ "$SKIP_CONFIRMATION" != true ]]; then
        read -p "Update $CURRENT_VERSION → $NEW_VERSION? (y/N): " r
        [[ "$r" =~ ^[Yy]$ ]] || { print_status "Cancelled"; return 0; }
    fi

    # Simple-update is just perform_upgrade without copying new apps.
    local backup_dir="/tmp/splunk_update_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    [[ -d "$SPLUNK_HOME/etc/system/local" ]] && cp -r "$SPLUNK_HOME/etc/system/local" "$backup_dir/"
    [[ -d "$SPLUNK_HOME/etc/apps" ]]         && cp -r "$SPLUNK_HOME/etc/apps"         "$backup_dir/"
    [[ -f "$SPLUNK_HOME/etc/auth/splunk.secret" ]] && cp "$SPLUNK_HOME/etc/auth/splunk.secret" "$backup_dir/"

    systemctl stop "$SPLUNK_SVC" 2>/dev/null || \
        run_as_splunkfwd 30 "$SPLUNK_HOME/bin/splunk stop" 2>/dev/null || true
    sleep 3
    pgrep -f splunkd >/dev/null && { pkill -9 -f splunkd; sleep 2; }

    local installer_file="${TGZ_FILE:-$RPM_FILE}"
    if [[ "$INSTALLER_TYPE" == "rpm" ]]; then
        rpm -Uvh "$installer_file" || { print_error "RPM upgrade failed"; return 1; }
    else
        tar -xzf "$installer_file" -C /opt/ || { print_error "Extraction failed"; return 1; }
    fi

    [[ -d "$backup_dir/local" ]] && cp -r "$backup_dir/local"/* "$SPLUNK_HOME/etc/system/local/" 2>/dev/null || true
    if [[ -f "$backup_dir/splunk.secret" ]]; then
        cp "$backup_dir/splunk.secret" "$SPLUNK_HOME/etc/auth/splunk.secret"
        chmod 600 "$SPLUNK_HOME/etc/auth/splunk.secret"
    fi

    timeout 30 "$SPLUNK_HOME/bin/splunk" enable boot-start \
        -user "$SPLUNK_USER" -systemd-managed 1 \
        --accept-license --answer-yes --no-prompt >/dev/null 2>&1 || true
    patch_systemd_capabilities
    chown -R "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME"
    apply_selinux_contexts
    systemctl daemon-reload
    systemctl start "$SPLUNK_SVC"
    print_success "Simple update complete. Backup: $backup_dir"
}

#################################################################
# SYSTEMD UNIT PATCHING (idempotent CAP_SYS_ADMIN)
#################################################################

patch_systemd_capabilities() {
    [[ -f "$SYSTEMD_FILE" ]] || { print_warning "Unit file missing; skipping capability patch"; return 0; }

    if grep -qE '^AmbientCapabilities=.*\bCAP_SYS_ADMIN\b' "$SYSTEMD_FILE"; then
        print_success "CAP_SYS_ADMIN already present"
    elif grep -qE '^AmbientCapabilities=' "$SYSTEMD_FILE"; then
        sed -i -E '/^\[Service\]/,/^\[/ {s/^(AmbientCapabilities=.*)$/\1 CAP_SYS_ADMIN/}' "$SYSTEMD_FILE"
        print_success "Appended CAP_SYS_ADMIN to AmbientCapabilities"
    else
        sed -i '/^\[Service\]/a AmbientCapabilities=CAP_DAC_READ_SEARCH CAP_SYS_ADMIN' "$SYSTEMD_FILE"
        print_success "Added AmbientCapabilities with CAP_DAC_READ_SEARCH + CAP_SYS_ADMIN"
    fi
}

#################################################################
# SERVICE CONFIGURATION (fresh install)
#################################################################

configure_service_fresh() {
    print_header "Configuring Service (fresh install)"

    # Enable boot-start writes the systemd unit but does NOT start the service
    # when --no-prompt is given and no "splunk start" is issued first.
    print_status "Enabling boot-start..."
    if ! timeout 30 "$SPLUNK_HOME/bin/splunk" enable boot-start \
            -user "$SPLUNK_USER" -systemd-managed 1 \
            --accept-license --answer-yes --no-prompt >/dev/null 2>&1; then
        print_error "enable boot-start failed"
        exit 1
    fi

    patch_systemd_capabilities

    # Ownership AFTER all files are written as root, BEFORE service starts
    chown -R "$SPLUNK_USER:$SPLUNK_USER" "$SPLUNK_HOME"
    apply_selinux_contexts

    systemctl daemon-reload

    print_status "Starting $SPLUNK_SVC..."
    if ! systemctl start "$SPLUNK_SVC"; then
        print_error "Service failed to start; check journalctl -u $SPLUNK_SVC"
        exit 1
    fi
    sleep 10

    if systemctl is-active --quiet "$SPLUNK_SVC"; then
        print_success "Service active"
    else
        print_error "Service not active after start"
        exit 1
    fi

    systemctl enable "$SPLUNK_SVC" 2>/dev/null || true
}

#################################################################
# VERIFICATION
#################################################################

verify_deployment() {
    print_header "Verification"

    local ok=true

    if systemctl is-active --quiet "$SPLUNK_SVC"; then
        print_success "Service active"
    else
        print_error "Service not active"
        ok=false
    fi

    if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
        local v
        v=$(get_installed_version)
        print_success "Version: $v"
    else
        print_error "splunk binary missing"
        ok=false
    fi

    if id "$SPLUNK_USER" >/dev/null 2>&1; then
        print_success "User $SPLUNK_USER present"
    else
        print_error "User $SPLUNK_USER missing"
        ok=false
    fi

    for f in server.conf deploymentclient.conf; do
        if [[ -f "$SPLUNK_HOME/etc/system/local/$f" ]]; then
            print_success "$f present"
        else
            print_error "$f missing"
            ok=false
        fi
    done

    # Secret should exist per-host; we don't compare its content to anything
    if [[ -f "$SPLUNK_HOME/etc/auth/splunk.secret" ]]; then
        print_success "Per-host splunk.secret present"
    else
        print_error "splunk.secret missing"
        ok=false
    fi

    # Ownership
    local wrong
    wrong=$(find "$SPLUNK_HOME" ! -user "$SPLUNK_USER" 2>/dev/null | wc -l)
    if (( wrong == 0 )); then
        print_success "Ownership OK"
    else
        print_warning "$wrong files not owned by $SPLUNK_USER"
    fi

    # Network reachability
    for target in "$INDEXER_01:$INDEXER_PORT" "$INDEXER_02:$INDEXER_PORT" "$DEPLOYMENT_SERVER"; do
        IFS=':' read -r host port <<< "$target"
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
            print_success "Reachable: $target"
        else
            print_warning "Not reachable: $target"
        fi
    done

    [[ "$ok" == true ]] && print_success "Verification passed" || print_warning "Verification had issues"
}

#################################################################
# DEPLOY ORCHESTRATOR
#################################################################

check_prerequisites() {
    print_header "Prerequisites"
    detect_os
    check_credentials_set
    check_disk_space || exit 1

    if [[ -d "$SPLUNK_HOME" ]] && [[ -f "$SPLUNK_HOME/bin/splunk" ]]; then
        find_splunk_installer || exit 1
        detect_upgrade_scenario
        if [[ "$FORCE_UPGRADE" == true ]] && [[ "$INSTALL_METHOD" == "UPGRADE" ]]; then
            :
        elif [[ "$FORCE_REINSTALL" == true ]]; then
            INSTALL_METHOD="REINSTALL"
        elif [[ "$INSTALL_METHOD" == "UPGRADE" ]] && [[ "$SKIP_CONFIRMATION" != true ]]; then
            read -p "Upgrade $CURRENT_VERSION → $NEW_VERSION? (y/N): " r
            [[ "$r" =~ ^[Yy]$ ]] || INSTALL_METHOD="SKIP"
        fi
    else
        INSTALL_METHOD="FRESH"
        find_splunk_installer || exit 1
    fi

    # Connectivity probe (non-fatal)
    for target in "$INDEXER_01:$INDEXER_PORT" "$INDEXER_02:$INDEXER_PORT" "$DEPLOYMENT_SERVER"; do
        IFS=':' read -r host port <<< "$target"
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
            print_success "Reachable: $target"
        else
            print_warning "Not reachable: $target"
        fi
    done
}

deploy_mode() {
    print_header "Deploy / Upgrade"
    [[ "$SKIP_CONFIRMATION" != true ]] && confirm_continue

    check_prerequisites
    configure_firewall

    case "$INSTALL_METHOD" in
        FRESH)
            install_package
            ensure_splunkfwd_user
            preseed_configs
            copy_apps
            configure_service_fresh
            verify_deployment
            ;;
        UPGRADE)
            perform_upgrade
            verify_deployment
            ;;
        REINSTALL)
            reinstall_cleanup
            install_package
            ensure_splunkfwd_user
            preseed_configs
            copy_apps
            configure_service_fresh
            verify_deployment
            ;;
        SKIP)
            print_status "Skipping installation"
            verify_deployment
            ;;
        *)
            print_error "Unknown install method: $INSTALL_METHOD"
            exit 1
            ;;
    esac
}

#################################################################
# REPAIR
#################################################################

perform_repair() {
    print_header "Repair"
    detect_os

    echo "Repair will:"
    echo "  1. Diagnose install state"
    echo "  2. Stop stuck processes"
    echo "  3. Back up surviving configs and apps"
    echo "  4. Clean the partial install"
    echo "  5. Reinstall from available installer"
    echo "  6. Restore configs and apps (per-host secret regenerated on first start)"
    echo "  7. Re-enable service and start"
    echo

    if [[ "$SKIP_CONFIRMATION" != true ]]; then
        read -p "Proceed? (y/N): " r
        [[ "$r" =~ ^[Yy]$ ]] || { print_status "Cancelled"; return 0; }
    fi
    check_disk_space || return 1

    local backup_dir="/tmp/splunk_repair_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    [[ -d "$SPLUNK_HOME/etc/system/local" ]] && cp -r "$SPLUNK_HOME/etc/system/local" "$backup_dir/" 2>/dev/null || true
    [[ -d "$SPLUNK_HOME/etc/apps" ]]         && cp -r "$SPLUNK_HOME/etc/apps"         "$backup_dir/" 2>/dev/null || true
    print_success "Backup: $backup_dir"

    systemctl stop "$SPLUNK_SVC" 2>/dev/null || true
    pkill -9 -f splunkd 2>/dev/null || true
    sleep 3
    rpm -qa 2>/dev/null | grep -q splunkforwarder && rpm -e splunkforwarder 2>/dev/null || true
    [[ -d "$SPLUNK_HOME" ]] && rm -rf "$SPLUNK_HOME"
    [[ -f "$SYSTEMD_FILE" ]] && rm -f "$SYSTEMD_FILE"
    systemctl daemon-reload 2>/dev/null || true

    find_splunk_installer || return 1
    install_package
    ensure_splunkfwd_user

    # Restore only configs (stanza-level) and apps. splunk.secret is
    # regenerated per-host on first start; any encrypted ciphertext in
    # restored server.conf that can't be decrypted will need to be re-
    # seeded as plaintext — preseed_configs handles pass4SymmKey.
    if [[ -d "$backup_dir/local" ]]; then
        mkdir -p "$SPLUNK_HOME/etc/system/local"
        cp -r "$backup_dir/local"/* "$SPLUNK_HOME/etc/system/local/" 2>/dev/null || true
        print_success "Restored local configs"
    fi
    if [[ -d "$backup_dir/apps" ]]; then
        mkdir -p "$SPLUNK_HOME/etc/apps"
        cp -r "$backup_dir/apps"/* "$SPLUNK_HOME/etc/apps/" 2>/dev/null || true
        print_success "Restored apps"
    fi

    # Ensure pass4SymmKey is sane and user-seed.conf is present for first start
    preseed_configs

    configure_service_fresh
    verify_deployment
}

#################################################################
# REMOVE
#################################################################

perform_remove() {
    print_header "Remove Splunk UF"
    echo "This will stop the service, uninstall the package, remove $SPLUNK_HOME,"
    echo "and remove the systemd unit."
    echo

    if [[ "$SKIP_CONFIRMATION" != true ]]; then
        read -p "Backup first? (Y/n): " b
        if [[ ! "$b" =~ ^[Nn]$ ]] && [[ -d "$SPLUNK_HOME" ]]; then
            local backup_dir="/tmp/splunk_remove_backup_$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$backup_dir"
            cp -r "$SPLUNK_HOME/etc" "$backup_dir/" 2>/dev/null || true
            print_success "Backup: $backup_dir"
        fi
        read -p "Proceed with removal? (y/N): " r
        [[ "$r" =~ ^[Yy]$ ]] || { print_status "Cancelled"; return 0; }
    fi

    systemctl stop "$SPLUNK_SVC" 2>/dev/null || true
    systemctl disable "$SPLUNK_SVC" 2>/dev/null || true
    pkill -9 -f splunkd 2>/dev/null || true
    sleep 3

    rpm -qa 2>/dev/null | grep -q splunkforwarder && rpm -e splunkforwarder 2>/dev/null || true
    [[ -d "$SPLUNK_HOME" ]] && rm -rf "$SPLUNK_HOME"
    [[ -f "$SYSTEMD_FILE" ]] && rm -f "$SYSTEMD_FILE"
    systemctl daemon-reload 2>/dev/null || true

    print_success "Splunk UF removed"
}

#################################################################
# VERIFY-ONLY
#################################################################

verify_only_mode() {
    detect_os
    if [[ ! -x "$SPLUNK_HOME/bin/splunk" ]]; then
        print_error "No installation at $SPLUNK_HOME"
        return 1
    fi
    CURRENT_VERSION=$(get_installed_version)
    print_status "Installed version: $CURRENT_VERSION"
    verify_deployment
}

#################################################################
# USAGE / MENU
#################################################################

show_usage() {
    cat << EOF
Splunk UF Management Script v4.0

Usage: sudo bash $0 [options]

Options:
  (none)              Interactive menu
  --deploy            Fresh install or upgrade (auto-detect)
  --upgrade           Force upgrade path
  --simple-update     Binary-only update (preserve configs/apps)
  --repair            Repair broken/partial install
  --remove            Uninstall completely
  --verify            Verify existing installation
  -r, --reinstall     Force complete reinstall
  -y, --yes           Skip confirmations (non-interactive)
  -h, --help          Show this help

Environment overrides:
  SPLUNK_HOME         (default: /opt/splunkforwarder)
  SPLUNK_USER         (default: splunkfwd)
  ADMIN_PASSWORD      (required — set before running)
  PASS4SYMMKEY        (required — must match DS [general] pass4SymmKey)
  DEPLOYMENT_SERVER   (default: deploymentserver.example.com:8089)
  INDEXER_01          (default: indexer01.example.com)
  INDEXER_02          (default: indexer02.example.com)
  INDEXER_PORT        (default: 9997)

Directory structure in /tmp/splunkinstall:
  splunkforwarder-*.tgz  OR  splunkforwarder-*.rpm
  apps/  (optional: any app directories to deploy)
EOF
}

show_menu() {
    local first_run=true
    while true; do
        show_banner
        detect_os

        if [[ "$first_run" == true ]]; then
            show_initial_prompt
            preflight_permission_check
            check_disk_space || true
            first_run=false
        fi

        if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
            CURRENT_VERSION=$(get_installed_version)
            [[ -n "$CURRENT_VERSION" ]] && print_status "Current: $CURRENT_VERSION" || print_warning "Binary present but version unreadable"
        else
            print_status "No existing install"
        fi

        echo
        echo "  1. Deploy / Upgrade (full)"
        echo "  2. Simple Update (binary only)"
        echo "  3. Force Upgrade"
        echo "  4. Verify existing installation"
        echo "  5. Repair"
        echo "  6. Remove"
        echo "  7. Help"
        echo "  8. Exit"
        echo
        read -p "Option [1-8]: " choice
        case $choice in
            1) deploy_mode;              read -p "ENTER..."; ;;
            2) perform_simple_update;    read -p "ENTER..."; ;;
            3) FORCE_UPGRADE=true; deploy_mode; read -p "ENTER..."; ;;
            4) verify_only_mode;         read -p "ENTER..."; ;;
            5) perform_repair;           read -p "ENTER..."; ;;
            6) perform_remove;           read -p "ENTER..."; ;;
            7) show_usage;               read -p "ENTER..."; ;;
            8) exit 0 ;;
            *) print_error "Invalid"; sleep 1 ;;
        esac
    done
}

#################################################################
# MAIN
#################################################################

check_root

while [[ $# -gt 0 ]]; do
    case $1 in
        --deploy)         deploy_mode;              exit 0 ;;
        --upgrade)        FORCE_UPGRADE=true; deploy_mode; exit 0 ;;
        --simple-update)  perform_simple_update;    exit 0 ;;
        --repair)         perform_repair;           exit 0 ;;
        --remove)         perform_remove;           exit 0 ;;
        --verify)         VERIFY_ONLY=true; verify_only_mode; exit 0 ;;
        -r|--reinstall)   FORCE_REINSTALL=true; shift ;;
        -y|--yes)         SKIP_CONFIRMATION=true; shift ;;
        -h|--help)        show_usage; exit 0 ;;
        *) print_error "Unknown option: $1"; show_usage; exit 1 ;;
    esac
done

show_menu
