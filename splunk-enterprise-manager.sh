#!/bin/bash
###############################################################################
# Splunk Enterprise Manager — Generic, Multi-Role
# Version: 3.0
#
# Manages full Splunk Enterprise installs (not Universal Forwarders). Use the
# companion UF manager script for forwarders.
#
# ROLES (multiple may be combined on one server):
#   cm          Cluster Manager
#   indexer     Indexer (clustered peer or standalone — chosen in wizard)
#   searchhead  Search Head (SHC captain / SHC member / standalone — wizard)
#   ds          Deployment Server
#   deployer    SHC Deployer
#   hf          Heavy Forwarder
#   lm          License Manager
#   mc          Monitoring Console
#
# Typical combinations on one host:
#   cm + lm                   Cluster mgmt + license source
#   ds + mc                   Deployment Server + Monitoring Console
#   ds + lm                   Deployment Server + license source
#   cm + lm + ds + mc         Consolidated management tier
#   deployer + mc             SHC Deployer + Monitoring Console
#   hf                        Heavy Forwarder (usually standalone)
#
# OPERATIONS:
#   --install           Fresh install with role wizard
#   --upgrade           In-place upgrade (preserves configs)
#   --simple-update     Binary-only update
#   --repair            Repair broken/partial install
#   --remove            Full removal with backup option
#   --reconfigure       Re-run wizard on an existing install
#   --verify            Health check
#   --topology          Show topology & Splunk-recommended upgrade order
#   --role r1,r2,...    Pre-select role(s), comma-separated
#   -y, --yes           Skip confirmations
#   -r, --reinstall     Force reinstall
#   -h, --help          Show usage
#
# ENVIRONMENT OVERRIDES (set before running for generic/multi-env use):
#   SPLUNK_HOME, SPLUNK_USER, ADMIN_PASSWORD
#   ENV_CM_HOST, ENV_DS_HOST, ENV_IDX01_HOST, ENV_IDX02_HOST
#   ENV_SH_HOST, ENV_HF_HOST, ENV_LM_HOST, ENV_MC_HOST
#   ENV_MGMT_PORT, ENV_WEB_PORT, ENV_RECV_PORT, ENV_REPL_PORT, ENV_SHC_REPL_PORT
#
# SECRET HANDLING:
#   This script never imports or overwrites splunk.secret from another host.
#   Each install generates its own per-host splunk.secret on first start.
#   Plaintext pass4SymmKeys are pre-seeded into server.conf and encrypted by
#   splunkd on first start using the per-host secret. Upgrade paths back up
#   and restore the HOST'S OWN splunk.secret only.
###############################################################################

set -euo pipefail

###############################################################################
# SECTION 1: HEADER, VARIABLES, UTILITIES
###############################################################################

# --- Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

# --- Global Configuration ---
HOSTNAME=$(hostname -s)
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER=""              # Auto-detected or defaults to "splunk"
SPLUNK_GROUP=""             # Auto-detected from user's primary group
SERVICE_NAME=""             # Auto-detected or defaults to "Splunkd"
SCRIPT_VERSION="3.0"

# --- Generic Environment Topology (override via env vars) ---
ENV_CM_HOST="${ENV_CM_HOST:-cm.example.com}"
ENV_DS_HOST="${ENV_DS_HOST:-ds.example.com}"
ENV_IDX01_HOST="${ENV_IDX01_HOST:-indexer01.example.com}"
ENV_IDX02_HOST="${ENV_IDX02_HOST:-indexer02.example.com}"
ENV_SH_HOST="${ENV_SH_HOST:-searchhead.example.com}"
ENV_HF_HOST="${ENV_HF_HOST:-heavyforwarder.example.com}"
ENV_LM_HOST="${ENV_LM_HOST:-$ENV_CM_HOST}"
ENV_MC_HOST="${ENV_MC_HOST:-$ENV_DS_HOST}"
ENV_MGMT_PORT="${ENV_MGMT_PORT:-8089}"
ENV_WEB_PORT="${ENV_WEB_PORT:-8000}"
ENV_RECV_PORT="${ENV_RECV_PORT:-9997}"
ENV_REPL_PORT="${ENV_REPL_PORT:-8100}"
ENV_SHC_REPL_PORT="${ENV_SHC_REPL_PORT:-8191}"

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/tmp/splunkinstall"

# --- Disk Space Minimums (MB) ---
MIN_TMP_SPACE_MB=2048
MIN_OPT_SPACE_MB=5120

# --- Installer State ---
INSTALL_METHOD=""
TGZ_FILE=""
RPM_FILE=""
INSTALLER_TYPE=""
CURRENT_VERSION=""
NEW_VERSION=""

# --- Flags ---
SKIP_CONFIRMATION=false
FORCE_REINSTALL=false
FORCE_UPGRADE=false
VERIFY_ONLY=false

# --- OS State ---
OS_TYPE=""
OS_VERSION=""
IS_ORACLE_LINUX=false

# --- Role State ---
SELECTED_ROLES=()          # Array of: cm, indexer, searchhead, ds, deployer, hf, lm, mc
CLUSTER_MODE=""            # For indexer: clustered | standalone
SHC_MODE=""                # For searchhead: captain | member | standalone

# --- Role Configuration (wizard-collected values, shared across roles) ---
declare -A ROLE_CONFIG

# --- Print Functions ---
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_step()    { echo -e "${WHITE}[STEP]${NC} $1"; }

print_header() {
    local text="$1"
    local len=${#text}
    local border=""
    for ((i = 0; i < len + 4; i++)); do border+="="; done
    echo ""
    echo -e "${CYAN}${border}${NC}"
    echo -e "${CYAN}  ${WHITE}${text}${CYAN}${NC}"
    echo -e "${CYAN}${border}${NC}"
}

print_section() { echo ""; echo -e "${MAGENTA}-- $1 --${NC}"; }
print_tip()     { echo -e "  ${DIM}TIP: $1${NC}"; }

# --- Utility Functions ---
command_exists() { command -v "$1" >/dev/null 2>&1; }

# systemctl wrapper that strips LD_LIBRARY_PATH. Splunk ships its own
# libcrypto/libssl under /opt/splunk/lib; if LD_LIBRARY_PATH points there,
# systemctl loads Splunk's OpenSSL instead of the system one and fails with:
#   "version 'OPENSSL_3.4.0' not found (required by libsystemd-shared)"
safe_systemctl() { env -u LD_LIBRARY_PATH systemctl "$@"; }

# Run a command as the Splunk service account with a timeout.
# Uses su (not sudo) because service accounts often have locked/blank passwords,
# and sudo triggers PAM authentication which hangs indefinitely. Root su'ing
# never requires a password. The script auto-detects whether the account has
# a login shell or nologin and uses the appropriate su form.
run_as_splunk() {
    local tout="$1"; shift
    local cmd="$*"
    local user_shell
    user_shell=$(getent passwd "$SPLUNK_USER" 2>/dev/null | cut -d: -f7) || true
    if [[ "$user_shell" == */nologin* ]] || [[ "$user_shell" == */false* ]] || [[ -z "$user_shell" ]]; then
        timeout "$tout" su -s /bin/bash "$SPLUNK_USER" -c "$cmd"
    else
        timeout "$tout" su - "$SPLUNK_USER" -c "$cmd"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "  Usage: sudo bash $0"
        exit 1
    fi
}

confirm() {
    local msg="${1:-Continue?}"
    [[ "$SKIP_CONFIRMATION" == true ]] && return 0
    echo -en "${YELLOW}${msg} [y/N]: ${NC}"
    local reply; read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Helper: is role X in the selected roles array?
has_role() {
    local r="$1"
    local x
    for x in "${SELECTED_ROLES[@]}"; do
        [[ "$x" == "$r" ]] && return 0
    done
    return 1
}

# Human-readable name for a role code
role_name() {
    case "$1" in
        cm)         echo "Cluster Manager" ;;
        indexer)    echo "Indexer" ;;
        searchhead) echo "Search Head" ;;
        ds)         echo "Deployment Server" ;;
        deployer)   echo "SHC Deployer" ;;
        hf)         echo "Heavy Forwarder" ;;
        lm)         echo "License Manager" ;;
        mc)         echo "Monitoring Console" ;;
        *)          echo "$1" ;;
    esac
}

###############################################################################
# SECTION 2: BACKUP SELECTION
###############################################################################

SELECTED_BACKUP_DIR=""

