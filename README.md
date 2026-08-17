# Linux AIO Toolkit

A single interactive script bundling common Ubuntu/Debian VPS setup and maintenance tasks — the stuff you'd otherwise do by hand every time you log into a fresh server, or hunt down in a pile of separate one-off scripts.

> **⚠️ Compatibility notice**
> This toolkit is tested end-to-end only on **Ubuntu 24.04 LTS**. It has *not* been verified on Debian (12/13) or other Ubuntu releases (e.g. 26.04) yet. Most modules are plain `apt`/`systemd` operations likely to work fine elsewhere — but the **DNS-over-TLS** module specifically relies on Ubuntu-specific behavior (netplan, systemd-networkd) that may not exist or may work differently on other distros/versions. That module checks its own compatibility at runtime and will warn and ask for confirmation before running on anything outside its tested list — see [Safety design](#safety-design).
>
> Use on other distros/versions at your own risk. PRs adding verified support for additional OS/version combos are welcome.

## What this gives you

- One script, one menu, that keeps returning to itself after each action — run several things back to back without relaunching
- Every module is **idempotent**: safe to re-run any time, checks what's already done before doing it
- Real safety checks before anything session- or account-destroying — not just a confirmation prompt, but actual verification (see [Safety design](#safety-design) below)
- No install step, no dependencies beyond what Ubuntu/Debian already ships — it's a single self-contained script

## Prerequisites

- A fresh Ubuntu or Debian VPS (tested on Ubuntu 24.04 LTS; should work on other Debian-based distros, but paths/behavior may differ slightly — see the compatibility notice above)
- Root access, or a sudo-capable user

## Quick start

```bash
mkdir -p ~/aio-toolkit && \
curl -fsSL https://raw.githubusercontent.com/alpinezx/linux-aio-toolkit/refs/heads/main/aio-toolkit.sh -o ~/aio-toolkit/aio-toolkit.sh && \
cd ~/aio-toolkit && sudo bash aio-toolkit.sh
```

Every time you come back to this server, just re-run `sudo bash aio-toolkit.sh` from that same directory — there's no separate install step or background service, it's a plain script you run when you need it.

## The menu

Options are ordered safe-to-dangerous — routine stuff at the top, anything that can affect your session, access, or account list at the bottom.

```
 1) System maintenance (update, upgrade, cleanup, journal trim, history)
 2) Check / set up swap space (auto-sized to your RAM, skips if already present)
 3) Harden server (fail2ban + UFW firewall + automatic security updates)
 4) Enable BBR congestion control (smoother throughput on fast links)
 5) DNS-over-TLS (Cloudflare / Quad9 / custom — bypasses provider DNS)
 6) Set up scheduled daily reboot + clock sync (NTP)
 7) Check root SSH login status (across every sshd config file, not just one)
 8) Create a non-root sudo user (adds them, sudo group, copies root's SSH key)
 9) Enable root SSH login (copies your key, sets PermitRootLogin, restarts sshd)
10) Passwordless sudo for a user (real security trade-off — reads warnings)
11) Disable root SSH login (locks it down — reads warnings before proceeding)
12) Remove a user (permanent — reads warnings, requires typed confirmation)
13) Exit
```

A quick rundown of what each does:

- **System maintenance** — `apt update`/`upgrade` (asks first, shows how many packages), fixes any interrupted `dpkg` state, cleans up unused packages and stale cache, trims the systemd journal to 200MB, flags a pending reboot if one's needed, and optionally clears shell history (opt-in, warns it's irreversible).
- **Swap** — detects RAM, recommends a size (2x under 1GB, 1x from 1–8GB, flat 4GB above), capped at 25% of free disk. Skips cleanly if swap already exists.
- **Harden server** — fail2ban (with the `ssh.service` vs `sshd.service` unit-detection fix baked in), UFW with base ports (22/80/443 by default, override via `UFW_PORTS`), and unattended-upgrades (security patches only, no auto-reboot).
- **BBR** — switches TCP congestion control from CUBIC to BBR + fq qdisc, lets you test live before persisting across reboots.
- **DNS-over-TLS** — switches the host to encrypted DNS (Cloudflare, Quad9, or a custom resolver), so a provider- or datacenter-assigned resolver (e.g. a cloud host's DHCP-served DNS) is never used in plaintext. Writes both `/etc/systemd/resolved.conf` and netplan (so DHCP can't silently reassert its own DNS later), and includes a one-click **Restore** back to the exact pre-toolkit configuration — no reboot required, even though the underlying fix (a `systemd-networkd` restart, to work around a documented DHCP/DNS propagation quirk) took real trial-and-error to land on. Ubuntu/netplan-specific; see the compatibility notice above.
- **Scheduled reboot** — optional timezone change, a daily reboot cron job at a time you choose, and NTP sync via systemd-timesyncd so the schedule doesn't drift.
- **Check root SSH login status** — read-only. Shows the raw `PermitRootLogin`/`PasswordAuthentication` settings in every file sshd actually reads (not just the obvious one), plus the final merged value.
- **Create a non-root sudo user** — `adduser`, adds to the `sudo` group, copies root's own SSH key over so they can log in immediately.
- **Enable root SSH login** — copies your key to root, sets `PermitRootLogin`, validates config before restarting sshd.
- **Passwordless sudo** — adds a `NOPASSWD:ALL` rule for a chosen user. A genuine security trade-off, not a convenience toggle — reads a clear warning first, and re-running it on the same user offers to remove the rule instead.
- **Disable root SSH login** — the most heavily guarded option short of removing a user. Refuses outright if no other account on the box has a working SSH key (a guaranteed lockout), and requires typing `CONFIRM` in full caps if you're connected as root over SSH with no sudo fallback detected.
- **Remove a user** — lists real (non-root) accounts by number first, so you don't need to remember an exact name. Can't remove `root` or the account you're currently using. Refuses if it would strand you (root login off + this is the only remaining keyed user). Requires re-typing the username as a second confirmation before anything happens.

## Safety design

This isn't just confirmation prompts everywhere — a few things are worth knowing about how it actually protects you:

- **Multi-file sshd awareness.** `PermitRootLogin` and `PasswordAuthentication` can live in `/etc/ssh/sshd_config` *or* any file in `/etc/ssh/sshd_config.d/*.conf` (cloud images commonly drop overrides there), and only the first one sshd reads actually takes effect — every module that touches these settings edits the *correct* file, not just the main one, and neutralizes shadowed duplicates with a comment instead of leaving them to silently win later.
- **Hard refusals, not just warnings, where lockout is provable.** Disabling root login or removing a user checks for an actual, real, non-empty `authorized_keys` file on another account before proceeding — not just an environment-variable guess. If it can't find one, it refuses outright with no way to override.
- **`sudo`-aware, not root-only.** Options that need to know "who's really running this" detect the real invoking user via `$SUDO_USER`, so they work correctly whether you're logged in as root directly or via `sudo` from a regular account — DigitalOcean-style (root-only by default) and Oracle/AWS-style (non-root user by default) droplets both work without extra steps.
- **`apt upgrade` won't silently undo your changes.** Uses `--force-confdef --force-confold` so a package update (e.g. `openssh-server`) can't quietly revert a config file this toolkit already customized — without this, dpkg's default behavior can either silently overwrite it or hang the whole script waiting for input that will never come.
- **Sudoers changes are double-validated before they're live.** Passwordless-sudo rules are checked in isolation with `visudo -cf` *before* being written, then the whole sudoers configuration is re-checked with `visudo -c` after — if anything fails, the new rule is removed immediately rather than left in a state that could break `sudo` for everyone on the box.
- **DNS changes know their own limits.** The DNS-over-TLS module checks that `systemd-resolved` is actually the active resolver (not just installed) before touching anything, and checks the detected OS + version against a short list of combos it's actually been run against end-to-end — anything else gets an explicit warning and a confirmation prompt rather than a silent "should work" assumption.
- **DNS changes are fully reversible, one step, no reboot.** The first time the DNS module touches a file, it saves an untouched "pre-toolkit" copy separately from its regular per-change backups — so **Restore** always returns to the true original state, not just the previous provider, and does so live.
- **Typed confirmations for the truly irreversible.** Removing a user requires re-typing their exact username, not just answering `y`.

## Notes

- Run as root, or with `sudo` — the script checks this at startup and exits with a clear message if not.
- The menu header shows the detected OS + version on every run (informational only). Only the DNS-over-TLS module actually checks this against a tested-version list before proceeding — it's the only module with genuinely OS-specific mechanics (netplan, systemd-networkd). Every other module is built on portable `apt`/`systemd` primitives and, as far as the code goes, has no known Ubuntu-only dependencies — but hasn't yet been run start-to-finish on Debian to confirm that in practice.
- Menu numbering isn't guaranteed permanent as more modules get added; check the on-screen menu rather than this README if the two ever drift.
- `UFW_PORTS` can be set before running to change the default allowed ports (`UFW_PORTS="22 80 443 8080" sudo -E bash aio-toolkit.sh`), though the hardening module refuses to enable UFW without port 22 in the list unless you explicitly confirm.

## Troubleshooting

- If a module reports it "did not fully complete," scroll up — every module prints its own specific error before returning, rather than failing silently.
- SSH-related options always tell you to test in a **new terminal window** before closing your current session. Follow that instruction literally — it's the difference between a mistake being a two-second fix and a full server rebuild.
