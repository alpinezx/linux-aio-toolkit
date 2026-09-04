#!/usr/bin/env bash
#
# aio-toolkit.sh — personal Ubuntu/Debian server utility bundle
#
# A single entry point for a growing collection of setup/maintenance tools
# that used to live as separate one-off scripts. The menu loops until you
# choose Exit, so you can run several actions back to back without
# relaunching the script.
#
# Design conventions (carried over from setup-aiostreams.sh, kept consistent
# as more modules get added):
#   - Every module function is idempotent: safe to re-run any time, checks
#     "is this already done?" before doing it, and reports what it found.
#   - info()/warn()/alert()/error() are the only things that print status —
#     error() exits, the others don't.
#   - Destructive or system-altering actions get an explicit [y/N] prompt.
#   - Menu numbering is NOT final — this is a first pass with two modules
#     (Hardening, Swap). Categories/ordering get revisited once the rest of
#     the toolkit is folded in.
#
# Run as root (or with sudo) on Ubuntu/Debian.
#
# Usage:
#   chmod +x aio-toolkit.sh
#   sudo ./aio-toolkit.sh

set -euo pipefail

# ============================================================
# ---------- shared helpers (used by every module) ----------
# ============================================================

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
alert() { printf '\033[1;31m!! %s !!\033[0m\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Pause point after a module finishes, so output doesn't disappear the
# instant the menu redraws.
press_enter() {
    echo ""
    read -rp "Press Enter to return to the menu... " _
}

# ---- shared sshd_config helpers ----
# sshd reads /etc/ssh/sshd_config.d/*.conf (alphabetically) BEFORE the rest
# of the main /etc/ssh/sshd_config file, and for any given setting only the
# FIRST occurrence it reads takes effect — every repeat after that is
# silently ignored, not "latest wins". Cloud images commonly drop
# PermitRootLogin/PasswordAuthentication overrides in sshd_config.d/ (e.g.
# 50-cloud-init.conf), so editing sshd_config alone can look successful and
# do nothing. Every SSH-login module below goes through these two helpers
# instead of touching sshd_config directly, so they all respect this.

_sshd_effective_files() {
    local f
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$f" ]] && echo "$f"
        done | sort
    fi
    echo "/etc/ssh/sshd_config"
}

# Sets $2's value to $3 at the FIRST effective occurrence of keyword $2
# across every file sshd reads (in the order above), and neutralizes any
# later duplicate occurrences — in that same file or any subsequent one —
# by commenting them out with a marker rather than deleting them, so a
# future read of the file doesn't lie about what's active. Backs up every
# file it touches before editing. If the keyword isn't set anywhere, it's
# appended to the main sshd_config. Prints the list of touched files, one
# per line, for the caller to report or use for a restore-on-failure.
_sshd_set_first_occurrence() {
    local keyword="$1" value="$2" f found=false backup_suffix
    backup_suffix="bak.$(date +%Y%m%d%H%M%S)"

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        grep -qE "^\s*${keyword}[[:space:]]" "$f" 2>/dev/null || continue

        cp "$f" "${f}.${backup_suffix}"
        echo "$f"

        if [[ "$found" == false ]]; then
            awk -v kw="$keyword" -v val="$value" '
                BEGIN { set=0 }
                $0 ~ "^[ \t]*" kw "[ \t]" {
                    if (set == 0) { print kw " " val; set=1; next }
                    else { print "# " $0 " (disabled by aio-toolkit - duplicate in same file, first occurrence wins)"; next }
                }
                { print }
            ' "$f" > "${f}.aio_tmp" && mv "${f}.aio_tmp" "$f"
            found=true
        else
            awk -v kw="$keyword" '
                $0 ~ "^[ \t]*" kw "[ \t]" { print "# " $0 " (disabled by aio-toolkit - superseded by an earlier file)"; next }
                { print }
            ' "$f" > "${f}.aio_tmp" && mv "${f}.aio_tmp" "$f"
        fi
    done < <(_sshd_effective_files)

    if [[ "$found" == false ]]; then
        cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.${backup_suffix}"
        echo "${keyword} ${value}" >> /etc/ssh/sshd_config
        echo "/etc/ssh/sshd_config"
    fi
}

# Restores the most recent aio-toolkit backup for each file in a
# newline-separated list (as produced by _sshd_set_first_occurrence).
# Used when sshd -t rejects the change, so a bad edit never gets restarted into.
_sshd_restore_backups() {
    local files="$1" f latest_backup
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        latest_backup=$(ls -t "${f}".bak.* 2>/dev/null | head -1)
        if [[ -n "$latest_backup" ]]; then
            cp "$latest_backup" "$f"
            echo "  restored $f from $latest_backup"
        fi
    done <<< "$files"
}

# ============================================================
# ---------- module: hardening ----------
# fail2ban (SSH brute-force protection) + UFW (firewall, base ports) +
# unattended-upgrades (automatic security-only OS updates).
# Pulled from setup-aiostreams.sh's harden_server()/setup_auto_updates(),
# generalized: no AIOStreams-specific ports or references.
# ============================================================

# Installs and enables unattended-upgrades (automatic OS security updates).
# Idempotent and lockout-safe: security patches only, no feature/release
# upgrades, and it never reboots on its own.
setup_auto_updates() {
    info "Automatic security updates (unattended-upgrades)"

    if dpkg -s unattended-upgrades >/dev/null 2>&1; then
        echo "unattended-upgrades is already installed."
    else
        echo "Installing unattended-upgrades (auto-installs OS security patches)..."
        apt-get install -y -qq unattended-upgrades || { warn "unattended-upgrades install failed."; return 1; }
    fi

    # Non-interactive equivalent of running 'dpkg-reconfigure unattended-upgrades'
    # and answering "Yes". Safe to (re)write every run — these are the only two
    # settings this file holds, and "1" simply means "on, daily".
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

    echo "Automatic security updates are ON (checked daily, security patches only)."
    echo "Note: kernel patches still need an eventual reboot to take effect — if you"
    echo "see '*** System restart required ***' when logging in, run 'sudo reboot'"
    echo "at a convenient moment."
    return 0
}

# Installs fail2ban (SSH brute-force protection), UFW (firewall), and
# unattended-upgrades (automatic security updates) — each one optional,
# asked about independently, so you can pick any combination. Idempotent:
# skips anything already installed and active.
# Deliberately does NOT touch SSH password settings — that's a manual,
# check-every-step process best done by hand, not automated here.
#
# UFW_PORTS controls which ports get allowed if UFW is installed. Defaults
# to SSH/HTTP/HTTPS (22, 80, 443) — override by exporting
# UFW_PORTS="22 80 443 8080" etc. before calling, or extend this once
# per-tool port needs are known.
harden_server() {
    local ports=(${UFW_PORTS:-22 80 443})

    info "Server hardening: fail2ban + UFW + automatic security updates"
    echo "Each piece below is independent — answer per component, skip anything you don't want."

    apt-get update -qq || { warn "apt update failed — check your network and try again."; return 1; }

    local did_fail2ban="skipped" did_ufw="skipped" did_updates="skipped"

    # --- fail2ban ---
    read -rp "Install/configure fail2ban (SSH brute-force protection)? [Y/n]: " CONFIRM_FAIL2BAN
    CONFIRM_FAIL2BAN="${CONFIRM_FAIL2BAN:-Y}"
    if [[ "$CONFIRM_FAIL2BAN" =~ ^[Yy]$ ]]; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            echo "fail2ban is already installed and running, skipping install."
        else
            echo "Installing fail2ban (bans IPs that repeatedly fail SSH login)..."
            apt-get install -y -qq fail2ban || { warn "fail2ban install failed."; return 1; }
            systemctl enable --now fail2ban
            echo "fail2ban is active. Check it any time with: fail2ban-client status sshd"
            echo "(A high 'Total failed' count is normal — that's internet bot noise, not you being targeted.)"
        fi

        # Known fail2ban packaging bug: the default filter.d/sshd.conf hardcodes
        # "journalmatch = _SYSTEMD_UNIT=sshd.service", but on Debian/Ubuntu the
        # actual systemd unit is usually "ssh.service", not "sshd.service". Left
        # as-is, fail2ban runs, reports "active", and looks fine in status output
        # — but silently matches zero journal entries and never bans anyone.
        # This runs every time (idempotent, no downside either way) so both
        # fresh installs and pre-existing ones get corrected.
        local ssh_unit="ssh.service"
        if systemctl list-unit-files 2>/dev/null | grep -q "^sshd\.service"; then
            ssh_unit="sshd.service"
        fi
        cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=${ssh_unit}
EOF
        systemctl restart fail2ban
        echo "fail2ban's SSH journal filter verified/corrected (watching ${ssh_unit})."
        did_fail2ban="done"
    else
        echo "Skipping fail2ban."
    fi

    # --- UFW ---
    read -rp "Install/configure UFW (firewall)? [Y/n]: " CONFIRM_UFW
    CONFIRM_UFW="${CONFIRM_UFW:-Y}"
    if [[ "$CONFIRM_UFW" =~ ^[Yy]$ ]]; then
        if require_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
            echo "UFW is already active, ensuring base ports are allowed..."
        else
            echo "Installing UFW (firewall)..."
            apt-get install -y -qq ufw || { warn "UFW install failed."; return 1; }
        fi

        local p
        for p in "${ports[@]}"; do
            ufw allow "$p" >/dev/null 2>&1 || warn "Could not add UFW rule for port $p."
        done

        if ! ufw status 2>/dev/null | grep -q "Status: active"; then
            # --force skips the interactive "this may disconnect SSH" prompt —
            # safe here specifically because SSH's port (22) is guaranteed to be
            # in $ports by the default above; if the caller overrode UFW_PORTS
            # and dropped 22, warn loudly before enabling.
            if [[ ! " ${ports[*]} " =~ " 22 " ]]; then
                alert "UFW is about to be enabled but port 22 (SSH) is NOT in the allow list."
                alert "This can lock you out of the server over SSH."
                read -rp "Continue enabling UFW anyway? [y/N]: " CONFIRM_UFW_NO_SSH
                if [[ ! "$CONFIRM_UFW_NO_SSH" =~ ^[Yy]$ ]]; then
                    warn "UFW left disabled. Add port 22 to UFW_PORTS and re-run."
                    CONFIRM_UFW="n"
                fi
            fi
        fi

        if [[ "$CONFIRM_UFW" =~ ^[Yy]$ ]]; then
            if ! ufw status 2>/dev/null | grep -q "Status: active"; then
                ufw --force enable
                echo "UFW enabled. Allowed ports: ${ports[*]}"
            else
                echo "UFW already active. Allowed ports (added/confirmed): ${ports[*]}"
            fi
            ufw status verbose
            did_ufw="done"
        fi
    else
        echo "Skipping UFW."
    fi

    # --- automatic security updates ---
    read -rp "Install/configure automatic security updates (unattended-upgrades)? [Y/n]: " CONFIRM_UPDATES
    CONFIRM_UPDATES="${CONFIRM_UPDATES:-Y}"
    if [[ "$CONFIRM_UPDATES" =~ ^[Yy]$ ]]; then
        setup_auto_updates || warn "Automatic security updates step did not fully complete."
        did_updates="done"
    else
        echo "Skipping automatic security updates."
    fi

    echo ""
    echo "Hardening summary: fail2ban (${did_fail2ban}), UFW (${did_ufw}), automatic security updates (${did_updates})."
    return 0
}

# ============================================================
# ---------- module: swap ----------
# Auto-sizes and creates a swap file based on detected RAM and free disk
# space, and tunes vm.swappiness. Pulled from setup-aiostreams.sh's
# setup_swap()/tune_swappiness() — unchanged, already generic.
# ============================================================

tune_swappiness() {
    local target=10
    sysctl -w vm.swappiness="$target" >/dev/null

    if grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^vm.swappiness.*/vm.swappiness=${target}/" /etc/sysctl.conf
    else
        echo "vm.swappiness=${target}" >> /etc/sysctl.conf
    fi

    info "swappiness set to ${target} (applied immediately + persisted in /etc/sysctl.conf)"
}

# Auto-detects RAM, recommends a swap size scaled to it, and creates the file
# if one doesn't already exist. Always checks for existing swap first and
# skips cleanly if found, so it's safe to re-run any time.
setup_swap() {
    local total_ram_mb swap_mb avail_disk_mb max_safe_swap_mb multiplier

    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    info "Detected ${total_ram_mb}MB RAM"

    if swapon --show 2>/dev/null | grep -q .; then
        echo "Swap is already configured — nothing to create."
        swapon --show
        tune_swappiness
        return 0
    fi

    # Recommended size scales down as RAM grows, since the relative benefit
    # of swap shrinks the more RAM you already have:
    #   < 1GB RAM  -> 2x RAM   (e.g. 512MB -> 1GB)
    #   1-8GB RAM  -> 1x RAM   (e.g. ~2GB -> ~2GB, 4GB -> 4GB)
    #   > 8GB RAM  -> 4GB flat (diminishing returns beyond this)
    # Note: cloud "2GB" plans usually report slightly under 2048MB in `free`
    # (some RAM is reserved by the host) — the 1GB cutoff keeps those boxes
    # in the 1x bracket instead of tipping into the more aggressive 2x one.
    if [[ "$total_ram_mb" -lt 1024 ]]; then
        multiplier=2
    elif [[ "$total_ram_mb" -le 8192 ]]; then
        multiplier=1
    else
        multiplier=0
    fi

    if [[ "$multiplier" -eq 0 ]]; then
        swap_mb=4096
    else
        swap_mb=$(( total_ram_mb * multiplier ))
        if [[ "$swap_mb" -gt 4096 ]]; then
            swap_mb=4096
        fi
    fi
    swap_mb=$(( ( (swap_mb + 255) / 256 ) * 256 ))
    info "Recommended swap size: ${swap_mb}MB"

    # Don't let the swap file eat more than 25% of free disk space, and always
    # leave at least 1GB free afterward.
    avail_disk_mb=$(df --output=avail -m / | tail -n1 | tr -d ' ')
    max_safe_swap_mb=$(( avail_disk_mb / 4 ))
    if [[ "$swap_mb" -gt "$max_safe_swap_mb" ]]; then
        swap_mb="$max_safe_swap_mb"
    fi

    if [[ "$swap_mb" -lt 256 || $(( avail_disk_mb - swap_mb )) -lt 1024 ]]; then
        warn "Not enough free disk space (${avail_disk_mb}MB available) to safely create a swap file. Skipping."
        return 1
    fi

    info "Creating a ${swap_mb}MB swap file (based on ${total_ram_mb}MB RAM and ${avail_disk_mb}MB free disk)"

    if ! fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb"
    fi

    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        echo "Swap file created and activated successfully (${swap_mb}MB)."
        tune_swappiness
        free -h
        return 0
    else
        warn "Swap setup ran, but /swapfile doesn't show as active. Check manually with: swapon --show"
        return 1
    fi
}

# ============================================================
# ---------- module: system maintenance / basics ----------
# The routine stuff you'd normally do by hand on login: apt update/upgrade,
# fix any interrupted dpkg state, clean up old packages and cached .debs,
# trim the systemd journal, flag if a reboot is pending, and (optionally,
# with an explicit warning) clear shell history. Every step here is safe
# to re-run — nothing destructive happens without its own confirmation.
# ============================================================

# Clears root's and the real sudo-invoking user's bash history file, plus
# the in-memory history of THIS script's own shell (which has no practical
# effect on the interactive shell that launched it — see the note printed
# to the user). Separated out from system_maintenance() because it's the
# one irreversible, non-idempotent step in this module and deserves its
# own explicit opt-in rather than running by default.
_clear_shell_history() {
    local target_home cleared=()

    history -c 2>/dev/null || true

    if [[ -f /root/.bash_history ]]; then
        : > /root/.bash_history
        cleared+=("/root/.bash_history")
    fi

    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        target_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
        if [[ -n "$target_home" && -f "$target_home/.bash_history" ]]; then
            : > "$target_home/.bash_history"
            cleared+=("$target_home/.bash_history")
        fi
    fi

    if [[ ${#cleared[@]} -eq 0 ]]; then
        echo "No .bash_history files found to clear."
    else
        echo "Cleared:"
        printf '  %s\n' "${cleared[@]}"
    fi
    echo "Note: this clears the saved history FILES. Your CURRENT live terminal session"
    echo "(the one you launched this script from) may still show old commands until you"
    echo "log out, or run 'history -c' yourself in that shell."
}

system_maintenance() {
    info "System maintenance"

    # --- fix any interrupted package install first, so update/upgrade
    # below aren't fighting a half-configured package ---
    info "Checking for interrupted package installs..."
    dpkg --configure -a || warn "dpkg --configure -a reported an issue — check 'dpkg -l | grep ^..H' for held/broken packages."

    # --- update package lists ---
    info "Updating package lists (apt update)..."
    apt-get update -qq || { warn "apt update failed — check your network and try again."; return 1; }
    echo "Package lists updated."

    # --- upgrade ---
    local upgradable
    upgradable=$(apt list --upgradable 2>/dev/null | grep -c '^' || echo 0)
    # apt list's first line is often a "Listing..." notice, not a package —
    # subtract it so the count reflects actual upgradable packages.
    upgradable=$(( upgradable > 0 ? upgradable - 1 : 0 ))

    if [[ "$upgradable" -eq 0 ]]; then
        echo "No packages to upgrade — already up to date."
    else
        echo "$upgradable package(s) can be upgraded."
        read -rp "Run apt upgrade now? [Y/n]: " CONFIRM_UPGRADE
        CONFIRM_UPGRADE="${CONFIRM_UPGRADE:-Y}"
        if [[ "$CONFIRM_UPGRADE" =~ ^[Yy]$ ]]; then
            # --force-confdef + --force-confold: if a packaged config file
            # (sshd_config via openssh-server, sysctl.conf via procps, etc.)
            # has been locally modified by another module in this toolkit —
            # PermitRootLogin, BBR/swappiness tuning — keep OUR version
            # instead of silently replacing it with the package's default.
            # Without this, dpkg's default behavior for a modified conffile
            # is either to overwrite it outright or to prompt interactively,
            # which would hang this script dead in an unattended run since
            # there's no one there to answer.
            apt-get upgrade -y -qq \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                || warn "apt upgrade reported an issue — check output above."
            echo "Upgrade complete."
        else
            echo "Skipped upgrade."
        fi
    fi

    # --- cleanup: remove packages no longer needed, clear stale .deb cache ---
    echo ""
    info "Cleaning up packages..."
    apt-get autoremove -y -qq || warn "autoremove reported an issue."
    apt-get autoclean -qq || warn "autoclean reported an issue."
    echo "Removed unused packages and cleared out-of-date package cache."

    # --- trim the systemd journal so logs don't quietly eat disk forever ---
    echo ""
    if require_cmd journalctl; then
        info "Trimming systemd journal to the last 200MB..."
        journalctl --vacuum-size=200M >/dev/null 2>&1 || warn "journalctl vacuum reported an issue."
        echo "Journal trimmed."
    fi

    # --- reboot-required check ---
    echo ""
    if [[ -f /var/run/reboot-required ]]; then
        warn "A reboot is required (usually a kernel or core library update)."
        if [[ -f /var/run/reboot-required.pkgs ]]; then
            echo "Packages requiring it:"
            sed 's/^/  /' /var/run/reboot-required.pkgs
        fi
        echo "Run 'sudo reboot' at a convenient moment."
    else
        echo "No reboot currently required."
    fi

    # --- optional: clear shell history ---
    echo ""
    read -rp "Also clear saved shell history (root's and your sudo user's .bash_history)? This is irreversible. [y/N]: " CONFIRM_CLEAR_HISTORY
    if [[ "$CONFIRM_CLEAR_HISTORY" =~ ^[Yy]$ ]]; then
        _clear_shell_history
    else
        echo "Skipped — history left as-is."
    fi

    # --- summary ---
    echo ""
    info "Summary"
    echo "Disk usage:"
    df -h / | sed 's/^/  /'
    echo "Memory:"
    free -h | sed 's/^/  /'
    echo "Uptime: $(uptime -p 2>/dev/null || uptime)"
    return 0
}

# ============================================================
# ---------- module: create a non-root sudo user ----------
# Creates a real user, adds them to the sudo group, and copies root's own
# SSH key(s) over so they can log in immediately. Exists mainly as the
# natural prerequisite for "Disable root SSH login" — on a stock
# DigitalOcean droplet (root-only by default, unlike Oracle/AWS/GCP which
# create a non-root user for you), there's otherwise no scripted way to get
# from "root-only" to "safe to disable root login" without doing these
# three steps by hand every time.
# ============================================================

create_sudo_user() {
    local username home

    read -rp "Username for the new account: " username
    if [[ -z "$username" ]]; then
        warn "No username given. Aborting."
        return 1
    fi
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        warn "'$username' doesn't look like a valid Linux username (lowercase letters,"
        warn "numbers, - or _, starting with a letter or underscore). Aborting."
        return 1
    fi

    if id "$username" >/dev/null 2>&1; then
        echo "User '$username' already exists — skipping creation, just ensuring sudo access + key."
    else
        info "Creating user '$username' (you'll be prompted to set a password)..."
        adduser "$username" || { warn "adduser failed."; return 1; }
    fi

    home=$(getent passwd "$username" 2>/dev/null | cut -d: -f6)
    if [[ -z "$home" || ! -d "$home" ]]; then
        warn "Could not find a home directory for '$username'. Aborting."
        return 1
    fi

    if id -nG "$username" 2>/dev/null | grep -qw sudo; then
        echo "'$username' is already in the sudo group."
    else
        usermod -aG sudo "$username"
        echo "'$username' added to the sudo group."
    fi

    # --- SSH key: default source is root's own authorized_keys, since on a
    # stock DigitalOcean droplet that's where the key you created the
    # droplet with already lives. ---
    mkdir -p "$home/.ssh"
    local key_src="/root/.ssh/authorized_keys"
    if [[ -s "$key_src" ]]; then
        if [[ -s "$home/.ssh/authorized_keys" ]]; then
            read -rp "'$username' already has an authorized_keys file. Overwrite with root's current key(s)? [y/N]: " CONFIRM_OVERWRITE_KEY
            if [[ "$CONFIRM_OVERWRITE_KEY" =~ ^[Yy]$ ]]; then
                cp "$key_src" "$home/.ssh/authorized_keys"
                echo "Copied root's key(s) to $username (overwritten)."
            else
                echo "Left '$username''s existing authorized_keys untouched."
            fi
        else
            cp "$key_src" "$home/.ssh/authorized_keys"
            echo "Copied root's key(s) to $username."
        fi
    else
        warn "No key found at $key_src to copy."
        read -rp "Paste a public key to add for '$username' now, or leave blank to skip: " PASTED_KEY
        if [[ -n "$PASTED_KEY" ]]; then
            echo "$PASTED_KEY" >> "$home/.ssh/authorized_keys"
            echo "Key added."
        else
            warn "No key added — '$username' won't be able to log in via SSH key yet."
        fi
    fi

    chmod 700 "$home/.ssh"
    [[ -f "$home/.ssh/authorized_keys" ]] && chmod 600 "$home/.ssh/authorized_keys"
    chown -R "$username":"$username" "$home/.ssh"

    echo ""
    echo "Done. Test in a NEW terminal BEFORE relying on this:"
    echo ""
    echo "    ssh $username@<this-server-ip>"
    echo "    sudo whoami   # should print root — will ask for ${username}'s own password"
    echo ""
    echo "Note: this does NOT change root's own SSH access. Use options for that"
    echo "separately once '$username' is confirmed working."
    return 0
}

# ============================================================
# ---------- module: remove a user ----------
# Deletes a non-root user account, optionally including their home
# directory. The most destructive option in this toolkit, so it gets the
# most guards of any single action here:
#   - Can't remove 'root'.
#   - Can't remove the account currently sudo'd in as (self-inflicted
#     mid-session lockout).
#   - Hard refusal (same pattern as disable_root_login) if root login is
#     currently OFF and this user is the only non-root account with a
#     working SSH key — removing them would strand the operator completely,
#     with no override possible.
#   - Requires re-typing the username as a second, deliberate confirmation
#     on top of the usual y/N — a typo on a single keypress shouldn't be
#     able to delete an account.
# ============================================================

remove_user() {
    local username

    # Show real (human) accounts up front with useful context, so you don't
    # need to remember an exact name from months ago. Same numbered-list +
    # manual-entry pattern used elsewhere in this toolkit's lineage (backup
    # selection in setup-aiostreams.sh's do_restore). The account currently
    # in use to run this script is shown for transparency but isn't
    # selectable — it can't be removed regardless (see the check below).
    local candidates=() uname uid home groups_str has_key i=1
    while IFS=: read -r uname _ uid _ _ home _; do
        [[ "$uid" -ge 1000 && "$uname" != "nobody" ]] || continue
        if [[ "$uname" == "${SUDO_USER:-}" ]]; then
            echo "      $uname  (currently in use — cannot remove)"
            continue
        fi
        groups_str=$(id -nG "$uname" 2>/dev/null | tr ' ' ',')
        if [[ -s "$home/.ssh/authorized_keys" ]]; then
            has_key="has SSH key"
        else
            has_key="no SSH key on file"
        fi
        candidates+=("$uname")
        printf '  %d) %s  (groups: %s; %s)\n' "$i" "$uname" "$groups_str" "$has_key"
        i=$((i + 1))
    done < /etc/passwd

    if [[ ${#candidates[@]} -gt 0 ]]; then
        echo "  m) Enter a username manually"
        local sel
        read -rp "Select a user to remove [1-${#candidates[@]}, m]: " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#candidates[@]} )); then
            username="${candidates[$((sel - 1))]}"
        else
            read -rp "Username to remove: " username
        fi
    else
        echo "No other non-root users found on this server."
        read -rp "Username to remove: " username
    fi

    if [[ -z "$username" ]]; then
        warn "No username given. Aborting."
        return 1
    fi
    if [[ "$username" == "root" ]]; then
        warn "Refusing to remove 'root'."
        return 1
    fi
    if ! id "$username" >/dev/null 2>&1; then
        warn "User '$username' doesn't exist. Nothing to do."
        return 1
    fi
    if [[ "$username" == "${SUDO_USER:-}" ]]; then
        warn "Refusing to remove '$username' — that's the account you're currently"
        warn "sudo'd in as. Log in as a different user (or root, if enabled) first."
        return 1
    fi

    require_cmd deluser || { warn "'deluser' not found (should ship with the 'adduser' package)."; return 1; }

    # Guaranteed-lockout guard: if root login is currently off AND this user
    # is the only non-root account with a working key, removing them would
    # leave no way back into the server at all. Same spirit, same
    # _nonroot_users_with_ssh_key helper, as disable_root_login's own gate.
    if sshd -T 2>/dev/null | grep -qi '^permitrootlogin no'; then
        local remaining
        remaining=$(_nonroot_users_with_ssh_key | grep -vFx "$username" || true)
        if [[ -z "$remaining" ]]; then
            alert "REFUSING: root login is disabled, and '$username' is the only non-root"
            alert "user with an SSH key on this server. Removing them would lock you out"
            alert "completely, with no way back in."
            echo ""
            echo "Create another sudo user first (option 4) and confirm you can log in as"
            echo "them, or re-enable root login, before removing '$username'."
            return 1
        fi
    fi

    echo "Account details for '$username':"
    id "$username"
    echo ""

    read -rp "Also delete '$username''s home directory and mail spool? [y/N]: " CONFIRM_HOME
    local delete_home_args=()
    if [[ "$CONFIRM_HOME" =~ ^[Yy]$ ]]; then
        delete_home_args=(--remove-home)
    fi

    alert "THIS WILL PERMANENTLY REMOVE THE USER '$username'."
    if [[ ${#delete_home_args[@]} -gt 0 ]]; then
        alert "Their home directory and all files in it will be DELETED too. This cannot be undone."
    else
        alert "Their home directory will be LEFT ON DISK (you chose not to delete it)."
    fi
    echo ""
    read -rp "Type the username again to confirm removal: " CONFIRM_USERNAME_TYPED
    if [[ "$CONFIRM_USERNAME_TYPED" != "$username" ]]; then
        warn "Typed name didn't match. Cancelled — no changes made."
        return 0
    fi

    if deluser "${delete_home_args[@]}" "$username"; then
        echo "'$username' removed."
    else
        warn "deluser reported an issue — check output above."
        return 1
    fi

    # Clean up any leftover passwordless-sudo drop-in — it would otherwise
    # sit there referencing a now-nonexistent user for no reason.
    local sudoers_file="/etc/sudoers.d/90-${username}-nopasswd"
    if [[ -f "$sudoers_file" ]]; then
        rm -f "$sudoers_file"
        echo "Also removed their passwordless-sudo rule ($sudoers_file)."
    fi

    return 0
}

# ============================================================
# ---------- module: passwordless sudo for a user ----------
# Adds (or removes) a /etc/sudoers.d drop-in granting NOPASSWD:ALL to a
# specific user. Deliberately its own opt-in option, not a flag on user
# creation — this is a real, standing reduction in security (anyone who
# gets the user's SSH key, not just their password, gets instant root), so
# it deserves its own explicit decision rather than being a checkbox that's
# easy to click through without thinking.
#
# Validated in two stages before anything touches the live config:
#   1. The new rule alone, via 'visudo -cf' on a temp file — never written
#      to sudoers.d unless it passes.
#   2. The WHOLE sudoers configuration, via 'visudo -c', after the file is
#      in place — catches the (rare) case where a rule is individually
#      valid but something about the combination isn't; the file is
#      removed immediately if this fails, rather than left in place broken.
# A bad sudoers file can break sudo for EVERY user on the box, not just the
# one being configured — worse than an SSH lockout, since there's no
# separate "sudo -t" equivalent to test before committing the way sshd has.
# ============================================================

setup_passwordless_sudo() {
    local username sudoers_file

    read -rp "Username to manage passwordless sudo for: " username
    if [[ -z "$username" ]]; then
        warn "No username given. Aborting."
        return 1
    fi
    if ! id "$username" >/dev/null 2>&1; then
        warn "User '$username' doesn't exist. Create them first (option 4)."
        return 1
    fi

    sudoers_file="/etc/sudoers.d/90-${username}-nopasswd"

    if [[ -f "$sudoers_file" ]]; then
        echo "'$username' already has a passwordless sudo rule:"
        sed 's/^/  /' "$sudoers_file"
        read -rp "Remove it (require ${username}'s password for sudo again)? [y/N]: " CONFIRM_REMOVE
        if [[ "$CONFIRM_REMOVE" =~ ^[Yy]$ ]]; then
            rm -f "$sudoers_file"
            echo "Removed. '$username' will need their password for sudo again."
        else
            echo "Left as-is."
        fi
        return 0
    fi

    if ! id -nG "$username" 2>/dev/null | grep -qw sudo; then
        warn "'$username' isn't in the sudo group yet — this rule would still grant"
        warn "them root via sudo regardless, but double-check this is the right user."
    fi

    alert "THIS LETS '$username' RUN ANY COMMAND AS ROOT WITHOUT A PASSWORD PROMPT."
    alert "Anyone who gets hold of ${username}'s SSH KEY (not just their password)"
    alert "gets instant, full root — there is no second factor left after this."
    echo ""
    read -rp "Proceed with passwordless sudo for '$username'? [y/N]: " CONFIRM_NOPASSWD
    if [[ ! "$CONFIRM_NOPASSWD" =~ ^[Yy]$ ]]; then
        warn "Cancelled. No changes made."
        return 0
    fi

    local tmp_file
    tmp_file=$(mktemp)
    echo "${username} ALL=(ALL) NOPASSWD:ALL" > "$tmp_file"

    info "Validating the new rule in isolation..."
    if ! visudo -cf "$tmp_file" >/dev/null 2>&1; then
        warn "Generated sudoers rule failed validation — NOT applying it. This"
        warn "shouldn't normally happen; please double-check the username."
        rm -f "$tmp_file"
        return 1
    fi

    chmod 440 "$tmp_file"
    chown root:root "$tmp_file"
    mv "$tmp_file" "$sudoers_file"

    info "Validating the FULL sudoers configuration with the new rule in place..."
    if ! visudo -c >/dev/null 2>&1; then
        warn "Overall sudoers configuration failed validation — removing the new rule"
        warn "immediately to avoid breaking sudo for everyone on this box."
        rm -f "$sudoers_file"
        return 1
    fi

    echo "Done. '$username' can now run 'sudo <command>' with no password prompt."
    echo ""
    echo "Test in a NEW terminal (keep this session open):"
    echo "    ssh $username@<this-server-ip>"
    echo "    sudo whoami   # should print root with NO password prompt this time"
    echo ""
    echo "To revert later: re-run this option for the same user and choose to remove it."
    return 0
}

# ============================================================
# ---------- module: enable root SSH login ----------
# Copies an existing sudo user's SSH public key(s) to /root/.ssh, sets
# PermitRootLogin, validates config, restarts sshd. Pulled from
# enable-root-ssh.sh, adapted to run under this toolkit's "always root via
# sudo" model instead of standalone-as-non-root: the original script
# insisted on being run AS the sudo user (not root) so it could read that
# user's ~/.ssh/authorized_keys directly. Here we're already root, so we
# find the real invoking user via $SUDO_USER instead (same pattern
# setup-aiostreams.sh uses for REAL_HOME) and read their key from there.
# ============================================================

enable_root_ssh() {
    local target_user target_home auth_keys_src key_count

    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        target_user="$SUDO_USER"
        info "Using keys from sudo-invoking user: $target_user"
    else
        # Not launched via sudo from a normal user (e.g. logged in directly
        # as root) — ask which user's key to copy.
        read -rp "Enter the username whose SSH key should be copied to root: " target_user
        [[ -z "$target_user" ]] && { warn "No username given. Aborting."; return 1; }
    fi

    target_home=$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6)
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        warn "Could not find a home directory for user '$target_user'. Aborting."
        return 1
    fi

    auth_keys_src="$target_home/.ssh/authorized_keys"
    if [[ ! -f "$auth_keys_src" ]]; then
        warn "No authorized_keys file found at $auth_keys_src"
        warn "Make sure you can already SSH in as '$target_user' with a key before running this."
        return 1
    fi

    key_count=$(grep -c -v '^\s*$' "$auth_keys_src" || true)
    echo "Found $key_count public key(s) in $auth_keys_src"

    # Show current state so this is informative even on a re-run.
    if [[ -f /root/.ssh/authorized_keys ]]; then
        echo "root/.ssh/authorized_keys already exists — it will be overwritten with $target_user's current key(s)."
    fi
    local current_permit_root
    current_permit_root=$(grep -E '^\s*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
    echo "Current PermitRootLogin: ${current_permit_root:-<unset, defaults to prohibit-password on modern OpenSSH>}"
    echo ""

    read -rp "Proceed with enabling root SSH login using these key(s)? [Y/n]: " CONFIRM_SSH
    CONFIRM_SSH="${CONFIRM_SSH:-Y}"
    if [[ ! "$CONFIRM_SSH" =~ ^[Yy]$ ]]; then
        warn "Aborted. No changes made."
        return 0
    fi

    # --- step 1: copy keys to root ---
    info "Setting up /root/.ssh/authorized_keys ..."
    mkdir -p /root/.ssh
    cp "$auth_keys_src" /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh /root/.ssh/authorized_keys
    echo "Root's authorized_keys now contains ${target_user}'s key(s)."

    # --- step 2: sshd_config (checks main file AND sshd_config.d/*.conf —
    # see _sshd_set_first_occurrence for why both matter) ---
    echo ""
    echo "Choose root login mode:"
    echo "  1) prohibit-password  (recommended: key-based root login only, no root password auth)"
    echo "  2) yes                (allow root login with password too — NOT recommended)"
    read -rp "Select [1/2] (default: 1): " MODE
    MODE="${MODE:-1}"

    local root_login_value
    if [[ "$MODE" == "2" ]]; then
        root_login_value="yes"
        warn "You selected password-based root login. This is significantly less secure."
        read -rp "Are you sure you want to allow root password login over SSH? [y/N]: " CONFIRM_PW_ROOT
        if [[ ! "$CONFIRM_PW_ROOT" =~ ^[Yy]$ ]]; then
            info "Falling back to prohibit-password (key-based only)."
            root_login_value="prohibit-password"
        fi
    else
        root_login_value="prohibit-password"
    fi

    info "Setting PermitRootLogin to '$root_login_value' (first effective occurrence across sshd_config + sshd_config.d/*)..."
    local touched_files
    touched_files=$(_sshd_set_first_occurrence "PermitRootLogin" "$root_login_value")
    echo "Touched files (backed up before editing):"
    echo "$touched_files" | sed 's/^/  /'

    # --- step 3: validate before restarting ---
    info "Validating SSH config syntax ..."
    if sshd -t; then
        echo "Config syntax OK."
    else
        warn "sshd config test failed! Restoring backups and aborting restart."
        _sshd_restore_backups "$touched_files"
        return 1
    fi

    # --- step 4: restart sshd ---
    read -rp "Restart sshd now to apply changes? [Y/n]: " CONFIRM_RESTART_SSHD
    CONFIRM_RESTART_SSHD="${CONFIRM_RESTART_SSHD:-Y}"
    if [[ "$CONFIRM_RESTART_SSHD" =~ ^[Yy]$ ]]; then
        if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
            echo "SSH service restarted."
        else
            warn "Could not restart ssh/sshd service automatically. Restart it manually."
            return 1
        fi
    else
        warn "Skipped restart. Changes won't take effect until you restart sshd manually:"
        warn "  systemctl restart sshd"
    fi

    echo ""
    echo "Done. IMPORTANT: keep your current session open and test in a NEW terminal:"
    echo ""
    echo "    ssh -i /path/to/your-key.pem root@<this-server-ip>"
    echo ""
    warn "Do not close this session until you've confirmed root login works in a new window."
    warn "If it fails, your backups are the files listed above (each has a .bak.<timestamp> copy)."
    return 0
}

# Scans real (non-system) accounts for a non-empty authorized_keys file.
# Used as a hard pre-flight gate before disabling root login — this is a
# genuine check, not a guess based on environment variables. UID >= 1000 is
# the standard Debian/Ubuntu cutoff for "real" human accounts vs system
# service accounts, which is what 'adduser' (and DigitalOcean's own
# non-root-user tutorials) produce by default.
_nonroot_users_with_ssh_key() {
    local uname uid home
    while IFS=: read -r uname _ uid _ _ home _; do
        if [[ "$uid" -ge 1000 && "$uname" != "nobody" && -d "$home" && -s "$home/.ssh/authorized_keys" ]]; then
            echo "$uname"
        fi
    done < /etc/passwd
}

# Disables root SSH login entirely (PermitRootLogin no), same file-aware
# handling as enable_root_ssh. From security-hardening.md's section 1.
# Deliberately its own menu option, not folded into hardening — this is a
# one-way-feeling, session-risking change that deserves its own explicit
# confirmation step rather than being bundled into a "do everything" action.
disable_root_login() {
    # Hard gate, checked FIRST, before any prompts: if literally no other
    # account on the box has an SSH key on file, disabling root login is a
    # guaranteed lockout, not just a risky one — refuse outright rather than
    # let a confirmation prompt talk someone into it. This is a real check
    # (an actual file on disk), unlike the environment-based heuristic below,
    # which can only guess at the situation, not verify it.
    local safe_users
    safe_users=$(_nonroot_users_with_ssh_key)
    if [[ -z "$safe_users" ]]; then
        alert "REFUSING: no non-root user on this server has an SSH key on file."
        alert "Disabling root login right now would lock you out completely — there is"
        alert "no other account that could get back in."
        echo ""
        echo "Set up a non-root user with a working key first, e.g.:"
        echo "  adduser deploy && usermod -aG sudo deploy"
        echo "  rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy"
        echo "Then confirm 'ssh deploy@<this-server-ip>' actually works in a NEW terminal"
        echo "before re-running this option."
        return 1
    fi
    echo "Non-root user(s) with an SSH key on file: $safe_users"
    echo "(This confirms a key FILE exists — it doesn't prove that key still works or"
    echo "that its private half hasn't been lost. Test logging in as one of them before"
    echo "AND after this change, not just once.)"
    echo ""

    alert "THIS WILL DISABLE ROOT SSH LOGIN ENTIRELY"
    alert "DO NOT CLOSE YOUR CURRENT SESSION until you've confirmed a NORMAL (non-root)"
    alert "user can still log in — that's your way back in if anything goes wrong."
    echo ""

    # Extra-hard gate: if this session is root over SSH with no sudo user
    # detected at all, root login may be the ONLY way back in — disabling it
    # here could lock the door with the operator still behind it.
    if [[ -z "${SUDO_USER:-}" && -n "${SSH_CONNECTION:-}" && $EUID -eq 0 ]]; then
        alert "You appear to be connected over SSH directly AS ROOT (no sudo user detected)."
        alert "If root login is your only way into this server, this could lock you out completely."
        echo ""
        read -rp "Type CONFIRM (all caps) to proceed anyway, or anything else to cancel: " CONFIRM_LOCKOUT_RISK
        if [[ "$CONFIRM_LOCKOUT_RISK" != "CONFIRM" ]]; then
            warn "Cancelled. No changes made."
            return 0
        fi
    else
        read -rp "Proceed with disabling root SSH login? [y/N]: " CONFIRM_DISABLE
        if [[ ! "$CONFIRM_DISABLE" =~ ^[Yy]$ ]]; then
            warn "Cancelled. No changes made."
            return 0
        fi
    fi

    echo ""
    info "Setting PermitRootLogin to 'no' (first effective occurrence across sshd_config + sshd_config.d/*)..."
    local touched_files
    touched_files=$(_sshd_set_first_occurrence "PermitRootLogin" "no")
    echo "Touched files (backed up before editing):"
    echo "$touched_files" | sed 's/^/  /'

    info "Validating SSH config syntax..."
    if ! sshd -t; then
        warn "sshd config test FAILED. Restoring backups..."
        _sshd_restore_backups "$touched_files"
        return 1
    fi
    echo "Config syntax OK."

    read -rp "Restart sshd now to apply changes? [Y/n]: " CONFIRM_RESTART_DISABLE
    CONFIRM_RESTART_DISABLE="${CONFIRM_RESTART_DISABLE:-Y}"
    if [[ "$CONFIRM_RESTART_DISABLE" =~ ^[Yy]$ ]]; then
        if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
            echo "SSH service restarted."
        else
            warn "Could not restart ssh/sshd automatically. Restart it manually — the config"
            warn "change is saved but won't take effect until sshd is restarted."
            return 1
        fi
    else
        warn "Skipped restart. Change won't take effect until you restart sshd manually:"
        warn "  systemctl restart sshd"
    fi

    echo ""
    alert "DO NOT CLOSE THIS SESSION YET."
    echo "In a NEW terminal window, confirm a normal (non-root) user can still log in:"
    echo ""
    echo "    ssh -i /path/to/your-key.pem your_normal_user@<this-server-ip>"
    echo ""
    warn "Only close this session once that succeeds. This session is your way back in"
    warn "if something's wrong — fix it here before disconnecting."
    return 0
}

# Read-only status check: shows the raw PermitRootLogin/PasswordAuthentication
# lines in every file sshd reads, plus sshd's own merged/effective values.
# Exists because — per security-hardening.md — different installs (cloud
# provider, image, OS version) can carry different override files, so
# "grep the main sshd_config" alone can be misleading. Safe to run any time.
check_root_login_status() {
    info "Root SSH login status"
    echo ""
    echo "Raw settings found (uncommented lines only), in the order sshd reads them:"
    local f found_any=false matches
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        matches=$(grep -nE '^\s*(PermitRootLogin|PasswordAuthentication)\b' "$f" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            found_any=true
            echo "  $f:"
            echo "$matches" | sed 's/^/    /'
        fi
    done < <(_sshd_effective_files)
    if [[ "$found_any" == false ]]; then
        echo "  (no explicit PermitRootLogin/PasswordAuthentication lines found anywhere — OpenSSH defaults apply)"
    fi

    echo ""
    echo "Effective (merged) values sshd will actually use right now:"
    sshd -T 2>/dev/null | grep -iE '^(permitrootlogin|passwordauthentication) ' || warn "Could not query 'sshd -T' — needs root."
    return 0
}

# ============================================================
# ---------- module: BBR congestion control ----------
# Switches TCP congestion control from CUBIC to BBR (+ fq qdisc), tests it
# live before persisting. Pulled from bbr-congestion-control.md, scripted
# and made idempotent: safe to re-run, reports current state either way.
# ============================================================

enable_bbr() {
    local current available

    info "TCP congestion control"
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    echo "Current: $current"
    echo "Available: $available"

    local persisted=false
    if grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null \
        && grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null \
        && [[ -f /etc/modules-load.d/bbr.conf ]] && grep -q '^tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null; then
        persisted=true
    fi

    if [[ "$current" == "bbr" && "$persisted" == true ]]; then
        echo "BBR is already active and persisted across reboots — nothing to do."
        return 0
    fi

    if [[ "$current" == "bbr" && "$persisted" == false ]]; then
        warn "BBR is active right now but NOT persisted — it will revert to CUBIC on reboot."
        echo "Persisting it now..."
    else
        # Not active yet — make sure the module is actually loadable first.
        if ! grep -qw bbr <<< "$available"; then
            info "Loading tcp_bbr kernel module..."
            if ! modprobe tcp_bbr 2>/dev/null; then
                warn "Could not load the tcp_bbr module. Your kernel may not support it. Aborting."
                return 1
            fi
        fi

        read -rp "Switch TCP congestion control to BBR now (live, testable before persisting)? [Y/n]: " CONFIRM_BBR
        CONFIRM_BBR="${CONFIRM_BBR:-Y}"
        if [[ ! "$CONFIRM_BBR" =~ ^[Yy]$ ]]; then
            warn "Aborted. No changes made."
            return 0
        fi

        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
        current=$(sysctl -n net.ipv4.tcp_congestion_control)
        echo "Active now: $current (temporary — reverts to CUBIC on reboot until persisted below)"
        echo ""
        echo "This is a good moment to benchmark before committing (e.g. re-run your usual"
        echo "speedtest and compare download-phase jitter against CUBIC)."
        echo ""
    fi

    read -rp "Persist BBR + fq qdisc across reboots now? [Y/n]: " CONFIRM_PERSIST_BBR
    CONFIRM_PERSIST_BBR="${CONFIRM_PERSIST_BBR:-Y}"
    if [[ ! "$CONFIRM_PERSIST_BBR" =~ ^[Yy]$ ]]; then
        warn "Not persisted. It will revert to CUBIC on reboot."
        warn "Revert immediately any time with: sysctl -w net.ipv4.tcp_congestion_control=cubic"
        return 0
    fi

    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

    if grep -q '^net.core.default_qdisc=' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.core.default_qdisc=.*/net.core.default_qdisc=fq/' /etc/sysctl.conf
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi

    if grep -q '^net.ipv4.tcp_congestion_control=' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.ipv4.tcp_congestion_control=.*/net.ipv4.tcp_congestion_control=bbr/' /etc/sysctl.conf
    else
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    sysctl -p >/dev/null 2>&1 || warn "sysctl -p reported an issue applying /etc/sysctl.conf — check it for unrelated bad lines. BBR settings were still written to the file."
    echo "Persisted. BBR + fq will survive reboots — confirmed via:"
    sysctl net.ipv4.tcp_congestion_control
    return 0
}

# Reverts TCP congestion control from BBR back to CUBIC, live and persisted.
# Mirrors enable_bbr(): checks current state first, is idempotent, and
# undoes exactly what enable_bbr() wrote (sysctl.conf line + the
# modules-load.d entry) rather than blindly overwriting unrelated settings.
# Leaves the fq qdisc in place deliberately — fq works fine under CUBIC too
# and there's no CUBIC-specific qdisc to restore instead.
revert_to_cubic() {
    local current persisted_bbr

    info "TCP congestion control: revert to CUBIC"
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    echo "Current: $current"

    persisted_bbr=false
    if grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null; then
        persisted_bbr=true
    fi

    if [[ "$current" == "cubic" && "$persisted_bbr" == false ]]; then
        echo "Already on CUBIC and nothing BBR-related is persisted — nothing to do."
        return 0
    fi

    read -rp "Switch TCP congestion control back to CUBIC now (live)? [Y/n]: " CONFIRM_CUBIC
    CONFIRM_CUBIC="${CONFIRM_CUBIC:-Y}"
    if [[ ! "$CONFIRM_CUBIC" =~ ^[Yy]$ ]]; then
        warn "Aborted. No changes made."
        return 0
    fi

    if ! sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1; then
        warn "Could not switch to CUBIC live. Is it in tcp_available_congestion_control?"
        return 1
    fi
    current=$(sysctl -n net.ipv4.tcp_congestion_control)
    echo "Active now: $current"

    if [[ "$persisted_bbr" == false && ! -f /etc/modules-load.d/bbr.conf ]]; then
        echo "No persisted BBR config found — live switch is enough, nothing to undo on disk."
        return 0
    fi

    read -rp "Also remove the persisted BBR config so it stays CUBIC after reboot? [Y/n]: " CONFIRM_PERSIST_CUBIC
    CONFIRM_PERSIST_CUBIC="${CONFIRM_PERSIST_CUBIC:-Y}"
    if [[ ! "$CONFIRM_PERSIST_CUBIC" =~ ^[Yy]$ ]]; then
        warn "Not persisted. It will revert back to BBR on reboot (BBR is still configured on disk)."
        return 0
    fi

    if grep -q '^net.ipv4.tcp_congestion_control=' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.ipv4.tcp_congestion_control=.*/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
    fi

    # Only the module autoload entry gets removed here — see the function
    # comment above for why fq itself is left alone.
    if [[ -f /etc/modules-load.d/bbr.conf ]]; then
        rm -f /etc/modules-load.d/bbr.conf
    fi

    sysctl -p >/dev/null 2>&1 || warn "sysctl -p reported an issue applying /etc/sysctl.conf — check it for unrelated bad lines. CUBIC setting was still written to the file."
    echo "Persisted. CUBIC will survive reboots — confirmed via:"
    sysctl net.ipv4.tcp_congestion_control
    return 0
}

# Small submenu wrapper for the main menu's congestion-control option, so
# BBR and its revert-to-CUBIC counterpart share one numbered slot instead
# of pushing every later option up by one.
congestion_control_menu() {
    local current
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

    echo ""
    info "TCP congestion control (currently: ${current})"
    echo "  1) Enable BBR"
    echo "  2) Revert to CUBIC"
    echo "  3) Back to main menu"
    read -rp "Select an option [1-3]: " CC_CHOICE

    case "$CC_CHOICE" in
        1) enable_bbr || warn "BBR setup did not fully complete — see messages above." ;;
        2) revert_to_cubic || warn "Revert to CUBIC did not fully complete — see messages above." ;;
        3) return 0 ;;
        *) warn "Not a valid option." ;;
    esac
}

# ============================================================
# ---------- module: DNS-over-TLS (encrypted DNS) ----------
# Switches the host's DNS resolution to DNS-over-TLS, so provider- or
# datacenter-assigned resolvers (e.g. a cloud host's metadata-service DNS
# proxy) are never used, and queries are encrypted end-to-end. Touches two
# places:
#   - /etc/systemd/resolved.conf   (DNS=, FallbackDNS=, DNSOverTLS=yes)
#   - /etc/netplan/90-dns-toolkit.yaml   (nameservers: + dhcp4-overrides.
#                                          use-dns: false, so DHCP-supplied
#                                          DNS is never even registered, not
#                                          just overridden)
# The netplan side writes to its OWN dedicated file rather than patching
# whatever cloud-init generated (usually 50-cloud-init.yaml) - that file is
# rewritten by cloud-init on every boot (confirmed by hand on Ubuntu 26.04:
# DHCP-assigned DNS was back and live on the primary interface after a
# reboot, even though the systemd-resolved side was still correctly set).
# Netplan merges every file under /etc/netplan/ in lexical order, so this
# module's higher-numbered file wins on nameservers/dhcp4-overrides for the
# same interface, and survives cloud-init doing its normal job untouched.
# The interface's identity (match:/macaddress: block if present, otherwise
# just the interface name) is read from the base file and mirrored into the
# override file, so it keeps applying to the right NIC either way.
# ============================================================

# Built-in provider pairs. Picking one uses the OTHER built-in provider as
# fallback, so primary and fallback are always two different operators -
# never two servers from the same company.
_DNS_CLOUDFLARE_IP1="1.1.1.1"; _DNS_CLOUDFLARE_IP2="1.0.0.1"; _DNS_CLOUDFLARE_HOST="cloudflare-dns.com"
_DNS_QUAD9_IP1="9.9.9.9"; _DNS_QUAD9_IP2="149.112.112.112"; _DNS_QUAD9_HOST="dns.quad9.net"

# The toolkit's own netplan file. Deliberately NOT the cloud-init-generated
# file (usually /etc/netplan/50-cloud-init.yaml) - that file is rewritten by
# cloud-init on every boot (it says so in its own header comment), which
# silently reverted this module's nameservers/dhcp4-overrides block on the
# very first reboot after applying it (confirmed by hand: DHCP-assigned DNS
# was back and live on the primary interface after reboot, even though
# /etc/systemd/resolved.conf's Global scope was untouched and still correct).
# Netplan merges every file under /etc/netplan/ in lexical order, so a HIGHER
# numbered file wins on any key it sets for the same interface - this file's
# nameservers/dhcp4-overrides override whatever cloud-init writes into its
# own lower-numbered file, and cloud-init regenerating that file on every
# boot no longer matters.
_DNS_NETPLAN_FILE="/etc/netplan/90-dns-toolkit.yaml"

# Finds whatever OTHER (non-toolkit) netplan file currently defines the
# interface - normally cloud-init's file. This is read-only: only used to
# copy the interface's existing identity (match/macaddress or plain name)
# into the toolkit's own override file, never edited itself. Errors out
# rather than guessing if there's more than one candidate, or none.
_dns_base_netplan_file() {
    local f files=()
    for f in /etc/netplan/*.yaml; do
        [[ -e "$f" ]] || continue
        [[ "$f" == "$_DNS_NETPLAN_FILE" ]] && continue
        files+=("$f")
    done
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "No netplan YAML file found under /etc/netplan/ (other than the toolkit's own) -"
        warn "skipping netplan changes. (Expected on non-Ubuntu hosts. /etc/systemd/resolved.conf"
        warn "is still updated, so DNS changes apply now - but without netplan there's nothing"
        warn "here stopping DHCP from re-asserting its own DNS on this interface later.)"
        return 1
    fi
    if [[ ${#files[@]} -gt 1 ]]; then
        warn "Multiple netplan files found under /etc/netplan/: ${files[*]}"
        warn "Not guessing which one defines the interface - edit netplan manually, or remove"
        warn "the extras first."
        return 1
    fi
    echo "${files[0]}"
}

# Extracts the interface name from the first entry under 'ethernets:' in a
# netplan YAML file. Uses literal space counts, not [:space:]{n} interval
# regex - Ubuntu's default /usr/bin/awk is mawk, which doesn't support
# interval quantifiers without a non-default flag.
_dns_detect_iface() {
    local file="$1"
    awk '
        /^  ethernets:/ { in_eth=1; next }
        in_eth && /^    [A-Za-z0-9_.-]+:/ {
            line=$0; gsub(/^[ ]+/,"",line); gsub(/:.*$/,"",line); print line; exit
        }
    ' "$file"
}

# Extracts whatever "match:" block (usually macaddress:) the base file uses
# to identify the interface, if any. Printed verbatim (already indented at
# the "match:"/"macaddress:" level, i.e. 6 spaces in the base file) so it can
# be reused as-is in the override file, which nests the interface at the
# same depth. If the base file has no match block (plain interface name,
# e.g. bare "eth0: dhcp4: true"), nothing is printed - the override file then
# matches by interface name alone, same as the base file does.
_dns_detect_match_block() {
    local file="$1" iface="$2"
    awk -v iface="$iface" '
        BEGIN { in_iface=0; in_match=0 }
        $0 ~ "^    "iface":" { in_iface=1; next }
        in_iface && /^    [A-Za-z0-9_.-]+:/ { exit }
        in_iface && /^      match:/ { in_match=1; print; next }
        in_iface && in_match {
            if ($0 ~ /^        /) { print; next }
            in_match=0
        }
    ' "$file"
}

# Writes/refreshes the toolkit's own netplan override file so that:
#   - the interface is identified the SAME way the base (cloud-init) file
#     identifies it - match:/macaddress: block copied verbatim if present,
#     otherwise just the bare interface name - so this file keeps applying
#     to the right NIC even if cloud-init regenerates its own file
#   - dhcp4-overrides: use-dns: false   (DHCP-supplied DNS never registered)
#   - nameservers: addresses: [...]     (explicit resolver list)
# Idempotent: the file is fully rewritten from scratch each run, so
# re-running never duplicates anything or leaves stale state behind.
# Prints the interface name on success (used by the caller to clear its
# live resolver cache immediately, rather than waiting for a reboot).
_dns_write_netplan() {
    local base_file="$1" ip1="$2" ip2="$3"

    local iface
    iface=$(_dns_detect_iface "$base_file")
    [[ -n "$iface" ]] || { warn "Could not find an interface under 'ethernets:' in $base_file - leaving netplan untouched."; return 1; }

    local match_block
    match_block=$(_dns_detect_match_block "$base_file" "$iface")

    {
        echo "network:"
        echo "  version: 2"
        echo "  ethernets:"
        echo "    ${iface}:"
        [[ -n "$match_block" ]] && printf '%s\n' "$match_block"
        echo "      dhcp4-overrides:"
        echo "        use-dns: false"
        echo "      nameservers:"
        echo "        addresses: [${ip1}, ${ip2}]"
    } > "$_DNS_NETPLAN_FILE"

    # Netplan requires its config files to be root-only (mode 600) and warns
    # (harmlessly, but repeatedly) otherwise - the plain '>' redirect above
    # inherits the shell's umask instead, which is usually more permissive
    # than netplan wants (confirmed by hand: got three "Permissions ... too
    # open" warnings from netplan apply on a freshly-written file at the
    # default umask). chown/chmod explicitly rather than relying on umask,
    # since umask isn't guaranteed to be the same on every host this runs on.
    chown root:root "$_DNS_NETPLAN_FILE"
    chmod 600 "$_DNS_NETPLAN_FILE"

    echo "$iface"
}

# Sets DNS=/FallbackDNS=/DNSOverTLS=yes/Domains=~. in /etc/systemd/resolved.conf.
# Replaces any existing LIVE (uncommented) line for each key; otherwise
# inserts a new line right after the [Resolve] header. The stock file's
# commented example lines are left untouched either way - only real, active
# keys are ever modified.
#
# Domains=~. is what actually keeps this module honest. Without it, a link
# that ends up with its OWN per-link DNS servers registered - which happens
# here because netplan MERGES (unions) nameservers.addresses across config
# files rather than letting a later file replace an earlier one, so cloud-
# init's file and this module's override file both contribute to the same
# interface's live resolver list - can end up preferred over the Global
# scope for ordinary queries, since systemd-resolved treats a link's own
# servers as usable for the same "~." (root) routing domain Global also
# serves, and tends to prefer the more specific/local scope. Confirmed by
# hand on Ubuntu 26.04: after a reboot, eth0 showed a live per-link DNS
# scope with the ORIGINAL plaintext DHCP/static resolver still present
# alongside the new one, while Global correctly showed DNSOverTLS - i.e.
# the encrypted config was present but not necessarily what was actually
# being used. Domains=~. makes Global explicitly authoritative for every
# domain, which is the documented fix for exactly this Global-vs-per-link
# precedence problem, and makes the per-link merge quirk harmless rather
# than something that has to be worked around at the netplan layer.
_dns_write_resolved_conf() {
    local dns_line="$1" fallback_line="$2"
    local file="/etc/systemd/resolved.conf"
    local pristine="${file}.pre-dns-toolkit"
    [[ -f "$pristine" ]] || cp "$file" "$pristine"
    local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$file" "$backup"

    grep -q '^\[Resolve\]' "$file" || { warn "No [Resolve] section found in $file - aborting DNS changes."; return 1; }

    local key value
    for pair in "DNS=$dns_line" "FallbackDNS=$fallback_line" "DNSOverTLS=yes" "Domains=~."; do
        key="${pair%%=*}"
        value="${pair#*=}"
        [[ "$key" == "FallbackDNS" && -z "$value" ]] && continue
        if grep -q "^${key}=" "$file"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$file"
        else
            sed -i "/^\[Resolve\]/a ${key}=${value}" "$file"
        fi
    done
}

# Restores /etc/systemd/resolved.conf to whatever it was BEFORE this module
# ever touched it (the "pre-dns-toolkit" copy, saved once on first use - not
# the per-switch timestamped backups, which would just restore the previous
# provider instead of the true original), and removes the toolkit's own
# netplan override file entirely. The base (cloud-init) netplan file is
# never touched by this module in the first place, so there's nothing to
# restore there - deleting the override file and letting netplan re-apply
# is enough for DHCP-assigned DNS to take over again.
restore_default_dns() {
    info "Restoring original (pre-toolkit) DNS configuration"
    local resolved_file="/etc/systemd/resolved.conf"
    local resolved_pristine="${resolved_file}.pre-dns-toolkit"
    local restored_any=false

    if [[ -f "$resolved_pristine" ]]; then
        cp "$resolved_pristine" "$resolved_file"
        echo "Restored $resolved_file from its pre-toolkit backup."
        restored_any=true
    else
        echo "No pre-toolkit backup found for $resolved_file - this module may never have changed it."
    fi

    if [[ -f "$_DNS_NETPLAN_FILE" ]]; then
        rm -f "$_DNS_NETPLAN_FILE"
        echo "Removed $_DNS_NETPLAN_FILE (the toolkit's own override - the base netplan file was never touched)."
        restored_any=true
    else
        echo "No toolkit netplan override file found at $_DNS_NETPLAN_FILE - this module may never have changed it."
    fi

    if [[ "$restored_any" == false ]]; then
        warn "Nothing to restore - DNS-over-TLS doesn't appear to have been set up yet."
        return 1
    fi

    read -rp "Apply the restored config now (netplan apply + restart systemd-resolved)? [Y/n]: " CONFIRM_RESTORE
    CONFIRM_RESTORE="${CONFIRM_RESTORE:-Y}"
    if [[ ! "$CONFIRM_RESTORE" =~ ^[Yy]$ ]]; then
        warn "Files restored but not applied. Run 'netplan apply' and 'systemctl restart systemd-resolved' manually, or re-run this option."
        return 0
    fi

    netplan apply || warn "netplan apply reported an issue - check the output above."

    # Restoring the netplan file removes our explicit nameservers/
    # dhcp4-overrides block, but that alone doesn't make DHCP-assigned DNS
    # (whatever the provider hands out) show up again - confirmed by hand:
    # neither a lone interface down/up cycle nor restarting systemd-resolved
    # on its own was enough. This is a known systemd-networkd quirk (DNS
    # info from a live lease renewal doesn't reliably get pushed to
    # systemd-resolved over D-Bus) - a full restart of the networkd DAEMON
    # itself is what reliably fixes it. Order matters: networkd first, so it
    # has fresh DHCP data to publish, THEN resolved, so it actually picks
    # that data up rather than restarting into an empty state again.
    info "Restarting systemd-networkd (picks up DHCP-assigned DNS immediately, no reboot needed)"
    systemctl restart systemd-networkd || warn "Could not restart systemd-networkd. DNS may not reappear until the next reboot - run 'sudo reboot' if 'resolvectl status' below still looks empty."
    sleep 3

    systemctl restart systemd-resolved

    sleep 1
    echo ""
    echo "=== Result ==="
    resolvectl status --no-pager
    return 0
}

# Preflight compatibility check. resolvectl EXISTING isn't enough proof this
# module is safe to run - the binary ships as part of systemd itself, so it
# can be present on a box where systemd-resolved isn't actually the active
# resolver (common on plain Debian, which favours ifupdown/NetworkManager
# and doesn't enable systemd-resolved by default the way Ubuntu does).
# Running the DNS-writing logic against an inactive resolved would edit
# files that nothing is actually reading, and REPORT success. This module
# was also built and tested specifically against Ubuntu 24.04's stack
# (netplan + systemd-networkd + systemd-resolved, including the
# networkd-restart quirk in restore_default_dns) - flags anything else
# rather than assuming it behaves the same way.
# OS+version combos this module has actually been run against, end-to-end
# (apply, switch, restore) and confirmed working. Add a "id:version" entry
# here only after doing that - not just after reading the code and assuming
# it should work. VERSION_ID from /etc/os-release, e.g. "24.04", "12", "13".
_DNS_TESTED_OS_VERSIONS=(
    "ubuntu:24.04"
    "ubuntu:26.04"
)

_dns_check_prereqs() {
    local os_id="" os_version=""
    if [[ -f /etc/os-release ]]; then
        os_id=$(. /etc/os-release 2>/dev/null; echo "$ID")
        os_version=$(. /etc/os-release 2>/dev/null; echo "$VERSION_ID")
    fi

    if ! require_cmd resolvectl; then
        warn "resolvectl not found - this module needs systemd-resolved. Aborting."
        return 1
    fi
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        warn "resolvectl is present, but systemd-resolved isn't the active resolver on this host"
        warn "(systemctl is-active systemd-resolved reports it's not running). Writing DNS config"
        warn "here would edit files nothing is actually reading. Aborting rather than report a"
        warn "false success - if this host should be using systemd-resolved, enable it first:"
        warn "  sudo systemctl enable --now systemd-resolved"
        return 1
    fi

    local key="${os_id}:${os_version}" tested=false entry
    for entry in "${_DNS_TESTED_OS_VERSIONS[@]}"; do
        [[ "$entry" == "$key" ]] && { tested=true; break; }
    done

    if [[ "$tested" == false ]]; then
        warn "This module has only been verified end-to-end on: ${_DNS_TESTED_OS_VERSIONS[*]}"
        warn "Detected: ${os_id:-unknown} ${os_version:-unknown} - not on that list yet."
        warn "Untested doesn't mean broken, just unconfirmed - the netplan step (silently"
        warn "skipped if no netplan file exists) and the Restore option's networkd-restart"
        warn "fix (which assumes networkd is what's actually managing DHCP) are the parts"
        warn "most likely to behave differently on a distro/version this hasn't been run on."
        read -rp "Continue anyway on this untested OS/version? [y/N]: " CONFIRM_OS_DNS
        [[ "$CONFIRM_OS_DNS" =~ ^[Yy]$ ]] || { echo "Aborted - no changes made."; return 1; }
    fi

    return 0
}

setup_dot_dns() {
    info "DNS-over-TLS (encrypted DNS, bypasses provider/datacenter DNS)"
    _dns_check_prereqs || return 1

    echo "Current resolver:"
    resolvectl status | grep -E "Current DNS Server|DNSOverTLS" | sed 's/^/  /'
    echo ""
    echo "  1) Cloudflare  (1.1.1.1 / 1.0.0.1, fallback: Quad9)"
    echo "  2) Quad9       (9.9.9.9 / 149.112.112.112, fallback: Cloudflare)"
    echo "  3) Custom resolver"
    echo "  4) Restore original (pre-toolkit) DNS config"
    echo "  5) Back"
    read -rp "Choose an option [1-5]: " DNS_CHOICE

    local p_ip1="" p_ip2="" p_host="" f_ip1="" f_ip2="" f_host=""
    case "$DNS_CHOICE" in
        1)
            p_ip1="$_DNS_CLOUDFLARE_IP1"; p_ip2="$_DNS_CLOUDFLARE_IP2"; p_host="$_DNS_CLOUDFLARE_HOST"
            f_ip1="$_DNS_QUAD9_IP1"; f_ip2="$_DNS_QUAD9_IP2"; f_host="$_DNS_QUAD9_HOST"
            ;;
        2)
            p_ip1="$_DNS_QUAD9_IP1"; p_ip2="$_DNS_QUAD9_IP2"; p_host="$_DNS_QUAD9_HOST"
            f_ip1="$_DNS_CLOUDFLARE_IP1"; f_ip2="$_DNS_CLOUDFLARE_IP2"; f_host="$_DNS_CLOUDFLARE_HOST"
            ;;
        3)
            echo ""
            echo "DoT needs a hostname alongside each IP, for certificate validation."
            read -rp "Primary DNS IP: " p_ip1
            read -rp "Primary DNS hostname (for TLS cert validation): " p_host
            read -rp "Second primary DNS IP (optional, blank to skip): " p_ip2
            read -rp "Fallback DNS IP (optional, blank to skip): " f_ip1
            if [[ -n "$f_ip1" ]]; then
                read -rp "Fallback DNS hostname: " f_host
                read -rp "Second fallback DNS IP (optional, blank to skip): " f_ip2
            fi
            [[ -n "$p_ip1" && -n "$p_host" ]] || { warn "Primary IP and hostname are required. Aborted."; return 1; }
            ;;
        4) restore_default_dns; return $? ;;
        *) echo "Cancelled."; return 0 ;;
    esac

    local dns_line="${p_ip1}#${p_host}"
    [[ -n "$p_ip2" ]] && dns_line="${dns_line} ${p_ip2}#${p_host}"
    local fallback_line=""
    if [[ -n "$f_ip1" ]]; then
        fallback_line="${f_ip1}#${f_host}"
        [[ -n "$f_ip2" ]] && fallback_line="${fallback_line} ${f_ip2}#${f_host}"
    fi

    echo ""
    echo "This will set:"
    echo "  Primary:  ${dns_line}"
    [[ -n "$fallback_line" ]] && echo "  Fallback: ${fallback_line}"
    echo "  DNS-over-TLS: enforced (DNSOverTLS=yes)"
    echo "  DHCP-supplied DNS: disabled on the primary interface (netplan dhcp4-overrides)"
    read -rp "Apply this now? [y/N]: " CONFIRM_DNS
    [[ "$CONFIRM_DNS" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 0; }

    info "Updating /etc/systemd/resolved.conf"
    _dns_write_resolved_conf "$dns_line" "$fallback_line" || return 1

    local iface=""
    local base_nfile
    if base_nfile=$(_dns_base_netplan_file); then
        info "Writing netplan override ($_DNS_NETPLAN_FILE, base interface def read from $base_nfile)"
        iface=$(_dns_write_netplan "$base_nfile" "$p_ip1" "${p_ip2:-$p_ip1}")
        if [[ -n "$iface" ]]; then
            echo "Applying netplan..."
            netplan apply || warn "netplan apply reported an issue - check the output above."
        fi
    fi

    info "Restarting systemd-resolved"
    systemctl restart systemd-resolved

    # Clears any DHCP-supplied per-link resolver still cached from before
    # this run, so the change takes effect immediately rather than waiting
    # for the next DHCP lease renewal or reboot.
    if [[ -n "$iface" ]]; then
        resolvectl dns "$iface" "" 2>/dev/null || true
    fi

    sleep 1
    echo ""
    echo "=== Result ==="
    resolvectl status --no-pager
    echo ""

    # Netplan MERGES (unions) nameservers.addresses across config files
    # rather than letting a higher-numbered file replace a lower one - so
    # the base (e.g. cloud-init) file's original resolvers and this
    # module's resolvers both end up registered on the same link. After a
    # reboot in particular, it's normal and expected for the primary
    # interface above to show a "Current Scopes: DNS" line listing the
    # ORIGINAL provider/DHCP resolvers (e.g. 8.8.8.8) alongside the new
    # ones - that's cosmetic, not a sign this didn't work. Domains=~. in
    # resolved.conf (set above) is what actually makes Global authoritative
    # for every domain regardless of what any per-link scope shows, so the
    # status listing is not what proves encryption is active - only an
    # actual query does, which is why the check below runs one and checks
    # the result, rather than asking you to eyeball the status output above.
    echo "Test query (this, not the status above, is what actually confirms it's working):"
    local query_output query_status
    query_output=$(resolvectl query example.com 2>&1)
    query_status=$?
    echo "$query_output"
    echo ""
    if [[ $query_status -eq 0 ]] && grep -q "encrypted transport: yes" <<<"$query_output"; then
        echo "PASS: resolution is going through the encrypted path (Global/DNSOverTLS), regardless"
        echo "of which resolvers any individual link above happens to list."
    else
        warn "Query did not confirm encrypted transport - see output above. Encryption may not be"
        warn "active even if the status block above looks correct; this is the check that matters."
    fi
    return 0
}

# ============================================================
# ---------- module: scheduled reboot + time sync ----------
# Sets an optional timezone, adds/updates a daily reboot cron job for root,
# and ensures the clock stays accurate via systemd-timesyncd/NTP (so the
# scheduled time doesn't drift). Pulled from scheduled-reboot-guide.md,
# generalized (was hardcoded to one server's 6:30 AM Europe/London) and
# made idempotent via a marker comment on the cron line so re-running
# updates the existing entry instead of duplicating it.
# ============================================================

setup_scheduled_reboot() {
    local cron_marker="# aio-toolkit: scheduled-reboot"

    info "Scheduled reboot + clock sync"

    local existing_line
    existing_line=$(crontab -l 2>/dev/null | grep -F "$cron_marker" || true)
    if [[ -n "$existing_line" ]]; then
        echo "Existing scheduled reboot found:"
        echo "  $existing_line"
    else
        echo "No scheduled reboot currently set up."
    fi
    echo ""

    # --- frequency (asked first so "disable" can bail out before any other
    # prompts — no point asking about timezone/time if you're just turning
    # the whole thing off) ---
    local freq_choice frequency
    echo "How often should the reboot run?"
    echo "  1) Daily"
    echo "  2) Weekly"
    echo "  3) Monthly"
    echo "  4) Disable / remove the current scheduled reboot"
    read -rp "Select [1-4] (default 1): " freq_choice
    freq_choice="${freq_choice:-1}"
    case "$freq_choice" in
        1) frequency="daily" ;;
        2) frequency="weekly" ;;
        3) frequency="monthly" ;;
        4) frequency="disable" ;;
        *) warn "'$freq_choice' isn't a valid choice. Aborting — no changes made to the cron job."; return 1 ;;
    esac

    if [[ "$frequency" == "disable" ]]; then
        if [[ -z "$existing_line" ]]; then
            echo "Nothing to disable, there's no scheduled reboot set up right now."
            return 0
        fi
        (crontab -l 2>/dev/null | grep -vF "$cron_marker" || true) | crontab -
        echo "Scheduled reboot removed. (Clock sync via systemd-timesyncd, if it was enabled, is left as-is.)"
        return 0
    fi

    # --- timezone (optional) ---
    local current_tz
    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
    echo ""
    read -rp "Current timezone is '$current_tz'. Enter an IANA timezone to change it (e.g. Europe/London), or leave blank to keep it: " NEW_TZ
    if [[ -n "$NEW_TZ" ]]; then
        if timedatectl set-timezone "$NEW_TZ" 2>/dev/null; then
            echo "Timezone set to $NEW_TZ."
        else
            warn "Could not set timezone to '$NEW_TZ' — check the name is a valid IANA zone (see: timedatectl list-timezones)."
        fi
    fi

    # --- day (only for weekly/monthly) ---
    local dom="*" dow="*"
    if [[ "$frequency" == "weekly" ]]; then
        local day_input day_lc
        echo ""
        echo "Day of the week to reboot. Enter a name (Sun, Mon, Tue, Wed, Thu, Fri, Sat)"
        echo "or a number (0/7=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat)."
        read -rp "Day (default Sun): " day_input
        day_input="${day_input:-Sun}"
        day_lc=$(echo "$day_input" | tr '[:upper:]' '[:lower:]')
        case "$day_lc" in
            sun|sunday|0|7) dow=0 ;;
            mon|monday|1)   dow=1 ;;
            tue|tues|tuesday|2) dow=2 ;;
            wed|weds|wednesday|3) dow=3 ;;
            thu|thur|thurs|thursday|4) dow=4 ;;
            fri|friday|5)   dow=5 ;;
            sat|saturday|6) dow=6 ;;
            *)
                warn "'$day_input' isn't a day I recognize. Aborting — no changes made to the cron job."
                return 1
                ;;
        esac
    elif [[ "$frequency" == "monthly" ]]; then
        local day_num
        read -rp "Day of the month to reboot, 1-28 (default 1; capped at 28 so it fires every month): " day_num
        day_num="${day_num:-1}"
        if [[ ! "$day_num" =~ ^([1-9]|1[0-9]|2[0-8])$ ]]; then
            warn "'$day_num' isn't valid — enter a number from 1 to 28. Aborting — no changes made to the cron job."
            return 1
        fi
        dom="$day_num"
    fi

    # --- reboot time ---
    local reboot_time hour minute
    read -rp "Reboot time, 24h HH:MM (default 06:30, matching your current timezone): " reboot_time
    reboot_time="${reboot_time:-06:30}"
    if [[ ! "$reboot_time" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
        warn "'$reboot_time' isn't a valid HH:MM time. Aborting — no changes made to the cron job."
        return 1
    fi
    hour="${reboot_time%%:*}"
    minute="${reboot_time##*:}"
    # Strip any leading zero so bash doesn't treat e.g. "08"/"09" as invalid octal.
    hour=$((10#$hour))
    minute=$((10#$minute))

    local new_line="${minute} ${hour} ${dom} * ${dow} /sbin/shutdown -r now  ${cron_marker}"
    # Idempotent update: drop any prior line carrying our marker, then add
    # the new one — re-running this always leaves exactly one such entry.
    # NOTE: 'crontab -l' exits non-zero (with an empty/no-op stream) if root
    # has never had a crontab before — the normal state on a fresh droplet.
    # Under this script's 'set -e', an unguarded failure here would kill the
    # ENTIRE subshell (and take the whole cron-add step down with it) before
    # 'echo "$new_line"' ever ran. The '|| true' makes an empty/missing
    # crontab a non-event, same as the read-only check above.
    (crontab -l 2>/dev/null | grep -vF "$cron_marker" || true; echo "$new_line") | crontab -

    local schedule_desc="daily"
    if [[ "$frequency" == "weekly" ]]; then
        local -a day_names=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
        schedule_desc="weekly on ${day_names[$dow]}"
    elif [[ "$frequency" == "monthly" ]]; then
        schedule_desc="monthly on day ${dom}"
    fi
    echo "Scheduled: reboot ${schedule_desc} at ${reboot_time} ($(timedatectl show -p Timezone --value 2>/dev/null))."

    # --- NTP / clock sync ---
    echo ""
    info "Clock synchronization (keeps the reboot time accurate over the long run)"
    if dpkg -s systemd-timesyncd >/dev/null 2>&1; then
        echo "systemd-timesyncd already installed."
    else
        echo "Installing systemd-timesyncd..."
        apt-get update -qq || warn "apt update failed — continuing, install may use stale package lists."
        apt-get install -y -qq systemd-timesyncd || { warn "systemd-timesyncd install failed."; return 1; }
    fi
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    timedatectl set-ntp true

    echo ""
    timedatectl | grep -E "synchronized|NTP service|Time zone" || timedatectl

    echo ""
    echo "Note: this reboot is unconditional (happens on schedule regardless of need) and is"
    echo "separate from unattended-upgrades' own occasional reboot-on-patch behavior."
    echo "If you've also enabled automatic security updates (hardening module), it's"
    echo "worth checking Automatic-Reboot-Time in /etc/apt/apt.conf.d/50unattended-upgrades"
    echo "doesn't land at the same moment as this cron job."
    return 0
}


# Read-only: shows whatever scheduled-reboot cron line aio-toolkit currently
# owns (if any) and translates it into plain English, without touching
# timezone, frequency, or NTP. Separate from setup_scheduled_reboot so you
# can check status without wading through the setup prompts.
check_scheduled_reboot_status() {
    local cron_marker="# aio-toolkit: scheduled-reboot"
    local existing_line

    info "Scheduled reboot status"

    existing_line=$(crontab -l 2>/dev/null | grep -F "$cron_marker" || true)
    if [[ -z "$existing_line" ]]; then
        echo "No scheduled reboot is currently set up."
        return 0
    fi

    local minute hour dom dow rest
    read -r minute hour dom _ dow rest <<< "$existing_line"

    local -a day_names=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
    local schedule_desc time_str
    time_str=$(printf '%02d:%02d' "$hour" "$minute")

    if [[ "$dom" != "*" ]]; then
        schedule_desc="monthly on day ${dom}"
    elif [[ "$dow" != "*" ]]; then
        schedule_desc="weekly on ${day_names[$dow]}"
    else
        schedule_desc="daily"
    fi

    echo "Reboot scheduled: ${schedule_desc} at ${time_str}"
    echo "  (system timezone: $(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown"))"
    echo ""
    echo "Raw cron line: $existing_line"
    return 0
}

# ============================================================
# ---------- entry checks ----------
# ============================================================

# Purely informational, computed once - shown in the menu header every loop
# so it's obvious what OS/version any given run (or screenshot) was against.
# No gating here; only the DNS-over-TLS module actually checks this against
# a tested-version list, since it's the only module with genuinely
# OS-specific mechanics (netplan, systemd-networkd). Everything else in this
# toolkit is built on portable apt/systemd primitives.
_TOOLKIT_OS_LABEL="unknown OS"
if [[ -f /etc/os-release ]]; then
    _detected_id=$(. /etc/os-release 2>/dev/null; echo "$ID")
    _detected_version=$(. /etc/os-release 2>/dev/null; echo "$VERSION_ID")
    [[ -n "$_detected_id" ]] && _TOOLKIT_OS_LABEL="${_detected_id}${_detected_version:+ $_detected_version}"
fi


if [[ $EUID -ne 0 ]]; then
    error "This script needs root privileges. Re-run with: sudo $0"
fi

for REQUIRED_CMD in curl awk sed grep; do
    require_cmd "$REQUIRED_CMD" || error "Required command '$REQUIRED_CMD' not found. Install it and re-run this script."
done

# ============================================================
# ---------- main menu loop ----------
# Numbering is a first pass, not final — expect this to be reorganized into
# categories once the rest of the toolkit is folded in.
# ============================================================

while true; do
    echo ""
    info "aio-toolkit — utility menu"
    echo "Detected OS: ${_TOOLKIT_OS_LABEL}"
    echo ""
    echo "  1) System maintenance (update, upgrade, cleanup, journal trim, history)"
    echo "  2) Check / set up swap space (auto-sized to your RAM, skips if already present)"
    echo "  3) Harden server (fail2ban / UFW / automatic security updates, each optional)"
    echo "  4) TCP congestion control (enable BBR / revert to CUBIC)"
    echo "  5) DNS-over-TLS (Cloudflare / Quad9 / custom — bypasses provider DNS)"
    echo "  6) Set up scheduled reboot (daily/weekly/monthly) + clock sync (NTP)"
    echo "  7) Check current scheduled reboot status (read-only, no prompts)"
    echo "  8) Check root SSH login status (across every sshd config file, not just one)"
    echo "  9) Create a non-root sudo user (adds them, sudo group, copies root's SSH key)"
    echo " 10) Enable root SSH login (copies your key, sets PermitRootLogin, restarts sshd)"
    echo " 11) Passwordless sudo for a user (real security trade-off — reads warnings)"
    echo " 12) Disable root SSH login (locks it down — reads warnings before proceeding)"
    echo " 13) Remove a user (permanent — reads warnings, requires typed confirmation)"
    echo " 14) Exit"
    echo ""
    read -rp "Select an option [1-14]: " MENU_CHOICE

    case "$MENU_CHOICE" in
        1)
            system_maintenance || warn "Maintenance did not fully complete — see messages above."
            press_enter
            ;;
        2)
            echo ""
            echo "=== Swap Status ==="
            free -h
            echo ""
            setup_swap || true
            press_enter
            ;;
        3)
            harden_server || warn "Hardening did not fully complete — see messages above. Safe to re-run any time."
            press_enter
            ;;
        4)
            congestion_control_menu
            press_enter
            ;;
        5)
            setup_dot_dns || warn "DNS setup did not fully complete — see messages above. Safe to re-run any time."
            press_enter
            ;;
        6)
            setup_scheduled_reboot || warn "Scheduled reboot setup did not fully complete — see messages above."
            press_enter
            ;;
        7)
            check_scheduled_reboot_status
            press_enter
            ;;
        8)
            check_root_login_status
            press_enter
            ;;
        9)
            create_sudo_user || warn "User creation did not fully complete — see messages above."
            press_enter
            ;;
        10)
            enable_root_ssh || warn "Root SSH setup did not fully complete — see messages above."
            press_enter
            ;;
        11)
            setup_passwordless_sudo || warn "Passwordless sudo setup did not fully complete — see messages above."
            press_enter
            ;;
        12)
            disable_root_login || warn "Disabling root SSH login did not fully complete — see messages above."
            press_enter
            ;;
        13)
            remove_user || warn "User removal did not fully complete — see messages above."
            press_enter
            ;;
        14)
            echo "Exiting."
            exit 0
            ;;
        *)
            warn "Not a valid option."
            ;;
    esac
done