select_backup_or_create() {
    local label="${1:-operation}"
    SELECTED_BACKUP_DIR=""

    local -a backup_dirs=()
    local -a backup_labels=()
    local dir
    while IFS= read -r dir; do
        [[ -d "$dir/etc" ]] || continue
        backup_dirs+=("$dir")
        local bname btype="unknown" ts="" display_ts bsize has_secret="no"
        bname=$(basename "$dir")
        case "$bname" in
            splunk_backup_*)    btype="upgrade" ;;
            splunk_repair_*)    btype="repair" ;;
            splunk_reconfig_*)  btype="reconfig" ;;
            splunk_remove_*)    btype="remove" ;;
            splunk_binupdate_*) btype="simple-update" ;;
        esac
        ts=$(echo "$bname" | grep -oP '[0-9]{14}$' 2>/dev/null) || true
        display_ts="$bname"
        if [[ -n "$ts" ]]; then
            display_ts="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}"
        fi
        bsize=$(du -sh "$dir" 2>/dev/null | cut -f1)
        [[ -f "$dir/splunk.secret" ]] && has_secret="yes"
        backup_labels+=("${btype} | ${display_ts} | size: ${bsize} | splunk.secret: ${has_secret}")
    done < <(find /tmp -maxdepth 1 -type d \( -name 'splunk_backup_*' -o -name 'splunk_repair_*' -o -name 'splunk_reconfig_*' -o -name 'splunk_remove_*' -o -name 'splunk_binupdate_*' \) 2>/dev/null | sort -r)

    if [[ ${#backup_dirs[@]} -gt 0 ]] && [[ "$SKIP_CONFIRMATION" != true ]]; then
        print_section "Existing Backups Detected"
        echo "  Found ${#backup_dirs[@]} backup(s):"
        local i
        for i in "${!backup_dirs[@]}"; do
            echo "    $((i + 1))) ${backup_labels[$i]}"
            echo "       ${DIM}${backup_dirs[$i]}${NC}"
        done
        echo "    n) Create a fresh backup for this ${label}"
        echo ""
        local choice
        read -rp "Use existing backup or create new? [1-${#backup_dirs[@]}/n]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#backup_dirs[@]} )); then
            SELECTED_BACKUP_DIR="${backup_dirs[$((choice - 1))]}"
            print_success "Using existing backup: $SELECTED_BACKUP_DIR"
            return 0
        fi
    fi

    # Create new backup
    local new_backup="/tmp/splunk_${label//operation/backup}_$(date +%Y%m%d%H%M%S)"
    mkdir -p "$new_backup"
    print_status "Creating backup: $new_backup"
    if [[ -d "$SPLUNK_HOME/etc" ]]; then
        cp -a "$SPLUNK_HOME/etc" "$new_backup/etc" 2>/dev/null || true
    fi
    if [[ -f "$SPLUNK_HOME/etc/auth/splunk.secret" ]]; then
        cp -a "$SPLUNK_HOME/etc/auth/splunk.secret" "$new_backup/splunk.secret"
        chmod 600 "$new_backup/splunk.secret"
    fi
    SELECTED_BACKUP_DIR="$new_backup"
    print_success "Backup created"
}

restore_from_backup() {
    local backup_dir="$1"
    [[ -d "$backup_dir/etc" ]] || { print_warning "No etc/ in backup — skipping restore"; return 0; }
    print_status "Restoring configs from: $backup_dir"
    # Restore etc/ contents into $SPLUNK_HOME/etc, preserving attributes
    if [[ -d "$SPLUNK_HOME/etc" ]]; then
        cp -a "$backup_dir/etc/." "$SPLUNK_HOME/etc/" 2>/dev/null || true
    else
        cp -a "$backup_dir/etc" "$SPLUNK_HOME/etc"
    fi
    # Restore this HOST'S OWN splunk.secret (same-host in-place restore only)
    if [[ -f "$backup_dir/splunk.secret" ]]; then
        cp -a "$backup_dir/splunk.secret" "$SPLUNK_HOME/etc/auth/splunk.secret"
        chmod 600 "$SPLUNK_HOME/etc/auth/splunk.secret"
        print_success "Restored host's own splunk.secret"
    fi
    print_success "Restore complete"
}

###############################################################################
# SECTION 3: USER / SERVICE DETECTION
###############################################################################

detect_splunk_user() {
    # Order: environment override → account owning $SPLUNK_HOME → common candidates → default "splunk"
    if [[ -n "${SPLUNK_USER_OVERRIDE:-}" ]]; then
        SPLUNK_USER="$SPLUNK_USER_OVERRIDE"
    elif [[ -d "$SPLUNK_HOME" ]]; then
        local owner
        owner=$(stat -c '%U' "$SPLUNK_HOME" 2>/dev/null || echo "")
        if [[ -n "$owner" ]] && [[ "$owner" != "root" ]] && id "$owner" >/dev/null 2>&1; then
            SPLUNK_USER="$owner"
        fi
    fi

    if [[ -z "$SPLUNK_USER" ]]; then
        local candidate
        for candidate in splunk splunkuser splunkadm; do
            if id "$candidate" >/dev/null 2>&1; then
                SPLUNK_USER="$candidate"
                break
            fi
        done
    fi
    [[ -z "$SPLUNK_USER" ]] && SPLUNK_USER="splunk"

    if id "$SPLUNK_USER" >/dev/null 2>&1; then
        SPLUNK_GROUP=$(id -gn "$SPLUNK_USER" 2>/dev/null) || SPLUNK_GROUP="$SPLUNK_USER"
    else
        SPLUNK_GROUP="$SPLUNK_USER"
    fi
}

detect_service_name() {
    SERVICE_NAME=""
    local candidate
    for candidate in Splunkd splunkd splunk; do
        if [[ -f "/etc/systemd/system/${candidate}.service" ]] || [[ -f "/usr/lib/systemd/system/${candidate}.service" ]]; then
            SERVICE_NAME="$candidate"
            return 0
        fi
    done
    SERVICE_NAME="Splunkd"   # Splunk 9+ default
}

###############################################################################
# SECTION 4: INPUT VALIDATION HELPERS
###############################################################################

prompt_required() {
    local var_msg="$1" default="${2:-}" reply
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "$var_msg [$default]: " reply
            reply="${reply:-$default}"
        else
            read -rp "$var_msg: " reply
        fi
        [[ -n "$reply" ]] && { echo "$reply"; return 0; }
        print_warning "Value required"
    done
}

prompt_optional() {
    local var_msg="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -rp "$var_msg [$default]: " reply
        reply="${reply:-$default}"
    else
        read -rp "$var_msg (optional): " reply
    fi
    echo "$reply"
}

prompt_password() {
    local var_msg="$1" reply reply2
    while true; do
        read -rsp "$var_msg: " reply; echo
        read -rsp "Confirm: " reply2; echo
        if [[ "$reply" != "$reply2" ]]; then
            print_error "Passwords do not match"; continue
        fi
        if [[ ${#reply} -lt 8 ]]; then
            print_warning "Password should be at least 8 characters"
            confirm "Use this password anyway?" || continue
        fi
        echo "$reply"; return 0
    done
}

prompt_secret() {
    # pass4SymmKey — single entry with confirmation
    local var_msg="$1" reply reply2
    while true; do
        read -rsp "$var_msg: " reply; echo
        read -rsp "Confirm: " reply2; echo
        [[ "$reply" == "$reply2" ]] && { echo "$reply"; return 0; }
        print_error "Values do not match"
    done
}

validate_ip_or_hostname() {
    local v="$1"
    [[ -z "$v" ]] && return 1
    # IPv4, hostname, or FQDN
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
    [[ "$v" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]] && return 0
    return 1
}

validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

validate_uri() {
    local u="$1"
    [[ "$u" =~ ^https?:// ]] || return 1
    return 0
}

prompt_validated_input() {
    local msg="$1" validator="$2" default="${3:-}" reply
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "$msg [$default]: " reply
            reply="${reply:-$default}"
        else
            read -rp "$msg: " reply
        fi
        if $validator "$reply"; then
            echo "$reply"; return 0
        fi
        print_warning "Invalid value"
    done
}

###############################################################################
# SECTION 5: OS DETECTION, BANNER, TOPOLOGY
###############################################################################

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_TYPE="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-0}"
        case "$OS_TYPE" in
            ol|oracle) IS_ORACLE_LINUX=true ;;
            *)         IS_ORACLE_LINUX=false ;;
        esac
    fi
    if [[ -f /etc/oracle-release ]]; then
        IS_ORACLE_LINUX=true
    fi
    return 0
}

show_banner() {
    clear
    echo -e "${CYAN}"
    cat << EOF
================================================================
  Splunk Enterprise Manager v${SCRIPT_VERSION}
  Generic, Multi-Role — RHEL-family Linux
================================================================
EOF
    echo -e "${NC}"
    echo "  Host: $HOSTNAME    OS: $OS_TYPE $OS_VERSION    SPLUNK_HOME: $SPLUNK_HOME"
    echo ""
}

show_environment_topology() {
    print_header "Environment Topology (generic)"
    echo ""
    echo "  Hosts (override via env vars):"
    echo "    Cluster Manager:     $ENV_CM_HOST"
    echo "    Deployment Server:   $ENV_DS_HOST"
    echo "    Indexer #1:          $ENV_IDX01_HOST"
    echo "    Indexer #2:          $ENV_IDX02_HOST"
    echo "    Search Head:         $ENV_SH_HOST"
    echo "    Heavy Forwarder:     $ENV_HF_HOST"
    echo "    License Manager:     $ENV_LM_HOST"
    echo "    Monitoring Console:  $ENV_MC_HOST"
    echo ""
    echo "  Ports:"
    echo "    Management: $ENV_MGMT_PORT    Web: $ENV_WEB_PORT"
    echo "    Receiving:  $ENV_RECV_PORT    Replication: $ENV_REPL_PORT    SHC Repl: $ENV_SHC_REPL_PORT"
    echo ""
    print_section "Splunk-recommended upgrade order"
    cat <<'EOF'
    1. Deployment Server      (upgrade, do NOT restart yet)
    2. Cluster Manager + LM   (upgrade and restart)
    3. Enable maintenance mode on the CM
    4. Search Heads           (one at a time)
    5. Indexers               (one at a time; use `splunk offline`)
    6. Disable maintenance mode
    7. Heavy Forwarder(s)     (stop, upgrade, start)
    8. Restart Deployment Server (from step 1)
    9. Universal Forwarders   (last; use the UF manager script)

    See the Splunk distributed upgrade documentation for details.
EOF
    echo ""
}

guess_roles_from_hostname() {
    # Suggest roles based on hostname keywords. Returns a comma-separated list.
    local h="${HOSTNAME,,}"
    local -a guessed=()
    [[ "$h" == *cm*      || "$h" == *cluster* ]] && guessed+=(cm)
    [[ "$h" == *idx*     || "$h" == *indexer* ]] && guessed+=(indexer)
    [[ "$h" == *sh*      || "$h" == *search*  ]] && guessed+=(searchhead)
    [[ "$h" == *ds*      || "$h" == *deploy*  ]] && guessed+=(ds)
    [[ "$h" == *deployer* ]] && guessed+=(deployer)
    [[ "$h" == *hf*      || "$h" == *heavy*   ]] && guessed+=(hf)
    [[ "$h" == *lm*      || "$h" == *license* ]] && guessed+=(lm)
    [[ "$h" == *mc*      || "$h" == *monitor* ]] && guessed+=(mc)
    # Remove dupes
    local IFS=,
    echo "${guessed[*]}"
}

###############################################################################
# SECTION 6: PREFLIGHT
###############################################################################

show_initial_prompt() {
    print_header "File Placement"
    echo "Required directory: $BASE_DIR"
    echo "Place one of:"
    echo "    splunk-*.tgz        TGZ installer (preferred)"
    echo "    splunk-*.rpm        RPM installer"
    echo ""

    if [[ ! -d "$BASE_DIR" ]]; then
        print_warning "$BASE_DIR does not exist"
        if confirm "Create it now?"; then
            mkdir -p "$BASE_DIR"
            chmod 755 "$BASE_DIR"
            print_success "Created $BASE_DIR"
        fi
    fi
}

preflight_permission_check() {
    print_section "Permission checks"
    local fixed=0
    for installer in "$BASE_DIR"/splunk-*.tgz "$BASE_DIR"/splunk-*.rpm; do
        [[ -f "$installer" ]] || continue
        if [[ ! -r "$installer" ]]; then
            chmod 644 "$installer" && fixed=$((fixed + 1))
        fi
    done
    [[ -w "/opt" ]] || print_warning "/opt is not writable"
    command_exists rpm || print_warning "rpm not found — RPM installs unavailable"
    (( fixed > 0 )) && print_success "Auto-fixed $fixed permission issue(s)" || print_success "Permission checks OK"
}

check_disk_space() {
    print_section "Disk Space"
    local space_ok=true
    local tmp_avail_mb opt_avail_mb
    tmp_avail_mb=$(( $(df -P /tmp 2>/dev/null | tail -1 | awk '{print $4}') / 1024 ))
    opt_avail_mb=$(( $(df -P /opt 2>/dev/null | tail -1 | awk '{print $4}') / 1024 ))
    if (( tmp_avail_mb < MIN_TMP_SPACE_MB )); then
        print_error "/tmp: ${tmp_avail_mb}MB available, need ${MIN_TMP_SPACE_MB}MB"
        space_ok=false
    else
        print_success "/tmp: ${tmp_avail_mb}MB"
    fi
    if (( opt_avail_mb < MIN_OPT_SPACE_MB )); then
        print_error "/opt: ${opt_avail_mb}MB available, need ${MIN_OPT_SPACE_MB}MB"
        space_ok=false
    else
        print_success "/opt: ${opt_avail_mb}MB"
    fi
    if [[ "$space_ok" == false ]]; then
        [[ "$SKIP_CONFIRMATION" == true ]] && return 1
        confirm "Continue anyway?" || return 1
    fi
    return 0
}

###############################################################################
# SECTION 7: VERSION MANAGEMENT
###############################################################################

get_current_version() {
    CURRENT_VERSION=""
    if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
        local out
        out=$(timeout 10 "$SPLUNK_HOME/bin/splunk" version 2>/dev/null) || true
        CURRENT_VERSION=$(echo "$out" | grep -oP 'Splunk \K[\d.]+' | head -1)
    fi
    if [[ -z "$CURRENT_VERSION" ]] && [[ -f "$SPLUNK_HOME/etc/splunk.version" ]]; then
        CURRENT_VERSION=$(grep -oP 'VERSION=\K[\d.]+' "$SPLUNK_HOME/etc/splunk.version" 2>/dev/null | head -1)
    fi
}

extract_version_from_tgz() { basename "$1" | sed -E 's/splunk-([0-9.]+)-.*/\1/'; }
extract_version_from_rpm() {
    if command_exists rpm; then
        local v; v=$(rpm -qp --queryformat '%{VERSION}' "$1" 2>/dev/null)
        [[ -n "$v" ]] && { echo "$v"; return; }
    fi
    basename "$1" | sed -E 's/splunk-([0-9.]+)-.*/\1/'
}

version_compare() {
    # Returns: 0 if v1==v2, 1 if v1<v2, 2 if v1>v2
    local v1="$1" v2="$2"
    [[ "$v1" == "$v2" ]] && { echo 0; return; }
    local first; first=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)
    [[ "$first" == "$v1" ]] && echo 1 || echo 2
}

detect_upgrade_scenario() {
    get_current_version
    local installer="${TGZ_FILE:-$RPM_FILE}"
    [[ "$INSTALLER_TYPE" == "tgz" ]] && NEW_VERSION=$(extract_version_from_tgz "$installer") \
                                     || NEW_VERSION=$(extract_version_from_rpm "$installer")

    if [[ -z "$CURRENT_VERSION" ]]; then
        INSTALL_METHOD="FRESH"; return
    fi
    print_status "Current: $CURRENT_VERSION  →  Package: $NEW_VERSION"
    local cmp; cmp=$(version_compare "$CURRENT_VERSION" "$NEW_VERSION")
    case "$cmp" in
        0) [[ "$FORCE_REINSTALL" == true ]] && INSTALL_METHOD="REINSTALL" || { print_warning "Same version"; INSTALL_METHOD="SKIP"; } ;;
        1) INSTALL_METHOD="UPGRADE" ;;
        2) [[ "$FORCE_REINSTALL" == true ]] && INSTALL_METHOD="REINSTALL" || { print_error "Downgrade not allowed; use --reinstall to force"; INSTALL_METHOD="SKIP"; } ;;
    esac
}

