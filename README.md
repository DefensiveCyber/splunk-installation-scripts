# Splunk Enterprise Manager

A multi-role lifecycle management script for Splunk Enterprise on RHEL-family Linux (RHEL, Rocky, AlmaLinux, Oracle Linux).

Handles fresh install, upgrade, repair, remove, and reconfiguration across eight Splunk roles, with support for combining multiple roles on one host (e.g., Cluster Manager + License Manager). Pairs with a companion Universal Forwarder manager script for endpoint/server forwarders.

---

## Table of contents

- [What this is](#what-this-is)
- [What this is not](#what-this-is-not)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Operations](#operations)
- [Roles](#roles)
- [Multi-role combinations](#multi-role-combinations)
- [Environment variables](#environment-variables)
- [Distributed upgrade order](#distributed-upgrade-order)
- [File locations](#file-locations)
- [Secret handling](#secret-handling)
- [Troubleshooting](#troubleshooting)
- [Companion: UF manager](#companion-uf-manager)

---

## What this is

A single Bash script that manages the full lifecycle of a Splunk Enterprise instance. It knows about the standard Splunk roles and can install multiple roles on the same host where that makes sense. It produces deterministic, role-aware configuration files and starts splunkd cleanly under systemd.

Key properties:

- **Generic environment.** Ships with placeholder hostnames (`cm.example.com`, `indexer01.example.com`, etc.) that are overridden via environment variables. No site-specific defaults baked in.
- **Multi-role.** Pick one role, two roles, or four roles on a single host. The script computes the union of required configuration stanzas, firewall ports, and verification checks.
- **Per-host secrets.** Every install generates its own `splunk.secret` on first start. The script never imports a shared secret from another host.
- **Correct sequencing.** Configs are pre-seeded as plaintext before first start. splunkd generates the secret, consumes `user-seed.conf`, and encrypts the plaintext `pass4SymmKey` values in place — in a single start, with no double-restart dance.
- **SELinux-aware.** Keeps SELinux in Enforcing mode throughout; uses `restorecon` after file operations rather than disabling SELinux during install.
- **Role-aware firewall.** `firewalld` rules are opened for the union of all roles' required ports, deduplicated.
- **Idempotent where it matters.** Systemd units, firewall rules, and configuration file updates are safe to re-run.

---

## What this is not

- **Not a UF installer.** Universal Forwarders have their own script — see [Companion: UF manager](#companion-uf-manager). This script manages full Splunk Enterprise instances only.
- **Not a cluster bootstrapper.** It configures a host to participate in an indexer cluster or search head cluster, but the cluster-wide coordination (bootstrapping a SHC captain, bringing indexer peers online, maintenance-mode toggling) is manual across hosts. See `--help-mode install` and `--topology` for the recommended order.
- **Not a cross-host orchestrator.** This script runs on one host at a time. Use your usual configuration management (Ansible, Puppet, Chef, Salt) to drive it across many hosts.
- **Not a data migration tool.** `--reconfigure` can change roles, but if you convert an indexer to a search head, you are responsible for the data implications.

---

## Requirements

- RHEL 8 or 9, Rocky Linux 8/9, AlmaLinux 8/9, or Oracle Linux 8/9
- Root access (the script re-exec's with sudo if needed in most flows — launch with `sudo -E` to preserve environment overrides)
- A Splunk Enterprise installer in `/tmp/splunkinstall/`, either `splunk-*.tgz` or `splunk-*.rpm` (not the UF installer)
- `firewalld` running, if you want automatic firewall rules (optional; skipped gracefully if not present)
- `bash` 4+, `systemd`, and standard GNU coreutils

Minimum free disk:
- `/tmp`: 2 GB
- `/opt`: 5 GB

---

## Quick start

**1. Stage the installer:**

```bash
sudo mkdir -p /tmp/splunkinstall
sudo cp splunk-10.0.3-abc123-Linux-x86_64.tgz /tmp/splunkinstall/
```

**2. Run:**

```bash
# Interactive menu
sudo -E ./splunk-enterprise-manager.sh

# Or specify roles directly
sudo -E ./splunk-enterprise-manager.sh --install --role cm,lm -y
```

**3. Verify:**

```bash
sudo ./splunk-enterprise-manager.sh --verify
```

Help:

```bash
./splunk-enterprise-manager.sh --help
./splunk-enterprise-manager.sh --help-mode install
./splunk-enterprise-manager.sh --help-mode upgrade
```

Help and `--help-mode` do not require root.

---

## Operations

All operations run against the local host only. Each operation has a full `--help-mode <name>` page with when-to-use, step-by-step behavior, what's preserved, and what's not.

| Flag | What it does |
|------|--------------|
| `--install` | Fresh install from scratch. Runs the role wizard, creates the service user, opens firewall ports, installs the package, generates all configs, enables boot-start, starts the service. Refuses to overwrite an existing install without `--reinstall`. |
| `--upgrade` | In-place version upgrade. Detects current vs. new version, refuses downgrades, backs up `etc/` and the host's own `splunk.secret`, stops the service, installs new binaries over the old ones, restores configs, restarts. Preserves roles, configs, apps, and the per-host secret. |
| `--simple-update` | Lighter binary-only swap. Same-version-format updates only (e.g. 9.4.5 → 9.4.6). Does not refuse downgrades or re-run wizards. Not for cross-major upgrades. |
| `--repair` | Recovers a corrupt or partial install. Re-runs the package install, restores surviving configs and the host's own secret from backup, fixes ownership and SELinux contexts, restarts the service. Does not wipe `$SPLUNK_HOME` or `var/`. |
| `--remove` | Full uninstall. Stops the service, offers a config backup, removes the RPM, deletes `$SPLUNK_HOME` (including indexed data in `var/`), removes the systemd unit. Leaves the service user account behind. |
| `--reconfigure` | Changes roles or regenerates configs on an existing install without reinstalling. Example uses: adding MC to an existing DS, changing `pass4SymmKey`, updating hostnames. Stops the service, re-runs the wizard, regenerates `server.conf` etc. (backing up the old ones), reapplies firewall rules, restarts. |
| `--verify` | Read-only health check. Confirms service is active, version is readable, service user exists, configs and secret are present, ownership is correct, role-specific stanzas are in `server.conf`. |
| `--topology` | Prints the generic topology reference and Splunk's distributed upgrade order. |

Flags:

| Flag | Meaning |
|------|---------|
| `--role r1,r2,...` | Pre-select one or more roles (comma-separated). Skips the role picker. |
| `-y`, `--yes` | Skip confirmations (non-interactive). |
| `-r`, `--reinstall` | Force reinstall. Also allows downgrade on `--upgrade`. |
| `-h`, `--help` | Summary help. Does not require root. |
| `--help-mode <mode>` | Detailed explanation of one operation. Does not require root. |

---

## Roles

Eight roles are supported. The role picker accepts any subset.

| Role | Name | What it does |
|------|------|--------------|
| `cm` | Cluster Manager | Manages indexer clustering. One per indexer cluster. |
| `indexer` | Indexer | Indexes and stores data. The wizard asks whether it's a clustered peer or standalone. |
| `searchhead` | Search Head | Runs searches against indexers. The wizard asks for SHC captain, SHC member, or standalone. |
| `ds` | Deployment Server | Pushes apps to Universal Forwarders and other deployment clients. |
| `deployer` | SHC Deployer | Pushes apps to Search Head Cluster members. Distinct from the Deployment Server. |
| `hf` | Heavy Forwarder | Full Splunk instance used as a forwarder, typically for syslog collection or parse-heavy inputs. The wizard collects indexer targets and syslog input ports. |
| `lm` | License Manager | Holds the Splunk Enterprise license file. Other instances point to it via `license_master_uri`. |
| `mc` | Monitoring Console | Monitors the health of the distributed deployment. Mostly UI-configured after install. |

---

## Multi-role combinations

Multiple roles on one host are supported. The script unions the config stanzas, firewall ports, and verification checks.

### Common combinations

**`cm,lm`** — Cluster Manager + License Manager. Standard management-tier combo.

```bash
sudo -E ./splunk-enterprise-manager.sh --install --role cm,lm
```

**`ds,mc`** — Deployment Server + Monitoring Console. Common second management-tier host.

```bash
sudo -E ./splunk-enterprise-manager.sh --install --role ds,mc
```

**`cm,lm,ds,mc`** — Consolidated management tier on a single host. Appropriate for lab, small deployments, or sites with one management box.

```bash
sudo -E ./splunk-enterprise-manager.sh --install --role cm,lm,ds,mc
```

**`deployer,mc`** — SHC Deployer + Monitoring Console.

**`hf`** alone — Heavy Forwarder, usually standalone on a collection tier.

### Combinations that get a warning (supported but discouraged)

These work but the script will warn:

- `indexer,searchhead` — Supported but discouraged in production. Search and indexing compete for CPU/memory/IO.
- `cm,indexer` — Fine for lab/test. Not recommended for production; loses the failure isolation between CM and the cluster it manages.
- `indexer,hf` — Unusual. Generally an indexer shouldn't be doing Heavy Forwarder duties.

The script proceeds regardless — these are not blocked, just flagged.

---

## Environment variables

Override defaults by exporting environment variables before running. Remember `sudo -E` to preserve them across the sudo boundary.

### Required-to-customize

| Variable | Default | Purpose |
|----------|---------|---------|
| `ADMIN_PASSWORD` | (wizard prompts) | Splunk admin password. If unset, wizard asks. |

### Topology placeholders

| Variable | Default |
|----------|---------|
| `ENV_CM_HOST` | `cm.example.com` |
| `ENV_DS_HOST` | `ds.example.com` |
| `ENV_IDX01_HOST` | `indexer01.example.com` |
| `ENV_IDX02_HOST` | `indexer02.example.com` |
| `ENV_SH_HOST` | `searchhead.example.com` |
| `ENV_HF_HOST` | `heavyforwarder.example.com` |
| `ENV_LM_HOST` | same as `ENV_CM_HOST` |
| `ENV_MC_HOST` | same as `ENV_DS_HOST` |

### Ports

| Variable | Default | Purpose |
|----------|---------|---------|
| `ENV_MGMT_PORT` | `8089` | splunkd management port |
| `ENV_WEB_PORT` | `8000` | Splunk Web |
| `ENV_RECV_PORT` | `9997` | Indexer receiving (from forwarders) |
| `ENV_REPL_PORT` | `8100` | Indexer cluster replication |
| `ENV_SHC_REPL_PORT` | `8191` | Search Head Cluster replication |

### Paths and users

| Variable | Default | Purpose |
|----------|---------|---------|
| `SPLUNK_HOME` | `/opt/splunk` | Install directory |
| `SPLUNK_USER_OVERRIDE` | (auto-detected) | Force a specific service account name |

### Example

```bash
export ENV_CM_HOST=cm.prod.local
export ENV_IDX01_HOST=idx01.prod.local
export ENV_IDX02_HOST=idx02.prod.local
export ADMIN_PASSWORD='correct-horse-battery-staple'

sudo -E ./splunk-enterprise-manager.sh --install --role cm,lm -y
```

---

## Distributed upgrade order

When upgrading a full distributed deployment, follow this order. The script only knows about the host it runs on — coordination across hosts is your job. Run `--topology` to see this reference in the terminal.

1. **Deployment Server** — upgrade but do NOT restart yet. Prevents it from pushing configs to hosts still at the old version.
2. **Cluster Manager + License Manager** — upgrade and restart.
3. **Enable maintenance mode** on the CM (`splunk enable maintenance-mode`).
4. **Search Heads** — one at a time.
5. **Indexers** — one at a time; use `splunk offline` to drain rather than hard-stop.
6. **Disable maintenance mode** on the CM.
7. **Heavy Forwarders** — stop, upgrade, start.
8. **Restart the Deployment Server** (from step 1).
9. **Universal Forwarders** — last. Use the UF manager script.

Per-host: `sudo -E ./splunk-enterprise-manager.sh --upgrade`.

Reference: [Splunk: Upgrade a distributed Splunk Enterprise environment](https://docs.splunk.com/Documentation/Splunk/latest/Installation/Howtoupgradeadistributedenvironment).

---

## File locations

**Inputs (you provide):**

| Path | Content |
|------|---------|
| `/tmp/splunkinstall/splunk-*.tgz` | TGZ installer (preferred — avoids RPM scriptlet noise) |
| `/tmp/splunkinstall/splunk-*.rpm` | RPM installer (alternative) |

**Outputs and state:**

| Path | Content |
|------|---------|
| `$SPLUNK_HOME` | Install root (default `/opt/splunk`) |
| `$SPLUNK_HOME/etc/system/local/server.conf` | Role-specific main config generated by the wizard |
| `$SPLUNK_HOME/etc/auth/splunk.secret` | Per-host secret, generated by splunkd on first start |
| `$SPLUNK_HOME/etc/shc_bootstrap_command.txt` | SHC captain bootstrap command (when applicable) |
| `/etc/systemd/system/Splunkd.service` | Systemd unit |
| `/tmp/splunk_backup_<ts>/` | Backup taken during `--upgrade` |
| `/tmp/splunk_repair_<ts>/` | Backup taken during `--repair` |
| `/tmp/splunk_reconfig_<ts>/` | Backup taken during `--reconfigure` |
| `/tmp/splunk_remove_<ts>/` | Backup taken during `--remove` (if opted in) |
| `/tmp/splunk_binupdate_<ts>/` | Backup taken during `--simple-update` |

---

## Secret handling

Every install generates its own unique `splunk.secret` on the host's first splunkd start. The script does not import a shared secret from anywhere, does not copy one from another host, and does not bundle one in a distribution package.

The sequencing that makes this work:

1. Install binaries.
2. Create the service user.
3. Write configs with **plaintext** `pass4SymmKey` values in `server.conf` and the admin password in `user-seed.conf` (mode 0600).
4. Fix ownership, restore SELinux contexts.
5. `splunk enable boot-start` — writes the systemd unit, does not start the service.
6. `systemctl start` — splunkd starts, generates `/opt/splunk/etc/auth/splunk.secret` for this host, consumes `user-seed.conf` (and deletes it), reads `server.conf`, encrypts the plaintext `pass4SymmKey` values in place using the new per-host secret.

After first start, everything sensitive in `server.conf` is ciphertext encrypted with that host's specific secret. The plaintext window exists only between steps 3 and 6 on the local filesystem, and the file is mode 0600 the entire time.

During `--upgrade`, `--repair`, and `--reconfigure`, the script backs up and restores **this host's own** secret — which is correct, because those operations happen in place on the same host. No cross-host secret ever moves through this script.

If you need to coordinate shared `pass4SymmKey` values across a cluster (CM + peers, SHC members, DS + forwarder), set the same value in `ADMIN_PASSWORD`/`pass4SymmKey` env vars or wizard inputs on each host. Each host will encrypt it with its own secret, but the plaintext input is identical — which is what Splunk requires for cluster membership authentication.

---

## Troubleshooting

### `./splunk-enterprise-manager.sh` exits with no output

You're likely running without root. The script prints "This script must be run as root" and exits. Launch with `sudo -E`.

### Script aborts silently right after reading `/etc/os-release`

Previously a real bug (`set -e` + trailing `&&` in `detect_os`) — fixed in v3.0.1. If you're seeing this, you're running an older copy of the script. Update.

### `[ERROR] Cannot su to 'splunk'`

The service user exists but has a locked password and no working shell configuration. The script attempts to repair this automatically. If it fails:

```bash
sudo usermod -U splunk
sudo usermod -s /sbin/nologin splunk
sudo chage -E -1 -M -1 splunk
```

Then re-run.

### Service fails to start under systemctl

On Splunk 10.x, splunkd refuses `splunk start` when the systemd unit exists, and vice versa. The script handles this with its `safe_systemctl` wrapper (which strips `LD_LIBRARY_PATH` to avoid Splunk's bundled OpenSSL being picked up by systemctl itself). If the service still won't start:

```bash
sudo journalctl -xeu Splunkd.service
sudo cat /opt/splunk/var/log/splunk/splunkd.log
```

Common causes: port already in use, SELinux denial (check `ausearch -m AVC -ts recent`), permission problem on `/opt/splunk/var/`.

### RPM install shows `chown: cannot dereference` warnings

These are harmless RPM scriptlet warnings that come from the Splunk package itself — symlinks point at targets that don't exist yet at scriptlet time. The script filters them from output and reports a count at the end. Prefer the TGZ installer to avoid them entirely.

### `splunk.secret` appears to be wrong after upgrade

The script restores the host's own secret during upgrade. If values in `server.conf` won't decrypt after upgrade, either:
- Someone replaced the secret by hand mid-upgrade, or
- The backup directory didn't include `splunk.secret` (check `ls /tmp/splunk_backup_*/`)

Recovery: re-run the wizard with `--reconfigure` to regenerate plaintext values, which splunkd will re-encrypt with the current on-disk secret.

---

## Companion: UF manager

Universal Forwarders have a separate management script (`splunk-uf-complete-manager.sh`, v4.0). Same philosophy — per-host secrets, generic environment, multi-mode — but scoped to UF-specific concerns: single role, lighter footprint, no distributed roles.

Use the UF manager for every endpoint forwarder. Use this Enterprise manager for CMs, Indexers, Search Heads, DSes, Deployers, HFs, LMs, MCs.

---

## Version

v3.0+ — see the header of `splunk-enterprise-manager.sh` for the exact version string.