###############################################################################
# SECTION 8: INSTALLER DETECTION
###############################################################################

find_splunk_installer() {
    print_section "Installer detection"
    local search_dirs=("$BASE_DIR" "$SCRIPT_DIR" "/tmp")
    local -a all=() types=() seen=()

    local d f rp
    for d in "${search_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        # TGZ
        while IFS= read -r -d '' f; do
            rp=$(realpath "$f" 2>/dev/null || echo "$f")
            local dup=false; for s in "${seen[@]}"; do [[ "$s" == "$rp" ]] && dup=true && break; done
            [[ "$dup" == true ]] && continue
            if file "$f" 2>/dev/null | grep -qi 'gzip\|tar'; then
                all+=("$f"); types+=("tgz"); seen+=("$rp")
            fi
        done < <(find "$d" -maxdepth 1 -name 'splunk-*.tgz' ! -name 'splunkforwarder*' -print0 2>/dev/null | sort -zV)
        # RPM
        while IFS= read -r -d '' f; do
            rp=$(realpath "$f" 2>/dev/null || echo "$f")
            local dup=false; for s in "${seen[@]}"; do [[ "$s" == "$rp" ]] && dup=true && break; done
            [[ "$dup" == true ]] && continue
            local valid=false
            file "$f" 2>/dev/null | grep -qi 'rpm' && valid=true
            [[ "$valid" == false ]] && command_exists rpm && rpm -qp "$f" >/dev/null 2>&1 && valid=true
            if [[ "$valid" == true ]]; then
                all+=("$f"); types+=("rpm"); seen+=("$rp")
            fi
        done < <(find "$d" -maxdepth 1 -name 'splunk-*.rpm' ! -name 'splunkforwarder*' -print0 2>/dev/null | sort -zV)
    done

    if [[ ${#all[@]} -eq 0 ]]; then
        print_error "No Splunk Enterprise installers found (splunk-*.tgz or *.rpm in $BASE_DIR)"
        return 1
    fi

    local idx=0
    if [[ ${#all[@]} -eq 1 ]]; then
        print_success "Found: $(basename "${all[0]}") [${types[0]^^}]"
    else
        echo "Found ${#all[@]} installers:"
        local i
        for i in "${!all[@]}"; do
            local v
            [[ "${types[$i]}" == "tgz" ]] && v=$(extract_version_from_tgz "${all[$i]}") || v=$(extract_version_from_rpm "${all[$i]}")
            echo "  $((i + 1))) $(basename "${all[$i]}") [v${v}] [${types[$i]^^}]"
        done
        if [[ "$SKIP_CONFIRMATION" == true ]]; then
            idx=$(( ${#all[@]} - 1 ))
            print_status "Auto-selected latest"
        else
            while true; do
                read -rp "Select [1-${#all[@]}] (default=latest): " sel
                [[ -z "$sel" ]] && sel=${#all[@]}
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#all[@]} )); then
                    idx=$((sel - 1)); break
                fi
                print_error "Invalid"
            done
        fi
    fi

    if [[ "${types[$idx]}" == "tgz" ]]; then
        TGZ_FILE="${all[$idx]}"; RPM_FILE=""; INSTALLER_TYPE="tgz"
        NEW_VERSION=$(extract_version_from_tgz "$TGZ_FILE")
    else
        RPM_FILE="${all[$idx]}"; TGZ_FILE=""; INSTALLER_TYPE="rpm"
        NEW_VERSION=$(extract_version_from_rpm "$RPM_FILE")
    fi
    print_success "Selected: $(basename "${all[$idx]}") [v${NEW_VERSION}] [${INSTALLER_TYPE^^}]"
    return 0
}

###############################################################################
# SECTION 9: SELINUX (tightened — keep Enforcing, restorecon only)
###############################################################################

apply_selinux_contexts() {
    if command_exists restorecon && command_exists getenforce; then
        local state; state=$(getenforce 2>/dev/null || echo "Disabled")
        if [[ "$state" != "Disabled" ]]; then
            print_status "Restoring SELinux contexts on $SPLUNK_HOME..."
            restorecon -R "$SPLUNK_HOME" 2>/dev/null || print_warning "restorecon had issues (non-fatal)"
        fi
    fi
}

###############################################################################
# SECTION 10: FIREWALL (role-aware, multi-role union)
###############################################################################

# Returns array of ports (tcp) this role needs.
ports_for_role() {
    case "$1" in
        cm|ds|deployer|lm|mc)
            echo "$ENV_MGMT_PORT"
            ;;
        indexer)
            echo "$ENV_MGMT_PORT $ENV_RECV_PORT $ENV_REPL_PORT"
            ;;
        searchhead)
            echo "$ENV_MGMT_PORT $ENV_WEB_PORT"
            if [[ "$SHC_MODE" == "captain" ]] || [[ "$SHC_MODE" == "member" ]]; then
                echo " $ENV_SHC_REPL_PORT"
            fi
            ;;
        hf)
            echo "$ENV_MGMT_PORT"
            # Syslog ports collected by the HF wizard
            local count="${ROLE_CONFIG[syslog_count]:-0}"
            local i
            for (( i = 0; i < count; i++ )); do
                local proto="${ROLE_CONFIG[syslog_${i}_proto]:-}"
                local port="${ROLE_CONFIG[syslog_${i}_port]:-}"
                if [[ "$proto" == "tcp" ]] && [[ -n "$port" ]]; then
                    echo " $port"
                fi
            done
            ;;
    esac
}

configure_firewall() {
    if ! command_exists firewall-cmd; then
        print_warning "firewall-cmd not available; skipping firewall setup"
        return 0
    fi
    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        print_warning "firewalld not active; skipping firewall setup"
        return 0
    fi

    print_section "Firewall (union of role ports)"

    # Collect all ports from all roles into a deduplicated set
    local -A port_set=()
    local r p
    for r in "${SELECTED_ROLES[@]}"; do
        for p in $(ports_for_role "$r"); do
            port_set["$p"]=1
        done
    done

    # UDP syslog ports from HF wizard
    local -A udp_port_set=()
    if has_role hf; then
        local count="${ROLE_CONFIG[syslog_count]:-0}"
        local i
        for (( i = 0; i < count; i++ )); do
            local proto="${ROLE_CONFIG[syslog_${i}_proto]:-}"
            local port="${ROLE_CONFIG[syslog_${i}_port]:-}"
            if [[ "$proto" == "udp" ]] && [[ -n "$port" ]]; then
                udp_port_set["$port"]=1
            fi
        done
    fi

    # Apply TCP rules
    for p in "${!port_set[@]}"; do
        if firewall-cmd --list-ports 2>/dev/null | grep -qw "${p}/tcp"; then
            print_success "TCP ${p}/tcp already open"
        else
            firewall-cmd --add-port="${p}/tcp" --permanent >/dev/null && \
                print_success "Opened ${p}/tcp (permanent)"
        fi
    done

    # Apply UDP rules
    for p in "${!udp_port_set[@]}"; do
        if firewall-cmd --list-ports 2>/dev/null | grep -qw "${p}/udp"; then
            print_success "UDP ${p}/udp already open"
        else
            firewall-cmd --add-port="${p}/udp" --permanent >/dev/null && \
                print_success "Opened ${p}/udp (permanent)"
        fi
    done

    firewall-cmd --reload >/dev/null 2>&1 || true
}

###############################################################################
# SECTION 11: USER MANAGEMENT
###############################################################################

ensure_splunk_user() {
    print_section "User management"

    # Detect login vs nologin shell (respected by run_as_splunk)
    local user_shell="" is_login=false
    if id "$SPLUNK_USER" >/dev/null 2>&1; then
        user_shell=$(getent passwd "$SPLUNK_USER" 2>/dev/null | cut -d: -f7) || true
        if [[ -n "$user_shell" ]] && [[ "$user_shell" != */nologin* ]] && [[ "$user_shell" != */false* ]]; then
            is_login=true
        fi
        print_success "User '$SPLUNK_USER' exists (UID: $(id -u "$SPLUNK_USER"), shell: ${user_shell:-?})"
    else
        print_status "Creating user '$SPLUNK_USER'..."
        if ! useradd -r -m -d "$SPLUNK_HOME" -s /sbin/nologin -c "Splunk Enterprise" "$SPLUNK_USER" 2>/dev/null; then
            useradd -r -d "$SPLUNK_HOME" -s /sbin/nologin -c "Splunk Enterprise" "$SPLUNK_USER" || {
                print_error "Failed to create user"; return 1;
            }
        fi
        print_success "User '$SPLUNK_USER' created"
    fi

    # On RHEL9+, service accounts with blank passwords can cause PAM hangs;
    # lock the password explicitly unless the account is a real login account.
    if [[ "$is_login" != true ]]; then
        local os_major="${OS_VERSION%%.*}"
        if [[ "${os_major:-0}" =~ ^[0-9]+$ ]] && (( os_major >= 9 )); then
            local pw_status
            pw_status=$(passwd -S "$SPLUNK_USER" 2>/dev/null | awk '{print $2}') || true
            if [[ "$pw_status" != "L" && "$pw_status" != "LK" ]]; then
                passwd -l "$SPLUNK_USER" >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Verify we can run as the user
    if ! timeout 5 su -s /bin/bash "$SPLUNK_USER" -c "whoami" >/dev/null 2>&1; then
        print_warning "Cannot su to '$SPLUNK_USER'; attempting repair"
        usermod -U "$SPLUNK_USER" 2>/dev/null || true
        usermod -s /sbin/nologin "$SPLUNK_USER" 2>/dev/null || true
        if ! timeout 5 su -s /bin/bash "$SPLUNK_USER" -c "whoami" >/dev/null 2>&1; then
            print_error "Cannot run commands as '$SPLUNK_USER'"
            return 1
        fi
    fi
    print_success "Ready to run commands as '$SPLUNK_USER'"
}

fix_ownership() {
    if [[ -d "$SPLUNK_HOME" ]]; then
        print_status "Setting ownership: $SPLUNK_HOME -> $SPLUNK_USER:$SPLUNK_GROUP"
        chown -Rh "$SPLUNK_USER:$SPLUNK_GROUP" "$SPLUNK_HOME"
    fi
}

###############################################################################
# SECTION 12: MULTI-ROLE SELECTION
###############################################################################

select_roles_interactive() {
    print_header "Select Role(s)"
    local guessed; guessed=$(guess_roles_from_hostname)
    [[ -n "$guessed" ]] && echo -e "  ${DIM}Hostname suggests: $guessed${NC}"
    echo ""
    echo "  Available roles (enter comma-separated, e.g. cm,lm):"
    echo "    cm          Cluster Manager"
    echo "    indexer     Indexer (clustered or standalone)"
    echo "    searchhead  Search Head (SHC or standalone)"
    echo "    ds          Deployment Server"
    echo "    deployer    SHC Deployer"
    echo "    hf          Heavy Forwarder"
    echo "    lm          License Manager"
    echo "    mc          Monitoring Console"
    echo ""
    echo "  Common combinations:"
    echo "    cm,lm                    CM + License Manager"
    echo "    ds,mc                    DS + Monitoring Console"
    echo "    cm,lm,ds,mc              Consolidated management tier"
    echo ""

    local input
    while true; do
        read -rp "Role(s): " input
        input=$(echo "$input" | tr -d '[:space:]')
        [[ -z "$input" ]] && { print_error "At least one role required"; continue; }
        parse_roles_string "$input" && break
    done
    validate_role_combination
}

parse_roles_string() {
    local s="$1"
    SELECTED_ROLES=()
    local IFS=','
    local r
    for r in $s; do
        case "$r" in
            cm|indexer|searchhead|ds|deployer|hf|lm|mc)
                # dedupe
                if ! has_role "$r"; then
                    SELECTED_ROLES+=("$r")
                fi
                ;;
            *)
                print_error "Unknown role: $r"
                return 1
                ;;
        esac
    done
    return 0
}

validate_role_combination() {
    # Warn on combinations that are supported but discouraged
    if has_role indexer && has_role searchhead; then
        print_warning "indexer + searchhead on the same host is supported but discouraged in production"
    fi
    if has_role indexer && has_role cm; then
        print_warning "indexer + cm on the same host is fine for lab/test, not for production"
    fi
    if has_role indexer && has_role hf; then
        print_warning "indexer + hf on the same host is unusual"
    fi
    echo ""
    print_success "Selected roles:"
    local r
    for r in "${SELECTED_ROLES[@]}"; do
        echo "    - $r ($(role_name "$r"))"
    done
}

###############################################################################
# SECTION 13: ROLE WIZARDS
###############################################################################

wizard_common() {
    print_section "Common settings"
    local server_name admin_pass
    server_name=$(prompt_required "Server name" "$HOSTNAME")
    ROLE_CONFIG[server_name]="$server_name"

    if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
        ROLE_CONFIG[admin_password]="$ADMIN_PASSWORD"
        print_status "Using admin password from ADMIN_PASSWORD env var"
    else
        admin_pass=$(prompt_password "Admin password (min 8 chars)")
        ROLE_CONFIG[admin_password]="$admin_pass"
    fi
}

wizard_cluster_manager() {
    print_section "Cluster Manager"
    ROLE_CONFIG[cm_pass4symmkey]=$(prompt_secret "Indexer cluster pass4SymmKey")
    ROLE_CONFIG[cluster_label]=$(prompt_optional "Cluster label" "idxcluster")
    ROLE_CONFIG[replication_factor]=$(prompt_validated_input "Replication factor" validate_port "2")
    ROLE_CONFIG[search_factor]=$(prompt_validated_input "Search factor" validate_port "2")
}

wizard_indexer_clustered() {
    print_section "Indexer — clustered"
    local cm_host cm_uri
    cm_host=$(prompt_validated_input "Cluster Manager host/IP" validate_ip_or_hostname "$ENV_CM_HOST")
    cm_uri="https://${cm_host}:${ENV_MGMT_PORT}"
    ROLE_CONFIG[manager_uri]="$cm_uri"
    ROLE_CONFIG[cm_pass4symmkey]=$(prompt_secret "Indexer cluster pass4SymmKey (same as CM)")
    ROLE_CONFIG[replication_port]=$(prompt_validated_input "Replication port" validate_port "$ENV_REPL_PORT")
    ROLE_CONFIG[receiving_port]=$(prompt_validated_input "Receiving port" validate_port "$ENV_RECV_PORT")
}

wizard_indexer_standalone() {
    print_section "Indexer — standalone"
    ROLE_CONFIG[receiving_port]=$(prompt_validated_input "Receiving port" validate_port "$ENV_RECV_PORT")
    ROLE_CONFIG[web_port]=$(prompt_validated_input "Web port" validate_port "$ENV_WEB_PORT")
}

wizard_indexer() {
    print_section "Indexer mode"
    echo "  1) Clustered (peer)"
    echo "  2) Standalone"
    local m
    while true; do
        read -rp "Select [1/2]: " m
        case "$m" in
            1) CLUSTER_MODE="clustered"; wizard_indexer_clustered; break ;;
            2) CLUSTER_MODE="standalone"; wizard_indexer_standalone; break ;;
            *) print_error "Invalid" ;;
        esac
    done
    ROLE_CONFIG[max_hot_buckets]=$(prompt_optional "maxHotBuckets" "3")
    ROLE_CONFIG[frozen_time_days]=$(prompt_optional "frozenTimePeriodInSecs (days)" "365")
    ROLE_CONFIG[custom_indexes]=$(prompt_optional "Custom indexes (comma-separated)" "")
}

wizard_searchhead() {
    print_section "Search Head mode"
    echo "  1) Standalone"
    echo "  2) SHC captain (bootstrap)"
    echo "  3) SHC member"
    local m
    while true; do
        read -rp "Select [1/2/3]: " m
        case "$m" in
            1) SHC_MODE="standalone" ;;
            2) SHC_MODE="captain"    ;;
            3) SHC_MODE="member"     ;;
            *) print_error "Invalid"; continue ;;
        esac
        break
    done

    ROLE_CONFIG[web_port]=$(prompt_validated_input "Web port" validate_port "$ENV_WEB_PORT")

    if [[ "$SHC_MODE" == "captain" || "$SHC_MODE" == "member" ]]; then
        local mgmt_host
        mgmt_host=$(prompt_validated_input "This host's management URI host/IP" validate_ip_or_hostname "$HOSTNAME")
        ROLE_CONFIG[mgmt_uri]="https://${mgmt_host}:${ENV_MGMT_PORT}"
        ROLE_CONFIG[shc_pass4symmkey]=$(prompt_secret "SHC pass4SymmKey")
        ROLE_CONFIG[shc_replication_factor]=$(prompt_optional "SHC replication factor" "3")
        ROLE_CONFIG[shc_replication_port]=$(prompt_validated_input "SHC replication port" validate_port "$ENV_SHC_REPL_PORT")
        ROLE_CONFIG[shcluster_label]=$(prompt_optional "SHC label" "shcluster")
        local deployer_host
        deployer_host=$(prompt_validated_input "SHC Deployer host/IP" validate_ip_or_hostname "$ENV_CM_HOST")
        ROLE_CONFIG[deployer_url]="https://${deployer_host}:${ENV_MGMT_PORT}"

        if [[ "$SHC_MODE" == "captain" ]]; then
            local members
            members=$(prompt_optional "Comma-separated SHC member URIs (https://host:8089,...)" "")
            ROLE_CONFIG[shc_member_uris]="$members"
        fi
    fi
}

wizard_ds() {
    print_section "Deployment Server"
    ROLE_CONFIG[ds_whitelist]=$(prompt_optional "Default serverClass whitelist (or blank)" "")
}

wizard_deployer() {
    print_section "SHC Deployer"
    ROLE_CONFIG[shc_pass4symmkey]=$(prompt_secret "SHC pass4SymmKey (matches SHC members)")
    ROLE_CONFIG[shcluster_label]=$(prompt_optional "SHC label" "shcluster")
}

wizard_heavy_forwarder() {
    print_section "Heavy Forwarder — outputs"
    local idx_list
    idx_list=$(prompt_required "Indexer list for tcpout (host:port,host:port,...)" "$ENV_IDX01_HOST:$ENV_RECV_PORT,$ENV_IDX02_HOST:$ENV_RECV_PORT")
    ROLE_CONFIG[indexer_list]="$idx_list"

    print_section "Heavy Forwarder — syslog inputs"
    local count=0 add more proto port stype sidx
    while true; do
        read -rp "Add a syslog input? [y/N]: " add
        [[ "$add" =~ ^[Yy]$ ]] || break
        while true; do
            read -rp "  Protocol (tcp/udp): " proto
            [[ "$proto" == "tcp" || "$proto" == "udp" ]] && break
            print_warning "Enter tcp or udp"
        done
        port=$(prompt_validated_input "  Port" validate_port "514")
        stype=$(prompt_required "  sourcetype" "syslog")
        sidx=$(prompt_required "  index" "main")
        ROLE_CONFIG[syslog_${count}_proto]="$proto"
        ROLE_CONFIG[syslog_${count}_port]="$port"
        ROLE_CONFIG[syslog_${count}_sourcetype]="$stype"
        ROLE_CONFIG[syslog_${count}_index]="$sidx"
        count=$((count + 1))
        read -rp "Add another? [y/N]: " more
        [[ "$more" =~ ^[Yy]$ ]] || break
    done
    ROLE_CONFIG[syslog_count]="$count"
}

wizard_lm() {
    print_section "License Manager"
    echo "  This host will hold the Splunk license file and act as the license source."
    echo "  Other instances should be configured with license_master_uri pointing here."
    echo ""
    local lic_path
    lic_path=$(prompt_optional "Path to Splunk license file (XML, optional — can import later via UI)" "")
    ROLE_CONFIG[license_file]="$lic_path"
}

wizard_mc() {
    print_section "Monitoring Console"
    echo "  The Monitoring Console is mostly configured via the Splunk UI after install."
    echo "  This wizard only records the role; no server.conf stanzas required."
}

run_role_wizards() {
    wizard_common
    local r
    for r in "${SELECTED_ROLES[@]}"; do
        case "$r" in
            cm)         wizard_cluster_manager ;;
            indexer)    wizard_indexer ;;
            searchhead) wizard_searchhead ;;
            ds)         wizard_ds ;;
            deployer)   wizard_deployer ;;
            hf)         wizard_heavy_forwarder ;;
            lm)         wizard_lm ;;
            mc)         wizard_mc ;;
        esac
    done
}

###############################################################################
# SECTION 14: REVIEW
###############################################################################

review_configuration() {
    print_header "Configuration Review"
    echo "  Roles:           ${SELECTED_ROLES[*]}"
    echo "  Server name:     ${ROLE_CONFIG[server_name]:-$HOSTNAME}"
    [[ -n "${CLUSTER_MODE:-}" ]] && echo "  Cluster mode:    $CLUSTER_MODE"
    [[ -n "${SHC_MODE:-}" ]]     && echo "  SHC mode:        $SHC_MODE"
    echo ""
    echo "  Key config values (secrets masked):"
    local k
    for k in "${!ROLE_CONFIG[@]}"; do
        case "$k" in
            admin_password|*pass4symmkey*) echo "    $k = [REDACTED]" ;;
            *)                              echo "    $k = ${ROLE_CONFIG[$k]}" ;;
        esac
    done | sort
    echo ""
}

run_wizard_with_review() {
    if [[ ${#SELECTED_ROLES[@]} -eq 0 ]]; then
        select_roles_interactive
    else
        validate_role_combination
    fi
    run_role_wizards
    review_configuration
    [[ "$SKIP_CONFIRMATION" == true ]] || confirm "Proceed with this configuration?" || {
        print_status "Cancelled"; exit 0;
    }
}

###############################################################################
# SECTION 15: CONFIG GENERATORS
###############################################################################

generate_server_conf() {
    local conf_dir="$SPLUNK_HOME/etc/system/local"
    local conf_file="$conf_dir/server.conf"
    mkdir -p "$conf_dir"
    [[ -f "$conf_file" ]] && cp "$conf_file" "${conf_file}.bak.$(date +%Y%m%d%H%M%S)"

    local server_name="${ROLE_CONFIG[server_name]:-$HOSTNAME}"

    {
        echo "# Splunk Enterprise server.conf"
        echo "# Generated by splunk-enterprise-manager.sh v${SCRIPT_VERSION}"
        echo "# Roles: ${SELECTED_ROLES[*]}"
        echo "# Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "[general]"
        echo "serverName = ${server_name}"
    } > "$conf_file"

    local r
    for r in "${SELECTED_ROLES[@]}"; do
        case "$r" in
            cm)
                {
                    echo ""
                    echo "[clustering]"
                    echo "mode = manager"
                    echo "replication_factor = ${ROLE_CONFIG[replication_factor]:-2}"
                    echo "search_factor = ${ROLE_CONFIG[search_factor]:-2}"
                    echo "pass4SymmKey = ${ROLE_CONFIG[cm_pass4symmkey]}"
                    echo "cluster_label = ${ROLE_CONFIG[cluster_label]:-idxcluster}"
                } >> "$conf_file"
                ;;
            indexer)
                if [[ "$CLUSTER_MODE" == "clustered" ]]; then
                    {
                        echo ""
                        echo "[clustering]"
                        echo "mode = peer"
                        echo "manager_uri = ${ROLE_CONFIG[manager_uri]}"
                        echo "pass4SymmKey = ${ROLE_CONFIG[cm_pass4symmkey]}"
                        echo ""
                        echo "[replication_port://${ROLE_CONFIG[replication_port]:-$ENV_REPL_PORT}]"
                    } >> "$conf_file"
                fi
                ;;
            searchhead)
                if [[ "$SHC_MODE" == "captain" ]] || [[ "$SHC_MODE" == "member" ]]; then
                    {
                        echo ""
                        echo "[shclustering]"
                        echo "disabled = false"
                        echo "mgmt_uri = ${ROLE_CONFIG[mgmt_uri]}"
                        echo "replication_factor = ${ROLE_CONFIG[shc_replication_factor]:-3}"
                        echo "pass4SymmKey = ${ROLE_CONFIG[shc_pass4symmkey]}"
                        echo "conf_deploy_fetch_url = ${ROLE_CONFIG[deployer_url]}"
                        echo "shcluster_label = ${ROLE_CONFIG[shcluster_label]:-shcluster}"
                        echo ""
                        echo "[replication_port://${ROLE_CONFIG[shc_replication_port]:-$ENV_SHC_REPL_PORT}]"
                    } >> "$conf_file"
                fi
                ;;
            deployer)
                {
                    echo ""
                    echo "[shclustering]"
                    echo "pass4SymmKey = ${ROLE_CONFIG[shc_pass4symmkey]}"
                    echo "shcluster_label = ${ROLE_CONFIG[shcluster_label]:-shcluster}"
                } >> "$conf_file"
                ;;
            lm|mc|ds|hf)
                # No server.conf stanzas needed (lm is implicit by having the license file;
                # mc is configured via the UI; ds and hf have their own conf files).
                :
                ;;
        esac
    done

    chown "$SPLUNK_USER:$SPLUNK_GROUP" "$conf_file"
    chmod 600 "$conf_file"
    print_success "server.conf generated"
}

generate_indexes_conf() {
    has_role indexer || return 0
    local conf_dir="$SPLUNK_HOME/etc/system/local"
    local conf_file="$conf_dir/indexes.conf"
    mkdir -p "$conf_dir"
    [[ -f "$conf_file" ]] && cp "$conf_file" "${conf_file}.bak.$(date +%Y%m%d%H%M%S)"

    local max_hot="${ROLE_CONFIG[max_hot_buckets]:-3}"
    local frozen_days="${ROLE_CONFIG[frozen_time_days]:-365}"
    local frozen_secs=$((frozen_days * 86400))

    {
        echo "# Splunk Enterprise indexes.conf"
        echo "# Generated by splunk-enterprise-manager.sh v${SCRIPT_VERSION}"
        echo ""
        echo "[default]"
        echo "maxHotBuckets = ${max_hot}"
        echo "frozenTimePeriodInSecs = ${frozen_secs}"
        echo 'homePath = $SPLUNK_DB/$_index_name/db'
        echo 'coldPath = $SPLUNK_DB/$_index_name/colddb'
        echo 'thawedPath = $SPLUNK_DB/$_index_name/thaweddb'
    } > "$conf_file"

    local custom="${ROLE_CONFIG[custom_indexes]:-}"
    if [[ -n "$custom" ]]; then
        local IFS=','; local idx
        for idx in $custom; do
            idx=$(echo "$idx" | xargs)
            [[ -z "$idx" ]] && continue
            {
                echo ""
                echo "[${idx}]"
                echo "homePath = \$SPLUNK_DB/${idx}/db"
                echo "coldPath = \$SPLUNK_DB/${idx}/colddb"
                echo "thawedPath = \$SPLUNK_DB/${idx}/thaweddb"
            } >> "$conf_file"
        done
    fi

    chown "$SPLUNK_USER:$SPLUNK_GROUP" "$conf_file"
    chmod 600 "$conf_file"
    print_success "indexes.conf generated"
}

generate_inputs_conf() {
    local conf_dir="$SPLUNK_HOME/etc/system/local"
    local conf_file="$conf_dir/inputs.conf"
    mkdir -p "$conf_dir"

    # Only generate inputs.conf if at least one role contributes inputs
    if ! has_role indexer && ! has_role hf; then
        return 0
    fi
    [[ -f "$conf_file" ]] && cp "$conf_file" "${conf_file}.bak.$(date +%Y%m%d%H%M%S)"

    {
        echo "# Splunk Enterprise inputs.conf"
        echo "# Generated by splunk-enterprise-manager.sh v${SCRIPT_VERSION}"
    } > "$conf_file"

    if has_role indexer; then
        local recv_port="${ROLE_CONFIG[receiving_port]:-$ENV_RECV_PORT}"
        {
            echo ""
            echo "[splunktcp://${recv_port}]"
            echo "disabled = false"
        } >> "$conf_file"
    fi

    if has_role hf; then
        local count="${ROLE_CONFIG[syslog_count]:-0}"
        local i
        for (( i = 0; i < count; i++ )); do
            local proto="${ROLE_CONFIG[syslog_${i}_proto]}"
            local port="${ROLE_CONFIG[syslog_${i}_port]}"
            local stype="${ROLE_CONFIG[syslog_${i}_sourcetype]}"
            local sidx="${ROLE_CONFIG[syslog_${i}_index]}"
            {
                echo ""
                echo "[${proto}://${port}]"
                echo "disabled = false"
                echo "sourcetype = ${stype}"
                echo "index = ${sidx}"
                echo "connection_host = dns"
            } >> "$conf_file"
        done
    fi

    chown "$SPLUNK_USER:$SPLUNK_GROUP" "$conf_file"
    chmod 600 "$conf_file"
    print_success "inputs.conf generated"
}

generate_outputs_conf() {
    has_role hf || return 0
    local conf_dir="$SPLUNK_HOME/etc/system/local"
    local conf_file="$conf_dir/outputs.conf"
    mkdir -p "$conf_dir"
    [[ -f "$conf_file" ]] && cp "$conf_file" "${conf_file}.bak.$(date +%Y%m%d%H%M%S)"

    cat > "$conf_file" <<EOF
# Splunk Enterprise outputs.conf
# Generated by splunk-enterprise-manager.sh v${SCRIPT_VERSION}

[tcpout]
defaultGroup = indexers
forwardedindex.filter.disable = true
indexAndForward = false

[tcpout:indexers]
server = ${ROLE_CONFIG[indexer_list]}
autoLBFrequency = 30
autoLBVolume = 1048576
useACK = true
EOF

    chown "$SPLUNK_USER:$SPLUNK_GROUP" "$conf_file"
    chmod 600 "$conf_file"
    print_success "outputs.conf generated"
}

generate_web_conf() {
    local web_port="${ROLE_CONFIG[web_port]:-}"
    # Generate web.conf if any role wants a specific web port, or we're disabling web for clustered indexer
    local needs_web=false
    [[ -n "$web_port" ]] && needs_web=true
    if has_role indexer && [[ "$CLUSTER_MODE" == "clustered" ]]; then
        needs_web=true
    fi
    [[ "$needs_web" == false ]] && return 0

    local conf_dir="$SPLUNK_HOME/etc/system/local"
    local conf_file="$conf_dir/web.conf"
    mkdir -p "$conf_dir"
    [[ -f "$conf_file" ]] && cp "$conf_file" "${conf_file}.bak.$(date +%Y%m%d%H%M%S)"

    {
        echo "# Splunk Enterprise web.conf"
        echo "# Generated by splunk-enterprise-manager.sh v${SCRIPT_VERSION}"
        echo ""
        echo "[settings]"
        [[ -n "$web_port" ]] && echo "httpport = ${web_port}"
        echo "enableSplunkWebSSL = true"
        # Disable web UI on clustered indexers (best practice), unless SH/DS/MC also on this host
        if has_role indexer && [[ "$CLUSTER_MODE" == "clustered" ]] && \
           ! has_role searchhead && ! has_role ds && ! has_role mc; then
            echo "startwebserver = false"
            print_tip "Web UI disabled (clustered indexer, no other web-serving role)"
        fi
    } > "$conf_file"

    chown "$SPLUNK_USER:$SPLUNK_GROUP" "$conf_file"
    chmod 600 "$conf_file"
    print_success "web.conf generated"
}

generate_user_seed() {
    local conf_dir="$SPLUNK_HOME/etc/system/local"
    local f="$conf_dir/user-seed.conf"
    mkdir -p "$conf_dir"
    local admin_pass="${ROLE_CONFIG[admin_password]:-}"
    if [[ -z "$admin_pass" ]]; then
        print_error "No admin password set in ROLE_CONFIG"
        return 1
    fi
    cat > "$f" <<EOF
[user_info]
USERNAME = admin
PASSWORD = ${admin_pass}
EOF
    chmod 600 "$f"
    chown "$SPLUNK_USER:$SPLUNK_GROUP" "$f"
    print_success "user-seed.conf written (consumed & deleted by splunkd on first start)"
}

generate_all_configs() {
    print_section "Generating configuration"
    generate_server_conf
    generate_indexes_conf
    generate_inputs_conf
    generate_outputs_conf
    generate_web_conf
    generate_user_seed
    if [[ -d "$SPLUNK_HOME/etc/system/local" ]]; then
        chown -Rh "$SPLUNK_USER:$SPLUNK_GROUP" "$SPLUNK_HOME/etc/system/local"
    fi
    print_success "All configs generated"
}

###############################################################################
# SECTION 16: INSTALL
###############################################################################

install_splunk() {
    print_header "Installing Splunk Enterprise"

    if [[ "$INSTALLER_TYPE" == "tgz" ]]; then
        print_step "Extracting TGZ to /opt/ ..."
        tar -xzf "$TGZ_FILE" -C /opt/ || { print_error "TGZ extraction failed"; return 1; }
        print_success "Extracted to $SPLUNK_HOME"
    else
        print_step "Installing RPM..."
        # Use rpm directly for local Splunk RPMs. Two known harmless warnings are
        # filtered from output:
        #   - "chown: cannot dereference" — symlink target not yet created
        #   - "remove failed: no such file or directory" — old-version files already gone
        local rpm_output="" rpm_exit=0
        rpm_output=$(rpm -Uvh --replacepkgs "$RPM_FILE" 2>&1) || rpm_exit=$?
        local real_errors
        real_errors=$(echo "$rpm_output" \
            | grep -v 'chown: cannot dereference' \
            | grep -v 'remove failed: [Nn]o such file or directory' \
            | grep -iE '^error|^fatal' 2>/dev/null || true)

        if [[ $rpm_exit -eq 0 ]] || [[ -z "$real_errors" ]]; then
            echo "$rpm_output" \
                | grep -v 'chown: cannot dereference' \
                | grep -v 'remove failed: [Nn]o such file or directory' || true
            local chown_n remove_n
            chown_n=$(echo "$rpm_output" | grep -c 'chown: cannot dereference' 2>/dev/null || echo 0)
            remove_n=$(echo "$rpm_output" | grep -c 'remove failed: [Nn]o such file or directory' 2>/dev/null || echo 0)
            if (( chown_n > 0 || remove_n > 0 )); then
                print_warning "Filtered harmless RPM scriptlet warnings: ${chown_n} chown, ${remove_n} remove"
                print_tip "Use TGZ format to avoid these entirely."
            fi
        elif command_exists dnf; then
            print_warning "rpm -Uvh failed, retrying with dnf (repos disabled)..."
            dnf install -y --disablerepo="*" "$RPM_FILE" || { print_error "RPM install failed"; return 1; }
        elif command_exists yum; then
            yum install -y --disablerepo="*" "$RPM_FILE" || { print_error "RPM install failed"; return 1; }
        else
            print_error "RPM install failed"
            echo "$rpm_output"
            return 1
        fi
        print_success "RPM installed"
    fi

    if [[ ! -x "$SPLUNK_HOME/bin/splunk" ]]; then
        print_error "splunk binary missing after install"
        return 1
    fi
    print_success "Splunk Enterprise installed to $SPLUNK_HOME"
}

###############################################################################
# SECTION 17: SERVICE CONFIG — enable boot-start (no start), then systemctl start
###############################################################################

configure_service_fresh() {
    print_section "Configuring systemd service"

    # Clean up any stale unit from prior installs that references a wrong user/group
    local svc
    for svc in "/etc/systemd/system/${SERVICE_NAME}.service" "/usr/lib/systemd/system/${SERVICE_NAME}.service"; do
        if [[ -f "$svc" ]]; then
            local old_user; old_user=$(grep -oP '^User=\K\S+' "$svc" 2>/dev/null) || true
            if [[ -n "$old_user" ]] && [[ "$old_user" != "$SPLUNK_USER" ]]; then
                print_warning "Existing unit has User=$old_user, updating"
                sed -i "s/^User=.*/User=${SPLUNK_USER}/" "$svc"
                sed -i "s/^Group=.*/Group=${SPLUNK_GROUP}/" "$svc"
            fi
        fi
    done

    print_step "Running: splunk enable boot-start (writes unit file, no service start)"
    if ! timeout 30 "$SPLUNK_HOME/bin/splunk" enable boot-start \
            -systemd-managed 1 \
            -user "$SPLUNK_USER" -group "$SPLUNK_GROUP" \
            --accept-license --answer-yes --no-prompt 2>/dev/null; then
        print_warning "boot-start returned non-zero (often OK on Splunk 10.x)"
    fi

    detect_service_name
    print_status "Service unit: $SERVICE_NAME"

    # Fix ownership (configs have been written as root so far)
    fix_ownership
    apply_selinux_contexts

    safe_systemctl daemon-reload
    safe_systemctl enable "$SERVICE_NAME" 2>/dev/null || true

    print_step "Starting $SERVICE_NAME..."
    if ! safe_systemctl start "$SERVICE_NAME"; then
        print_error "Service failed to start. Try: journalctl -u $SERVICE_NAME -n 200"
        return 1
    fi

    # Wait for splunkd to become ready (consumes user-seed.conf, generates secret,
    # encrypts plaintext pass4SymmKeys in server.conf)
    print_step "Waiting for Splunk to be ready..."
    local retries=0
    while (( retries < 30 )); do
        if run_as_splunk 15 "$SPLUNK_HOME/bin/splunk status" >/dev/null 2>&1; then
            print_success "Splunk is running"
            return 0
        fi
        retries=$((retries + 1))
        sleep 2
    done
    print_warning "Status check timed out; process may still be initializing"
    pgrep -x splunkd >/dev/null && { print_success "splunkd process is up"; return 0; }
    return 1
}

stop_splunk() {
    print_status "Stopping Splunk..."
    safe_systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sleep 2
    [[ -x "$SPLUNK_HOME/bin/splunk" ]] && run_as_splunk 30 "$SPLUNK_HOME/bin/splunk stop" 2>/dev/null || true
    sleep 2
    pkill -x splunkd 2>/dev/null || true
    sleep 3
    if pgrep -x splunkd >/dev/null 2>&1; then
        print_warning "Force-killing remaining splunkd"
        pkill -9 -x splunkd 2>/dev/null || true
        sleep 2
    fi
    pgrep -x splunkd >/dev/null && { print_error "Could not stop all splunkd"; return 1; }
    print_success "Splunk stopped"
}

###############################################################################
# SECTION 18: FRESH INSTALL, UPGRADE, SIMPLE UPDATE, REPAIR, REMOVE, RECONFIGURE
###############################################################################

perform_fresh_install() {
    print_header "Fresh installation"

    run_wizard_with_review

    print_step "Step 1/6: Prepare"
    ensure_splunk_user || return 1
    configure_firewall

    print_step "Step 2/6: Install binaries"
    install_splunk || return 1
    fix_ownership

    print_step "Step 3/6: Generate configuration"
    generate_all_configs

    print_step "Step 4/6: SELinux contexts"
    apply_selinux_contexts

    print_step "Step 5/6: Enable service & start"
    configure_service_fresh || return 1

    if has_role searchhead && [[ "$SHC_MODE" == "captain" ]]; then
        generate_bootstrap_command
    fi

    # Handle license file import if provided
    if has_role lm && [[ -n "${ROLE_CONFIG[license_file]:-}" ]] && [[ -f "${ROLE_CONFIG[license_file]}" ]]; then
        print_status "License file at ${ROLE_CONFIG[license_file]} — import via UI or 'splunk add licenses'"
    fi

    print_step "Step 6/6: Verify"
    verify_deployment
    display_final_status
    return 0
}

generate_bootstrap_command() {
    print_header "SHC Captain Bootstrap"
    echo "  Run AFTER all SHC members are up:"
    local members="${ROLE_CONFIG[shc_member_uris]:-https://sh1:8089,https://sh2:8089}"
    echo -e "    ${GREEN}$SPLUNK_HOME/bin/splunk bootstrap shcluster-captain \\${NC}"
    echo -e "    ${GREEN}  -servers_list \"${members}\" \\${NC}"
    echo -e "    ${GREEN}  -auth admin:<password>${NC}"
    local f="$SPLUNK_HOME/etc/shc_bootstrap_command.txt"
    {
        echo "# SHC Captain Bootstrap — generated $(date)"
        echo "$SPLUNK_HOME/bin/splunk bootstrap shcluster-captain -servers_list \"${members}\" -auth admin:<password>"
    } > "$f"
    chown "$SPLUNK_USER:$SPLUNK_GROUP" "$f"
    chmod 600 "$f"
    print_status "Saved: $f"
}

perform_upgrade() {
    print_header "In-place upgrade"
    get_current_version
    [[ -z "$CURRENT_VERSION" ]] && { print_error "Cannot determine current version"; return 1; }
    print_status "Current: $CURRENT_VERSION → Package: $NEW_VERSION"

    echo ""
    echo "  Splunk recommends upgrading tiers in this order:"
    echo "    DS (down) → CM+LM → SHs → Indexers → HF → DS (up) → UFs"
    echo "  See --topology for details."
    echo ""
    confirm "Proceed with upgrade on this host ($HOSTNAME)?" || return 0

    # Detect any existing installed roles so the user is reminded of what's here
    local detected; detected=$(detect_installed_roles) || true
    [[ -n "$detected" ]] && print_status "Detected roles on this host: $detected"

    select_backup_or_create "backup"
    local backup_dir="$SELECTED_BACKUP_DIR"

    stop_splunk || true

    install_splunk || {
        print_error "Upgrade failed — restoring backup"
        restore_from_backup "$backup_dir"
        return 1
    }

    restore_from_backup "$backup_dir"
    fix_ownership

    # Re-enable boot-start so the unit file reflects current install
    timeout 30 "$SPLUNK_HOME/bin/splunk" enable boot-start \
        -systemd-managed 1 \
        -user "$SPLUNK_USER" -group "$SPLUNK_GROUP" \
        --accept-license --answer-yes --no-prompt 2>/dev/null || true

    detect_service_name
    apply_selinux_contexts
    safe_systemctl daemon-reload

    # Start via systemctl (Splunk 10.x refuses `splunk start` when systemd-managed)
    local start_ok=false
    local svc_try
    for svc_try in "$SERVICE_NAME" Splunkd splunkd splunk; do
        if safe_systemctl start "$svc_try" 2>/dev/null; then
            SERVICE_NAME="$svc_try"
            start_ok=true
            break
        fi
    done

    if [[ "$start_ok" != true ]] && pgrep -x splunkd >/dev/null 2>&1; then
        print_warning "Already running (started during migration)"
        start_ok=true
    fi

    if [[ "$start_ok" != true ]]; then
        print_error "Service did not start via systemctl. Check: journalctl -xeu $SERVICE_NAME"
        echo "  Manual start:"
        echo "    sudo su - $SPLUNK_USER"
        echo "    $SPLUNK_HOME/bin/splunk start"
        return 0
    fi

    get_current_version
    print_success "Upgrade complete: now running v$CURRENT_VERSION"
    verify_deployment
}

perform_simple_update() {
    print_header "Simple update (binary only)"
    echo "  Replaces binaries while preserving all configurations."
    echo ""

    get_current_version
    [[ -z "$CURRENT_VERSION" ]] && { print_error "No existing install"; return 1; }
    find_splunk_installer || return 1
    if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
        print_warning "Already on v$CURRENT_VERSION"
        return 0
    fi
    check_disk_space || return 1
    confirm "Update $CURRENT_VERSION → $NEW_VERSION?" || return 0

    select_backup_or_create "binupdate"
    local backup_dir="$SELECTED_BACKUP_DIR"

    stop_splunk || true
    install_splunk || {
        print_error "Update failed — restoring backup"
        restore_from_backup "$backup_dir"
        return 1
    }
    restore_from_backup "$backup_dir"
    fix_ownership

    timeout 30 "$SPLUNK_HOME/bin/splunk" enable boot-start \
        -systemd-managed 1 \
        -user "$SPLUNK_USER" -group "$SPLUNK_GROUP" \
        --accept-license --answer-yes --no-prompt 2>/dev/null || true
    detect_service_name
    apply_selinux_contexts
    safe_systemctl daemon-reload
    safe_systemctl start "$SERVICE_NAME" || { print_error "Service failed to start"; return 1; }

    get_current_version
    print_success "Simple update complete: now running v$CURRENT_VERSION"
    verify_deployment
}

perform_repair() {
    print_header "Repair"
    echo "  Diagnoses and re-installs over a corrupt/partial Splunk install."
    echo "  Preserves this host's own configs and splunk.secret."
    echo ""
    confirm "Proceed?" || return 0
    check_disk_space || return 1

    find_splunk_installer || return 1
    select_backup_or_create "repair"
    local backup_dir="$SELECTED_BACKUP_DIR"

    stop_splunk || true
    rpm -qa 2>/dev/null | grep -q '^splunk-' && rpm -e splunk 2>/dev/null || true
    # Don't rm -rf SPLUNK_HOME here — let the installer overwrite; configs restored after.

    install_splunk || return 1
    ensure_splunk_user
    restore_from_backup "$backup_dir"
    fix_ownership

    timeout 30 "$SPLUNK_HOME/bin/splunk" enable boot-start \
        -systemd-managed 1 \
        -user "$SPLUNK_USER" -group "$SPLUNK_GROUP" \
        --accept-license --answer-yes --no-prompt 2>/dev/null || true
    detect_service_name
    apply_selinux_contexts
    safe_systemctl daemon-reload
    safe_systemctl start "$SERVICE_NAME" || { print_error "Service failed to start"; return 1; }

    verify_deployment
    print_success "Repair complete"
}

perform_remove() {
    print_header "Remove Splunk Enterprise"
    echo "  Stops service, uninstalls package, removes $SPLUNK_HOME and systemd unit."
    echo ""
    if [[ "$SKIP_CONFIRMATION" != true ]]; then
        if confirm "Back up configs before removing?"; then
            local backup_dir="/tmp/splunk_remove_$(date +%Y%m%d%H%M%S)"
            mkdir -p "$backup_dir"
            [[ -d "$SPLUNK_HOME/etc" ]] && cp -a "$SPLUNK_HOME/etc" "$backup_dir/" 2>/dev/null || true
            [[ -f "$SPLUNK_HOME/etc/auth/splunk.secret" ]] && cp -a "$SPLUNK_HOME/etc/auth/splunk.secret" "$backup_dir/" 2>/dev/null || true
            print_success "Backed up to: $backup_dir"
        fi
        confirm "Proceed with removal?" || return 0
    fi

    stop_splunk || true
    detect_service_name
    safe_systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rpm -qa 2>/dev/null | grep -q '^splunk-' && rpm -e splunk 2>/dev/null || true
    [[ -d "$SPLUNK_HOME" ]] && rm -rf "$SPLUNK_HOME"
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
    safe_systemctl daemon-reload 2>/dev/null || true
    print_success "Splunk Enterprise removed"
}

perform_reconfigure() {
    print_header "Reconfigure"
    [[ -x "$SPLUNK_HOME/bin/splunk" ]] || { print_error "No existing install"; return 1; }
    echo "  Regenerates configs for the selected role(s). The service will be restarted."
    echo ""
    select_backup_or_create "reconfig"
    stop_splunk || true

    if [[ ${#SELECTED_ROLES[@]} -eq 0 ]]; then
        select_roles_interactive
    else
        validate_role_combination
    fi
    run_role_wizards
    review_configuration
    confirm "Apply new configuration?" || return 0

    generate_all_configs
    configure_firewall
    fix_ownership
    apply_selinux_contexts

    detect_service_name
    safe_systemctl daemon-reload
    safe_systemctl start "$SERVICE_NAME" || { print_error "Service failed to start"; return 1; }
    verify_deployment
    print_success "Reconfigure complete"
}

###############################################################################
# SECTION 19: ROLE DETECTION FROM INSTALLED CONFIG
###############################################################################

detect_installed_roles() {
    local detected=()
    local srv="$SPLUNK_HOME/etc/system/local/server.conf"
    if [[ -f "$srv" ]]; then
        grep -qE '^\s*mode\s*=\s*manager' "$srv" 2>/dev/null && detected+=(cm)
        grep -qE '^\s*mode\s*=\s*peer'    "$srv" 2>/dev/null && detected+=(indexer)
        grep -qE '^\[shclustering\]'      "$srv" 2>/dev/null && detected+=(searchhead-or-deployer)
    fi
    [[ -d "$SPLUNK_HOME/etc/deployment-apps" ]] && detected+=(ds)
    [[ -d "$SPLUNK_HOME/etc/shcluster" ]]       && detected+=(deployer)
    [[ -f "$SPLUNK_HOME/etc/system/local/outputs.conf" ]] && detected+=(hf-or-forwarder)
    local IFS=','
    echo "${detected[*]}"
}

###############################################################################
# SECTION 20: VERIFICATION
###############################################################################

verify_deployment() {
    print_header "Verification"
    detect_service_name
    local ok=true

    if safe_systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "Service active: $SERVICE_NAME"
    else
        print_error "Service not active"
        ok=false
    fi

    if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
        get_current_version
        print_success "Version: $CURRENT_VERSION"
    else
        print_error "splunk binary missing"; ok=false
    fi

    if id "$SPLUNK_USER" >/dev/null 2>&1; then
        print_success "User $SPLUNK_USER present"
    else
        print_error "User $SPLUNK_USER missing"; ok=false
    fi

    for f in server.conf; do
        if [[ -f "$SPLUNK_HOME/etc/system/local/$f" ]]; then
            print_success "$f present"
        else
            print_warning "$f missing"
        fi
    done

    if [[ -f "$SPLUNK_HOME/etc/auth/splunk.secret" ]]; then
        print_success "Per-host splunk.secret present"
    else
        print_error "splunk.secret missing"; ok=false
    fi

    # Ownership
    local wrong
    wrong=$(find "$SPLUNK_HOME" ! -user "$SPLUNK_USER" 2>/dev/null | wc -l)
    (( wrong == 0 )) && print_success "Ownership OK" || print_warning "$wrong files not owned by $SPLUNK_USER"

    verify_role_config
    [[ "$ok" == true ]] && print_success "Verification passed" || print_warning "Verification had issues"
}

verify_role_config() {
    local srv="$SPLUNK_HOME/etc/system/local/server.conf"
    [[ -f "$srv" ]] || return 0
    local r
    for r in "${SELECTED_ROLES[@]}"; do
        case "$r" in
            cm)
                grep -q '^\[clustering\]' "$srv" && grep -q 'mode = manager' "$srv" \
                    && print_success "Role cm: clustering stanza present" \
                    || print_warning "Role cm: clustering stanza missing/wrong"
                ;;
            indexer)
                if [[ "$CLUSTER_MODE" == "clustered" ]]; then
                    grep -q 'mode = peer' "$srv" \
                        && print_success "Role indexer: peer mode set" \
                        || print_warning "Role indexer: peer mode missing"
                fi
                ;;
            searchhead)
                if [[ "$SHC_MODE" == "captain" ]] || [[ "$SHC_MODE" == "member" ]]; then
                    grep -q '^\[shclustering\]' "$srv" \
                        && print_success "Role searchhead: shclustering stanza present" \
                        || print_warning "Role searchhead: shclustering stanza missing"
                fi
                ;;
        esac
    done
}

display_final_status() {
    print_header "Final Status"
    echo "  Host:       $HOSTNAME"
    echo "  Roles:      ${SELECTED_ROLES[*]}"
    echo "  Version:    $CURRENT_VERSION"
    echo "  Service:    $SERVICE_NAME"
    echo ""
    echo "  Next steps:"
    echo "    - Confirm service: systemctl status $SERVICE_NAME"
    echo "    - Review logs:     $SPLUNK_HOME/var/log/splunk/splunkd.log"
    if has_role cm; then
        echo "    - CM dashboard:    https://${HOSTNAME}:${ENV_MGMT_PORT} (admin)"
    fi
    if has_role searchhead; then
        echo "    - SH web UI:       https://${HOSTNAME}:${ROLE_CONFIG[web_port]:-$ENV_WEB_PORT}"
    fi
    if has_role lm && [[ -n "${ROLE_CONFIG[license_file]:-}" ]]; then
        echo "    - Add license:     $SPLUNK_HOME/bin/splunk add licenses ${ROLE_CONFIG[license_file]} -auth admin:<password>"
    fi
    if has_role searchhead && [[ "$SHC_MODE" == "captain" ]]; then
        echo "    - SHC bootstrap:   $SPLUNK_HOME/etc/shc_bootstrap_command.txt"
    fi
    echo ""
}

###############################################################################
# SECTION 21: MAIN: ARG PARSING, MENU, USAGE
###############################################################################

deploy_mode() {
    detect_os
    detect_splunk_user
    detect_service_name
    show_initial_prompt
    preflight_permission_check
    check_disk_space || exit 1
    find_splunk_installer || exit 1
    if [[ -x "$SPLUNK_HOME/bin/splunk" ]]; then
        detect_upgrade_scenario
        case "$INSTALL_METHOD" in
            UPGRADE|REINSTALL) perform_upgrade ;;
            SKIP)              print_status "Nothing to do"; return 0 ;;
            FRESH)             perform_fresh_install ;;
        esac
    else
        INSTALL_METHOD="FRESH"
        perform_fresh_install
    fi
}

verify_only_mode() {
    detect_os
    detect_splunk_user
    detect_service_name
    [[ -x "$SPLUNK_HOME/bin/splunk" ]] || { print_error "No install at $SPLUNK_HOME"; exit 1; }
    verify_deployment
}

show_usage() {
    cat <<EOF
Splunk Enterprise Manager v${SCRIPT_VERSION}

Usage: sudo bash $0 [options]

OPERATIONS:
  --install           Fresh install from scratch (runs role wizard)
  --upgrade           In-place upgrade to a newer version (preserves configs)
  --simple-update     Binary-only swap for same-config minor updates
  --repair            Re-install over a corrupt or partial install
  --remove            Uninstall Splunk and remove all files
  --reconfigure       Change role(s) or regenerate configs on existing install
  --verify            Read-only health check (no changes)
  --topology          Show generic topology and upgrade order reference

For a longer explanation of any mode:
  $0 --help-mode <install|upgrade|simple-update|repair|remove|reconfigure|verify|topology>

FLAGS:
  --role r1,r2,...    Pre-select role(s): cm, indexer, searchhead, ds,
                      deployer, hf, lm, mc (comma-separated, no spaces)
  -y, --yes           Skip confirmations (non-interactive)
  -r, --reinstall     Force reinstall (allows downgrade, forces same-version)
  -h, --help          This help
  --help-mode <mode>  Detailed explanation of a specific mode

ENVIRONMENT OVERRIDES (export before running, use sudo -E):
  SPLUNK_HOME           Install directory (default: /opt/splunk)
  SPLUNK_USER_OVERRIDE  Force a specific service account
  ADMIN_PASSWORD        Admin password (wizard prompts if unset)
  ENV_CM_HOST, ENV_DS_HOST, ENV_IDX01_HOST, ENV_IDX02_HOST
  ENV_SH_HOST, ENV_HF_HOST, ENV_LM_HOST, ENV_MC_HOST
  ENV_MGMT_PORT, ENV_WEB_PORT, ENV_RECV_PORT, ENV_REPL_PORT, ENV_SHC_REPL_PORT

ROLES:
  cm          Cluster Manager — manages indexer clustering
  indexer     Indexer (clustered peer or standalone — wizard asks)
  searchhead  Search Head (SHC captain, SHC member, or standalone)
  ds          Deployment Server — pushes apps to forwarders
  deployer    SHC Deployer — pushes apps to SHC members
  hf          Heavy Forwarder — full Splunk instance forwarding data
  lm          License Manager — holds the enterprise license file
  mc          Monitoring Console — monitors the deployment

COMMON EXAMPLES:
  sudo -E bash $0 --install --role cm,lm -y
  sudo -E bash $0 --install --role ds,mc
  sudo -E bash $0 --upgrade
  sudo -E bash $0 --reconfigure --role cm,lm,ds,mc
  sudo -E bash $0 --verify
EOF
}

show_help_mode() {
    local mode="$1"
    case "$mode" in
        install)
            cat <<'EOF'
--install: Fresh installation

WHEN TO USE
  You are setting up Splunk Enterprise on a server that does not already
  have it installed. If a previous install exists, use --upgrade, --repair,
  or --reconfigure instead.

WHAT IT DOES (in order)
  1. Runs preflight checks (disk space, installer present, permissions)
  2. Detects the OS and chooses the right install path
  3. Prompts for role(s) unless --role was given on the command line
  4. Runs each role's wizard to collect hostnames, ports, pass4SymmKeys,
     and the admin password (admin password can be set via ADMIN_PASSWORD
     env var to skip the prompt)
  5. Creates the service user (splunk by default) if missing
  6. Opens firewall ports specific to the selected role(s)
  7. Installs the package (RPM or TGZ, auto-detected from /tmp/splunkinstall)
  8. Generates server.conf, indexes.conf, inputs.conf, outputs.conf,
     web.conf, and user-seed.conf based on role(s)
  9. Enables boot-start (writes the systemd unit, does NOT start splunkd)
 10. Fixes ownership on $SPLUNK_HOME and applies SELinux contexts
 11. Starts splunkd via systemctl — splunkd generates its own per-host
     splunk.secret, consumes user-seed.conf to create the admin account,
     encrypts plaintext pass4SymmKeys in server.conf in place, and begins
     operating
 12. Runs verification

SECRETS
  Every host generates its own unique splunk.secret on first start. This
  script does NOT import secrets from other hosts. pass4SymmKeys are
  written plaintext to server.conf and encrypted by splunkd on first start.

SAFETY
  Refuses to overwrite an existing $SPLUNK_HOME unless you also pass
  --reinstall (-r).
EOF
            ;;
        upgrade)
            cat <<'EOF'
--upgrade: In-place version upgrade

WHEN TO USE
  You already have Splunk Enterprise installed and you want to move to a
  newer version. Your roles, configs, apps, and the host's own splunk.secret
  are preserved.

WHAT IT DOES
  1. Detects the current installed version and compares it to the installer
     version you staged in /tmp/splunkinstall
  2. Refuses downgrades unless --reinstall is passed
  3. Offers to use an existing backup in /tmp if one is found, or creates
     a fresh timestamped backup of etc/ and the host's own splunk.secret
  4. Stops the Splunk service cleanly (systemctl first, then splunk stop,
     then pkill as a last resort)
  5. Installs the new binaries over the existing install (RPM -Uvh or
     TGZ extracted over /opt/)
  6. Restores configs from the backup (this host's own configs and its
     own splunk.secret — never a shared secret from another host)
  7. Re-runs splunk enable boot-start to refresh the systemd unit file
  8. Starts the service via systemctl

WHAT IT PRESERVES
  Everything in etc/ (server.conf, apps, indexes, inputs, outputs, users,
  authentication), and the host's own splunk.secret so existing encrypted
  values in conf files stay decryptable.

WHAT IT DOES NOT DO
  Does not re-run the role wizard. Does not change server.conf content.
  Does not touch var/ (indexes, data, checkpoints). Does not restart the
  deployment server or cluster manager automatically — follow Splunk's
  documented upgrade order across your environment.

IF SOMETHING GOES WRONG
  The backup is kept in /tmp/splunk_backup_<timestamp>/. You can manually
  restore or use --repair.
EOF
            ;;
        simple-update)
            cat <<'EOF'
--simple-update: Binary-only update, no config regen

WHEN TO USE
  You want to swap binaries between two close versions (for example
  9.4.5 → 9.4.6) and you're confident no config format changes are required.
  Lighter-weight than --upgrade because it does no scenario analysis.

WHAT IT DOES
  1. Gets the current installed version
  2. Finds the installer in /tmp/splunkinstall
  3. If current == new, exits as a no-op
  4. Creates a fresh backup of etc/ and the host's own splunk.secret
  5. Stops the service, installs the new binaries, restores the backup
  6. Re-enables boot-start and starts the service

WHAT IT DOES NOT DO
  Does not refuse downgrades (use --upgrade if you want that safety).
  Does not re-run wizards. Does not change configs. Does not reconfigure
  firewall rules.

WHEN NOT TO USE
  Cross-major-version updates (8.x → 9.x → 10.x). Use --upgrade instead
  so you get the version-sanity checks and restore guarantees.
EOF
            ;;
        repair)
            cat <<'EOF'
--repair: Repair a corrupt or partial install

WHEN TO USE
  Splunk won't start, files are missing, an RPM upgrade was interrupted,
  or a disk event corrupted the install. You want to recover without
  losing your configs or starting from scratch.

WHAT IT DOES
  1. Finds an installer in /tmp/splunkinstall
  2. Creates a timestamped backup of what survives in etc/ and the
     host's own splunk.secret
  3. Stops any running Splunk processes (systemctl, then pkill)
  4. Removes the RPM registration (if any), but NOT the files in place
  5. Re-installs the package — the installer replaces missing or damaged
     files, preserves existing ones where possible
  6. Ensures the splunk service user still exists
  7. Restores the backup (configs + host's own secret) in case the
     reinstall overwrote anything
  8. Fixes ownership, restores SELinux contexts
  9. Re-enables boot-start and starts the service

WHAT IT PRESERVES
  Everything in etc/ that was intact, plus the host's own splunk.secret.
  Data in var/ is untouched.

WHAT IT DOES NOT DO
  Does not wipe $SPLUNK_HOME. Does not re-run wizards. If your install
  is so broken that you want to start clean, use --remove then --install.
EOF
            ;;
        remove)
            cat <<'EOF'
--remove: Full uninstall

WHEN TO USE
  You are decommissioning Splunk on this host, or you want a clean slate
  before reinstalling from scratch.

WHAT IT DOES
  1. Offers to back up etc/ and the host's own splunk.secret to
     /tmp/splunk_remove_<timestamp>/ first (skip with --yes)
  2. Stops the Splunk service (systemctl, then splunk stop, then pkill)
  3. Disables the systemd unit
  4. Uninstalls the RPM if present
  5. Removes the systemd unit file from /etc/systemd/system/
  6. Deletes $SPLUNK_HOME entirely, including var/ and all indexed data
  7. Runs systemctl daemon-reload

WARNING
  This deletes ALL indexed data in $SPLUNK_HOME/var/. If you need any of
  it, copy it out before running this, or accept the backup-configs offer
  and separately back up var/ yourself. The backup this script takes is
  configs-only by default.

WHAT IT DOES NOT DO
  Does not remove the splunk service user account (useradd -r user is
  left behind so its UID can be reused). Does not touch firewall rules
  (the ports opened during install stay open). Does not remove the
  license file from any separate LM host.
EOF
            ;;
        reconfigure)
            cat <<'EOF'
--reconfigure: Change roles or regenerate configs on an existing install

WHEN TO USE
  Your binary install is fine, but you want to:
    - Add a role (e.g., make your DS also serve as MC)
    - Remove a role you no longer want
    - Change your pass4SymmKey or cluster labels
    - Change hostnames or ports after moving to new infra
    - Rebuild server.conf from scratch after manual editing went wrong

WHAT IT DOES
  1. Verifies Splunk is installed
  2. Creates a timestamped backup of the current configs
  3. Stops the service
  4. Runs the role selection wizard (unless --role was given)
  5. Runs each selected role's wizard to collect fresh values
  6. Regenerates server.conf, indexes.conf, inputs.conf, outputs.conf,
     web.conf (old versions saved as .bak.<timestamp> in the same dir)
  7. Applies firewall rules for the new role set
  8. Fixes ownership and SELinux contexts
  9. Starts the service and runs verification

WHAT IT DOES NOT DO
  Does not reinstall binaries. Does not touch the admin password (if you
  want to change it, use splunk edit user admin). Does not migrate data
  from one role to another — if you change an indexer to a search head,
  you are responsible for the data implications.

USE CASES
  - ds → ds,mc       Add the Monitoring Console to your DS
  - cm → cm,lm       Consolidate the License Manager onto the CM
  - indexer (standalone) → indexer (clustered)  Join an existing cluster
EOF
            ;;
        verify)
            cat <<'EOF'
--verify: Read-only health check

WHEN TO USE
  After any install, upgrade, or config change. Or as a periodic drift
  check. Makes no changes to the system.

WHAT IT CHECKS
  1. The Splunk service is active (systemctl is-active)
  2. The splunk binary exists and reports its version
  3. The service user ($SPLUNK_USER) exists
  4. server.conf is present
  5. splunk.secret exists (per-host secret)
  6. Ownership of $SPLUNK_HOME matches the service user (reports count of
     files owned by other users)
  7. For each role the host is configured for, checks that the expected
     stanzas are in server.conf (e.g., [clustering] mode=manager for cm,
     [shclustering] for searchhead in SHC, etc.)

WHAT IT DOES NOT CHECK
  Does not check network connectivity to peers or the DS (this script
  doesn't know your full topology). Does not check license validity.
  Does not check cluster health (use the CM dashboard). Does not check
  data ingestion or search functionality.

EXIT CODE
  0 if everything passed. Non-zero is NOT returned on warnings — this
  mode is informational. Read the output.
EOF
            ;;
        topology)
            cat <<'EOF'
--topology: Print topology reference

WHEN TO USE
  You want to see the generic environment layout this script assumes and
  Splunk's canonical upgrade order for a distributed deployment. No
  changes are made to the system.

WHAT IT SHOWS
  1. Placeholder hostnames for each role (override via ENV_* env vars)
  2. Standard Splunk port numbers used across the script
  3. Splunk's recommended tiered upgrade order for a full distributed
     deployment (DS → CM+LM → SHs → Indexers → HF → DS restart → UFs)

PURPOSE
  Reference material. Useful as a reminder before starting a coordinated
  upgrade across multiple servers, or for onboarding someone to the
  environment conventions used in this script.
EOF
            ;;
        *)
            print_error "Unknown mode: $mode"
            echo "Valid modes: install, upgrade, simple-update, repair, remove, reconfigure, verify, topology"
            return 1
            ;;
    esac
}

show_menu() {
    detect_os
    detect_splunk_user
    detect_service_name
    while true; do
        show_banner
        echo "  Splunk Enterprise Manager — Main Menu"
        echo ""
        echo "    1) Install (fresh)"
        echo "    2) Upgrade"
        echo "    3) Simple update (binary only)"
        echo "    4) Reconfigure"
        echo "    5) Repair"
        echo "    6) Remove"
        echo "    7) Verify"
        echo "    8) Show topology & upgrade order"
        echo "    9) Help"
        echo "    0) Exit"
        echo ""
        read -rp "Option: " c
        case "$c" in
            1) perform_fresh_install;   read -rp "ENTER..." _ ;;
            2) find_splunk_installer && perform_upgrade; read -rp "ENTER..." _ ;;
            3) perform_simple_update;   read -rp "ENTER..." _ ;;
            4) perform_reconfigure;     read -rp "ENTER..." _ ;;
            5) perform_repair;          read -rp "ENTER..." _ ;;
            6) perform_remove;          read -rp "ENTER..." _ ;;
            7) verify_only_mode;        read -rp "ENTER..." _ ;;
            8) show_environment_topology; read -rp "ENTER..." _ ;;
            9) show_usage;              read -rp "ENTER..." _ ;;
            0) exit 0 ;;
            *) print_error "Invalid"; sleep 1 ;;
        esac
    done
}

###############################################################################
# MAIN
###############################################################################

# Handle help flags before requiring root (they make no changes to the system)
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_usage; exit 0 ;;
    esac
done
# Handle --help-mode <mode> before root check
for (( i = 1; i <= $#; i++ )); do
    if [[ "${!i}" == "--help-mode" ]]; then
        next=$((i + 1))
        if (( next <= $# )); then
            show_help_mode "${!next}"; exit $?
        fi
        print_error "--help-mode requires a mode argument"
        echo "Valid modes: install, upgrade, simple-update, repair, remove, reconfigure, verify, topology"
        exit 1
    fi
done

check_root

# Parse args
ACTION=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --install)       ACTION=install; shift ;;
        --upgrade)       ACTION=upgrade; shift ;;
        --simple-update) ACTION=simple-update; shift ;;
        --repair)        ACTION=repair; shift ;;
        --remove)        ACTION=remove; shift ;;
        --reconfigure)   ACTION=reconfigure; shift ;;
        --verify)        ACTION=verify; VERIFY_ONLY=true; shift ;;
        --topology)      ACTION=topology; shift ;;
        --role)          parse_roles_string "$2" || exit 1; shift 2 ;;
        -y|--yes)        SKIP_CONFIRMATION=true; shift ;;
        -r|--reinstall)  FORCE_REINSTALL=true; shift ;;
        -h|--help)       show_usage; exit 0 ;;
        --help-mode)     show_help_mode "$2"; exit $? ;;
        *) print_error "Unknown option: $1"; show_usage; exit 1 ;;
    esac
done

if [[ -z "$ACTION" ]]; then
    show_menu
fi

# Action dispatch
detect_os
detect_splunk_user
detect_service_name

case "$ACTION" in
    install)
        show_initial_prompt
        preflight_permission_check
        check_disk_space || exit 1
        find_splunk_installer || exit 1
        perform_fresh_install
        ;;
    upgrade)
        find_splunk_installer || exit 1
        perform_upgrade
        ;;
    simple-update)
        perform_simple_update
        ;;
    repair)
        perform_repair
        ;;
    remove)
        perform_remove
        ;;
    reconfigure)
        perform_reconfigure
        ;;
    verify)
        verify_only_mode
        ;;
    topology)
        show_environment_topology
        ;;
esac
