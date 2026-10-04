#!/usr/bin/env bash
#
# bootstrap.sh -- rebuild a workstation's USER-SPACE environment on top of an Arch
# install that already boots and has working hardware.
#
# Scope:
#   IN  -- user applications, language toolchains, CLI tooling, fonts, dotfiles,
#          secrets checkout, systemd USER units, the WM session.
#   OUT -- kernel, base, microcode, GPU drivers, firmware, bootloader, device-specific
#          networking. Stage 15 DETECTS those and reports; it never blindly installs
#          them, because replaying one machine's driver set onto another is how you
#          break a working graphics stack.
#
# Assumes: Arch is installed, boots, has network and a real (non-root) user account.
# Does NOT do: partitioning, bootloader, user creation, or entering any secret.
#
# CONFIGURATION -- this script ships with NO personal data in it. Remotes and paths
# come from bootstrap.conf (see bootstrap.conf.example). On first run, stage 00 will
# offer to create that file interactively.
#
# Usage:
#   ./bootstrap.sh --list                 show stages and their completion state
#   ./bootstrap.sh                        run every incomplete stage in order
#   ./bootstrap.sh --resume               same, but silently skip completed stages
#   ./bootstrap.sh --only dotfiles,xmonad run just those (ignores completion state)
#   ./bootstrap.sh --skip xmonad          run everything except those
#   ./bootstrap.sh --redo packages        clear a stage's completion mark and re-run
#   ./bootstrap.sh --dry-run              print what would happen, change nothing
#   ./bootstrap.sh --yes                  assume yes for optional prompts
#   ./bootstrap.sh --reset-state          forget all completion marks
#
# RESUMABLE vs IDEMPOTENT -- two different properties, and this script has both.
#
#   Resumable: completion is recorded per-stage, so you can Ctrl-C out to another
#   TTY, do something by hand, and re-run -- finished stages will not repeat.
#
#   Idempotent: a full run against an already-provisioned machine changes NOTHING.
#   Every stage checks the state of the world before acting, reports `ok` when it
#   was already correct, and `did` only when it changed something. The run ends
#   with a count of the `did` lines, so "nothing happened" is a fact you read off
#   the last line rather than one you infer.
#
# That second property is what makes it safe to re-run as a routine check that the
# script still reproduces the machine. Note that a re-run deliberately does NOT
# upgrade the system: packages are installed only when missing. Upgrading is a
# separate job with a separate risk profile; do it with pacman directly.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------------------------------------------------------- config

# Defaults. Everything here is overridable by bootstrap.conf or the environment.
# NOTE: these are deliberately generic -- no usernames, hosts, or repo names.
DOTFILES_REMOTE="${DOTFILES_REMOTE:-}"          # e.g. git@github.com:you/dotfiles.git
SECRETS_REMOTE="${SECRETS_REMOTE:-}"            # optional; leave empty to skip stage 35
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dot}"      # bare repo location
SECRETS_DIR="${SECRETS_DIR:-$HOME/secrets}"
WALLPAPERS_REMOTE="${WALLPAPERS_REMOTE:-}"      # optional; the .xinitrc wallpaper source
WALLPAPERS_DIR="${WALLPAPERS_DIR:-$HOME/projects/wallpapers}"
XMONAD_DIR="${XMONAD_DIR:-$HOME/.xmonad}"
OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-}"            # optional; leave empty to skip obsidian
NODE_MAJOR="${NODE_MAJOR:-24}"
KEYXFER_URL="${KEYXFER_URL:-}"                  # optional SSH key-transfer helper binary
CONFIG_HOME_OVERRIDE="${CONFIG_HOME_OVERRIDE:-}" # set if you use a non-standard XDG dir
LOGIN_SHELL="${LOGIN_SHELL:-zsh}"
# 1 = bootstrap.conf is a copy of $SECRETS_DIR/arch-bootstrap/bootstrap.conf,
# adopted as soon as stage 05 can clone the secrets repo. Set by answering only
# the first question on a fresh run. See adopt_config_from_secrets.
CONFIG_FROM_SECRETS="${CONFIG_FROM_SECRETS:-0}"

# sshd. Enabling the daemon is not the same as configuring it, and the config is
# the part that is machine-specific -- so it is parameterised here rather than
# baked in. Both are optional and both default to something safe.
#
# SSHD_LISTEN_ADDRESS defaults to EMPTY, meaning "listen on every interface",
# which is sshd's own default. Do NOT put an address here as a convenience: a
# ListenAddress that does not exist on the machine makes sshd fail to bind, and
# on a headless box that is unrecoverable without console access. Set it only
# when you mean it -- typically to a VPN address, so the host is reachable over
# the tailnet and nowhere else. If you do, stage 60 also writes a systemd drop-in
# ordering sshd after tailscaled, because the address does not exist until the
# interface is up.
#
# The special value `tailscale` means "this machine's own tailnet IPv4, read when
# stage 60 runs". It is what lets ONE bootstrap.conf (the copy in the secrets repo)
# serve every machine, and it follows a node that re-registers and gets a new
# address -- on the next `--redo services`, not by itself. If tailscale has no
# address yet, sshd is left on every interface and the run says so.
SSHD_LISTEN_ADDRESS="${SSHD_LISTEN_ADDRESS:-}"   # an address, `tailscale`, or empty = all interfaces
SSHD_ALLOW_USERS="${SSHD_ALLOW_USERS:-$USER}"    # empty disables the AllowUsers restriction

# Your other machines, by tailnet name (space-separated; this machine is skipped).
# Stage 60 writes a ~/.ssh/config stanza for each, pointing at its MagicDNS FQDN,
# so `ssh carbon` and `herdr --remote carbon` follow the node through address
# changes with no IP written down anywhere. Empty = write nothing.
SSH_PEERS="${SSH_PEERS:-}"
# Stage 75 (tailnet): may the peers' keys (secrets ssh/pubkeys/<peer>.pub) go into THIS machine's
# authorized_keys? "ask" prompts per peer, "no" never adds any. Set "no" on a host that must
# not be reachable (micro, an outbound-only recovery box).
AUTHORIZE_PEERS="${AUTHORIZE_PEERS:-ask}"

# Chores to enable on this machine: names of directories under chores/, each with a
# chore-NAME.timer. See chores/chore-run for the protocol. Empty = none.
CHORES="${CHORES:-}"

# /tmp: RAM or disk. systemd's static tmp.mount makes /tmp a tmpfs at size=50% of
# RAM, which is an UNBOUNDED claim on memory that no quota limits -- on a 32 GiB
# box that is a 16 GiB ceiling one runaway `dd` can reach. Setting this to `true`
# masks the unit so /tmp is a plain directory on the root filesystem.
#
# `false` leaves systemd's default alone, and that is the right answer more often
# than it looks: a tmpfs /tmp is faster, it self-cleans at every boot, and on a
# machine with plenty of RAM relative to its workload the ceiling never matters.
# Decide per machine -- a memory-tight desktop and a headless server want
# different answers.
#
# TWO THINGS THIS DOES NOT DO, both learned the expensive way on beast-arch:
#   - It does NOT take effect until the next boot. The tmpfs that is mounted now
#     stays mounted; masking only stops it coming back. Anything verifying this
#     before a reboot is verifying nothing.
#   - It does NOT touch /dev/shm, which is also tmpfs and must stay that way --
#     POSIX shared memory is what it is for. If you use nix, its
#     `sandbox-dev-shm-size` is a separate 50%-of-RAM claim per build sandbox and
#     this setting does not bound it.
TMP_ON_DISK="${TMP_ON_DISK:-false}"              # true = mask tmp.mount so /tmp is on disk

# Disk swap, encrypted with a fresh random key at every boot (nothing to manage,
# contents unrecoverable after power-off; the cost is no hibernation). The value is
# the swap partition's PARTUUID -- `lsblk -no PARTUUID /dev/sdXN` -- NOT its
# filesystem UUID: the random-key layer reformats the partition every boot, so the
# swap UUID and label are gone after the first one. Stage 60 refuses a partition
# that is not currently `swap`, because whatever this names is overwritten. Sits at
# pri=10, behind zram's 100, so it only takes overflow. Empty = no disk swap.
SWAP_PARTUUID="${SWAP_PARTUUID:-}"

# USB media drives for Jellyfin (profile media-center). Space-separated
# name:fs-UUID:fstype entries -- `lsblk -no UUID,FSTYPE /dev/sdXN` -- each mounted at
# /srv/media/<name> on first access. Use ntfs3 (the kernel driver) for NTFS, not ntfs.
# Empty = none.
MEDIA_DRIVES="${MEDIA_DRIVES:-}"

# earlyoom acts only when available RAM AND free swap are BOTH under threshold, so
# adding disk swap without raising -s means it waits until most of that swap has
# been thrashed through. Written verbatim to /etc/default/earlyoom. Empty = leave
# the packaged file alone.
EARLYOOM_ARGS="${EARLYOOM_ARGS:-}"

# Used as the Obsidian sync device name, so the version history says which
# machine a change came from. `hostname` is not installed everywhere (it is in
# inetutils, which is not in the package list); `uname -n` always is.
HOSTNAME_SHORT="${HOSTNAME:-$(uname -n)}"

# ~/.ssh is deliberately NOT tracked in a dotfiles repo, so nothing restores it on
# a rebuild. Stage 05 writes a minimal config instead. How long the agent should
# hold a decrypted key is a judgement call about your own threat model, not a
# default anyone else should pick for you -- `yes` keeps it for the session, which
# is ssh's own behaviour. Set a duration (e.g. 2m, 1h) in bootstrap.conf to expire
# it sooner.
SSH_ADD_KEYS_TO_AGENT="${SSH_ADD_KEYS_TO_AGENT:-yes}"

# The ONE key stage 05 uses for the git host. Empty = ~/.ssh/id_ed25519, or the
# only key in ~/.ssh. Its passphrase (or none) is chosen when it is generated.
SSH_KEY="${SSH_KEY:-}"

# Packages from the shared lists that this MACHINE should not get. One name per
# line, '#' comments allowed. Defaults to pkglist-exclude.txt beside the script;
# point it anywhere (e.g. a private per-host list in another repo).
#
# The package lists describe one reference environment. A second machine usually
# wants most of it and not all of it -- a laptop replicating a command-line
# environment has no use for a video-editing suite. Without this the only options
# are installing everything or maintaining a divergent copy of the lists, and the
# second one rots.
PKG_EXCLUDE_FILE="${PKG_EXCLUDE_FILE:-}"

# Extra roles for this machine, on top of the shared lists: each name adds the
# packages in pkglist-profile-<name>.txt (and any SYSTEM_UNITS they bring). Set it
# per host in bootstrap.conf, e.g.  case "$(uname -n)" in tv) PROFILES="media-center" ;; esac
PROFILES="${PROFILES:-}"

BOOTSTRAP_CONFIG="${BOOTSTRAP_CONFIG:-$SCRIPT_DIR/bootstrap.conf}"

# A path written as "~/BRAIN" -- which is what anyone types at a prompt -- keeps
# its tilde LITERALLY: bash expands a tilde only when it is unquoted in the
# script's own text, never one that arrives inside a quoted value. On 2026-09-30
# that sent OBSIDIAN_VAULT and XDG_CONFIG_HOME to a directory actually named `~`
# under whatever the cwd was (the arch-bootstrap checkout), leaving ~/BRAIN
# missing, the obsidian-sync unit failing on `--path ~/BRAIN` (systemd does not
# expand it either), and an auth token and vault key untracked inside a repo
# meant to be publishable. Expand once, at load, for every path setting.
expand_tilde() {
  local v=$1
  case $v in
    "~")   v=$HOME ;;
    "~/"*) v="$HOME/${v#\~/}" ;;
  esac
  printf '%s' "$v"
}

load_config() {
  # shellcheck disable=SC1090
  if [[ -f $BOOTSTRAP_CONFIG ]]; then . "$BOOTSTRAP_CONFIG"; fi
  local v
  for v in DOTFILES_DIR SECRETS_DIR WALLPAPERS_DIR XMONAD_DIR OBSIDIAN_VAULT \
           CONFIG_HOME_OVERRIDE PKG_EXCLUDE_FILE SSH_KEY; do
    printf -v "$v" '%s' "$(expand_tilde "${!v}")"
  done
  # A non-standard XDG_CONFIG_HOME must be exported BEFORE anything else runs, or
  # applications scatter their config into ~/.config and the dotfiles never take
  # effect. This is the single easiest thing to get wrong.
  if [[ -n $CONFIG_HOME_OVERRIDE ]]; then export XDG_CONFIG_HOME="$CONFIG_HOME_OVERRIDE"; fi
}

load_config
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/arch-bootstrap"
STATE_FILE="$STATE_DIR/completed-stages"

DRY_RUN=0
ASSUME_YES=0
RESUME=0
ONLY=""
SKIP=""
REDO=""

# obsidian runs AFTER services, and only under X: its login and vault binding are
# interactive, and on a raw TTY there is no KeePassXC to copy a password from and
# no second window to work in. From a TTY it is DEFERRED -- not failed, not
# marked done -- and the run ends by saying to resume it from X.
# tailnet is deferred the same way when it would need `tailscale up`: that login is
# a URL to open in a browser. Already on the tailnet, it runs from a TTY too.
STAGES=(preflight ssh packages hardware aur toolchains dotfiles secrets
        session xmonad services obsidian tailnet verify manual)

# --------------------------------------------------------------------------- output

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_BOLD=
fi

stage_banner() {
  printf '\n%s== %s %s%s\n' "$C_BOLD$C_BLU" "$1" \
    "$(printf '=%.0s' $(seq 1 $(( 58 - ${#1} > 0 ? 58 - ${#1} : 3 ))))" "$C_RESET"
}
ok()    { printf '%s  ok  %s %s\n' "$C_GRN" "$C_RESET" "$*"; }
info()  { printf '%s  --  %s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn()  { printf '%s warn %s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()   { printf '%s FAIL %s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
todo()  { printf '%s  >>  %s %s\n' "$C_BOLD$C_YEL" "$C_RESET" "$*"; }

run() {
  if (( DRY_RUN )); then
    printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$*"
    return 0
  fi
  # sudo with no terminal cannot ask for a password, and every such attempt still
  # counts as a failure to pam_faillock: three of them lock the account for ten
  # minutes. A non-interactive `--only services` did exactly that on 2026-09-30.
  # Refuse up front unless credentials are already cached (`sudo -n` does not
  # count as an attempt).
  if [[ ${1:-} == sudo ]] && ! have_tty && ! sudo -n true 2>/dev/null; then
    warn "needs sudo and there is no terminal to ask on -- not attempted: $*"
    warn "(each password-less attempt counts toward the faillock lockout)"
    return 1
  fi
  "$@"
}

# Confirmation of something that ACTUALLY happened. Silent under --dry-run, where
# claiming "installed" right after printing "would run" would just be a lie.
#
# The counter is the idempotency test. A run against a machine that is already
# provisioned must finish with DID_COUNT at zero -- every stage reporting `ok`,
# nothing reporting `did`. The summary at the end of main() prints it, so the
# property is checked by running the script rather than by reading it.
#
# Under --dry-run the message is suppressed but the call is still COUNTED. That is
# not a fudge: every `did` sits on a branch chosen by a real read-only check, and
# only the mutation is stubbed out. So a dry run answers "how many things would
# change" honestly, and the idempotency property can be tested without touching a
# working machine.
DID_COUNT=0
did() {
  DID_COUNT=$(( DID_COUNT + 1 ))
  (( DRY_RUN )) && return 0
  ok "$*"
}

confirm() {
  (( ASSUME_YES )) && return 0
  (( DRY_RUN ))    && return 1
  # No controlling terminal (cron, a pipe, ssh without -t): answer NO rather than
  # dying on an unbound $reply under `set -u`. Every caller treats a declined
  # prompt as "leave it alone", so refusing is the safe reading of silence.
  if ! have_tty; then
    warn "no terminal to ask on -- assuming no: $1"
    return 1
  fi
  local reply=""
  read -r -p "$(printf '%s  ?   %s %s [y/N] ' "$C_YEL" "$C_RESET" "$1")" reply </dev/tty || true
  [[ $reply == [yY]* ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

# Is there a controlling terminal we can prompt on?
#
# `[[ -r /dev/tty ]]` is NOT this test: the device node's permission bits are
# readable even in a session with no controlling terminal, so it returns true and
# the redirect then fails with ENXIO. Opening it is the only honest check.
have_tty() { { : </dev/tty; } 2>/dev/null; }

# ------------------------------------------------------------------- exclusions

declare -A PKG_EXCLUDED=()
EXCLUDE_SOURCE=""

load_exclusions() {
  local f="${PKG_EXCLUDE_FILE:-$SCRIPT_DIR/pkglist-exclude.txt}"
  [[ -f $f ]] || return 0
  EXCLUDE_SOURCE="$f"
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"                    # trailing comments
    line="${line//[[:space:]]/}"
    [[ -n $line ]] && PKG_EXCLUDED["$line"]=1
  done < "$f"

  # NOT decoration. A `while` loop returns the status of the last command its
  # body ran, and for a comment or blank line that is a FALSE `[[ -n $line ]]`.
  # The loop then returns 1, so does this function, and `set -e` kills the script
  # in main() -- before the first printf, so with exit status 1 and NO OUTPUT AT
  # ALL. Carbon hit this because its exclusion file ends in comment lines.
  return 0
}

# Split a package list into what this machine wants and what it has excluded.
#
# Excluding means "do not install here". It does NOT mean "uninstall": removing
# software because a list changed is a far larger action than declining to add
# it, and not one a bootstrap should take on its own initiative. A machine that
# already has an excluded package keeps it, and the fact is reported so the drift
# is visible rather than silent.
#
# Sets EX_WANT, EX_SKIPPED and EX_SKIPPED_PRESENT in the caller.
partition_by_exclusion() {
  EX_WANT=(); EX_SKIPPED=(); EX_SKIPPED_PRESENT=()
  local p
  for p in "$@"; do
    if [[ -n ${PKG_EXCLUDED[$p]:-} ]]; then
      EX_SKIPPED+=("$p")
      pacman -Qq "$p" >/dev/null 2>&1 && EX_SKIPPED_PRESENT+=("$p")
    else
      EX_WANT+=("$p")
    fi
  done
  # Same trap as load_exclusions: the loop body's last command can be a failing
  # `pacman -Qq ... && ...`, which would make this function return 1 and take the
  # whole script down silently under `set -e`.
  return 0
}

report_exclusions() {
  (( ${#EX_SKIPPED[@]} )) || return 0
  info "${#EX_SKIPPED[@]} excluded for this machine: ${EX_SKIPPED[*]}"
  if (( ${#EX_SKIPPED_PRESENT[@]} )); then
    warn "excluded but ALREADY INSTALLED here -- left alone, not removed:"
    warn "  ${EX_SKIPPED_PRESENT[*]}"
  fi
}

# Set a git config key only if it does not already hold the wanted value, so a
# re-run reports `ok` instead of claiming it configured something.
#   git_config_ensure <label> <key> <value> <git-argv...>
git_config_ensure() {
  local label="$1" key="$2" want="$3"; shift 3
  local cur
  cur="$("$@" config --local --get "$key" 2>/dev/null || true)"
  if [[ $cur == "$want" ]]; then
    ok "$label: $key already '$want'"
  else
    run "$@" config --local "$key" "$want"
    did "$label: $key set to '$want'"
  fi
}

# --------------------------------------------------------------- interactive helpers

# Print a manual instruction and block until the user says they've done it.
# Returns 1 if the user chose to skip, so callers can react.
pause_for() {
  local what="$1"; shift
  printf '\n%s  MANUAL STEP %s %s\n' "$C_BOLD$C_YEL" "$C_RESET" "$what"
  local line
  for line in "$@"; do printf '        %s\n' "$line"; done
  if (( DRY_RUN )); then
    info "(dry run -- would wait for you here)"
    return 0
  fi
  # Same no-terminal guard as confirm(). A manual step nobody can be asked about
  # is a skipped manual step, not a crash.
  if ! have_tty; then
    warn "no terminal to prompt on -- treating as skipped: $what"
    return 1
  fi
  local reply=""
  read -r -p "$(printf '\n%s  ?   %s Done? [Enter=yes / s=skip this step] ' \
    "$C_YEL" "$C_RESET")" reply </dev/tty || true
  [[ $reply == [sS]* ]] && { warn "skipped: $what"; return 1; }
  return 0
}

# Run a command interactively in the user's terminal, tolerating failure so the
# stage can offer a retry instead of aborting the whole bootstrap.
run_interactive() {
  if (( DRY_RUN )); then
    printf '%s  would run (interactive):%s %s\n' "$C_DIM" "$C_RESET" "$*"
    return 0
  fi
  info "running: $*"
  # Fall back to the inherited stdio with no controlling terminal. Redirecting to
  # /dev/tty there fails with ENXIO before the command ever starts, so the caller
  # sees a non-zero exit and reports the TOOL as broken -- which is how a run
  # without a tty produced "sync-status reported a problem" against a daemon that
  # was in fact healthy. A misattributed failure is worse than a missing prompt.
  if have_tty; then
    "$@" </dev/tty >/dev/tty 2>&1 || return $?
  else
    "$@" || return $?
  fi
}

# ------------------------------------------------------------------- state / resume

state_load()      { [[ -f $STATE_FILE ]] && cat "$STATE_FILE" || true; }
state_done()      { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
state_mark() {
  (( DRY_RUN )) && return 0
  mkdir -p "$STATE_DIR"
  state_done "$1" || printf '%s\n' "$1" >> "$STATE_FILE"
}
state_clear() {
  [[ -f $STATE_FILE ]] || return 0
  (( DRY_RUN )) && return 0
  grep -vxF "$1" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# --------------------------------------------------------------------------- 00

# Written on first run so the script itself stays free of personal data.
write_config_interactively() {
  printf '\n%sNo %s found.%s This script ships with no personal data in it, so it\n' \
    "$C_BOLD" "$(basename "$BOOTSTRAP_CONFIG")" "$C_RESET"
  printf 'needs to know where your dotfiles and secrets live.\n\n'

  local dotfiles secrets wallpapers vault confighome shell_pref from_secrets=""
  # One question instead of six, when the answers already live somewhere: the
  # secrets repo carries arch-bootstrap/bootstrap.conf, and stage 05 adopts it the
  # moment GitHub auth works. Nothing personal has to be typed, or remembered, on
  # a machine being rebuilt under pressure. Added 2026-09-30.
  read -r -p "  Secrets repo holding arch-bootstrap/bootstrap.conf (blank: answer the questions here): " \
    from_secrets </dev/tty
  if [[ -n $from_secrets ]]; then
    cat > "$BOOTSTRAP_CONFIG" <<EOF
# arch-bootstrap local configuration -- generated $(date -Iseconds)
# PLACEHOLDER: stage 05 replaces this file with arch-bootstrap/bootstrap.conf
# from the secrets repo below, as soon as it can clone it.
SECRETS_REMOTE="${from_secrets}"
CONFIG_FROM_SECRETS=1
EOF
    chmod 600 "$BOOTSTRAP_CONFIG"
    ok "wrote $BOOTSTRAP_CONFIG -- the rest comes from the secrets repo after stage 05"
    load_config
    return 0
  fi

  read -r -p "  Dotfiles git remote (bare repo, e.g. git@github.com:you/dotfiles.git): " \
    dotfiles </dev/tty
  read -r -p "  Secrets git remote (blank to skip that stage): " secrets </dev/tty
  # Asked for because it was NOT, until 2026-09-30: the generated file had no
  # WALLPAPERS_REMOTE line at all, so stage 35 skipped the clone and the desktop
  # came up blank on a machine whose RUNBOOK said to set it.
  read -r -p "  Wallpapers git remote (blank to skip; the desktop gets no wallpaper): " \
    wallpapers </dev/tty
  read -r -p "  Obsidian vault path, e.g. ~/vault (blank to skip Obsidian stages): " \
    vault </dev/tty
  read -r -p "  Non-standard XDG_CONFIG_HOME (blank for the default ~/.config): " \
    confighome </dev/tty
  read -r -p "  Preferred login shell [zsh]: " shell_pref </dev/tty

  # Written out absolute, so the file says what it means. load_config expands a
  # tilde as well, but a file that holds the literal is a trap for anything else
  # that reads it.
  vault="$(expand_tilde "$vault")"
  confighome="$(expand_tilde "$confighome")"

  cat > "$BOOTSTRAP_CONFIG" <<EOF
# arch-bootstrap local configuration -- generated $(date -Iseconds)
# This file is gitignored. It holds machine- and person-specific values so that
# bootstrap.sh itself can stay publishable.

DOTFILES_REMOTE="${dotfiles}"
SECRETS_REMOTE="${secrets}"
WALLPAPERS_REMOTE="${wallpapers}"
OBSIDIAN_VAULT="${vault}"
CONFIG_HOME_OVERRIDE="${confighome}"
LOGIN_SHELL="${shell_pref:-zsh}"

# Optional: URL of a precompiled SSH key-transfer helper, fetched over plain HTTPS
# in stage 05. It needs no credentials to download, which is what lets it break the
# chicken-and-egg (cloning dotfiles needs a key; getting the key needed the dotfiles).
KEYXFER_URL=""

# Paths (defaults shown)
#DOTFILES_DIR="\$HOME/.dot"
#SECRETS_DIR="\$HOME/secrets"
#XMONAD_DIR="\$HOME/.xmonad"
#NODE_MAJOR="24"
EOF
  chmod 600 "$BOOTSTRAP_CONFIG"
  ok "wrote $BOOTSTRAP_CONFIG (mode 600, gitignored)"

  # Through load_config, not a bare `.`: that also expands the paths. And the old
  # `[[ -n $CONFIG_HOME_OVERRIDE ]] && export ...` as this function's LAST line
  # returned 1 whenever the answer was blank -- harmless while stages ran with
  # errexit off, fatal to preflight now that they do not.
  load_config
}

stage_preflight() {
  stage_banner "00 preflight"

  [[ -f /etc/arch-release ]] || die "not an Arch system (/etc/arch-release missing)"
  ok "Arch Linux confirmed"

  [[ $EUID -ne 0 ]] || die "run as your normal user, not root. Stages that need root call sudo."
  ok "running as $USER (uid $EUID)"

  have sudo || die "sudo not installed"
  if sudo -n true 2>/dev/null; then
    ok "sudo available (cached)"
  else
    info "sudo will prompt for a password during package stages"
  fi
  sudo_timeout_dropin

  if ping -c1 -W3 archlinux.org >/dev/null 2>&1; then
    ok "network reachable"
  else
    die "no network -- cannot fetch packages or clone repos"
  fi

  local f
  for f in pkglist-userspace.txt pkglist-aur.txt; do
    [[ -f "$SCRIPT_DIR/$f" ]] || die "missing $SCRIPT_DIR/$f"
  done
  ok "package lists present ($(wc -l < "$SCRIPT_DIR/pkglist-userspace.txt") user-space, \
$(wc -l < "$SCRIPT_DIR/pkglist-aur.txt") AUR)"

  if [[ ! -f $BOOTSTRAP_CONFIG ]] && ! (( DRY_RUN )); then
    write_config_interactively
  fi

  if [[ -n $DOTFILES_REMOTE ]]; then
    ok "dotfiles remote configured"
  elif (( CONFIG_FROM_SECRETS )); then
    info "the rest of the configuration arrives from the secrets repo at stage 05"
  else
    warn "DOTFILES_REMOTE unset -- stage 30 will be skipped"
  fi
  [[ -n $SECRETS_REMOTE ]] \
    && ok "secrets remote configured" \
    || info "SECRETS_REMOTE unset -- stage 35 will be skipped"
  ok "XDG_CONFIG_HOME=$XDG_CONFIG_HOME"

  if [[ -n $EXCLUDE_SOURCE ]]; then
    ok "${#PKG_EXCLUDED[@]} package(s) excluded for this machine ($EXCLUDE_SOURCE)"
    # A typo in the exclusion file is silent in the worst way: the package you
    # meant to skip gets installed and the line that was supposed to stop it
    # matches nothing. Check every name against the lists it is meant to filter.
    local -a unknown=() e
    for e in "${!PKG_EXCLUDED[@]}"; do
      grep -qxF "$e" "$SCRIPT_DIR/pkglist-userspace.txt" "$SCRIPT_DIR/pkglist-aur.txt" \
        2>/dev/null || unknown+=("$e")
    done
    if (( ${#unknown[@]} )); then
      warn "${#unknown[@]} excluded name(s) match nothing in the package lists:"
      warn "  ${unknown[*]}"
      warn "a typo here silently installs the thing you meant to skip"
    fi
  else
    info "no exclusion file -- this machine gets the full package lists"
  fi

  info "stage completion is recorded in $STATE_FILE"
}

# One sudo password lasts an hour per terminal, not Arch's default 5 minutes. A run
# needs sudo across many stages, and on 2026-10-03 (media-center) it asked over and
# over. timestamp_type stays the default (tty), so a cached credential still only
# works in the terminal where the password was typed. sudo re-reads sudoers on every
# call, so the hour applies from the next sudo in this same run. Asking here, at
# stage 00, also puts the first password prompt up front. `visudo -c` checks the
# file before it goes in, because a broken sudoers.d file breaks sudo outright.
sudo_timeout_dropin() {
  local dropin=/etc/sudoers.d/10-timestamp-timeout want='Defaults timestamp_timeout=60' have
  if (( DRY_RUN )); then
    if ! have="$(sudo -n cat "$dropin" 2>/dev/null)" && ! sudo -n true 2>/dev/null; then
      info "cannot check $dropin without sudo (sudo -v first to check)"; return 0
    fi
  else
    have="$(run sudo cat "$dropin" 2>/dev/null)" || have=""
  fi
  if [[ $have == "$want" ]]; then
    ok "sudo credentials last 60 min per terminal ($dropin)"
  elif (( DRY_RUN )); then
    info "(dry run) would write $dropin: $want"
    did "wrote $dropin"
  else
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$want" > "$tmp"
    if run sudo visudo -cqf "$tmp" && run sudo install -m 440 -o root -g root "$tmp" "$dropin"; then
      did "sudo credentials now last 60 min per terminal ($dropin)"
    else
      warn "could not write $dropin -- sudo keeps its 5-minute timeout"
    fi
    rm -f "$tmp"
  fi
}

# --------------------------------------------------------------------------- 05

stage_ssh() {
  stage_banner "05 ssh -- HARD GATE"

  [[ -d $HOME/.ssh ]] || { run mkdir -p "$HOME/.ssh"; run chmod 700 "$HOME/.ssh"; }

  # Optional helper that copies a key from a machine you still have. Served over
  # UNAUTHENTICATED HTTPS on purpose -- it needs no credentials to obtain, so it
  # can legitimately be the first thing fetched.
  if [[ -n $KEYXFER_URL ]] && ! ssh_auth_works; then
    if confirm "fetch and run the key-transfer helper from $KEYXFER_URL?"; then
      run curl -fsSL "$KEYXFER_URL" -o /tmp/keyxfer
      run chmod +x /tmp/keyxfer
      run_interactive /tmp/keyxfer || warn "key-transfer helper exited non-zero"
    fi
  fi

  # ONE key, used for everything: your own pushes, agents and cron, and the hops
  # between your machines. Whether it has a passphrase is YOUR call, asked when
  # the key is generated (2026-10-01).
  #
  # Until then this stage also made a second, passphrase-less "agent" key, pinned
  # it first for github.com and registered it automatically. On 2026-09-28 a
  # phishing script ran on a git branch change with exactly that key's reach --
  # push access to every repo on the account. A passphrase-less key is still
  # allowed; it is just no longer made for you behind your back.
  local key
  key="$(pick_ssh_key)" || die "several SSH keys in ~/.ssh and no id_ed25519 -- set SSH_KEY in bootstrap.conf to the one to use"
  local key_short="${key/#$HOME/\~}"

  if [[ -f $key ]]; then
    ok "SSH key: $key_short"
  elif (( DRY_RUN )); then
    info "(dry run) would generate $key_short"
  else
    warn "no SSH key at $key_short"
    info "ssh-keygen will ask for a passphrase. It is your choice:"
    info "  a passphrase -- a stolen copy is useless. Unlock once per login (ssh-add);"
    info "                  unattended jobs cannot push while it is locked."
    info "  empty        -- agents and cron push with no prompt. So can ANY script that"
    info "                  runs as you: this key reaches every repo on the account."
    confirm "generate $key_short now?" \
      || die "no SSH key -- nothing below this stage can work"
    run_interactive ssh-keygen -t ed25519 -f "$key" -C "$(whoami)@$(uname -n)"
  fi

  # ssh offers only its default names (id_ed25519, id_rsa, ...) unprompted. A key
  # under any other name must be named for the git host, or it is never tried.
  local sshcfg="$HOME/.ssh/config"
  case $(basename "$key") in
    id_rsa|id_ecdsa|id_ecdsa_sk|id_ed25519|id_ed25519_sk) ;;
    *)
      local host; host="$(ssh_git_host)"
      if [[ -z $host ]] || { [[ -f $sshcfg ]] && grep -qF "$key_short" "$sshcfg"; }; then
        :
      elif (( DRY_RUN )); then
        info "(dry run) would prepend a Host $host stanza for $key_short to $sshcfg"
      else
        # PREPENDED: ssh takes the first value it obtains for each keyword, so a
        # stanza after a `Host *` wildcard would silently do nothing.
        local tmpcfg; tmpcfg="$(mktemp)"
        printf '# Added by bootstrap.sh (stage 05). Keep ABOVE any `Host *` block.\nHost %s\n    IdentityFile %s\n\n' \
          "$host" "$key_short" > "$tmpcfg"
        [[ -f $sshcfg ]] && cat "$sshcfg" >> "$tmpcfg"
        run install -m 600 "$tmpcfg" "$sshcfg"
        rm -f "$tmpcfg"
        did "named $key_short for $host in ~/.ssh/config"
      fi ;;
  esac

  # A machine bootstrapped before 2026-10-01 may still hold the old agent key and
  # a github.com stanza that offers it FIRST. Not removed here -- deleting a key
  # is not this script's call -- but said out loud.
  if [[ -f $HOME/.ssh/id_ed25519_agent && $key != "$HOME/.ssh/id_ed25519_agent" ]]; then
    warn "legacy passphrase-less agent key ~/.ssh/id_ed25519_agent is still here (no longer managed)"
    if [[ -f $sshcfg ]] && grep -q 'id_ed25519_agent' "$sshcfg"; then
      warn "  ~/.ssh/config still offers it for the git host -- delete that line, or the key"
    fi
  fi

  local tries=0 gh_tried=0 wh_tried=0
  while ! ssh_auth_works; do
    (( DRY_RUN )) && { info "(dry run -- skipping the auth gate)"; return 0; }
    (( ++tries > 3 )) && break

    # Easiest: hand the public key to a machine that already has GitHub access,
    # which registers it with its own gh (`adopt-key CODE` there). This machine
    # then needs no GitHub login at all.
    if (( ! wh_tried )) && [[ $(ssh_git_host) == github.com ]]; then
      wh_tried=1
      if confirm "send this key to a machine that already has GitHub access (you run adopt-key there)?"; then
        wormhole_send_key "$key" && continue
        warn "key handoff did not complete -- trying the GitHub device code instead"
      fi
    fi

    # GitHub: log in with a one-time device code and register every key through
    # the API, instead of hand-copying public keys from a raw TTY into a web form
    # (which is what this stage asked for until 2026-09-30, twice per rebuild).
    if (( ! gh_tried )) && [[ $(ssh_git_host) == github.com ]]; then
      gh_tried=1
      if github_register_keys "$key"; then
        continue
      fi
      warn "automatic GitHub key registration did not complete -- falling back to manual"
    fi

    # BEFORE blaming registration: a locked key looks exactly like an
    # unregistered one to the probe, because the probe cannot prompt. Try to
    # unlock first, and only fall through to "register it" if that fails or is
    # declined. Getting this order wrong tells the user to re-register a key that
    # is already registered, repeatedly, and never asks for the passphrase.
    if ssh_try_unlock "$key"; then
      continue
    fi

    printf '\n'
    if [[ -f $key.pub ]]; then
      printf '%s  public key (%s):%s\n' "$C_BOLD" "$(basename "$key.pub")" "$C_RESET"
      sed 's/^/        /' "$key.pub"
    fi

    pause_for "Register that public key with your git host." \
      "GitHub: https://github.com/settings/keys -> New SSH key" \
      "" \
      "If it is ALREADY registered, the problem is not registration -- it is that" \
      "the key is passphrase-protected and not loaded. Answer 'y' to the unlock" \
      "prompt above, or in another terminal run:  ssh-add" \
      "" \
      "If you have no account access because the password is in a vault you" \
      "cannot clone yet, use your account recovery codes. They must be stored" \
      "somewhere that is NOT the vault." || break
  done

  if ssh_auth_works; then
    ok "git host SSH authentication working"
    bootstrap_remote_to_ssh
    adopt_config_from_secrets
    return 0
  fi

  (( DRY_RUN )) && return 0
  cat >&2 <<'EOF'

  Nothing below this stage can work -- the dotfiles and secrets remotes are SSH.

  Fix the key, then re-run. Completed stages will not repeat.
EOF
  die "SSH authentication to the git host failed"
}

# The one key stage 05 manages. SSH_KEY wins if set; otherwise id_ed25519, or the
# only private key in ~/.ssh if there is exactly one. With several and no choice
# made it refuses rather than guesses: registering the wrong one with GitHub --
# say a per-server key -- would give it push access it was never meant to have.
# With none, it names the key to generate.
pick_ssh_key() {
  local -a keys=()
  if [[ -n $SSH_KEY ]]; then printf '%s' "$SSH_KEY"; return 0; fi
  if [[ -f $HOME/.ssh/id_ed25519 ]]; then printf '%s' "$HOME/.ssh/id_ed25519"; return 0; fi
  mapfile -t keys < <(list_private_keys)
  case ${#keys[@]} in
    0) printf '%s' "$HOME/.ssh/id_ed25519" ;;
    1) printf '%s' "${keys[0]}" ;;
    *) return 1 ;;
  esac
}

# Every private key in ~/.ssh, found by pairing with its .pub.
#
# NOT a glob of id_*. That misses any key with a project-specific name
# (github_rsa, work_ed25519, …), and the stage then reports "no SSH private key
# found" on a machine that has one -- offering to generate a second key, and
# afterwards presenting THAT key for registration while the real one sits unused.
list_private_keys() {
  local pub priv
  for pub in "$HOME"/.ssh/*.pub; do
    [[ -e $pub ]] || continue
    priv="${pub%.pub}"
    [[ -f $priv ]] && printf '%s\n' "$priv"
  done
  return 0
}

# An agent this script started, so it can be cleaned up rather than orphaned for
# the rest of the login session holding an unlocked key.
BOOTSTRAP_AGENT_PID=""
bootstrap_agent_cleanup() {
  [[ -n $BOOTSTRAP_AGENT_PID ]] || return 0
  kill "$BOOTSTRAP_AGENT_PID" 2>/dev/null || true
  BOOTSTRAP_AGENT_PID=""
}

# The single EXIT trap. A second `trap ... EXIT` would replace the first, so agent
# cleanup is called from here rather than trapped on its own.
CURRENT_STAGE=""
# A stage that cannot run in this context (obsidian without X) sets this and
# returns 0: the run carries on, but the stage is NOT marked done.
STAGE_DEFERRED=0
DEFERRED=()
on_exit() {
  local rc=$?
  bootstrap_agent_cleanup
  if [[ -n $CURRENT_STAGE ]] && (( rc != 0 )); then
    warn "stage '$CURRENT_STAGE' did not complete cleanly (exit $rc) -- not marking it done"
    printf '\n%sStopped at stage %s.%s Fix the problem above and re-run:\n\n' \
      "$C_BOLD$C_YEL" "$CURRENT_STAGE" "$C_RESET" >&2
    printf '    %s --resume\n\n' "$0" >&2
    printf 'Completed stages will not repeat.\n' >&2
  fi
}

# A locked key and an unregistered key are indistinguishable to the silent probe,
# because the probe is forbidden from prompting. Offer to load the key instead of
# concluding the key is not registered.
#
# Returns 0 only if something was actually added, so the caller can re-probe.
ssh_try_unlock() {
  local -a keys=("$@")
  (( ${#keys[@]} )) || return 1

  ssh-add -l >/dev/null 2>&1
  local rc=$?      # 0 = agent holds keys, 1 = agent but empty, 2 = no agent

  # If the agent already holds an identity, a locked key is not the problem and
  # unlocking again would not change the answer.
  (( rc == 0 )) && return 1

  if ! have_tty; then
    warn "a key exists but is not loaded, and there is no terminal to unlock it on"
    todo "run this from a real terminal, or: ssh-add"
    return 1
  fi

  info "a key exists but the agent is empty -- the silent probe cannot use it,"
  info "which looks identical to the key not being registered. It may well be."
  confirm "unlock a key now with ssh-add? (you will be asked for its passphrase)" \
    || return 1

  # There may be no agent to add a key TO. Stage 40 is what enables the systemd
  # user agent, and it runs AFTER this gate -- so on a machine that has never been
  # bootstrapped, `ssh-add` here has nothing to talk to and fails with "Could not
  # open a connection to your authentication agent".
  #
  # Adopt the socket if it already exists, otherwise start an agent for the rest
  # of this run. It is exported, so the later stages that clone over SSH reuse the
  # same unlocked key instead of prompting again.
  if (( rc == 2 )); then
    local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
    if [[ -S $sock ]]; then
      info "adopting the systemd user agent at $sock"
      export SSH_AUTH_SOCK="$sock"
      ssh-add -l >/dev/null 2>&1; rc=$?
    fi
    if (( rc == 2 )); then
      info "no ssh-agent running -- starting one for the rest of this run"
      eval "$(ssh-agent -s)" >/dev/null 2>&1 || {
        warn "could not start an ssh-agent"; return 1; }
      BOOTSTRAP_AGENT_PID="${SSH_AGENT_PID:-}"   # on_exit kills it
    fi
  fi

  # Match the configured retention so this does not become the long-lived
  # unlocked key that SSH_ADD_KEYS_TO_AGENT exists to prevent. `yes`/`ask`/etc.
  # are not durations and cannot be passed to -t.
  local -a add=(ssh-add)
  [[ $SSH_ADD_KEYS_TO_AGENT =~ ^(yes|no|ask|confirm)$ ]] \
    || add+=(-t "$SSH_ADD_KEYS_TO_AGENT")

  local k
  for k in "${keys[@]}"; do
    run_interactive "${add[@]}" "$k" && { did "loaded $(basename "$k") into the agent"; return 0; }
    warn "could not load $(basename "$k")"
  done
  return 1
}

# Derive the host from the configured remote so this works for any git host,
# not just GitHub. ssh -T exits non-zero even on success, hence the tolerance.
#
# BatchMode=yes is deliberate and is ONLY safe because ssh_try_unlock exists.
# It makes this a silent probe -- without it, every iteration of the gate loop
# would prompt for a passphrase. But it also means this can NEVER succeed with a
# passphrase-protected key that is not in the agent, so a caller that treats a
# false return as "not registered" is wrong. See stage_ssh.
ssh_auth_works() {
  local host out
  host="$(ssh_git_host)"
  [[ -z $host ]] && return 1
  out="$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T "git@$host" 2>&1 || true)"
  grep -qiE 'successfully authenticated|You.ve successfully|logged in as' <<<"$out"
}

# This checkout's own origin, HTTPS -> SSH. The rescue ISO's clone gets an HTTPS origin
# on purpose (chores/rescue-usb/make-rescue-iso): it is all a machine with no registered
# key can fetch. Once the key works, the HTTPS remote is only a liability -- a push asks
# for a username and fails (micro, 2026-10-03), and if the repo is made private, fetch
# would fail too. Leaves any non-GitHub-HTTPS origin alone.
bootstrap_remote_to_ssh() {
  local url new
  url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)" || return 0
  [[ $url == https://github.com/* ]] || return 0
  new="git@github.com:${url#https://github.com/}"
  new="${new%/}"; new="${new%.git}.git"
  run git -C "$SCRIPT_DIR" remote set-url origin "$new"
  did "arch-bootstrap origin: $url -> $new"
}

# The git host to authenticate against, from whichever remote is known. The
# secrets remote counts: when bootstrap.conf comes from the secrets repo, it is
# the ONLY remote known at stage 05.
ssh_git_host() {
  local remote="${DOTFILES_REMOTE:-${SECRETS_REMOTE:-}}" host
  [[ -z $remote ]] && return 0
  host="${remote#*@}"; host="${host%%:*}"
  printf '%s' "$host"
}

# Send the public key by magic-wormhole to a machine running tools/adopt-key, then
# wait for GitHub to accept it. PAKE-authenticated: only the holder of the printed
# code receives it, and the relay cannot swap it. The code is allocated by the
# server -- a hand-picked one collides with strangers' on the public relay.
wormhole_send_key() {
  local pub=$1.pub i
  [[ -f $pub ]] || return 1
  have wormhole || run sudo pacman -S --needed --noconfirm magic-wormhole || return 1
  info "sending $(ssh-keygen -lf "$pub")"
  info "on beast-arch (or any machine with gh logged in), run:  adopt-key <code below>"
  run_interactive wormhole send --no-qr --text "$(cat "$pub")" || return 1
  info "sent -- waiting for GitHub to accept the key (up to 5 minutes)"
  for (( i = 0; i < 60; i++ )); do
    ssh_auth_works && return 0
    sleep 5
  done
  return 1
}

# Is gh logged in to github.com with a scope that can manage SSH keys?
github_cli_ready() {
  have gh || return 1
  local st; st="$(gh auth status --hostname github.com 2>&1 || true)"
  [[ $st == *"Logged in to github.com"* && $st == *"admin:public_key"* ]]
}

# Is this public key already on the GitHub account? Unknown (gh not ready)
# answers no, so callers fall back to asking the human -- the pre-gh behaviour.
github_key_registered() {
  local pub=$1 body
  github_cli_ready || return 1
  body="$(awk '{print $1" "$2}' "$pub")"
  gh api user/keys --jq '.[].key' 2>/dev/null | grep -qxF "$body"
}

# Log in to GitHub with the device flow and register every local public key.
#
# `gh auth login --web` prints a one-time code and a URL. On a raw TTY no browser
# opens -- enter the code at https://github.com/login/device from a phone or any
# other machine. That is the whole of the manual work.
#
# The token gh stores (~/.config/gh/hosts.yml, or the keyring) can manage SSH keys
# on the account. It stays after this stage because gh is used day to day; to drop
# it once the keys are registered:  gh auth logout --hostname github.com
github_register_keys() {
  local k pub title
  if ! have gh; then
    info "installing github-cli (stage 10 has not run yet; this stage needs it now)"
    run sudo pacman -S --needed --noconfirm github-cli || return 1
  fi
  if ! github_cli_ready; then
    if gh auth status --hostname github.com >/dev/null 2>&1; then
      info "gh is logged in without admin:public_key -- asking for that scope"
      run_interactive gh auth refresh --hostname github.com --scopes admin:public_key \
        || return 1
    else
      pause_for "Log in to GitHub with a one-time code." \
        "gh will print a code and a URL. No browser opens on a TTY: enter the code" \
        "at https://github.com/login/device from your phone or another machine." \
        || return 1
      run_interactive gh auth login --hostname github.com --git-protocol ssh \
        --skip-ssh-key --web --scopes admin:public_key || return 1
    fi
    github_cli_ready || { warn "gh login did not take"; return 1; }
  fi
  ok "gh logged in to github.com (can manage SSH keys)"

  for k in "$@"; do
    pub="$k.pub"
    [[ -f $pub ]] || continue
    if github_key_registered "$pub"; then
      ok "$(basename "$pub") already registered on GitHub"
      continue
    fi
    title="$(uname -n) $(basename "$k") $(date +%F)"
    run gh ssh-key add "$pub" --title "$title" || return 1
    did "registered $(basename "$pub") on GitHub as \"$title\""
  done
}

# --------------------------------------------------------------------------- 10

stage_packages() {
  stage_banner "10 packages -- user-space only"

  info "installing from pkglist-userspace.txt -- no kernel, microcode, GPU or firmware"

  local -a all=() want=() missing=()
  mapfile -t all < <(grep -vE '^[[:space:]]*(#|$)' "$SCRIPT_DIR/pkglist-userspace.txt")
  local p plist
  for p in $PROFILES; do
    plist="$SCRIPT_DIR/pkglist-profile-$p.txt"
    [[ -f $plist ]] || die "PROFILES names '$p', but there is no ${plist##*/}"
    info "profile $p: adding ${plist##*/}"
    mapfile -t -O "${#all[@]}" all < <(grep -vE '^[[:space:]]*(#|$)' "$plist")
  done
  partition_by_exclusion "${all[@]}"
  want=("${EX_WANT[@]}")
  report_exclusions

  # `pacman -T` prints only what is genuinely unsatisfied and understands provides
  # and virtual packages, which a loop over `pacman -Qq <name>` does not: `sh` is
  # satisfied by bash but has no package of its own, and `-Qq sh` reports it
  # missing forever. -T exits 127 when anything is unsatisfied, hence the `|| true`.
  mapfile -t missing < <(pacman -T "${want[@]}" 2>/dev/null || true)

  if (( ${#missing[@]} == 0 )); then
    ok "all ${#want[@]} user-space packages already installed"
  else
    info "${#missing[@]} missing: ${missing[*]}"
    # -Syu rather than -S, and only on the path that actually installs something.
    # Installing against a stale sync database is Arch's partial-upgrade trap, so
    # the refresh has to happen; doing it unconditionally would mean a routine
    # re-run silently upgraded the whole system, which is not this script's job.
    run sudo pacman -Syu --needed --noconfirm "${missing[@]}"
    did "${#missing[@]} user-space package(s) installed"
  fi

  if [[ -f $SCRIPT_DIR/pkglist-hardware.txt ]]; then
    info "held back for stage 15 to decide: \
$(tr '\n' ' ' < "$SCRIPT_DIR/pkglist-hardware.txt")"
  fi
}

# --------------------------------------------------------------------------- 15

# Read `lspci -nnk -d ::0280` (wireless controllers) on stdin; print the packages a
# card with no bound kernel driver needs. Warns about unbound cards it cannot map.
wifi_driver_packages() {
  local line dev="" vid="" bound=0 out=()
  flush() {
    [[ -z $dev ]] && return
    if (( ! bound )); then
      case $vid in
        # Arch dropped the prebuilt broadcom-wl; the dkms build needs the headers
        # of every installed kernel (dkms itself comes as a dependency).
        14e4) out+=(broadcom-wl-dkms)
              local k; for k in linux linux-lts linux-zen linux-hardened; do
                pacman -Qq "$k" >/dev/null 2>&1 && out+=("$k-headers")
              done ;;
        *) warn "Wi-Fi card with no kernel driver, vendor [$vid] -- not guessed: $dev" ;;
      esac
    fi
  }
  while IFS= read -r line; do
    if [[ $line != [[:space:]]* ]]; then
      flush
      dev=$line bound=0
      vid="$(grep -oE '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' <<<"$line" | tail -1 | tr -d '[]' | cut -d: -f1 | tr 'A-F' 'a-f')"
    elif [[ $line == *"Kernel driver in use:"* ]]; then
      bound=1
    fi
  done
  flush
  printf '%s\n' "${out[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//'
}

stage_hardware() {
  stage_banner "15 hardware -- DETECT, do not replay"

  # `detected` = everything this hardware calls for, installed or not.
  # `suggest`  = the subset not yet installed. Keeping them apart matters: the
  # drift report compares against DETECTED, so an already-installed package is
  # not mistaken for one this box never needed.
  local -a detected=()

  # -- CPU vendor -> microcode ---------------------------------------------
  local vendor ucode=""
  vendor="$(awk -F': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo)"
  case "$vendor" in
    GenuineIntel) ucode=intel-ucode ;;
    AuthenticAMD) ucode=amd-ucode   ;;
    *)            warn "unrecognised CPU vendor '$vendor' -- microcode is a manual call" ;;
  esac
  if [[ -n $ucode ]]; then
    info "CPU: $vendor -> $ucode"
    detected+=("$ucode")
  fi

  # -- GPU -> driver set ---------------------------------------------------
  local gpu
  gpu="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d controller|display controller' || true)"
  if [[ -z $gpu ]]; then
    warn "no GPU found via lspci (VM, or lspci missing) -- deferring to stage 90"
  else
    printf '%s\n' "$gpu" | sed 's/^/      /'
    local n_gpu; n_gpu="$(grep -c . <<<"$gpu")"
    if (( n_gpu > 1 )); then
      warn "MULTIPLE display devices -- hybrid graphics. Deferred to stage 90, not guessing."
    else
      # Match on the PCI VENDOR ID, never on the description text.
      #
      # The previous test was `grep -Eqi 'amd|ati|radeon'` against the whole
      # lspci line. "ati" is a substring of "compATIble" and of "CorporATIon",
      # both of which appear in essentially every line lspci prints -- so that
      # branch matched everything that was not NVIDIA, and the `intel` branch
      # below it was UNREACHABLE. Carbon (Intel UHD 620) was classified AMD and
      # offered vulkan-radeon + xf86-video-amdgpu, with vulkan-intel left out.
      # Beast-arch only ever looked correct because it genuinely is AMD.
      #
      # Vendor IDs are stable, locale-independent, and not substrings of English:
      #   8086 Intel    1002 AMD/ATI    10de NVIDIA
      # `lspci -nn` always emits them as [vendor:device], distinct from the
      # [0300] class code by having a colon.
      local vendor_id
      vendor_id="$(grep -oE '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' <<<"$gpu" \
                   | head -1 | tr -d '[]' | cut -d: -f1 | tr 'A-F' 'a-f' || true)"

      case "$vendor_id" in
        10de)
          warn "NVIDIA detected [10de]. Never guessed here -- open vs proprietary vs"
          warn "nouveau is a real decision with real tradeoffs. Deferred to stage 90."
          ;;
        1002)
          info "GPU: AMD/ATI [1002] -> mesa vulkan-radeon xf86-video-amdgpu (or modesetting)"
          detected+=(mesa vulkan-radeon xf86-video-amdgpu)
          if pacman -Qq ollama >/dev/null 2>&1; then
            info "ollama installed and GPU is AMD -> ollama-vulkan is the accelerated variant"
            detected+=(ollama-vulkan)
          fi
          ;;
        8086)
          info "GPU: Intel [8086] -> mesa vulkan-intel (modesetting; xf86-video-intel is worse)"
          detected+=(mesa vulkan-intel)
          ;;
        "")
          warn "could not read a PCI vendor ID from lspci -- deferred to stage 90"
          ;;
        *)
          warn "unrecognised GPU vendor [$vendor_id] -- deferred to stage 90"
          ;;
      esac
    fi
  fi

  # -- Wi-Fi -> driver --------------------------------------------------------
  # Only cards with NO kernel driver bound are acted on; a bound driver means the
  # kernel (and linux-firmware) already covers it. The one common gap is Broadcom:
  # many of its chips (BCM4313, 43142, 4331, 4360 ...) have no open driver, so the
  # live ISO and a fresh install show no Wi-Fi device at all (iwctl device list is
  # empty). broadcom-wl-dkms builds the module and blacklists b43/bcma/ssb, which
  # would otherwise claim the card first.
  local wifi_line wifi_pkgs
  wifi_line="$(lspci -nnk -d ::0280 2>/dev/null || true)"
  if [[ -z $wifi_line ]]; then
    info "Wi-Fi: no PCI wireless controller (none, or USB) -- nothing to add"
  else
    printf '%s\n' "$wifi_line" | grep -v '^[[:space:]]' | sed 's/^/      /'
    wifi_pkgs="$(wifi_driver_packages <<<"$wifi_line")"
    if [[ -n $wifi_pkgs ]]; then
      info "Wi-Fi: unbound Broadcom card -> $wifi_pkgs (loads at next boot, or: sudo modprobe wl)"
      read -ra _w <<<"$wifi_pkgs"; detected+=("${_w[@]}")
    fi
  fi

  # -- audio firmware ------------------------------------------------------
  if grep -qi 'sof' /proc/asound/cards 2>/dev/null; then
    info "audio: SOF-based codec detected -> sof-firmware"
    detected+=(sof-firmware)
  else
    info "audio: no SOF codec detected -- sof-firmware not needed"
  fi

  # -- boot mode -----------------------------------------------------------
  if [[ -d /sys/firmware/efi ]]; then
    info "boot: UEFI -> efibootmgr and memtest86+-efi are meaningful"
    detected+=(efibootmgr memtest86+-efi)
  else
    info "boot: legacy BIOS -> efibootmgr is NOT meaningful here; skipping"
  fi

  # -- bluetooth -----------------------------------------------------------
  if lsusb 2>/dev/null | grep -qi bluetooth || \
     [[ -n "$(lspci -nn 2>/dev/null | grep -i bluetooth || true)" ]] || \
     compgen -G '/sys/class/bluetooth/*' >/dev/null; then
    info "bluetooth adapter present -> bluez bluez-utils"
    detected+=(bluez bluez-utils)
  else
    info "no bluetooth adapter -- bluez not needed"
  fi

  # -- memory tuning -------------------------------------------------------
  local memgb
  memgb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  info "RAM: ~${memgb} GiB"
  if (( memgb <= 16 )); then
    info "-> zram-generator is worth having at this size"
    detected+=(zram-generator)
  else
    info "-> zram-generator optional above 16 GiB"
  fi

  # -- report --------------------------------------------------------------

  # Drift is measured against DETECTED, not against what is missing -- otherwise an
  # already-installed package reads as "the reference box needed this and we don't".
  if [[ -f $SCRIPT_DIR/pkglist-hardware.txt && ${#detected[@]} -gt 0 ]]; then
    local drift
    drift="$(comm -13 <(printf '%s\n' "${detected[@]}" | sort -u) \
                      <(sort "$SCRIPT_DIR/pkglist-hardware.txt") \
             | grep -vE '^(base|base-devel|linux|linux-firmware)$' || true)"
    [[ -n $drift ]] && \
      info "on the reference box but not called for here: $(tr '\n' ' ' <<<"$drift")"
  fi

  local -a suggest=()
  local p
  for p in $(printf '%s\n' "${detected[@]}" | sort -u); do
    if pacman -Qq "$p" >/dev/null 2>&1; then
      ok "$p already installed"
    else
      suggest+=("$p")
    fi
  done

  if (( ${#suggest[@]} == 0 )); then
    ok "no hardware packages to add -- everything this box calls for is present"
    return 0
  fi

  printf '\n%s  detected hardware needs these, not yet installed:%s %s\n' \
    "$C_BOLD" "$C_RESET" "${suggest[*]}"

  if (( DRY_RUN )); then
    run sudo pacman -S --needed "${suggest[@]}"
    return 0
  fi

  if confirm "install these hardware packages?"; then
    sudo pacman -S --needed "${suggest[@]}"
    did "hardware packages installed"
  else
    warn "skipped -- install by hand, or see stage 90"
  fi
}

# --------------------------------------------------------------------------- 20

stage_aur() {
  stage_banner "20 aur"

  # makepkg needs base-devel (fakeroot, debugedit). It is in pkglist-userspace.txt
  # since 2026-09-30; before that the script assumed pacstrap had installed it, and
  # on a rebuild where it had not, makepkg failed with "Cannot find the fakeroot
  # binary" and -- with stage errors ignored at the time -- stage 20 was marked
  # done with nothing from the AUR installed. Checked here too, so a run with
  # `--only aur` or an excluded base-devel fails with the cause, not a symptom.
  if ! pacman -Q base-devel >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      info "(dry run) base-devel is not installed -- a real run would stop here"
    else
      warn "base-devel is not installed -- makepkg cannot build anything without it"
      todo "sudo pacman -S --needed base-devel    (or re-run stage 10: --redo packages)"
      return 1
    fi
  fi

  # yay is itself in the AUR list, so it has to be built from source first.
  if have yay; then
    ok "yay already installed"
  else
    info "building yay from source (it is in the AUR list but cannot install itself)"
    local tmp; tmp="$(mktemp -d)"
    run git clone --depth 1 https://aur.archlinux.org/yay.git "$tmp/yay"
    if (( DRY_RUN )); then
      printf '%s  would run:%s makepkg -si --noconfirm in %s/yay\n' "$C_DIM" "$C_RESET" "$tmp"
    else
      ( cd "$tmp/yay" && makepkg -si --noconfirm )
    fi
    run rm -rf "$tmp"
    did "yay built"
  fi

  local -a all=() want=() missing=()
  mapfile -t all < <(grep -vE '^[[:space:]]*(#|$)' "$SCRIPT_DIR/pkglist-aur.txt" | grep -vx 'yay')
  partition_by_exclusion "${all[@]}"
  want=("${EX_WANT[@]}")
  report_exclusions

  # Same reasoning as stage 10. An AUR package is an ordinary pacman package once
  # built, so -T answers for these too -- and asking pacman rather than yay avoids
  # yay's habit of hitting the AUR RPC on every invocation.
  mapfile -t missing < <(pacman -T "${want[@]}" 2>/dev/null || true)

  if (( ${#missing[@]} == 0 )); then
    ok "all ${#want[@]} AUR packages already installed"
  else
    info "${#missing[@]} missing from the AUR list: ${missing[*]}"
    local n=${#missing[@]}
    # shellcheck disable=SC2086
    run yay -S --needed --noconfirm "${missing[@]}"
    if ! (( DRY_RUN )); then
      # Ask pacman, not yay's exit status: this stage's "done" mark is what a
      # later session trusts, so it is only earned by the packages being there.
      mapfile -t missing < <(pacman -T "${want[@]}" 2>/dev/null || true)
      if (( ${#missing[@]} )); then
        warn "still missing after yay: ${missing[*]}"
        return 1
      fi
    fi
    did "$n AUR package(s) installed"
  fi

  if [[ " ${want[*]} " == *" rambox-pro-bin "* ]]; then
    install_rambox_perms_hook
  fi
}

# rambox-pro-bin installs /opt/rambox as drwx------ root, so `rambox` fails with
# "permission denied" for every user and xmonad's spawnOnOnce silently opens
# nothing. The cause is upstream: the Rambox .deb ships ./opt/Rambox/ as 0700
# (its postinst chmods only chrome-sandbox), and the PKGBUILD's `cp -rp .../.`
# carries that mode onto the package directory. Found 2026-09-30 on beast-arch,
# pkgver 2.7.1-1. Every upgrade reinstalls the 0700, so a one-off chmod is not a
# fix -- a pacman hook re-applies it after each install or upgrade. Retire this
# when the AUR package sets the mode itself.
RAMBOX_HOOK=/etc/pacman.d/hooks/rambox-perms.hook
install_rambox_perms_hook() {
  local want
  want="$(cat <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = rambox-pro-bin

[Action]
Description = Fixing /opt/rambox permissions (upstream deb ships it 0700)
When = PostTransaction
Exec = /usr/bin/chmod 755 /opt/rambox
EOF
)"
  if [[ -f $RAMBOX_HOOK ]] && [[ "$(cat "$RAMBOX_HOOK")" == "$want" ]]; then
    ok "rambox permissions hook in place"
  else
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$want" > "$tmp"
    run sudo install -D -m 644 "$tmp" "$RAMBOX_HOOK" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    did "installed $RAMBOX_HOOK"
  fi

  # The hook fires on the NEXT transaction; the package installed a moment ago is
  # already 0700. `stat` needs only search permission on /opt, not on /opt/rambox.
  if [[ -d /opt/rambox && "$(stat -c %a /opt/rambox)" != 755 ]]; then
    run sudo chmod 755 /opt/rambox
    did "chmod 755 /opt/rambox"
  fi
}

# --------------------------------------------------------------------------- 25

stage_toolchains() {
  stage_banner "25 toolchains"

  # rustup / stack / go / ruby / python-pip / luarocks / mise arrive from pacman in
  # stage 10. What they still need is per-user initialisation. ghcup does not come
  # from pacman; it is installed below.

  # stable AND nightly (Ben, 2026-08-24). beast-arch also carries pinned 1.97.1 and
  # 1.98.0; those are deliberately NOT reproduced -- a pin belongs to whatever
  # project needed it, and baking someone's old pin into every future machine is
  # how a toolchain list rots.
  if have rustup; then
    local rust_have tc
    rust_have="$(rustup toolchain list 2>/dev/null || true)"
    for tc in stable nightly; do
      if printf '%s' "$rust_have" | grep -q "^$tc-"; then
        ok "rust: $tc already installed"
      else
        run rustup toolchain install "$tc"
        did "rust: $tc installed"
      fi
    done
    # Set a default ONLY when there is none. An earlier draft forced it to stable
    # and the dry run caught what that costs: beast-arch's default is a pinned
    # 1.98.0, so a re-run would have silently moved it and broken whatever wanted
    # the pin. Installing a toolchain is additive; repointing the default is not,
    # and nobody asked for it.
    if rustup default 2>/dev/null | grep -q '.'; then
      ok "rust: default is already set ($(rustup default 2>/dev/null | head -1))"
    else
      run rustup default stable
      did "rust: default set to stable"
    fi
  else
    warn "rustup missing -- did stage 10 run?"
  fi

  if have stack; then
    ok "stack present ($(stack --version 2>/dev/null | head -1 | cut -d, -f1))"
    info "GHC itself is fetched by the xmonad stage's build"
  else
    warn "stack missing -- the xmonad stage will fail"
  fi

  # ghcup: GHC and cabal for Haskell work outside xmonad (Ben, 2026-10-01). Not in
  # the Arch repos (only the AUR's ghcup-hs-bin), so the official installer is used,
  # the way nvm is. Non-interactive, it installs the recommended GHC and cabal, and
  # it does NOT edit shell rc files: .zshrc already sources ~/.ghcup/env. NO_STACK
  # keeps it off stack, which is pacman's. xmonad's build relies on stack fetching
  # its own GHC (lts-15.9, no system-ghc), and ghcup's stack hook would change that.
  if [[ -x $HOME/.ghcup/bin/ghc && -x $HOME/.ghcup/bin/cabal ]]; then
    ok "ghcup: ghc $("$HOME/.ghcup/bin/ghc" --numeric-version) and cabal $("$HOME/.ghcup/bin/cabal" --numeric-version) present"
  else
    info "installing ghcup with the recommended ghc and cabal"
    # pipefail: without it a failed download pipes nothing into sh, which exits 0.
    run env BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1 \
      bash -c "set -o pipefail; curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh"
    did "ghcup installed (ghc + cabal)"
  fi

  have go && ok "go present ($(go version))" || warn "go missing"

  # nvm is NOT a pacman package -- it is a shell function installed by script.
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s $NVM_DIR/nvm.sh ]]; then
    ok "nvm present at $NVM_DIR"
  else
    info "installing nvm"
    # The installer REFUSES to run when NVM_DIR is set but the directory does not
    # exist ("You have $NVM_DIR set to ..., but that directory does not exist"),
    # and NVM_DIR is exported just above. On 2026-09-30 that had to be fixed by
    # hand with mkdir; make it here instead.
    run mkdir -p "$NVM_DIR"
    run bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
    did "nvm installed"
  fi

  if (( DRY_RUN )) && [[ -s $NVM_DIR/nvm.sh ]]; then
    # Sourcing nvm and asking `nvm ls` is read-only, so the dry run can answer
    # this properly instead of always claiming it would install. It used to print
    # "would run: nvm install 24" on a machine that already had v24.
    set +eu; # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    if nvm ls --no-colors "$NODE_MAJOR" >/dev/null 2>&1; then
      ok "node v$NODE_MAJOR already installed"
    else
      printf '%s  would run:%s nvm install %s\n' "$C_DIM" "$C_RESET" "$NODE_MAJOR"
      did "node v$NODE_MAJOR installed"
    fi
    set -eu
  elif (( DRY_RUN )); then
    printf '%s  would run:%s nvm install %s\n' "$C_DIM" "$C_RESET" "$NODE_MAJOR"
    did "node v$NODE_MAJOR installed"
  elif [[ -s $NVM_DIR/nvm.sh ]]; then
    # nvm is a function, not a binary -- must be sourced, and it trips `set -u`.
    # It trips `set -e` too: its internal helpers return non-zero as ordinary
    # control flow, so errexit is off for this block and each step that matters is
    # checked by hand. Every exit from the block goes through the one `set -eu`
    # below -- returning early with errexit still off would leave it off for the
    # rest of the run, and the failure would be marked done like before.
    set +eu; # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    local nvm_fail=""

    # `nvm install` on an already-installed version is close to a no-op, but it
    # still resolves the version index over the network on every run. Ask locally.
    if nvm ls --no-colors "$NODE_MAJOR" >/dev/null 2>&1; then
      ok "node v$NODE_MAJOR already installed"
    elif nvm install "$NODE_MAJOR"; then
      did "node v$NODE_MAJOR installed"
    else
      nvm_fail="nvm install $NODE_MAJOR"
    fi

    if [[ -n $nvm_fail ]]; then
      :
    elif [[ "$(nvm alias default --no-colors 2>/dev/null)" == *"v$NODE_MAJOR."* ]]; then
      ok "nvm default alias already -> v$NODE_MAJOR"
    elif nvm alias default "$NODE_MAJOR" >/dev/null; then
      did "nvm default alias set to v$NODE_MAJOR"
    else
      nvm_fail="nvm alias default $NODE_MAJOR"
    fi

    if [[ -z $nvm_fail ]]; then
      if nvm use "$NODE_MAJOR" >/dev/null; then
        ok "node $(node --version) active (pinned to v$NODE_MAJOR)"
      else
        nvm_fail="nvm use $NODE_MAJOR"
      fi
    fi

    if [[ -z $nvm_fail && -n $OBSIDIAN_VAULT ]]; then
      if npm ls -g --depth 0 2>/dev/null | grep -q obsidian-headless; then
        ok "obsidian-headless already installed"
      elif npm install -g obsidian-headless; then
        did "obsidian-headless installed"
      else
        nvm_fail="npm install -g obsidian-headless"
      fi
    fi
    set -eu
    [[ -z $nvm_fail ]] || { warn "failed: $nvm_fail"; return 1; }
  fi

  install_npm_globals

  # NOTE: no gems are installed by default (Ben, 2026-08-24). `ruby` is in the
  # package list and `gem` is only checked for presence. beast-arch carries a
  # large jekyll/github-pages-looking set installed by hand; it belongs to
  # whatever built it, not to every machine, so there is no pkglist-gem.txt and
  # adding one should be a decision rather than a reflex.
  local t
  for t in mise luarocks gem starship; do
    have "$t" && ok "$t present" || warn "$t missing"
  done

  # mise arrives from pacman in stage 10, but nothing ever asked it to install the
  # tools its config DECLARES -- so a rebuild got the manager and none of the
  # toolchains. Added 2026-08-24.
  #
  # It installs what the CONFIG asks for, which is deliberately not the same as
  # what the reference machine happens to have. beast-arch also carries elixir,
  # erlang and postgres under mise, installed by hand and declared in no config
  # file at all; they belong to a project Ben has left (his call, 2026-08-24) and
  # are NOT reproduced. If they are ever wanted, declaring them is the fix --
  # putting them in a package list is not, because mise owns their versions.
  #
  # XDG_CONFIG_HOME is passed explicitly. mise resolves its config through it, and
  # the systemd/PATH notes elsewhere in this script exist because this box's is
  # non-standard; a stage that assumed ~/.config would silently find no tools and
  # report success.
  if have mise; then
    local mise_missing
    mise_missing="$(XDG_CONFIG_HOME="$XDG_CONFIG_HOME" mise ls --missing 2>/dev/null || true)"
    if [[ -z $mise_missing ]]; then
      ok "mise: every declared tool is already installed"
    else
      info "mise: installing declared tools -- $(printf '%s' "$mise_missing" | tr '\n' ' ')"
      run env XDG_CONFIG_HOME="$XDG_CONFIG_HOME" mise install
      did "mise tools installed"
    fi
  fi

  install_self_distributed_binaries
  install_claude
  report_unmanaged_binaries
}

# Claude Code. Ben's call 2026-08-24 to install it, unlike nono and zed which are
# reported only.
#
# It is a NATIVE build, not the npm package: installs land in
# ~/.local/share/claude/versions/<version> with ~/.local/bin/claude symlinked at
# the current one, which is what this box has. Once present it manages itself --
# `claude update` -- so this only has to solve the fresh-machine case.
#
# The endpoint was VERIFIED rather than remembered (2026-08-24): it returns 200
# and serves a bash script taking [stable|latest|VERSION]. Overridable, because a
# hardcoded vendor URL is exactly the line that rots quietly.
install_claude() {
  [[ -n ${CLAUDE_INSTALL_URL:-} ]] || CLAUDE_INSTALL_URL="https://claude.ai/install.sh"

  if have claude; then
    ok "claude present ($(claude --version 2>/dev/null | head -1))"
    info "it self-updates: run 'claude update' when you want a newer build"
    return 0
  fi

  if (( DRY_RUN )); then
    printf '%s  would run:%s curl -fsSL %s | bash\n' "$C_DIM" "$C_RESET" "$CLAUDE_INSTALL_URL"
    did "claude installed"
    return 0
  fi

  if run bash -c "curl -fsSL '$CLAUDE_INSTALL_URL' | bash"; then
    did "claude installed"
  else
    warn "claude install failed from $CLAUDE_INSTALL_URL"
    todo "install it by hand; see https://claude.com/claude-code"
    return 0
  fi

  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) todo "~/.local/bin is not on PATH -- claude will not be found until it is" ;;
  esac
}

# Binaries this machine relies on that NOTHING here installs, and honestly cannot.
# Added 2026-08-24 after a sweep found five of them in ~/.local/bin against one
# (herdr) that the script actually manages.
#
# This function deliberately does NOT install anything. Each of these arrives
# through its vendor's own installer, and none of those endpoints is recorded
# anywhere on this box -- `nono --help` offers pack management, not self-install,
# and its embedded URLs are sandbox-policy examples, not a download host. Writing
# a plausible-looking curl line for any of them would be exactly the confidently
# wrong line this project cannot afford: it would appear to work until the day
# someone rebuilds under pressure.
#
# So it REPORTS. A rebuild that is missing these now says so, instead of coming up
# quietly incomplete, which is the failure this whole sweep was chasing.
#
# Format: <binary>|<what it is, and why its absence matters>
UNMANAGED_BINARIES=(
  "nono|the agent sandbox. Its absence is a SECURITY regression, not a missing convenience -- see beast-arch task 45"
  "zed|editor, vendor installer, lives in ~/.local/zed.app"
)

report_unmanaged_binaries() {
  local entry name why present=0 absent=0

  for entry in "${UNMANAGED_BINARIES[@]}"; do
    IFS='|' read -r name why <<< "$entry"
    if have "$name"; then
      ok "$name present (not managed by this script -- it updates itself)"
      present=$(( present + 1 ))
    else
      warn "$name is NOT installed, and this script cannot install it"
      todo "  $why"
      absent=$(( absent + 1 ))
    fi
  done

  # meetily is deliberately absent from the list above. It was built from source
  # into ~/build for beast-arch task 50, which is closed and whose audio Ben tore
  # down; .xinitrc still autostarts it but guards on the path, so a machine
  # without it is correct rather than broken. Reproducing a retired tool is worse
  # than not reproducing it.

  (( absent )) && info "$absent binary/binaries above need a manual install on a fresh machine"
  return 0
}

# Global npm packages from pkglist-npm.txt. Added 2026-08-24: a sweep found six
# globals on beast-arch and exactly one -- obsidian-headless -- installed by this
# script, so a rebuild silently dropped the rest.
#
# Must run INSIDE the nvm-sourced part of stage 25, against the pinned node.
# Installing globals against a system node puts them somewhere the pinned node
# will not look, which fails in the confusing direction: `npm ls -g` shows them
# and the command is still not found.
install_npm_globals() {
  local list="$SCRIPT_DIR/pkglist-npm.txt"
  [[ -f $list ]] || return 0

  local -a all=() want=() missing=()
  mapfile -t all < <(grep -vE '^[[:space:]]*(#|$)' "$list")
  (( ${#all[@]} )) || { info "npm: nothing listed"; return 0; }

  partition_by_exclusion "${all[@]}"
  want=("${EX_WANT[@]}")
  report_exclusions
  (( ${#want[@]} )) || return 0

  if ! have npm; then
    warn "npm not on PATH -- skipping ${#want[@]} global(s). Did the nvm block run?"
    return 0
  fi

  # Ask npm ONCE and match locally. `npm ls -g <name>` per package is a process
  # spawn each, and on a scoped name it is easy to get a false negative.
  local installed
  # npm ls exits non-zero over any extraneous/invalid dependency; the listing is
  # still complete, and under pipefail + errexit that would kill the stage.
  installed="$(npm ls -g --depth 0 --parseable 2>/dev/null | sed 's|.*/node_modules/||' || true)"

  local pkg
  for pkg in "${want[@]}"; do
    if printf '%s\n' "$installed" | grep -qxF "$pkg"; then
      ok "npm: $pkg already installed"
    else
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    ok "npm: all ${#want[@]} global(s) already installed"
    return 0
  fi

  info "npm: ${#missing[@]} missing: ${missing[*]}"
  run npm install -g "${missing[@]}"
  did "${#missing[@]} npm global(s) installed"
}

# Tools that are neither pacman, AUR, cargo nor npm: single binaries published by
# their upstream and updated in place. Installing them here rather than committing
# them to a dotfiles repo keeps a self-updating binary from leaving the repo
# permanently dirty, and keeps the repo from carrying a large blob per version.
install_self_distributed_binaries() {
  # herdr -- terminal multiplexer. Referenced by xmonad's startup hook
  # (spawnOnOnce "2" "alacritty -e herdr"), so a machine without it fails at login
  # with "command not found".
  # Pinned: the release publishes no checksum or attestation, so the sha256 here is
  # the only integrity check (task 76). Bump both together; `herdr update` moves an
  # installed copy past this pin, which only governs the first install.
  local ver=0.9.3 arch sum asset
  case "$(uname -m)" in
    x86_64)         arch=linux-x86_64;  sum=18a8dc65f1c2fa485884344356dea1cfd911c6f06cf46fa78e193f4087f4dba7 ;;
    aarch64|arm64)  arch=linux-aarch64; sum=4de7aa3e25678812e92960de64f7c2aaa1bca1f0f80a3c5e559837e231e1f5c0 ;;
    *) warn "no herdr build for $(uname -m) -- skipping"; return 0 ;;
  esac
  asset="https://github.com/herdrdev/herdr/releases/download/v$ver/herdr-$arch"

  if have herdr; then
    ok "herdr present ($(herdr --version 2>/dev/null | head -1))"
    info "it self-updates: run 'herdr update' when you want a newer build"
    return 0
  fi

  if (( DRY_RUN )); then
    printf '%s  would run:%s install herdr %s from %s\n' "$C_DIM" "$C_RESET" "$ver" "$asset"
    return 0
  fi

  mkdir -p "$HOME/.local/bin"
  if curl -fsSL "$asset" -o "$HOME/.local/bin/herdr.tmp" \
     && echo "$sum  $HOME/.local/bin/herdr.tmp" | sha256sum -c --quiet; then
    chmod +x "$HOME/.local/bin/herdr.tmp"
    mv "$HOME/.local/bin/herdr.tmp" "$HOME/.local/bin/herdr"
    ok "herdr installed ($("$HOME/.local/bin/herdr" --version 2>/dev/null | head -1))"
  else
    rm -f "$HOME/.local/bin/herdr.tmp"
    warn "herdr download failed or checksum mismatch from $asset"
  fi

  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) todo "~/.local/bin is not on PATH -- herdr will not be found until it is" ;;
  esac
}

# --------------------------------------------------------------------------- 30

stage_dotfiles() {
  stage_banner "30 dotfiles"

  if [[ -z $DOTFILES_REMOTE ]]; then
    warn "DOTFILES_REMOTE is not set in $BOOTSTRAP_CONFIG -- skipping"
    return 0
  fi

  local dot=(git --git-dir="$DOTFILES_DIR" --work-tree="$HOME")
  local fresh_clone=0

  if [[ -d $DOTFILES_DIR ]]; then
    ok "$DOTFILES_DIR already cloned"
  else
    run git clone --bare "$DOTFILES_REMOTE" "$DOTFILES_DIR"
    did "cloned dotfiles"
    fresh_clone=1
  fi

  if (( DRY_RUN )); then
    printf '%s  would run:%s checkout into $HOME (backing up collisions only on a first clone)\n' \
      "$C_DIM" "$C_RESET"
  else
    dotfiles_checkout "$fresh_clone" || return 1
  fi

  # core.bare=true makes git ignore --work-tree for index operations, which is
  # why `<alias> ls-files` returns nothing on a bare dotfiles repo. These two
  # settings are what make day-to-day use behave.
  git_config_ensure "dotfiles" status.showUntrackedFiles no "${dot[@]}"
  # A bare clone has no fetch refspec, so origin/master never exists locally and
  # a bare `pull`/`push` fails. Set it so new machines don't inherit that quirk.
  git_config_ensure "dotfiles" remote.origin.fetch \
    '+refs/heads/*:refs/remotes/origin/*' "${dot[@]}"
  # Nor does a bare clone set an upstream, so a bare `pull` says "no tracking
  # information" and `status -sb` shows no ahead/behind (beast-arch, 2026-10-03).
  local br
  if br="$("${dot[@]}" symbolic-ref --short HEAD 2>/dev/null)"; then
    git_config_ensure "dotfiles" "branch.$br.remote" origin "${dot[@]}"
    git_config_ensure "dotfiles" "branch.$br.merge" "refs/heads/$br" "${dot[@]}"
    # The refspec above only takes effect at the next fetch; until origin/$br
    # exists, status reports the upstream as gone.
    "${dot[@]}" rev-parse -q --verify "refs/remotes/origin/$br" >/dev/null \
      || run "${dot[@]}" fetch -q origin
  elif (( DRY_RUN )); then
    info "(dry run) would set the dotfiles branch upstream to origin"
  else
    warn "dotfiles HEAD is detached -- upstream not set"
  fi

  if [[ -n $CONFIG_HOME_OVERRIDE ]]; then
    [[ -d $CONFIG_HOME_OVERRIDE ]] \
      && ok "$CONFIG_HOME_OVERRIDE arrived with the dotfiles" \
      || warn "$CONFIG_HOME_OVERRIDE missing after checkout -- check the tree"
  fi

  # Scripts under ~/.local/bin are commonly referenced by WM configs; a
  # non-executable one fails at login with a confusing "command not found".
  if [[ -d $HOME/.local/bin ]]; then
    local n=0 s
    for s in "$HOME"/.local/bin/*; do
      [[ -f $s && ! -x $s ]] && { run chmod 755 "$s"; n=$(( n + 1 )); }
    done
    (( n )) && did "made $n script(s) in ~/.local/bin executable" \
            || ok "~/.local/bin scripts already executable"
  fi
}

# Check the bare dotfiles repo out into $HOME.
#
# There are two ways `checkout` can fail here and they call for OPPOSITE responses.
# Conflating them is how a routine re-run eats a day of uncommitted work:
#
#   FIRST CLONE -- the collisions are the stock files `useradd` wrote (.bashrc,
#     .bash_profile, commonly tracked). Nobody typed them, moving them aside is
#     right, and it is what makes an unattended first run possible.
#
#   RE-RUN -- the repo was already here, so the checkout that failed had succeeded
#     before. The usual cause is LOCAL MODIFICATIONS to tracked files: your edits.
#     Nothing that runs routinely may move those aside without asking. Stop and
#     report instead, and let the human decide.
#
# git's own error header distinguishes the two, so this reads the header rather
# than inferring intent from the path list.
dotfiles_checkout() {
  local fresh=$1
  local dot=(git --git-dir="$DOTFILES_DIR" --work-tree="$HOME")
  local err f

  if err="$("${dot[@]}" checkout 2>&1)"; then
    ok "dotfiles checked out into \$HOME"
    return 0
  fi

  if grep -q 'Your local changes to the following files' <<<"$err"; then
    warn "checkout refused: you have uncommitted changes to tracked dotfiles."
    printf '%s\n' "$err" | sed 's/^/        /'
    warn "This stage will NOT move them aside -- they are your edits, not stock files."
    todo "review:  git --git-dir=$DOTFILES_DIR --work-tree=\$HOME status"
    todo "then commit or stash them and re-run:  $0 --redo dotfiles"
    return 1
  fi

  if ! grep -q 'untracked working tree files would be overwritten' <<<"$err"; then
    warn "checkout failed in a way this stage does not recognise -- not guessing:"
    printf '%s\n' "$err" | sed 's/^/        /'
    return 1
  fi

  # ---- untracked collisions -------------------------------------------------
  #
  # Build the set of tracked paths from the REPO and use it to validate what we
  # parse out of the error.
  #
  # NOTE the missing --work-tree. core.bare=true makes git ignore --work-tree for
  # index operations, and `ls-tree` then returns ZERO lines with exit status 0 --
  # a silent empty answer, not an error. Passing it here would make every
  # collision look untracked and the guard below would fire on a healthy repo.
  local -A is_tracked=()
  while IFS= read -r f; do
    [[ -n $f ]] && is_tracked["$f"]=1
  done < <(git --git-dir="$DOTFILES_DIR" ls-tree -r --name-only HEAD 2>/dev/null || true)

  if (( ${#is_tracked[@]} == 0 )); then
    warn "could not enumerate tracked paths in $DOTFILES_DIR -- refusing to move anything"
    printf '%s\n' "$err" | sed 's/^/        /'
    return 1
  fi

  # git indents each offending path with a single TAB. Two bugs lived in the old
  # parse of this list, both only reachable on a re-run:
  #
  #   grep -E '^\s+\.'  matched only paths beginning with a dot. 497 of the 623
  #                     paths tracked on the reference box do not -- the whole of
  #                     bin/. They were never moved, the retry failed again, and
  #                     the work tree was left HALF CHECKED OUT.
  #   awk '{print $1}'  truncated any path containing a space at the first space.
  #
  # Take the whole line minus its indent, then keep only what the repo actually
  # tracks.
  local -a collisions=() unknown=()
  while IFS= read -r f; do
    f="${f#"${f%%[![:space:]]*}"}"          # strip leading whitespace
    [[ -z $f ]] && continue
    if [[ -n ${is_tracked[$f]:-} ]]; then
      collisions+=("$f")
    else
      unknown+=("$f")
    fi
  done < <(grep -E '^[[:space:]]' <<<"$err" || true)

  if (( ${#unknown[@]} )); then
    warn "git named ${#unknown[@]} colliding path(s) that are not tracked in HEAD:"
    printf '%s\n' "${unknown[@]}" | sed 's/^/        /'
    warn "that should not happen -- not touching anything"
    return 1
  fi

  if (( ${#collisions[@]} == 0 )); then
    warn "checkout reported a collision but no path could be parsed from it:"
    printf '%s\n' "$err" | sed 's/^/        /'
    return 1
  fi

  if ! (( fresh )); then
    warn "${#collisions[@]} untracked file(s) in \$HOME collide with tracked paths."
    warn "The repo was already cloned, so these are not the stock files useradd made:"
    printf '%s\n' "${collisions[@]}" | sed 's/^/        /'
    confirm "move them into a backup directory and continue?" || {
      warn "left untouched -- resolve by hand, then: $0 --redo dotfiles"
      return 1
    }
  fi

  local backup="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  warn "backing up ${#collisions[@]} colliding file(s) to $backup"
  for f in "${collisions[@]}"; do
    mkdir -p "$backup/$(dirname "$f")"
    mv "$HOME/$f" "$backup/$f"
  done

  if err="$("${dot[@]}" checkout 2>&1)"; then
    did "dotfiles checked out (${#collisions[@]} collision(s) saved in $backup)"
    return 0
  fi

  # Never leave this ambiguous. A half-checked-out $HOME that reports success is
  # worse than either outcome.
  warn "checkout STILL failed after backing up the collisions. \$HOME may now be"
  warn "half checked out. Do not log out until this is resolved."
  printf '%s\n' "$err" | sed 's/^/        /'
  todo "the backed-up files are in $backup -- nothing was deleted"
  return 1
}

# --------------------------------------------------------------------------- 35

# Clone the secrets repo if it is not here yet. Shared by stage 05 (which needs
# bootstrap.conf out of it) and stage 35 (which needs the vault). Remembers that
# THIS run cloned it, so stage 35 still asks for the vault unlock.
SECRETS_CLONED_THIS_RUN=0
clone_secrets() {
  if [[ -d $SECRETS_DIR ]]; then
    ok "$SECRETS_DIR already cloned"
    return 0
  fi
  run git clone "$SECRETS_REMOTE" "$SECRETS_DIR"
  did "cloned secrets repo"
  SECRETS_CLONED_THIS_RUN=1
}

# Replace bootstrap.conf with the copy kept in the secrets repo. The secrets copy
# is the source of truth while CONFIG_FROM_SECRETS=1: edit it there, commit, and
# the next run picks the change up. It is plain bash, so a value that differs per
# machine can switch on the host:  case "$(uname -n)" in carbon) ... ;; esac
adopt_config_from_secrets() {
  (( CONFIG_FROM_SECRETS )) || return 0
  [[ -n $SECRETS_REMOTE ]] || die "CONFIG_FROM_SECRETS=1 but SECRETS_REMOTE is empty"
  if (( DRY_RUN )) && [[ ! -d $SECRETS_DIR ]]; then
    info "(dry run) would clone $SECRETS_REMOTE and adopt its bootstrap.conf"
    return 0
  fi
  clone_secrets
  local src="$SECRETS_DIR/arch-bootstrap/bootstrap.conf"
  if [[ ! -f $src ]]; then
    warn "$src not found in the secrets repo"
    todo "add it there, or delete $BOOTSTRAP_CONFIG and answer the questions instead"
    return 1
  fi
  grep -q '^CONFIG_FROM_SECRETS=1' "$src" \
    || warn "$src lacks CONFIG_FROM_SECRETS=1 -- later runs will stop following it"
  if cmp -s "$src" "$BOOTSTRAP_CONFIG"; then
    ok "bootstrap.conf matches the secrets repo's copy"
  else
    run install -m 600 "$src" "$BOOTSTRAP_CONFIG"
    did "adopted bootstrap.conf from the secrets repo"
  fi
  load_config
}

stage_secrets() {
  stage_banner "35 secrets"

  if [[ -z $SECRETS_REMOTE ]]; then
    info "SECRETS_REMOTE not set -- skipping"
    return 0
  fi

  clone_secrets
  local fresh_clone=$SECRETS_CLONED_THIS_RUN

  (( DRY_RUN )) || {
    local kdbx
    kdbx="$(find "$SECRETS_DIR" -maxdepth 2 -name '*.kdbx' 2>/dev/null | head -1 || true)"
    [[ -n $kdbx ]] && ok "vault found: $(basename "$kdbx")" \
                   || info "no .kdbx found under $SECRETS_DIR"
  }

  have keepassxc && ok "keepassxc installed" || warn "keepassxc not installed"

  # Only on the run that actually cloned the repo. An unconditional prompt here is
  # a blocking manual step on a machine that has been set up for months, which is
  # exactly what stops anyone re-running this as a routine check.
  if (( fresh_clone )); then
    pause_for "Unlock your password vault." \
      "The master password comes from your memory. It is the one step in this" \
      "entire chain that cannot be automated, and everything downstream that" \
      "needs a credential depends on it." || true
  else
    ok "secrets repo was already present -- not prompting for the vault"
  fi

  clone_wallpapers
}

# The wallpapers moved out of the dotfiles into their own repo on 2026-08-15, and
# .xinitrc now points `nitrogen --set-zoom-fill --random` at that path. Nothing
# cloned it, so a machine provisioned before the split -- or a fresh one -- comes
# up with no wallpaper at all and no error that explains why.
#
# It lives here rather than in stage 30 because it is an ordinary (non-bare) clone
# over SSH, same as the secrets repo, and wants the same already-working key.
# Optional: an unset WALLPAPERS_REMOTE just skips it.
clone_wallpapers() {
  if [[ -z $WALLPAPERS_REMOTE ]]; then
    info "WALLPAPERS_REMOTE not set -- skipping (the desktop will have no wallpaper)"
    return 0
  fi

  if [[ -d $WALLPAPERS_DIR/.git ]]; then
    ok "$WALLPAPERS_DIR already cloned"
    return 0
  fi

  # A non-empty directory that is not a checkout is somebody's loose images, not
  # a failed clone. Refuse rather than clone over them.
  if [[ -d $WALLPAPERS_DIR ]]; then
    warn "$WALLPAPERS_DIR exists but is not a git checkout -- leaving it alone"
    todo "move it aside and re-run, or clone $WALLPAPERS_REMOTE by hand"
    return 0
  fi

  run mkdir -p "$(dirname "$WALLPAPERS_DIR")"
  run git clone "$WALLPAPERS_REMOTE" "$WALLPAPERS_DIR"
  did "cloned wallpapers repo"
}

# --------------------------------------------------------------------------- 40

# oh-my-zsh, and the third-party plugins the dotfiles' .zshrc asks for.
#
# Nothing installed it before 2026-09-30, so a rebuilt machine opened every
# terminal with
#     .zshrc:source:176: no such file or directory: ~/.oh-my-zsh/oh-my-zsh.sh
# and, with none of its lib loaded, no AUTO_CD: typing a directory name or `..`
# answered "permission denied" (zsh tried to EXECUTE the directory).
#
# Cloned, NOT installed with the upstream install.sh: that script replaces
# ~/.zshrc with its template, which would clobber the dotfiles' copy. Plugins are
# cloned only if .zshrc actually names them in its plugins=(...) line.
OMZ_REMOTE="https://github.com/ohmyzsh/ohmyzsh.git"
declare -A OMZ_EXTERNAL_PLUGINS=(
  [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions.git"
  [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
)

# Put mozc in fcitx5's input-method group. The group lives in
# $XDG_CONFIG_HOME/fcitx5/profile, which is NOT in the dotfiles: fcitx5 rewrites it
# at runtime. Without mozc in it, the trigger key (Super+`, in the dotfiles'
# fcitx5/config) has nothing to switch to and just types a grave. That is how both
# machines came out of the 2026-09-30 rebuilds. Adds mozc; never removes anything.
fcitx5_add_mozc() {
  pacman -Qq fcitx5-mozc >/dev/null 2>&1 || return 0
  local profile="$XDG_CONFIG_HOME/fcitx5/profile"
  if grep -qx 'Name=mozc' "$profile" 2>/dev/null; then
    ok "fcitx5: mozc is in the input-method group"
    return 0
  fi
  local fc=(busctl --user --json=short call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1)
  if "${fc[@]}" CurrentInputMethodGroup >/dev/null 2>&1; then
    # Running: change it through fcitx5, which saves the profile itself. A file
    # written underneath a running fcitx5 is overwritten from memory on exit.
    local group info layout items
    group="$("${fc[@]}" CurrentInputMethodGroup | jq -r '.data[0]')"
    info="$("${fc[@]}" InputMethodGroupInfo s "$group")"
    layout="$(jq -r '.data[0]' <<<"$info")"
    mapfile -t items < <(jq -r '.data[1][] | .[0], .[1]' <<<"$info")
    run busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 \
      SetInputMethodGroupInfo 'ssa(ss)' "$group" "$layout" $(( ${#items[@]} / 2 + 1 )) "${items[@]}" mozc ''
  elif [[ ! -e $profile ]]; then
    # Fresh machine, fcitx5 never started: seed the profile it will read.
    if (( ! DRY_RUN )); then
      mkdir -p "${profile%/*}"
      printf '%s\n' '[Groups/0]' 'Name=Default' 'Default Layout=us' 'DefaultIM=mozc' '' \
        '[Groups/0/Items/0]' 'Name=keyboard-us' 'Layout=' '' \
        '[Groups/0/Items/1]' 'Name=mozc' 'Layout=' '' \
        '[GroupOrder]' '0=Default' > "$profile"
    fi
  else
    warn "fcitx5: mozc is not in the input-method group, and fcitx5 is not running to add it"
    todo "re-run this stage from X:  $0 --only session"
    return 0
  fi
  did "fcitx5: mozc added to the input-method group (Super+\` toggles it)"
}

install_oh_my_zsh() {
  local zdir="${ZSH:-$HOME/.oh-my-zsh}"
  if [[ -f $zdir/oh-my-zsh.sh ]]; then
    ok "oh-my-zsh present at $zdir"
  elif [[ -e $zdir ]]; then
    warn "$zdir exists but has no oh-my-zsh.sh -- leaving it alone"
    todo "move it aside and re-run:  $0 --redo session"
    return 1
  else
    run git clone --depth 1 "$OMZ_REMOTE" "$zdir"
    did "cloned oh-my-zsh into $zdir"
  fi

  local zshrc="$HOME/.zshrc" plugins_line="" name
  [[ -f $zshrc ]] && plugins_line="$(grep -E '^[[:space:]]*plugins=\(' "$zshrc" || true)"
  for name in "${!OMZ_EXTERNAL_PLUGINS[@]}"; do
    [[ " ${plugins_line//[()=]/ } " == *" $name "* ]] || continue
    local pdir="${ZSH_CUSTOM:-$zdir/custom}/plugins/$name"
    if [[ -d $pdir ]]; then
      ok "oh-my-zsh plugin $name present"
    else
      run git clone --depth 1 "${OMZ_EXTERNAL_PLUGINS[$name]}" "$pdir"
      did "cloned oh-my-zsh plugin $name"
    fi
  done
}

# --------------------------------------------------------------------------- 75

# Joins the tailnet and wires ssh between this machine and the others in SSH_PEERS.
# Added 2026-10-03 after micro and media-center were each wired by hand: tailscale up,
# a Tailnet Lock signature carried to a signer, host keys, and authorized_keys lines
# carried around by magic-wormhole.
#
# Public keys come from the secrets repo, ssh/pubkeys/<host>.pub -- one per machine.
# GitHub's .keys endpoint cannot be used: it does not say which key is which host's.
#
# Every grant of access is a prompt (y/N), because the right answer is not always yes:
# a recovery box that must stay unreachable, or a peer whose key is suspect. A peer is
# authorized as from="<its tailnet IP>" -- the same restriction beast-arch already
# had on carbon's key -- so a stolen key alone does not get in from elsewhere. If a
# peer re-registers with a new IP, re-run this stage.
#
# The tailnet POLICY (hosts + grants, admin console) is not touched; a new machine
# must be added there by hand, or every port times out while `tailscale ping` works.
stage_tailnet() {
  stage_banner "75 tailnet -- join, sign, and ssh keys with the other machines (needs X to sign in)"

  if ! have tailscale; then
    info "tailscale not installed -- skipping"
    return 0
  fi
  if (( DRY_RUN )); then
    info "(dry run) would: tailscale up if needed, offer the Tailnet Lock sign command,"
    info "  publish this machine's key, and offer peer keys in both directions: $SSH_PEERS"
    return 0
  fi

  # 1. Join. `tailscale up` prints a login URL, i.e. it needs a browser: from a TTY,
  # defer to the run from X (as obsidian does). Already Running needs no login.
  systemctl is-active --quiet tailscaled || run sudo systemctl enable --now tailscaled
  local backend
  backend="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)"
  if [[ $backend != Running && -z ${DISPLAY:-} ]]; then
    info "not on the tailnet, and no X display to sign in from -- deferring"
    STAGE_DEFERRED=1
    return 0
  fi
  if [[ $backend != Running ]]; then
    info "tailscale is '${backend:-unknown}' -- logging in (open the URL it prints)"
    run_interactive sudo tailscale up || { warn "tailscale up failed"; return 1; }
  fi
  ok "on the tailnet as $(tailscale ip -4 2>/dev/null | head -n1)"

  # 2. Tailnet Lock: a new node is locked out until a trusted node signs it.
  local sign
  sign="$(tailscale lock status 2>/dev/null | grep -o 'tailscale lock sign nodekey:[0-9a-f]* tlpub:[0-9a-f]*' || true)"
  if [[ -n $sign ]]; then
    warn "locked out by Tailnet Lock until a trusted node signs this one"
    if have wormhole && confirm "send the sign command to a trusted node by magic-wormhole?"; then
      run_interactive wormhole send --text "$sign" || true
    else
      printf '\n    on a trusted node (beast-arch, carbon):\n      %s\n\n' "$sign"
    fi
    pause_for "Run that on a trusted node, then press Enter." || true
    tailscale lock status 2>/dev/null | grep -q 'LOCKED OUT' && {
      warn "still locked out -- re-run:  $0 --redo tailnet"; return 1; }
  fi

  # sshd: on a first install stage 60 ran before there was a tailnet address, so it
  # left sshd on every interface (and said so). Now there is one; rebind -- but only if
  # sshd is not already on it. harden_sshd's own check needs sudo to read its 0600
  # drop-in, so calling it unconditionally would ask for a password on every run.
  if [[ $SSHD_LISTEN_ADDRESS == tailscale ]] && systemctl is-active --quiet sshd; then
    local tip; tip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    if [[ -n $tip ]] && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qx "$tip:22"; then
      ok "sshd already listens on the tailnet only ($tip:22)"
    else
      harden_sshd
    fi
  fi

  [[ -n $SSH_PEERS ]] || { info "SSH_PEERS not set -- no peers to wire"; return 0; }
  ssh_tailnet_peers      # ~/.ssh/config stanzas, also written by stage 60

  # 3. Publish this machine's public key to the secrets repo, for the others to read.
  local self keydir mine
  self="$(uname -n)"; keydir="$SECRETS_DIR/ssh/pubkeys"
  if [[ -f $HOME/.ssh/id_ed25519.pub ]] && [[ -d $SECRETS_DIR ]]; then
    mine="$(awk -v h="$self" '{print $1, $2, "ben@" h}' "$HOME/.ssh/id_ed25519.pub")"
    if [[ "$(cat "$keydir/$self.pub" 2>/dev/null)" == "$mine" ]]; then
      ok "this machine's key is in secrets ($keydir/$self.pub)"
    else
      mkdir -p "$keydir" && printf '%s\n' "$mine" > "$keydir/$self.pub"
      did "wrote $keydir/$self.pub"
      todo "commit and push the secrets repo so the other machines can read it"
    fi
  fi

  # Inbound access is the tracked file secrets ssh/authorized_keys/<host>, installed as
  # ~/.ssh/authorized_keys by tools/authorized-keys (a checked copy). This stage edits
  # the tracked files and then applies; it never appends to the live file. A file
  # holding the line `# no-inbound` (micro) is never offered keys.
  local akdir="$SECRETS_DIR/ssh/authorized_keys" ak_changed=0
  local ak="$akdir/$self"
  if [[ -d $SECRETS_DIR && ! -f $ak ]]; then
    mkdir -p "$akdir"
    printf '%s\n' "# $self: who may ssh in. Installed by arch-bootstrap tools/authorized-keys." \
      '# Every line needs from="<peer tailnet IP>". Edit here, commit, then: tools/authorized-keys apply' > "$ak"
    [[ $AUTHORIZE_PEERS == no ]] && echo '# no-inbound' >> "$ak"
    did "created $ak"; ak_changed=1
  fi
  local peer fqdn ip pub body suffix
  suffix="$(tailscale status --json 2>/dev/null | jq -r '.MagicDNSSuffix // empty' 2>/dev/null || true)"
  for peer in $SSH_PEERS; do
    [[ $peer == "$self" ]] && continue
    fqdn="$peer.$suffix"

    # 4. Host key, pinned under the alias the stanza uses. ONE key type, ONE line: appending
    # raw ssh-keyscan output writes only the first line with a hostname (media-center, 2026-10-03).
    if ! ssh-keygen -F "$peer" >/dev/null 2>&1; then
      local hk
      hk="$(ssh-keyscan -T 8 -t ed25519 "$fqdn" 2>/dev/null | awk -v h="$peer" '!/^#/ {$1=h; print; exit}' || true)"
      if [[ -n $hk ]]; then
        printf '%s\n' "$hk" >> "$HOME/.ssh/known_hosts"
        did "$peer: host key pinned ($(printf '%s\n' "$hk" | ssh-keygen -lf - | awk '{print $2}'))"
      else
        warn "$peer: no host key over the tailnet (offline, or the policy does not allow tcp:22?)"
      fi
    fi

    # 5. Inbound: may $peer ssh in here?
    pub="$keydir/$peer.pub"
    if [[ $AUTHORIZE_PEERS == no ]]; then
      info "$peer: not offered ssh access here (AUTHORIZE_PEERS=no)"
    elif [[ ! -f $pub ]]; then
      info "$peer: no key in secrets ($pub) -- cannot authorize it"
    elif [[ ! -f $ak ]] || grep -qx '# no-inbound' "$ak"; then
      info "$peer: not offered ssh access here (no tracked file, or # no-inbound)"
    else
      body="$(awk '{print $2}' "$pub")"
      if grep -qF "$body" "$ak" 2>/dev/null; then
        ok "$peer may ssh in here (tracked in $ak)"
      else
        ip="$(tailscale ip -4 "$peer" 2>/dev/null | head -n1 || true)"
        if [[ -n $ip ]] && confirm "let $peer ssh into this machine (from=\"$ip\" only)?"; then
          printf 'from="%s" %s\n' "$ip" "$(cat "$pub")" >> "$ak"
          did "$peer added to $ak (from=$ip)"; ak_changed=1
        elif [[ -z $ip ]]; then
          warn "$peer: no tailnet IP -- not authorized"
        fi
      fi
    fi

    # 6. Outbound: can this machine ssh to $peer? If not, offer to add this machine to
    # $peer's tracked file. It takes effect when $peer pulls secrets and applies.
    local pak="$akdir/$peer"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$peer" true 2>/dev/null; then
      ok "ssh to $peer works"
    elif [[ -z ${mine:-} || ! -f $pak ]] || grep -qx '# no-inbound' "$pak"; then
      info "ssh to $peer does not work; left alone (no tracked file for it, or # no-inbound)"
    elif grep -qF "$(awk '{print $2}' <<<"$mine")" "$pak"; then
      info "ssh to $peer does not work yet, but $pak already lists this machine:"
      info "  on $peer:  git -C ~/secrets pull && ~/projects/arch-bootstrap/tools/authorized-keys apply"
    elif confirm "add this machine to $peer's authorized_keys (tracked in secrets)?"; then
      printf 'from="%s" %s\n' "$(tailscale ip -4 | head -n1)" "$mine" >> "$pak"
      did "this machine added to $pak"; ak_changed=1
      todo "on $peer, after the secrets push:  git -C ~/secrets pull && ~/projects/arch-bootstrap/tools/authorized-keys apply"
    fi
  done

  # 7. Install this machine's tracked file as ~/.ssh/authorized_keys (checks it, backs
  # up the live file, asks before dropping a live key), then the 15-minute user timer
  # that keeps it in step with secrets from here on. Already enabled: just apply.
  if [[ -f $ak ]]; then
    if systemctl --user is-enabled --quiet authorized-keys.timer 2>/dev/null; then
      "$SCRIPT_DIR/tools/authorized-keys" apply || warn "authorized_keys not installed -- see above"
    else
      "$SCRIPT_DIR/tools/authorized-keys" enable || warn "authorized_keys not installed, no timer -- see above"
    fi
  fi
  (( ak_changed )) && todo "commit and push the secrets repo (ssh/authorized_keys changed)"
  return 0
}

stage_session() {
  stage_banner "40 session -- things a fresh Arch install leaves undone"

  # Login shell. archinstall leaves this as /bin/bash regardless of what you
  # installed, and the dotfiles' PATH/XDG setup usually lives in the zsh rc.
  if [[ $SHELL == */$LOGIN_SHELL ]]; then
    ok "login shell is already $LOGIN_SHELL"
  elif have "$LOGIN_SHELL"; then
    local shpath; shpath="$(command -v "$LOGIN_SHELL")"
    if confirm "change login shell to $shpath? (needs your password)"; then
      run_interactive chsh -s "$shpath" || warn "chsh failed"
      did "login shell set -- takes effect at next login"
    else
      todo "later:  chsh -s $shpath"
    fi
  else
    warn "$LOGIN_SHELL not installed"
  fi

  install_oh_my_zsh
  fcitx5_add_mozc

  # NetworkManager. Not hardware -- the general network stack, and easy to
  # forget because the live ISO's networking is not what the installed system uses.
  if systemctl is-enabled NetworkManager >/dev/null 2>&1; then
    ok "NetworkManager enabled"
  elif have nmcli; then
    if confirm "enable NetworkManager at boot?"; then
      run sudo systemctl enable --now NetworkManager
      did "NetworkManager enabled"
    fi
  fi

  # Font cache. Newly installed fonts are invisible to running apps until this
  # runs, which looks exactly like the font failing to install.
  #
  # Note the missing -f. `-f` forces a full rebuild of every directory whether or
  # not anything changed, so this stage always reported that it had done work.
  # Plain fc-cache re-reads only the directories whose cache is stale, and says
  # which it did, so the report can be honest.
  if have fc-cache; then
    if (( DRY_RUN )); then
      printf '%s  would run:%s fc-cache\n' "$C_DIM" "$C_RESET"
    else
      local fcout
      fcout="$(fc-cache -v 2>&1 || true)"
      if grep -q 'caching, new cache contents' <<<"$fcout"; then
        did "font cache rebuilt ($(grep -c 'caching, new cache contents' <<<"$fcout") dir(s))"
      else
        ok "font cache already up to date"
      fi
    fi
  fi

  # ~/.ssh/config and the agent socket. Neither is restored by anything else:
  # ~/.ssh is deliberately untracked in the dotfiles repo, so on a rebuilt machine
  # these simply do not exist and their absence is silent -- ssh keeps working,
  # it just re-prompts for the passphrase on every single operation.
  if [[ -f $HOME/.ssh/config ]]; then
    if grep -qi '^[[:space:]]*AddKeysToAgent' "$HOME/.ssh/config"; then
      ok "~/.ssh/config present with an AddKeysToAgent setting"
    else
      ok "~/.ssh/config present"
      todo "no AddKeysToAgent line -- consider adding one (see bootstrap.conf)"
    fi
  elif (( DRY_RUN )); then
    printf '%s  would write:%s ~/.ssh/config (AddKeysToAgent %s)\n' \
      "$C_DIM" "$C_RESET" "$SSH_ADD_KEYS_TO_AGENT"
  else
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    cat > "$HOME/.ssh/config" <<EOF
# Written by arch-bootstrap. ~/.ssh is deliberately NOT tracked in the dotfiles
# repo, so this is recreated on a new machine rather than restored.

Host *
    # How long the agent holds a decrypted key. Shorter means more passphrase
    # prompts and a smaller window in which an unattended unlocked session is
    # also an unlocked key. Set SSH_ADD_KEYS_TO_AGENT in bootstrap.conf.
    AddKeysToAgent $SSH_ADD_KEYS_TO_AGENT

# No IdentityFile line on purpose: naming one REPLACES the default search list,
# so a key added later would be silently ignored.
EOF
    chmod 600 "$HOME/.ssh/config"
    did "wrote ~/.ssh/config (AddKeysToAgent $SSH_ADD_KEYS_TO_AGENT)"
  fi

  if systemctl --user is-enabled ssh-agent.socket >/dev/null 2>&1; then
    ok "ssh-agent.socket enabled"
  elif [[ -f /usr/lib/systemd/user/ssh-agent.socket ]]; then
    run systemctl --user enable --now ssh-agent.socket
    did "ssh-agent.socket enabled"
  else
    info "no ssh-agent.socket user unit shipped -- the agent starts some other way here"
  fi

  # Cap the AGENT's key lifetime, not just the clients that add keys.
  #
  # `AddKeysToAgent` above only governs keys that ssh loads from disk while
  # opening a connection. A bare `ssh-add` bypasses it completely and pins the key
  # with NO expiry until the agent process dies -- which, for a systemd user
  # agent, means the whole login session. On beast-arch that kept a key unlocked
  # for three days while the config correctly read 120 seconds, and it was
  # invisible because "the agent already holds the key" is a silent success.
  #
  # `ssh-agent -t` makes it structural: nothing outlives the cap however it was
  # added. Only meaningful when a lifetime was actually chosen -- the default
  # `yes` means "keep for the session", so there is nothing to cap.
  if [[ $SSH_ADD_KEYS_TO_AGENT =~ ^(yes|no|ask|confirm)$ ]]; then
    info "SSH_ADD_KEYS_TO_AGENT=$SSH_ADD_KEYS_TO_AGENT -- no interval to cap the agent at"
  elif [[ ! -f /usr/lib/systemd/user/ssh-agent.service ]]; then
    info "no ssh-agent user service to add a lifetime cap to"
  else
    local agent_dir="$HOME/.config/systemd/user/ssh-agent.service.d"
    local agent_conf="$agent_dir/lifetime.conf"
    local staged_agent; staged_agent="$(mktemp)"
    cat > "$staged_agent" <<EOF
# GENERATED by bootstrap.sh (stage 40). Do not hand-edit; re-run --redo session.
#
# A maximum lifetime on the agent itself. AddKeysToAgent in ~/.ssh/config governs
# only keys that ssh loads while connecting; a bare \`ssh-add\` bypasses it and
# pins the key for the life of the agent. This caps every path.
[Service]
ExecStart=
ExecStart=/usr/bin/ssh-agent -D -t $SSH_ADD_KEYS_TO_AGENT
EOF
    if [[ -f $agent_conf ]] && cmp -s "$staged_agent" "$agent_conf"; then
      rm -f "$staged_agent"
      ok "ssh-agent lifetime cap already set to $SSH_ADD_KEYS_TO_AGENT"
    elif (( DRY_RUN )); then
      printf '%s  would write:%s %s (ssh-agent -t %s)\n' \
        "$C_DIM" "$C_RESET" "$agent_conf" "$SSH_ADD_KEYS_TO_AGENT"
      rm -f "$staged_agent"
      did "ssh-agent lifetime cap written"
    else
      mkdir -p "$agent_dir"
      mv "$staged_agent" "$agent_conf"
      chmod 644 "$agent_conf"
      systemctl --user daemon-reload
      did "ssh-agent capped at $SSH_ADD_KEYS_TO_AGENT ($agent_conf)"
      todo "takes effect when the agent restarts: systemctl --user restart ssh-agent.service"
    fi
  fi

  # X session entry point.
  if [[ -f $HOME/.xinitrc ]]; then
    ok ".xinitrc present ($(grep -cE '^[^#]' "$HOME/.xinitrc" 2>/dev/null || echo 0) active lines)"
  else
    warn "no ~/.xinitrc -- startx will not launch your WM"
    todo "expected it to arrive with the dotfiles; check the tree"
  fi

  # Vimium settings from the dotfiles' backup, written straight into each Chromium-family
  # profile's extension storage (tools/vimium-restore says how). Replaces a manual
  # Options -> Restore in every browser on every machine. It only needs the browser
  # CLOSED, which a first run from a TTY guarantees. From X with a browser open, it
  # says so and leaves a todo rather than failing the stage.
  local vbackup="${XDG_CONFIG_HOME:-$HOME/.configure}/vimium-backup/vimium-options.json"
  if [[ ! -f $vbackup ]]; then
    info "no Vimium backup at $vbackup -- skipping restore"
  elif (( DRY_RUN )); then
    python3 "$SCRIPT_DIR/tools/vimium-restore" --backup "$vbackup" --dry-run || true
  else
    local vrc=0
    python3 "$SCRIPT_DIR/tools/vimium-restore" --backup "$vbackup" || vrc=$?
    case $vrc in
      0) did "Vimium settings restored from $vbackup" ;;
      3) warn "a browser is open, so Vimium settings were not restored"
         todo "close it, then:  $SCRIPT_DIR/tools/vimium-restore" ;;
      *) warn "vimium-restore failed (exit $vrc)" ;;
    esac
  fi

  # Deliberately NOT enabling lingering here. systemd starts a user manager at login
  # and pulls in default.target, so `WantedBy=default.target` units come up by
  # themselves every session. Linger governs one thing only -- whether user units keep
  # running while you are logged OUT -- and on a single-user desktop that window is
  # usually worth nothing. It stays opt-in; see the note in the services stage.
}

# --------------------------------------------------------------------------- 50

stage_xmonad() {
  stage_banner "50 xmonad"

  if [[ ! -d $XMONAD_DIR ]]; then
    info "$XMONAD_DIR not present -- skipping (not an xmonad setup, or dotfiles not checked out)"
    return 0
  fi
  have stack || die "stack missing -- run the toolchains stage first"

  warn "this stage is SLOW. The resolver pins a specific GHC, which stack downloads"
  warn "and builds against from scratch -- budget 20-40 minutes on a cold cache."

  [[ -f $XMONAD_DIR/stack.yaml.lock ]] \
    && ok "stack.yaml.lock present (build is reproducible)" \
    || warn "no stack.yaml.lock -- the build may resolve different package versions"

  # A cold `stack build` is 20-40 minutes, which is enough on its own to stop
  # anyone re-running this script routinely. It is incremental, so a warm re-run
  # is cheap -- but skip it outright when nothing that feeds the build is newer
  # than the binary it produced. -newer is the right test here: the question is
  # "has a source file changed since the last build", not "what did stack decide".
  local built="$XMONAD_DIR/xmonad-$(uname -m)-linux"
  if [[ -x $built ]] && \
     [[ -z "$(find "$XMONAD_DIR" -maxdepth 1 \
                -name '*.hs' -newer "$built" -o \
                -name '*.yaml' -newer "$built" -o \
                -name '*.cabal' -newer "$built" 2>/dev/null)" ]]; then
    # Both the build AND the recompile sit behind this guard, deliberately.
    #
    # `xmonad --recompile` looks like it does its own mtime check, and it does --
    # until a `build` script is present in XMONAD_DIR, at which point xmonad hands
    # the decision to that script and ALWAYS forces ("XMonad recompiling
    # (forced)"). So on a box with a custom build script this stage rewrote the
    # binary on every single run. Cheap, but not nothing, and not idempotent.
    #
    # There is nothing to validate when no input has changed. Force it with
    # `--redo xmonad`, or touch the config.
    ok "xmonad binary is newer than its sources -- nothing to build or recompile"
    return 0
  fi

  # The freshness check above runs under --dry-run too, deliberately. It only
  # stats files, and it answers the one question worth knowing before you commit
  # to this stage: whether you are in for 40 minutes or for nothing. The dry run
  # used to return before reaching it and always printed "would run: stack build",
  # which is exactly the case where a prediction has to be right.
  if (( DRY_RUN )); then
    printf '%s  would run:%s stack build && xmonad --recompile in %s\n' \
      "$C_DIM" "$C_RESET" "$XMONAD_DIR"
    warn "sources are newer than the binary -- this WILL rebuild. Budget the time."
    did "xmonad rebuilt"
    return 0
  fi

  ( cd "$XMONAD_DIR" && stack build )
  did "xmonad config project compiled"

  if have xmonad; then
    if ( cd "$XMONAD_DIR" && xmonad --recompile ); then
      did "xmonad --recompile clean"
    else
      warn "recompile failed -- see $XMONAD_DIR/xmonad.errors"
      return 1
    fi
  else
    warn "xmonad binary not on PATH yet; recompile after the next login"
  fi
}

# --------------------------------------------------------------------------- 55

stage_obsidian() {
  stage_banner "70 obsidian -- interactive sync setup (needs X)"

  if [[ -z $OBSIDIAN_VAULT ]]; then
    info "OBSIDIAN_VAULT not set -- skipping"
    return 0
  fi

  if [[ -z ${DISPLAY:-} ]] && ! (( DRY_RUN )); then
    info "no X display -- deferring: this stage wants KeePassXC and a second window"
    STAGE_DEFERRED=1
    return 0
  fi

  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  local node_root=""
  if [[ -d $NVM_DIR/versions/node ]]; then
    node_root="$(find "$NVM_DIR/versions/node" -maxdepth 1 -type d \
                   -name "v${NODE_MAJOR}.*" | sort -V | tail -1)"
  fi
  [[ -z $node_root ]] && { warn "no nvm node v${NODE_MAJOR}.x -- run the toolchains stage"; return 0; }

  local ob="$node_root/bin/ob"
  if [[ ! -x $ob ]]; then
    warn "obsidian-headless not installed at $ob"
    todo "npm install -g obsidian-headless   (with node v$NODE_MAJOR active)"
    return 0
  fi
  export PATH="$node_root/bin:$PATH"

  if [[ ! -d $OBSIDIAN_VAULT ]]; then
    warn "vault path $OBSIDIAN_VAULT does not exist yet"
    confirm "create it?" && run mkdir -p "$OBSIDIAN_VAULT"
  fi

  printf '\n%s  BACK UP YOUR VAULT BEFORE THE FIRST SYNC.%s The official docs lead with\n' \
    "$C_BOLD$C_RED" "$C_RESET"
  printf '      this warning, and a first sync against the wrong remote is destructive.\n'

  # 1. login -- writes an auth token under $XDG_CONFIG_HOME/obsidian-headless
  if [[ -f $XDG_CONFIG_HOME/obsidian-headless/auth_token ]]; then
    ok "already logged in (auth token present)"
  else
    pause_for "Log in to your Obsidian account." \
      "About to run:  ob login" \
      "This is interactive and one-time. The token persists on disk at" \
      "$XDG_CONFIG_HOME/obsidian-headless/ -- it is a SECRET and must not be" \
      "committed to your dotfiles." && run_interactive "$ob" login || \
        warn "login skipped or failed"
  fi

  # 2. bind the local path to a remote vault
  if (( DRY_RUN )); then
    info "(dry run -- would run ob sync-list-remote / sync-setup / sync-status)"
    obsidian_sync_unit      # dry-run safe: reports whether the unit would change
    return 0
  fi

  if "$ob" sync-list-local 2>/dev/null | grep -qF "$OBSIDIAN_VAULT"; then
    ok "vault already configured for sync"
  else
    obsidian_sync_setup "$ob" \
      || warn "vault NOT bound -- the daemon has nothing to sync on this machine"
  fi

  run_interactive "$ob" sync-status --path "$OBSIDIAN_VAULT" || \
    warn "sync-status reported a problem -- the daemon may not start cleanly"

  # This used to be an unconditional manual prompt, which meant every re-run
  # blocked on a question the file on disk already answers. Now it reads the file,
  # and offers to fix it rather than only warning about it.
  local core_plugins="$OBSIDIAN_VAULT/.obsidian/core-plugins.json"
  if [[ ! -f $core_plugins ]]; then
    info "no core-plugins.json yet -- the desktop app has not opened this vault"
  elif grep -q '"sync"[[:space:]]*:[[:space:]]*true' "$core_plugins"; then
    obsidian_disable_desktop_sync "$core_plugins"
  else
    ok "desktop app's Sync plugin is disabled for this vault"
  fi

  obsidian_sync_unit
}

# Bind the local vault path to a remote vault.
#
# `ob sync-setup` REQUIRES --vault and does NOT prompt for it. The previous code
# ran `sync-setup --path <p>` and told the operator "it will ask which remote
# vault to connect to", which is not what the command does:
#
#     error: required option '--vault <vault>' not specified
#
# Found on carbon 2026-08-07. The consequences were quiet and bad: the bind
# failed, `sync-status` reported "No sync configuration found", the daemon had
# nothing to sync, and because `sync-list-local` never listed the vault the stage
# stopped for a manual step on EVERY subsequent run. The stage reported a warning
# and carried on, so the run still ended looking broadly successful.
#
# Resolve the vault id from sync-list-remote and pass it explicitly.
obsidian_sync_setup() {
  local ob="$1"
  local -a ids=() names=()
  local id name

  info "remote vaults available to bind to:"
  while IFS=$'\t' read -r id name; do
    [[ -n $id ]] && { ids+=("$id"); names+=("$name"); }
  done < <("$ob" sync-list-remote 2>/dev/null |
           sed -nE 's/^[[:space:]]+([0-9a-fA-F]{16,})[[:space:]]+"([^"]*)".*/\1\t\2/p')

  if (( ${#ids[@]} == 0 )); then
    warn "no remote vaults found to bind to"
    todo "create one first:  ob sync-create-remote"
    return 1
  fi

  local vault="" vname=""
  if (( ${#ids[@]} == 1 )); then
    vault="${ids[0]}"; vname="${names[0]}"
    info "one remote vault: \"$vname\" ($vault)"
  else
    printf '\n%s  remote vaults:%s\n' "$C_BOLD" "$C_RESET"
    local i
    for i in "${!ids[@]}"; do
      printf '        %d) %-34s "%s"\n' "$((i+1))" "${ids[i]}" "${names[i]}"
    done
    have_tty || { warn "several remote vaults and no terminal to choose on"; return 1; }
    local choice=""
    read -r -p "$(printf '%s  ?   %s bind to which vault? [1-%d] ' \
      "$C_YEL" "$C_RESET" "${#ids[@]}")" choice </dev/tty || true
    if ! [[ $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ids[@]} )); then
      warn "no valid choice made -- not binding"
      return 1
    fi
    vault="${ids[$((choice-1))]}"; vname="${names[$((choice-1))]}"
  fi

  pause_for "Bind $OBSIDIAN_VAULT to remote vault \"$vname\"." \
    "About to run:" \
    "  ob sync-setup --vault $vault --path $OBSIDIAN_VAULT --device-name $HOSTNAME_SHORT" \
    "" \
    "You will be asked for the END-TO-END ENCRYPTION PASSWORD. That is NOT your" \
    "Obsidian account password. It must match what the vault was created with," \
    "and it is not recoverable -- getting it wrong means the sync cannot decrypt." \
    || return 1

  run_interactive "$ob" sync-setup \
      --vault "$vault" \
      --path "$OBSIDIAN_VAULT" \
      --device-name "$HOSTNAME_SHORT" \
    || { warn "sync-setup failed"; return 1; }

  # Confirm the bind landed rather than trusting an exit status. This is the
  # check whose absence let the original bug pass as a mere warning.
  if "$ob" sync-list-local 2>/dev/null | grep -qF "$OBSIDIAN_VAULT"; then
    did "vault bound to \"$vname\" ($vault)"
    return 0
  fi
  warn "sync-setup reported success but the vault is still not listed locally"
  return 1
}

# Two sync clients on one device is explicitly unsupported by Obsidian, and the
# headless daemon this script installs is meant to be the only one. So when the
# desktop app's Sync plugin is enabled, offer to turn it off rather than printing
# a warning the operator has to remember to act on.
#
# This is a PER-MACHINE setting. `ob sync-status` reports "Configs: none (config
# syncing disabled)", so `.obsidian/` does not travel between machines -- setting
# it on one box does nothing for the next one. That is exactly why it belongs in
# the bootstrap instead of in a checklist.
obsidian_disable_desktop_sync() {
  local f="$1"

  warn "the desktop app's Sync plugin is ENABLED for this vault:"
  warn "  $f"
  warn "combined with the headless daemon that is two sync clients on one device."

  # Do not edit a file the desktop app has open: it holds this config in memory
  # and rewrites it on exit, so the edit would look like it worked and then be
  # silently reverted. Match on the process, and exclude the headless daemon --
  # its own command line contains "obsidian-headless".
  local desktop
  desktop="$(pgrep -af -i obsidian 2>/dev/null | grep -vi 'obsidian-headless\|cli\.js' || true)"
  if [[ -n $desktop ]]; then
    warn "the desktop app appears to be running:"
    printf '%s\n' "$desktop" | sed 's/^/        /'
    warn "it would overwrite this change when it exits, so not touching it."
    todo "quit the desktop app, then: $0 --redo obsidian"
    return 0
  fi

  if (( DRY_RUN )); then
    printf '%s  would set:%s "sync": false in %s\n' "$C_DIM" "$C_RESET" "$f"
    did "desktop Sync plugin disabled"
    return 0
  fi

  confirm "set \"sync\": false so the headless daemon is the only sync client?" || {
    warn "left enabled -- do NOT open this vault in the desktop app while it is"
    warn "logged into Sync, or you will have two clients writing to one remote"
    return 0
  }

  cp -a "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
  if have jq; then
    jq '.sync = false' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    # core-plugins.json is a flat "plugin-id": bool object in current Obsidian, so
    # a targeted substitution is safe. jq is preferred and is in the package list;
    # this only matters if stage 10 has not run yet.
    sed -i 's/\("sync"[[:space:]]*:[[:space:]]*\)true/\1false/' "$f"
  fi

  # Confirm the edit landed instead of assuming it did.
  if grep -q '"sync"[[:space:]]*:[[:space:]]*false' "$f"; then
    did "desktop Sync plugin disabled in $f"
  else
    warn "tried to disable it but the file still does not say false -- fix by hand"
    return 1
  fi
}

# --------------------------------------------------------------------------- 60

# System-level daemons whose PACKAGE is in the shared lists but whose UNIT nothing
# here ever enabled. Added 2026-08-24 after the weekly catalogue found four of
# them installed by hand on beast-arch and enabled by hand afterwards -- which is
# the same "the command works, the feature does not" gap this script keeps hitting:
# a package list alone reproduces the binary and not the behaviour.
#
# NetworkManager is deliberately NOT here. Stage 45 already enables it, because
# the session stage needs the network up before it, not after.
#
# Format: <package>|<unit>|<what it is for>
SYSTEM_UNITS=(
  "bluez|bluetooth.service|bluetooth radio -- matters most on a laptop"
  "docker|docker.service|container runtime"
  "earlyoom|earlyoom.service|kills a memory hog before the box livelocks"
  "tailscale|tailscaled.service|mesh VPN; joining a tailnet is a separate manual step"
  "openssh|sshd.service|remote shell; harden_sshd() writes the config it needs"
  "pacman-contrib|paccache.timer|weekly: keeps 3 versions per package in /var/cache/pacman, which is on the root filesystem"
  "jellyfin-server|jellyfin.service|media server (profile media-center); web UI on port 8096"
)

# Profile `lean`: old, slow hardware (first: micro, an i3-3227U with 3.5 GiB and a
# spinning disk, 2026-10-03). Units the shared lists enable that a lean host does
# without. enable_system_units skips them; apply_lean_profile turns them OFF where an
# earlier run or the installer already enabled them. docker was the only thing pulling
# in network-online.target, so it and wait-online together were ~15 s of micro's boot.
LEAN_UNITS_OFF=(docker.service docker.socket containerd.service bluetooth.service
                NetworkManager-wait-online.service)

profile_on() { [[ " $PROFILES " == *" $1 "* ]]; }

# A machine nothing may ssh into (micro, a recovery box): AUTHORIZE_PEERS=no, or
# `# no-inbound` in its tracked secrets ssh/authorized_keys/<host>. Its sshd is not
# enabled at all -- an empty authorized_keys behind the tailnet policy still leaves
# a listening daemon, and its attack surface, for nothing.
no_inbound() {
  [[ $AUTHORIZE_PEERS == no ]] \
    || grep -qx '# no-inbound' "$SECRETS_DIR/ssh/authorized_keys/$(uname -n)" 2>/dev/null
}

# Write sshd's configuration, and the boot ordering it needs if it binds a VPN
# address. Called from stage 60 AFTER enable_system_units, so the unit exists.
#
# WHY A DROP-IN AND NOT /etc/ssh/sshd_config
# `Include /etc/ssh/sshd_config.d/*.conf` is line 2 of the shipped Arch config, and
# sshd uses the FIRST value it obtains for each keyword -- so a drop-in wins over
# anything later in the main file, and editing the main file by hand produces a
# config where the effective value is not the one you edited. It also survives
# `pacman -Syu` writing an sshd_config.pacnew.
harden_sshd() {
  pacman -Qq openssh >/dev/null 2>&1 || return 0
  [[ -z ${PKG_EXCLUDED[openssh]:-} ]] || return 0

  local dropin=/etc/ssh/sshd_config.d/10-hardening.conf
  local want="# Written by arch-bootstrap. Edit bootstrap.conf, not this file.
PasswordAuthentication no
PermitRootLogin no"
  [[ -n $SSHD_ALLOW_USERS ]] && want+="
AllowUsers $SSHD_ALLOW_USERS"

  local listen=$SSHD_LISTEN_ADDRESS
  if [[ $listen == tailscale ]]; then
    listen="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    if [[ -n $listen ]]; then
      info "SSHD_LISTEN_ADDRESS=tailscale -> $listen"
    else
      warn "SSHD_LISTEN_ADDRESS=tailscale, but tailscale has no address (not logged in yet?)"
      warn "  leaving sshd on every interface -- run 'tailscale up', then: $0 --redo services"
    fi
  fi

  # A ListenAddress the machine does not have is the one setting here that can
  # lock you out, so it is checked against reality before being written rather
  # than trusted from config. Warn and write anyway -- a tailnet address is
  # legitimately absent when tailscaled has not started yet -- but say so, because
  # a typo and a not-yet-up interface look identical at this point.
  if [[ -n $listen ]]; then
    if ! ip -o addr show 2>/dev/null | grep -qw "$listen"; then
      warn "ListenAddress $listen is not currently assigned to any interface"
      warn "  if that is a typo, sshd will fail to bind and this box becomes unreachable"
    fi
    want+="
ListenAddress $listen"
  fi

  # The drop-in is installed 0600 root, so a plain `cat` as the user always fails
  # and the comparison always said "differs": every run rewrote it and asked for
  # sudo, and a dry run counted a change that was not there. Read it through
  # cached sudo credentials when there are some; otherwise say it could not be
  # compared rather than claim it is different.
  local have="" readable=1
  if [[ -r $dropin ]]; then
    have="$(cat "$dropin")"
  elif [[ -f $dropin ]]; then
    have="$(sudo -n cat "$dropin" 2>/dev/null)" || readable=0
  fi

  if [[ -f $dropin ]] && (( readable )) && [[ $have == "$want" ]]; then
    ok "sshd hardening already in place ($dropin)"
  elif [[ -f $dropin ]] && (( ! readable && DRY_RUN )); then
    info "$dropin exists but is root-only -- cannot compare without sudo (sudo -v first to check)"
  elif (( DRY_RUN )); then
    info "(dry run) would write $dropin"
    did "wrote $dropin"          # counts only; did() prints nothing under DRY_RUN
  else
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$want" > "$tmp"
    # Install, THEN validate, then reload -- in that order, and it is safe.
    # `sshd -t` tests the whole effective config including drop-ins, so the
    # candidate has to be on disk to be testable. A running sshd keeps serving the
    # config it already loaded, so a bad file that is removed before any reload
    # never reaches the daemon. What must not happen is reloading first and
    # discovering the problem afterwards.
    run sudo install -m 600 "$tmp" "$dropin"
    rm -f "$tmp"
    if sudo sshd -t 2>/dev/null; then
      did "wrote $dropin"
      systemctl is-active --quiet sshd && run sudo systemctl reload sshd
    else
      warn "sshd -t REJECTED the new config -- removing it and leaving sshd as it was"
      run sudo rm -f "$dropin"
    fi
  fi

  # The boot-order dependency. Only meaningful when sshd binds an address that
  # another service brings up; without it sshd starts first, fails to bind, and
  # the box is unreachable in exactly the situation remote access is for.
  # RestartSec is here because the shipped unit already sets Restart=always --
  # what it lacks is a sane retry interval, not the restart itself.
  local unitdir=/etc/systemd/system/sshd.service.d
  local unitfile="$unitdir/10-tailnet.conf"
  if [[ -z $listen ]]; then
    return 0
  fi
  local wantunit="[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
RestartSec=5s"
  if [[ -f $unitfile ]] && [[ "$(cat "$unitfile")" == "$wantunit" ]]; then
    ok "sshd boot ordering already in place ($unitfile)"
  elif (( DRY_RUN )); then
    info "(dry run) would write $unitfile"
    did "wrote $unitfile"        # counts only; did() prints nothing under DRY_RUN
  else
    local tmp2; tmp2="$(mktemp)"
    printf '%s\n' "$wantunit" > "$tmp2"
    run sudo mkdir -p "$unitdir"
    run sudo install -m 644 "$tmp2" "$unitfile"
    rm -f "$tmp2"
    run sudo systemctl daemon-reload
    did "wrote $unitfile (sshd ordered after tailscaled)"
  fi
}

# Chores: regular jobs as systemd user timers (chores/, beast-arch task 69). chore-run
# and chores go on PATH; every chore shares the chore@.service template, and only the
# timers named in CHORES are enabled. `systemctl --user link` rather than copying, so a
# `git pull` here updates the schedule, and it puts the link wherever THIS user manager
# looks -- not $XDG_CONFIG_HOME, which the manager does not have (the task 58 path trap).
install_chores() {
  local d="$SCRIPT_DIR/chores" c unit
  [[ -d $d ]] || return 0
  for c in chore-run chores; do
    if [[ "$(readlink -f "$HOME/.local/bin/$c" 2>/dev/null)" == "$d/$c" ]]; then
      ok "$c on PATH"
    else
      run mkdir -p "$HOME/.local/bin"
      run ln -sfn "$d/$c" "$HOME/.local/bin/$c"
      did "linked $c into ~/.local/bin"
    fi
  done
  [[ -n $CHORES ]] || { info "no CHORES enabled for this machine"; return 0; }
  # `link` is idempotent: re-linking the same file is a no-op, so no check first.
  for unit in "$d/chore@.service" "$d"/*/chore-*.timer; do
    run systemctl --user --quiet link "$unit"
  done
  for c in $CHORES; do
    [[ -f $d/$c/chore-$c.timer ]] || { warn "CHORES names '$c', but there is no chores/$c/chore-$c.timer"; continue; }
    if systemctl --user is-enabled --quiet "chore-$c.timer" 2>/dev/null; then
      ok "chore $c scheduled"
    else
      run systemctl --user enable --now "chore-$c.timer"
      did "scheduled chore $c ($(sed -n 's/^OnCalendar=//p' "$d/$c/chore-$c.timer"))"
    fi
  done
}

# ~/.ssh/config stanzas for SSH_PEERS, kept between markers so a re-run replaces
# them rather than stacking copies.
#
# The FQDN (carbon.<tailnet>.ts.net), not the bare name and not an IP. An IP goes
# stale when a node re-registers -- beast-arch's did in the 2026-09-30 rebuild.
# The bare name is worse, because it fails only SOMETIMES: systemd-resolved also
# answers it over the LAN (LLMNR, fe80::/fd41:: addresses), picks between the
# answers per attempt, and over the LAN carbon's sshd refused the key (denied or
# connection reset, on most attempts that hour). Measured 2026-10-01: the FQDN
# connected 10 of 10, five each way between beast-arch and carbon.
# HostKeyAlias keeps known_hosts keyed by the short name.
ssh_tailnet_peers() {
  [[ -n $SSH_PEERS ]] || return 0
  local suffix
  suffix="$(tailscale status --json 2>/dev/null | jq -r '.MagicDNSSuffix // empty' 2>/dev/null || true)"
  if [[ -z $suffix ]]; then
    warn "SSH_PEERS is set, but tailscale reports no MagicDNS suffix (not on the tailnet yet?)"
    todo "after 'tailscale up', with MagicDNS on: $0 --redo services"
    return 0
  fi

  local begin="# >>> arch-bootstrap: tailnet peers (stage 60 -- edit SSH_PEERS, not this block)"
  local end="# <<< arch-bootstrap: tailnet peers"
  local want="$begin" peer self; self="$(uname -n)"
  for peer in $SSH_PEERS; do
    [[ $peer == "$self" ]] && continue
    want+=$'\n'"Host $peer"$'\n'"    HostName $peer.$suffix"$'\n'"    HostKeyAlias $peer"
  done
  want+=$'\n'"$end"

  local sshcfg="$HOME/.ssh/config" current=""
  [[ -f $sshcfg ]] && current="$(sed -n "\|^$begin\$|,\|^$end\$|p" "$sshcfg")"
  if [[ $current == "$want" ]]; then
    ok "ssh peer stanzas up to date ($SSH_PEERS)"
    return 0
  elif (( DRY_RUN )); then
    info "(dry run) would write ssh stanzas for: $SSH_PEERS (via .$suffix)"
    did "wrote ssh peer stanzas"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  if [[ -f $sshcfg ]]; then
    sed "\|^$begin\$|,\|^$end\$|d" "$sshcfg" > "$tmp"
  fi
  printf '\n%s\n' "$want" >> "$tmp"
  run install -m 600 "$tmp" "$sshcfg"
  rm -f "$tmp"
  did "wrote ssh stanzas for tailnet peers: $SSH_PEERS"
  # ssh takes the FIRST value per keyword: a hand-written stanza for the same
  # host earlier in the file still wins over this block.
  for peer in $SSH_PEERS; do
    [[ $peer == "$self" ]] && continue
    if [[ "$(ssh -G "$peer" 2>/dev/null | awk '$1=="hostname"{print $2}')" != "$peer.$suffix" ]]; then
      warn "an earlier stanza in ~/.ssh/config overrides HostName for $peer -- remove it"
    fi
  done
}

enable_system_units() {
  local entry pkg unit why

  for entry in "${SYSTEM_UNITS[@]}"; do
    IFS='|' read -r pkg unit why <<< "$entry"

    if profile_on lean && [[ " ${LEAN_UNITS_OFF[*]} " == *" $unit "* ]]; then
      info "$unit: off on lean hosts (PROFILES=lean) -- not enabling"
      continue
    fi
    if [[ $unit == sshd.service ]] && no_inbound; then
      info "$unit: no inbound ssh on this machine -- not enabling (stop_sshd_no_inbound)"
      continue
    fi

    # An excluded package must not have its unit enabled either. Without this the
    # exclusion file would decline to INSTALL something and then this loop would
    # try to start it, which is worse than either behaviour on its own.
    if [[ -n ${PKG_EXCLUDED[$pkg]:-} ]]; then
      info "$unit: $pkg is excluded on this machine -- not enabling"
      continue
    fi

    # Installed-but-not-enabled is the case worth acting on. Not-installed means
    # stage 10 declined or has not run; say so rather than failing on `enable`.
    if ! pacman -Qq "$pkg" >/dev/null 2>&1; then
      info "$unit: $pkg not installed -- skipping"
      continue
    fi

    # ENABLEMENT is what this script controls; RUNNING is not. Conflating them
    # was the first version of this loop and it was wrong: beast-arch has bluez
    # installed and bluetooth.service enabled, but no bluetooth hardware, so
    # systemd skips the unit on ConditionPathIsDirectory=/sys/class/bluetooth and
    # it is `inactive` forever. An "enabled AND active" test would have reported a
    # change on every single run of this box, which is exactly the idempotency
    # property the whole script is built around.
    #
    # So: decide on is-enabled, then REPORT on is-active separately, because an
    # enabled daemon that is not running is still worth saying out loud.
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      ok "$unit already enabled"
    else
      info "enabling $unit -- $why"
      run sudo systemctl enable --now "$unit"
      did "$unit enabled and started"
      continue
    fi

    systemctl is-active --quiet "$unit" 2>/dev/null && continue

    # Not running. Distinguish "systemd deliberately skipped it" from "it died",
    # because only the second one is a fault. ConditionResult=no means the unit's
    # own Condition* checks failed -- absent hardware, usually -- and nothing here
    # can or should fix that.
    if [[ "$(systemctl show -p ConditionResult --value "$unit" 2>/dev/null)" == "no" ]]; then
      info "$unit is enabled but skipped -- its Condition* checks do not hold here"
      info "  (usually the hardware is absent; harmless)"
    else
      warn "$unit is enabled but NOT running -- check: systemctl status $unit"
    fi
  done

  # Two things the unit alone does NOT give you, both deliberately left manual.

  # tailscaled running is not the same as being ON the tailnet. `tailscale up`
  # opens a browser for interactive auth, once per machine, exactly like
  # `ob login` in stage 55. Checked on beast-arch 2026-08-24: the tailnet had
  # beast-arch and one tablet on it and nothing else, so a second workstation
  # does NOT arrive by itself.
  if pacman -Qq tailscale >/dev/null 2>&1 && [[ -z ${PKG_EXCLUDED[tailscale]:-} ]]; then
    if tailscale status >/dev/null 2>&1; then
      ok "tailscale: this machine is on a tailnet"
    else
      todo "tailscale is installed but this machine has not joined a tailnet:"
      todo "    sudo tailscale up        # interactive, once per machine"
    fi
  fi

  # This script does NOT add $USER to the `docker` group, and that omission is a
  # decision, not an oversight. Membership is root-equivalent: `docker run -v
  # ~/.ssh:/m` reads files a Landlock sandbox denies, which is a demonstrated
  # escape from the agent sandboxing on beast-arch. Enabling the daemon is
  # reversible; handing every process running as you a root-equivalent socket is
  # not. Use `sudo docker`, or add the group by hand knowing what it costs.
  if pacman -Qq docker >/dev/null 2>&1 && id -nG "$USER" 2>/dev/null | grep -qw docker; then
    warn "$USER is in the 'docker' group -- that is root-equivalent access to this box"
  fi
}

# Move /tmp off tmpfs, or leave it alone. Called from stage 60.
#
# WHY MASK AND NOT A DROP-IN. /tmp is not in /etc/fstab on Arch -- it is mounted
# by the static unit /usr/lib/systemd/system/tmp.mount. An fstab entry would be a
# SECOND mechanism racing that unit, so the change has to go through systemd.
# A tmp.mount.d drop-in can only resize the tmpfs; it cannot make it not exist.
# Masking is the supported way to say "do not mount this", and basic.target's own
# comment says so.
#
# WHAT YOU GIVE UP, stated because it is a real trade and not a free win: a tmpfs
# /tmp is emptied by the kernel at every boot. On disk, /tmp persists across
# reboots and cleanup falls to systemd-tmpfiles, which ages files out rather than
# truncating the tree. Expect stale files to accumulate where none did before.
manage_tmp_storage() {
  local unit=tmp.mount
  local state
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"

  if [[ $TMP_ON_DISK != true ]]; then
    # Not our business -- but say what is true, because "I did not configure it"
    # and "it is not a tmpfs" are different facts and only one of them is safe to
    # assume later.
    if [[ $state == masked ]]; then
      warn "$unit is masked but TMP_ON_DISK=false -- /tmp is on disk and this script did not do it"
    else
      info "$unit left alone (TMP_ON_DISK=false) -- /tmp is a tmpfs at systemd's default size=50%"
    fi
    return 0
  fi

  if [[ $state == masked ]]; then
    ok "$unit already masked -- /tmp is on disk from the next boot onward"
  else
    info "masking $unit -- /tmp becomes a plain directory on the root filesystem"
    run sudo systemctl mask "$unit"
    did "$unit masked"
  fi

  # The gap that matters. Masking is a boot-time change; reporting it as done
  # while a 16 GiB tmpfs is still mounted underneath you is exactly the
  # "the command works, the feature does not" failure this script keeps hitting.
  if findmnt -no FSTYPE /tmp 2>/dev/null | grep -qx tmpfs; then
    warn "/tmp is STILL a tmpfs right now -- masking only applies at the next boot"
    warn "  reboot, then check: findmnt /tmp (expect no output) and stat -c '%a %U %G' /tmp (expect 1777 root root)"
  fi
}

# Write a whole root-owned file from a string: compare, then `sudo install`.
# Returns 0 if it wrote (or would write), 1 if the file was already right -- so
# call it in an `if` and restart whatever reads it only on 0.
put_etc_file() {   # <path> <content> <what>
  local path=$1 want=$2 what=$3
  if [[ -f $path ]] && [[ "$(cat "$path")" == "$want" ]]; then
    ok "$what already in place ($path)"
    return 1
  fi
  if (( DRY_RUN )); then
    info "(dry run) would write $path"
    did "wrote $path"            # counts only; did() prints nothing under DRY_RUN
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  printf '%s\n' "$want" > "$tmp"
  if run sudo install -D -m 644 "$tmp" "$path"; then
    rm -f "$tmp"
    did "wrote $path -- $what"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Two drop-ins that lived only in /etc on beast-arch and were lost in the
# 2026-09-30 rebuild. Universal, not per-host: each is cheap anywhere.
#   coredump: without a cap, one crashing multi-GiB process writes a multi-GiB
#     core, and systemd-coredump holds it in memory while compressing it.
#   journald: the default 5-minute sync means a hard freeze loses the last
#     minutes of kernel log -- exactly the minutes that would say why it froze.
install_system_dropins() {
  put_etc_file /etc/systemd/coredump.conf.d/limits.conf \
"# Written by arch-bootstrap.
[Coredump]
ProcessSizeMax=2G
MaxUse=1G" "coredump size limits" || true   # read per crash, nothing to restart

  if put_etc_file /etc/systemd/journald.conf.d/sync.conf \
"# Written by arch-bootstrap.
[Journal]
SyncIntervalSec=10s" "journald 10s sync"; then
    run sudo systemctl restart systemd-journald
  fi
}

# Every browser searches DuckDuckGo (Ben, 2026-10-03; station-maintenance beast-arch
# task 73). Uses *managed* policy, so the setting is locked in the browser's UI. For
# a default that can be changed in the UI, use policies/recommended/ instead.
# Chromium-family browsers merge every file in managed/, so this file sits next to
# any extension policy without needing to know about it. A browser reads policy
# only at launch, so one already running needs a restart. qutebrowser's half is
# in the dotfiles.
install_browser_search_policy() {
  local d chromium_family='{
  "DefaultSearchProviderEnabled": true,
  "DefaultSearchProviderName": "DuckDuckGo",
  "DefaultSearchProviderKeyword": "ddg",
  "DefaultSearchProviderSearchURL": "https://duckduckgo.com/?q={searchTerms}",
  "DefaultSearchProviderSuggestURL": "https://duckduckgo.com/ac/?q={searchTerms}&type=list"
}'
  for d in /etc/vivaldi /etc/chromium /etc/opt/chrome; do
    put_etc_file "$d/policies/managed/search-duckduckgo.json" "$chromium_family" \
      "DuckDuckGo default search" || true
  done
  # Firefox reads one policies.json, not a directory; nothing else writes it yet.
  put_etc_file /etc/firefox/policies/policies.json \
    '{ "policies": { "SearchEngines": { "Default": "DuckDuckGo" } } }' \
    "Firefox DuckDuckGo default search" || true
}

# zram is this machine's ONLY swap: zram configured, no SWAP_PARTUUID, and nothing
# but zram in /proc/swaps. The sysctls below assume exactly that.
zram_only_swap() {
  [[ -f /etc/systemd/zram-generator.conf ]] || return 1
  [[ -z ${SWAP_PARTUUID:-} ]] || return 1
  ! awk 'NR>1 && $1 !~ /^\/dev\/zram/' /proc/swaps | grep -q .
}

# Universal, but each part only where it applies. Added 2026-10-03 from micro.
#   bfq: the I/O scheduler built for interactive latency on rotational disks. The
#     rule matches rotational=1 only, so on SSD/NVMe machines it is inert.
#   zram sysctls (ArchWiki "zram"): swappiness 60 is the disk-swap default. With
#     zram as the only swap, compressing idle anonymous memory is far cheaper than
#     dropping page cache, which a spinning disk then has to seek to re-read. NOT
#     applied where disk swap sits behind zram (beast-arch): at 180 the kernel would
#     swap to that disk as eagerly.
tune_storage_and_swap() {
  if put_etc_file /etc/udev/rules.d/60-ioscheduler.rules \
'# Written by arch-bootstrap. bfq on rotational disks only.
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"' \
     "bfq I/O scheduler for rotational disks"; then
    run sudo udevadm control --reload
    run sudo udevadm trigger --subsystem-match=block --action=change
  fi

  if zram_only_swap; then
    if put_etc_file /etc/sysctl.d/99-vm-zram-parameters.conf \
"# Written by arch-bootstrap. zram is the only swap here (see tune_storage_and_swap).
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0" "zram swap tuning"; then
      run sudo sysctl --system
    fi
  else
    info "zram is not the only swap here -- zram sysctls not applied"
  fi
}

# Profile `lean` (see LEAN_UNITS_OFF). Everything here is reversible by dropping the
# profile and re-running `--redo services`, except the units, which stay disabled
# until enabled by hand.
apply_lean_profile() {
  profile_on lean || return 0
  info "profile lean: turning off ${LEAN_UNITS_OFF[*]}"
  local unit
  for unit in "${LEAN_UNITS_OFF[@]}"; do
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      run sudo systemctl disable --now "$unit"
      did "$unit disabled (lean)"
    else
      ok "$unit already off"
    fi
  done

  # CPU governor follows the power source. schedutil's ramp-up lags bursts of typing
  # on a slow CPU; on AC that is not worth the saved heat. Tested on micro 2026-10-03
  # by unplugging and replugging. `$$` is a literal `$` to udev.
  local rule
  rule="$(cat <<'EOF'
# Written by arch-bootstrap (profile lean). performance on AC, schedutil on battery.
# Fires on plug/unplug (change) and at boot (coldplug add).
SUBSYSTEM=="power_supply", ACTION=="add|change", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="/bin/sh -c 'for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do echo performance > $$f; done'"
SUBSYSTEM=="power_supply", ACTION=="add|change", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="/bin/sh -c 'for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do echo schedutil > $$f; done'"
EOF
)"
  if put_etc_file /etc/udev/rules.d/61-cpu-governor-ac.rules "$rule" "CPU governor follows AC (lean)"; then
    run sudo udevadm control --reload
    run sudo udevadm trigger --subsystem-match=power_supply --action=change
  fi

  # zram as big as RAM (ArchWiki's suggestion for low-memory machines). The cap is on
  # UNcompressed data; at micro's measured ~3.4:1 a full 3.5 GiB zram holds ~1 GiB of
  # real RAM. At the default (half of RAM) micro's zram sat 97% full. Applies at the
  # next boot: resizing live would mean swapping everything back into RAM first.
  if zram_only_swap && put_etc_file /etc/systemd/zram-generator.conf \
"# Written by arch-bootstrap (profile lean).
[zram0]
zram-size = ram
compression-algorithm = zstd" "zram sized to RAM (lean)"; then
    info "zram size changes at the next boot"
  fi
}

# A readable kernel-console font. default8x16 at 1920x1080 is tiny; ter-v24n
# (terminus-font, 12x24) gives about 160x45. vconsole.conf also holds KEYMAP, so
# only its FONT= line is touched. The `consolefont` mkinitcpio hook copies the font
# into the initramfs, so the LUKS passphrase prompt only changes after a rebuild.
CONSOLE_FONT=ter-v24n
set_console_font() {
  local f=/etc/vconsole.conf
  if grep -qx "FONT=$CONSOLE_FONT" "$f" 2>/dev/null; then
    ok "console font $CONSOLE_FONT already set"; return 0
  fi
  if [[ ! -e /usr/share/kbd/consolefonts/$CONSOLE_FONT.psf.gz ]] && (( ! DRY_RUN )); then
    warn "$CONSOLE_FONT not installed (terminus-font) -- console font left alone"; return 0
  fi
  if grep -q '^FONT=' "$f" 2>/dev/null; then
    run sudo sed -i "s/^FONT=.*/FONT=$CONSOLE_FONT/" "$f" || return 0
  else
    run sudo sh -c "echo FONT=$CONSOLE_FONT >> $f" || return 0
  fi
  did "console font $CONSOLE_FONT in $f"
  # Used from the next boot. The rebuild is what reaches the passphrase prompt.
  grep -Eq '^HOOKS=.*\<consolefont\>' /etc/mkinitcpio.conf && run sudo mkinitcpio -P
}

# kmscon on tty2-6: a userspace console that draws with real fonts (pango, so
# fallback glyphs too), full Unicode and truecolor -- what the kernel console's
# 512-glyph, 16-colour bitmap cannot. Only the autovt@ alias is pointed at it, so
# tty1, where X is started, keeps agetty, and so does the initramfs passphrase
# prompt (that one gets CONSOLE_FONT above). kmsconvt@ falls back to getty@ on its
# own failure (OnFailure=). From a kmscon tty, X needs `kmscon-launch-gui startx`:
# kmscon has to let go of the display first. Ttys already spawned keep agetty
# until they are released (logout, or a reboot).
#
# KMSCON_TTY1=yes moves tty1 too: kmsconvt@tty1 enabled, getty@tty1 disabled (the
# unit Conflicts= with it). The dotfiles alias startx to kmscon-launch-gui on a
# kmscon tty, so the login habit is unchanged. =no puts agetty back. Off by default
# until it has been tried on a machine that can be rebooted freely (micro/carbon).
KMSCON_FONT="${KMSCON_FONT:-Fira Code}"   # Alacritty's font
KMSCON_TTY1="${KMSCON_TTY1:-no}"
setup_kmscon() {
  if ! pacman -Qq kmscon >/dev/null 2>&1; then
    (( DRY_RUN )) || warn "kmscon not installed -- console left on agetty"
    return 0
  fi
  put_etc_file /etc/kmscon/kmscon.conf \
"# Written by arch-bootstrap. Edit bootstrap.sh, not this file.
font-engine=pango
font-name=$KMSCON_FONT" "kmscon font" || true

  local link=/etc/systemd/system/autovt@.service
  local target=/usr/lib/systemd/system/kmsconvt@.service
  if [[ "$(readlink "$link" 2>/dev/null)" == "$target" ]]; then
    ok "kmscon already serves tty2-6 (autovt@)"
  else
    run sudo ln -sfn "$target" "$link"
    run sudo systemctl daemon-reload
    did "kmscon on tty2-6 (autovt@ -> kmsconvt@)"
  fi

  # Enable/disable only, never --now: switching the tty under a logged-in session
  # would kill it. Takes effect at the next boot.
  local on=kmsconvt@tty1.service off=getty@tty1.service
  [[ $KMSCON_TTY1 == yes ]] || { on=getty@tty1.service; off=kmsconvt@tty1.service; }
  if systemctl is-enabled --quiet "$on" 2>/dev/null \
     && ! systemctl is-enabled --quiet "$off" 2>/dev/null; then
    ok "tty1: ${on%@*} (KMSCON_TTY1=$KMSCON_TTY1)"
  else
    run sudo systemctl disable "$off"
    run sudo systemctl enable "$on"
    did "tty1: ${on%@*} from the next boot (KMSCON_TTY1=$KMSCON_TTY1)"
  fi
}

# Host firewall (beast-arch task 76, 2026-10-03): none was active on beast-arch,
# carbon or micro. Inbound is dropped except loopback, the tailnet (tailscale0 --
# the tailnet policy is the access control there), docker's bridges, ICMP,
# tailscale's direct UDP port, mDNS (cast discovery) and DHCP replies.
# FIREWALL_LAN_TCP / FIREWALL_LAN_UDP open ports to the LAN; profile media-center
# adds Jellyfin (8096, and 7359 for the apps' discovery) for the LAN-only phone.
#
# Its own table only, never `flush ruleset`, so a reload leaves the tables docker
# and tailscaled maintain alone. It does NOT cover docker-published ports: those
# are DNATed in prerouting and never reach the input hook, so a container
# published on 0.0.0.0 stays reachable. Bind those to 127.0.0.1 in compose.
# Tested 2026-10-03 across two user+net namespaces: LAN :8096 open, :22 and
# :56379 dropped, tailscale0 open, ping answered, a foreign table survived reload.
FIREWALL="${FIREWALL:-yes}"
FIREWALL_LAN_TCP="${FIREWALL_LAN_TCP:-}"
FIREWALL_LAN_UDP="${FIREWALL_LAN_UDP:-}"
setup_firewall() {
  if [[ $FIREWALL != yes ]]; then
    info "FIREWALL=$FIREWALL -- host firewall left alone"; return 0
  fi
  pacman -Qq nftables >/dev/null 2>&1 || { warn "nftables not installed -- no firewall"; return 0; }
  # A kernel upgraded but not yet booted has no modules on disk, so nft_ct cannot
  # load and `ct state` fails nft -c with ENOENT (carbon, 2026-10-04).
  [[ -d /lib/modules/$(uname -r) ]] || {
    warn "kernel $(uname -r) is running but its modules are gone (upgraded, not rebooted) -- reboot, then --only services for the firewall"; return 0; }
  local tcp=$FIREWALL_LAN_TCP udp=$FIREWALL_LAN_UDP extra=""
  profile_on media-center && { tcp+=" 8096"; udp+=" 7359"; }
  tcp="$(echo $tcp | tr ' ' ',')"; udp="$(echo $udp | tr ' ' ',')"
  [[ -n $tcp ]] && extra+="
    tcp dport { $tcp } accept"
  [[ -n $udp ]] && extra+="
    udp dport { $udp } accept"

  local rules="#!/usr/bin/nft -f
# Written by arch-bootstrap. Edit bootstrap.sh / bootstrap.conf, not this file.
# Only this table: no flush ruleset, which would wipe docker's and tailscaled's.
table inet hostfw
delete table inet hostfw
table inet hostfw {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif \"lo\" accept
    iifname \"tailscale0\" accept
    iifname \"docker0\" accept
    iifname \"br-*\" accept
    meta l4proto { icmp, ipv6-icmp } accept
    udp dport 41641 accept
    udp dport 5353 accept
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept$extra
  }
}"
  # Syntax-check before it goes near /etc: a private user+net namespace gives nft
  # the capability it needs for -c without sudo.
  local tmp; tmp="$(mktemp)"
  printf '%s\n' "$rules" > "$tmp"
  if unshare -rn true 2>/dev/null && ! unshare -rn nft -c -f "$tmp" >/dev/null; then
    rm -f "$tmp"; warn "generated firewall rules fail nft -c -- not installed"; return 0
  fi
  rm -f "$tmp"

  if put_etc_file /etc/nftables.conf "$rules" "host firewall" \
     || ! systemctl is-enabled --quiet nftables 2>/dev/null; then
    run sudo systemctl enable nftables
    run sudo nft -f /etc/nftables.conf
    did "host firewall loaded and enabled (LAN tcp: ${tcp:-none}, udp: ${udp:-none})"
  fi
}

# LLMNR answers name queries from anyone on the LAN on tcp/udp 5355; nothing here
# uses it (mDNS covers .local, the tailnet has MagicDNS). Found listening on every
# interface on beast-arch and carbon, 2026-10-03 (task 76).
disable_llmnr() {
  put_etc_file /etc/systemd/resolved.conf.d/no-llmnr.conf \
"# Written by arch-bootstrap.
[Resolve]
LLMNR=no" "LLMNR off" && run sudo systemctl restart systemd-resolved
  return 0
}

# Random-key encrypted swap on SWAP_PARTUUID. See the config comment for why
# PARTUUID. Lines are appended to /etc/crypttab and /etc/fstab, never rewritten:
# both hold this machine's other filesystems.
setup_encrypted_swap() {
  [[ -n $SWAP_PARTUUID ]] || return 0
  local dev=/dev/disk/by-partuuid/$SWAP_PARTUUID
  local ct="swap  PARTUUID=$SWAP_PARTUUID  /dev/urandom  swap,cipher=aes-xts-plain64,size=512,sector-size=4096,nofail"
  local fs="/dev/mapper/swap  none  swap  defaults,pri=10,nofail  0 0"

  # An unreadable file makes every "already there?" grep below say no, and each
  # run would append another copy.
  local f
  for f in /etc/crypttab /etc/fstab; do
    [[ ! -e $f || -r $f ]] || { warn "$f is not readable -- cannot check it, so not adding disk swap"; return 0; }
  done

  if grep -qxF "$ct" /etc/crypttab; then
    ok "encrypted swap already in /etc/crypttab"
  elif grep -qE '^[[:space:]]*swap[[:space:]]' /etc/crypttab; then
    warn "/etc/crypttab already maps a 'swap' that is not this one -- not touching it"
    return 0
  else
    # The safety check. The `swap` option reformats the device at every boot, so
    # a wrong PARTUUID destroys a filesystem. Only a partition that is swap NOW
    # and not in use is accepted. Done once: after the first boot the partition
    # reads as random data, and the crypttab line above is the proof it was ours.
    local fstype mnt
    fstype="$(lsblk -no FSTYPE "$dev" 2>/dev/null || true)"
    mnt="$(lsblk -no MOUNTPOINTS "$dev" 2>/dev/null || true)"
    if [[ ! -b $dev ]]; then
      warn "SWAP_PARTUUID=$SWAP_PARTUUID: no such partition -- no disk swap"
      return 0
    elif [[ $fstype != swap ]]; then
      warn "REFUSING disk swap: $dev is '${fstype:-unformatted}', not swap -- it would be overwritten every boot"
      return 0
    elif [[ -n $mnt ]]; then
      warn "REFUSING disk swap: $dev is in use ($mnt) -- swapoff it first"
      return 0
    fi
    printf '%s\n' "$ct" | run sudo tee -a /etc/crypttab
    did "encrypted swap added to /etc/crypttab ($dev)"
  fi

  if grep -qxF "$fs" /etc/fstab; then
    ok "encrypted swap already in /etc/fstab"
  elif grep -qE '^[[:space:]]*/dev/mapper/swap[[:space:]]' /etc/fstab; then
    warn "/etc/fstab already has a /dev/mapper/swap line that is not this one -- not touching it"
  else
    printf '%s\n' "$fs" | run sudo tee -a /etc/fstab
    did "encrypted swap added to /etc/fstab (pri=10, behind zram)"
  fi

  # Same boot-time gap as manage_tmp_storage: written is not active.
  if [[ -e /dev/mapper/swap ]] && grep -q "^$(realpath /dev/mapper/swap) " /proc/swaps; then
    ok "encrypted swap is active"
  else
    warn "encrypted swap is NOT active yet -- it comes up at the next boot; check: swapon --show"
  fi
}

# MEDIA_DRIVES at /srv/media/<name> (added 2026-10-03 for media-center).
# exFAT and NTFS store no Unix ownership, so the mount options ARE the permissions:
# the login user owns everything (read/write/delete), group jellyfin can read but
# not write (the server cannot delete media), and root bypasses the masks.
# nofail + x-systemd.automount: an absent drive does not hold up boot, and one
# plugged in later mounts when the path is touched (a Jellyfin scan does that).
# udiskie would otherwise mount it first under /run/media/$USER, which is 750 root
# plus an ACL for the user only, so jellyfin cannot read it there; a udev rule
# marks these UUIDs UDISKS_IGNORE. fstab lines are appended, never rewritten, as
# for the encrypted swap.
setup_media_drives() {
  [[ -n $MEDIA_DRIVES ]] || return 0
  [[ -r /etc/fstab ]] || { warn "/etc/fstab is not readable -- media drives not added"; return 0; }
  local gid
  gid="$(getent group jellyfin | cut -d: -f3)"
  [[ -n $gid ]] || { warn "no jellyfin group (jellyfin-server not installed?) -- media drives not added"; return 0; }

  local entry name uuid fstype mp line where rules="# Written by arch-bootstrap (MEDIA_DRIVES). Mounted by fstab, not udisks/udiskie."
  local -a units=()
  for entry in $MEDIA_DRIVES; do
    IFS=: read -r name uuid fstype <<< "$entry"
    if [[ -z $name || -z $uuid || -z $fstype || $name == */* ]]; then
      warn "MEDIA_DRIVES entry '$entry' is not name:uuid:fstype -- skipped"
      continue
    fi
    mp=/srv/media/$name
    line="UUID=$uuid  $mp  $fstype  nofail,x-systemd.automount,x-systemd.device-timeout=10s,uid=$(id -u),gid=$gid,dmask=0027,fmask=0137  0 0"
    rules+=$'\n'"SUBSYSTEM==\"block\", ENV{ID_FS_UUID}==\"$uuid\", ENV{UDISKS_IGNORE}=\"1\""

    if grep -qxF "$line" /etc/fstab; then
      ok "$mp already in /etc/fstab"
    elif grep -qE "^[^#]*[[:space:]]$mp[[:space:]]" /etc/fstab || grep -qE "^[[:space:]]*UUID=$uuid[[:space:]]" /etc/fstab; then
      warn "/etc/fstab already has a line for $mp or UUID=$uuid that is not this one -- not touching it"
      continue
    else
      run sudo install -d -m 755 "$mp"
      printf '%s\n' "$line" | run sudo tee -a /etc/fstab
      did "media drive $name added to /etc/fstab ($mp, $fstype)"
    fi
    units+=("$(systemd-escape -p --suffix=automount "$mp")")

    # Mounted elsewhere already (udiskie got there first): a second mount of the
    # same device would not take these options. Say so rather than unmount it.
    where="$(findmnt -rno TARGET -S "UUID=$uuid" 2>/dev/null | grep -vxF "$mp" || true)"
    [[ -z $where ]] || warn "$name is mounted at $where -- unmount it (udisksctl unmount -b $(findmnt -rno SOURCE -S "UUID=$uuid" | head -1)), then: ls $mp"
  done

  if put_etc_file /etc/udev/rules.d/61-media-drives-udisks-ignore.rules "$rules" "udisks ignores the media drives"; then
    run sudo udevadm control --reload
  fi
  (( ${#units[@]} )) || return 0
  run sudo systemctl daemon-reload
  run sudo systemctl start "${units[@]}"
  ok "media drives on automount: ${units[*]}"
}

configure_earlyoom() {
  [[ -n $EARLYOOM_ARGS ]] || return 0
  pacman -Qq earlyoom >/dev/null 2>&1 || return 0
  [[ -z ${PKG_EXCLUDED[earlyoom]:-} ]] || return 0
  if [[ $EARLYOOM_ARGS == *'"'* ]]; then
    warn "EARLYOOM_ARGS contains a double quote -- use single quotes inside it; not written"
    return 0
  fi
  # systemd splits $EARLYOOM_ARGS and honours single quotes, so --avoid/--prefer
  # regexes survive as one argument each (checked against `ps` on beast-arch).
  if put_etc_file /etc/default/earlyoom \
"# Written by arch-bootstrap. Edit EARLYOOM_ARGS in bootstrap.conf, not this file.
EARLYOOM_ARGS=\"$EARLYOOM_ARGS\"" "earlyoom thresholds"; then
    systemctl is-active --quiet earlyoom && run sudo systemctl restart earlyoom
  fi
  return 0
}


stage_services() {
  stage_banner "60 services -- system and user units"

  enable_system_units
  harden_sshd
  stop_sshd_no_inbound
  ssh_tailnet_peers
  install_chores
  manage_tmp_storage
  install_system_dropins
  install_browser_search_policy
  tune_storage_and_swap
  apply_lean_profile
  set_console_font
  setup_kmscon
  setup_firewall
  disable_llmnr
  setup_encrypted_swap
  setup_media_drives
  configure_earlyoom

  # ---- login keyring auto-unlock (added 2026-08-23) ---------------------------
  #
  # Without this the login keyring stays LOCKED for the whole session: git's
  # libsecret credential helper cannot store anything, and Emacs/Forge cannot read
  # a token back out. This box logs in on a TTY and then runs startx, so
  # /etc/pam.d/login is the stack that actually runs. A display-manager setup would
  # need that DM's own PAM file instead -- do not assume this one covers it.
  #
  # `auth` captures the login password. When the keyring daemon is not up yet,
  # gkr-pam stashes it and unlocks at `session` open, so that race resolves itself
  # -- "unable to locate daemon control file" in the journal is normal, not a fault.
  # `password` keeps the keyring password in step when the login password changes.
  #
  # The keyring password must EQUAL the login password or the unlock fails silently.
  # This does NOT repair a keyring created earlier under a different password: for
  # that, delete ~/.local/share/keyrings/login.keyring and let the next login make a
  # new one. Be aware that deleting it leaves NO collection until that next login,
  # during which clients report "object does not exist" rather than "locked".
  local pamfile=/etc/pam.d/login
  if [[ ! -f $pamfile ]]; then
    warn "$pamfile missing -- skipping keyring auto-unlock"
  elif grep -q 'pam_gnome_keyring' "$pamfile"; then
    ok "pam_gnome_keyring already wired into $pamfile"
  elif (( DRY_RUN )); then
    info "(dry run) would add pam_gnome_keyring lines to $pamfile"
  else
    local tmppam; tmppam="$(mktemp)"
    awk '
      { print }
      /^auth[[:space:]]+include[[:space:]]+system-local-login/ && !a {
        print "auth       optional     pam_gnome_keyring.so"; a=1 }
      /^session[[:space:]]+include[[:space:]]+system-local-login/ && !s {
        print "session    optional     pam_gnome_keyring.so auto_start"; s=1 }
      /^password[[:space:]]+include[[:space:]]+system-local-login/ && !p {
        print "password   optional     pam_gnome_keyring.so"; p=1 }
    ' "$pamfile" > "$tmppam"

    # Refuse to install anything that did not gain all three lines. A PAM file
    # written from a partial match can lock you out of the console, and that is a
    # far worse failure than a locked keyring.
    if [[ $(grep -c 'pam_gnome_keyring' "$tmppam") -eq 3 ]]; then
      run sudo install -m 644 "$tmppam" "$pamfile"
      did "wired pam_gnome_keyring into $pamfile"
      # PAM runs at LOGIN. The session this bootstrap runs in logged in before
      # these lines existed, so it has no login keyring -- and the first app that
      # asks for one under X gets a "create a new keyring" prompt instead. On
      # 2026-09-30 that made a second keyring, `Default_Keyring`, the default, and
      # it stayed locked at every later login.
      todo "log out and back in BEFORE startx, so PAM creates the login keyring"
    else
      warn "could not place all three pam_gnome_keyring lines -- $pamfile left untouched"
      warn "add them by hand: auth/session(auto_start)/password optional pam_gnome_keyring.so"
    fi
    rm -f "$tmppam"
  fi

  # Only the keyring named `login` is unlocked by PAM. If the default alias names
  # any other, apps store their secrets where nothing unlocks them and prompt at
  # every login. tools/keyring-to-login moves the items (backup, copy, read back,
  # switch the alias, then delete originals). It needs the session's D-Bus and both
  # keyrings unlocked, so it runs only under X; exit 3 (locked / no login keyring)
  # becomes a todo. install.sh now wires PAM at install time, so new machines should
  # not reach this branch; beast-arch, carbon and micro all did.
  local kdefault="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings/default"
  if [[ -f $kdefault ]] && [[ "$(cat "$kdefault")" != login ]]; then
    warn "default keyring is '$(cat "$kdefault")', not 'login' -- it will not unlock at login"
    if [[ -z ${DISPLAY:-} ]]; then
      todo "from X:  $SCRIPT_DIR/tools/keyring-to-login"
    elif (( DRY_RUN )); then
      python3 "$SCRIPT_DIR/tools/keyring-to-login" --dry-run || true
    else
      local krc=0
      python3 "$SCRIPT_DIR/tools/keyring-to-login" || krc=$?
      case $krc in
        0) did "keyring items moved into 'login', default switched -- log out and back in to check" ;;
        3) todo "unlock both keyrings (seahorse), then:  $SCRIPT_DIR/tools/keyring-to-login" ;;
        *) warn "keyring-to-login failed (exit $krc) -- backup in ~/keyrings-backup-*.tar.gz" ;;
      esac
    fi
  elif [[ -f $kdefault ]]; then
    ok "default keyring is 'login'"
  fi

  # NOTE: user units live in ~/.config/systemd/user. systemd does NOT honour
  # XDG_CONFIG_HOME for unit lookup, so this path stays .config even on a box
  # with a non-standard config root. This bites people constantly.
  local unit_dir="$HOME/.config/systemd/user"
  run mkdir -p "$unit_dir"

  # The obsidian-sync unit is generated by the obsidian stage (obsidian_sync_unit),
  # which runs AFTER this one and only under X -- a unit for a vault that is not
  # bound yet would just crash-loop.
}

# Generate and (once the vault is usable) enable the obsidian-sync user unit.
# Called at the end of stage_obsidian. It lived in stage 60 until 2026-09-30, when
# the obsidian stage moved after services and under X -- in services it ran
# before any vault could be bound, and only a later `--redo services` enabled it.
obsidian_sync_unit() {
  local unit_dir="$HOME/.config/systemd/user"
  run mkdir -p "$unit_dir"

  if [[ -z $OBSIDIAN_VAULT ]]; then
    info "OBSIDIAN_VAULT not set -- no sync unit to generate"
    return 0
  fi

  local unit="$unit_dir/obsidian-sync.service"

  # GENERATE, do not restore. A checked-in copy of this unit hardcodes one
  # machine's absolute node path in both ExecStart and Environment=PATH, which
  # breaks on any other machine and after any nvm upgrade that retires that
  # version. Resolve it fresh instead.
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  local node_root=""
  if [[ -d $NVM_DIR/versions/node ]]; then
    node_root="$(find "$NVM_DIR/versions/node" -maxdepth 1 -type d \
                   -name "v${NODE_MAJOR}.*" | sort -V | tail -1)"
  fi

  if [[ -z $node_root ]]; then
    warn "no nvm node v${NODE_MAJOR}.x found -- skipping unit generation."
    warn "run the toolchains stage first, then: ./bootstrap.sh --redo obsidian"
    return 0
  fi
  info "generating unit against $node_root"

  local cli="$node_root/lib/node_modules/obsidian-headless/cli.js"
  [[ -f $cli ]] || warn "obsidian-headless not at $cli -- the unit will fail until it is"

  # Render to a temp file and compare. Writing unconditionally meant every re-run
  # dropped another .bak-<timestamp> beside the unit and reloaded systemd for a
  # file whose contents had not changed.
  #
  # The render happens under --dry-run too. Rendering is harmless -- it touches
  # only a temp file -- and doing it means the dry run can compare and report
  # truthfully whether the unit would change, instead of always claiming it would.
  local unit_changed=0 staged
  staged="$(mktemp)"
  cat > "$staged" <<EOF
[Unit]
Description=Obsidian Sync (headless, continuous)
Documentation=https://obsidian.md/help/sync/headless
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Call node EXPLICITLY with cli.js -- do not use the \`ob\` wrapper here. \`ob\` is a
# symlink to cli.js whose shebang is \`#!/usr/bin/env node\`, so an absolute path to \`ob\`
# pins the SCRIPT but not the INTERPRETER: env resolves node from systemd's PATH and
# finds the system node, not nvm's. better-sqlite3 is a native module built for one
# NODE_MODULE_VERSION; a mismatched node aborts with ERR_DLOPEN_FAILED and crash-loops.
#
# GENERATED by bootstrap.sh against the node this machine resolved.
# Re-run \`./bootstrap.sh --redo obsidian\` after any nvm upgrade.
ExecStart=$node_root/bin/node \\
    $cli \\
    sync --path $OBSIDIAN_VAULT --continuous

Environment=PATH=$node_root/bin:/usr/local/bin:/usr/bin

# REQUIRED when XDG_CONFIG_HOME is non-standard. \`ob\` resolves its credential store
# to \$XDG_CONFIG_HOME/obsidian-headless, falling back to ~/.config when unset. The
# systemd user manager does NOT inherit your shell's environment, so without this the
# daemon reads the wrong directory, finds no credentials, and fails.
Environment=XDG_CONFIG_HOME=$XDG_CONFIG_HOME
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
EOF
  if [[ -f $unit ]] && cmp -s "$staged" "$unit"; then
    rm -f "$staged"
    ok "$unit already matches what this machine resolves to"
  elif (( DRY_RUN )); then
    printf '%s  would write:%s %s (ExecStart -> %s/bin/node)\n' \
      "$C_DIM" "$C_RESET" "$unit" "$node_root"
    [[ -f $unit ]] && diff -u "$unit" "$staged" | sed 's/^/        /' || true
    rm -f "$staged"
    did "wrote $unit"
    unit_changed=1
  else
    [[ -f $unit ]] && cp -a "$unit" "$unit.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$staged" "$unit"
    chmod 644 "$unit"
    did "wrote $unit"
    unit_changed=1
  fi

  # Only reload when the unit actually changed. daemon-reload is cheap but not
  # free, and an unconditional one hides whether anything happened.
  if (( unit_changed )); then
    run systemctl --user daemon-reload
  else
    ok "no unit change -- systemd reload not needed"
  fi

  # Starting before the vault is USABLE just crash-loops the unit. That needs two
  # preconditions, not one:
  #
  #   auth token  -- `ob login` has run
  #   vault bound -- `ob sync-setup` has run AND took
  #
  # Only the first was checked. On carbon 2026-08-07 that meant this stage
  # enabled a daemon that could not work: `ob sync --continuous` found no sync
  # configuration, exited, and systemd restarted it every RestartSec=30 forever.
  # `systemctl is-active` reported "activating" rather than "failed", because a
  # unit in restart backoff is not failed -- so nothing looked obviously wrong.
  local have_token=0 vault_bound=0
  [[ -f $XDG_CONFIG_HOME/obsidian-headless/auth_token ]] && have_token=1
  local ob_bin="$node_root/bin/ob"
  if [[ -x $ob_bin ]] && "$ob_bin" sync-list-local 2>/dev/null | grep -qF "$OBSIDIAN_VAULT"; then
    vault_bound=1
  fi

  if (( have_token && vault_bound )); then
    if systemctl --user is-enabled --quiet obsidian-sync.service 2>/dev/null \
       && systemctl --user is-active --quiet obsidian-sync.service 2>/dev/null; then
      ok "obsidian-sync already enabled and running"
    else
      run systemctl --user enable --now obsidian-sync.service
      did "obsidian-sync enabled and started"
    fi
    info "the unit is session-scoped: it starts at login and stops with your last"
    info "session. To keep syncing while logged out: sudo loginctl enable-linger \$USER"
    return 0
  fi

  if ! (( have_token )); then
    warn "no obsidian-headless auth token -- NOT starting the daemon"
    todo "log into X and run:  $0 --redo obsidian"
  else
    warn "logged in, but $OBSIDIAN_VAULT is not bound to a remote vault."
    warn "Starting the daemon now would restart it every 30s indefinitely."
    todo "bind it:  $0 --redo obsidian"
  fi

  # If a previous run already enabled it, it is crash-looping right now. Say so
  # and offer to stop it -- leaving a unit to wake up every 30s forever is worse
  # than a stopped one, especially on a laptop.
  if systemctl --user is-enabled --quiet obsidian-sync.service 2>/dev/null; then
    local st; st="$(systemctl --user is-active obsidian-sync.service 2>/dev/null || true)"
    warn "obsidian-sync is already enabled and currently '$st' -- it cannot succeed yet"
    if confirm "stop and disable it until the vault is bound?"; then
      run systemctl --user disable --now obsidian-sync.service
      did "obsidian-sync stopped and disabled (re-enable with --redo obsidian once bound)"
    fi
  fi
}

# Turn sshd off on a no_inbound machine. harden_sshd still writes its config, so
# turning it back on later (drop the marker / AUTHORIZE_PEERS) starts it hardened.
# Disabled AND stopped: enabled-but-stopped comes back at the next boot.
stop_sshd_no_inbound() {
  no_inbound || return 0
  if systemctl is-enabled --quiet sshd.service 2>/dev/null \
     || systemctl is-active --quiet sshd.service 2>/dev/null; then
    run sudo systemctl disable --now sshd.service
    did "sshd disabled and stopped (no inbound ssh on this machine)"
  else
    ok "sshd off (no inbound ssh on this machine)"
  fi
}

# --------------------------------------------------------------------------- 80

stage_verify() {
  stage_banner "80 verify"

  local fails=0
  check() {
    if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "$1 -- FAILED"; fails=$(( fails + 1 )); fi
  }

  check "zsh installed"                 "command -v zsh"
  check "git installed"                 "command -v git"
  check "XDG_CONFIG_HOME resolves"      "[ -d '$XDG_CONFIG_HOME' ]"
  [[ -n $DOTFILES_REMOTE ]] && check "dotfiles repo present" "[ -d '$DOTFILES_DIR' ]"
  [[ -n $SECRETS_REMOTE  ]] && check "secrets repo present"  "[ -d '$SECRETS_DIR' ]"
  [[ -d $XMONAD_DIR ]]      && check "xmonad binary built"   "command -v xmonad"
  check "nvm present"                   "[ -s \"\${NVM_DIR:-\$HOME/.nvm}/nvm.sh\" ]"
  check "herdr installed"               "command -v herdr"
  check "arch-bootstrap origin is SSH"  "git -C '$SCRIPT_DIR' remote get-url origin | grep -q '^git@'"
  check "bfq rule for rotational disks"  "[ -f /etc/udev/rules.d/60-ioscheduler.rules ]"
  if zram_only_swap; then
    check "zram swap tuning live (swappiness 180)" "[ \"\$(sysctl -n vm.swappiness)\" = 180 ]"
  fi
  if profile_on lean; then
    local u
    for u in "${LEAN_UNITS_OFF[@]}"; do
      check "lean: $u not enabled" "! systemctl is-enabled --quiet $u"
    done
    check "lean: CPU governor rule present" "[ -f /etc/udev/rules.d/61-cpu-governor-ac.rules ]"
  fi

  # Clock. install.sh sets the timezone and turns NTP on; the prompt's clock must then
  # FOLLOW the system rather than pin an offset. starship.toml pinned utc_time_offset
  # "-5" until 2026-10-03, which put the prompt an hour behind for all of daylight time
  # while every other clock on the machine was right.
  info "timezone: $(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
  check "system clock NTP-synchronised" "[ \"\$(timedatectl show -p NTPSynchronized --value)\" = yes ]"
  check "prompt clock follows system time (no utc_time_offset in starship.toml)" \
    "! grep -qE '^[[:space:]]*utc_time_offset' '$HOME/.config/starship.toml'"

  # Only once the obsidian stage has run: from a TTY it is deferred to X, and
  # failing verify for a stage that deliberately has not happened would stop the run.
  if [[ -n $OBSIDIAN_VAULT ]] && state_done obsidian; then
    check "obsidian auth token"         "[ -f '$XDG_CONFIG_HOME/obsidian-headless/auth_token' ]"
    check "obsidian-sync unit active"   "systemctl --user is-active obsidian-sync.service"
  elif [[ -n $OBSIDIAN_VAULT ]]; then
    info "obsidian stage not done yet (deferred to X) -- its checks are skipped"
  fi

  if (( fails )); then
    warn "$fails check(s) failed -- see the stage they belong to, then re-run that stage"
    # Under --dry-run these checks interrogate a machine the dry run deliberately
    # did NOT change, so on any incompletely-provisioned box they fail by
    # construction: nothing was installed, so nothing verifies. Failing the stage
    # then aborted the whole run at 80 and swallowed the summary -- which is the
    # one line a dry run exists to produce. Report and carry on.
    (( DRY_RUN )) && {
      info "(dry run -- these describe the machine as it is NOW, before any change)"
      return 0
    }
    return 1
  fi
  ok "all checks passed"
}

# --------------------------------------------------------------------------- 90

stage_manual() {
  stage_banner "90 manual checklist"

  cat <<EOF
  Things this script must not do. Work through them by hand.

  ${C_BOLD}Before this script could run at all${C_RESET}
    [ ] Partitioning, filesystems, bootloader install
    [ ] User account creation
    [ ] SSH key on the box, registered with your git host  (stage 05 gate)

  ${C_BOLD}Credentials${C_RESET}
    [ ] Password vault master password -- from memory only. Nothing automates it.
    [ ] Confirm an out-of-band account recovery route exists that is NOT inside
        the vault. Otherwise total-loss recovery deadlocks: git-host access lives
        in the vault, the vault lives in a repo needing git-host access.
    [ ] Browser profiles and extensions
    [ ] Any application logins not covered by the vault

  ${C_BOLD}Hardware the detection stage would not guess at${C_RESET}
    [ ] NVIDIA: open vs proprietary vs nouveau -- a real decision, made by you
    [ ] Hybrid graphics laptops (Optimus / PRIME)
    [ ] Non-standard audio codecs
    [ ] Anything you declined at the stage-15 prompt

  ${C_BOLD}Session${C_RESET}
    [ ] Log out and back in so the login shell and PATH take effect
    [ ] Verify XDG_CONFIG_HOME is exported before anything reads config
    [ ] Log into X and confirm the WM starts; check its error log
    [ ] Test your keybindings with real keypresses, not by running the command.
        A binding can be dead while the command works fine.

  ${C_BOLD}If pulling dotfiles onto a machine that already has them${C_RESET}
    [ ] Check whether the incoming commits DELETE any tracked file that the
        running session depends on (~/.Xauthority is the classic). Deleting that
        mid-session breaks launching new GUI apps. Save it, pull, restore:
            cp -a ~/.Xauthority /tmp/Xauthority.keep
            git --git-dir=\$DOTFILES_DIR --work-tree=\$HOME pull origin master
            cp -a /tmp/Xauthority.keep ~/.Xauthority && chmod 600 ~/.Xauthority
        Recovery if it does get deleted: log out and back in; startx regenerates it.
EOF
}

# --------------------------------------------------------------------------- driver

# Print the header comment block. Derived from the file rather than a hardcoded
# line range, which silently truncated the help text every time the header grew.
usage() {
  sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed -n '/^#/p' | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

list_stages() {
  local s
  for s in "${STAGES[@]}"; do
    if state_done "$s"; then
      printf '%s  [done] %s%s\n' "$C_GRN" "$s" "$C_RESET"
    else
      printf '  [    ] %s\n' "$s"
    fi
  done
}

selected() {
  local s=$1
  [[ -n $ONLY ]] && { [[ ",$ONLY," == *",$s,"* ]]; return; }
  [[ -n $SKIP && ",$SKIP," == *",$s,"* ]] && return 1
  # Stages with no persistent result are always worth re-running.
  [[ $s == manual || $s == verify ]] && return 0
  if (( RESUME )) && state_done "$s"; then return 1; fi
  return 0
}

main() {
  while (( $# )); do
    case $1 in
      --dry-run)     DRY_RUN=1 ;;
      --yes|-y)      ASSUME_YES=1 ;;
      --resume)      RESUME=1 ;;
      --only)        ONLY="${2:?--only needs a stage list}"; shift ;;
      --skip)        SKIP="${2:?--skip needs a stage list}"; shift ;;
      --redo)        REDO="${2:?--redo needs a stage list}"; shift ;;
      --reset-state) rm -f "$STATE_FILE"; ok "cleared $STATE_FILE"; exit 0 ;;
      --list)        list_stages; exit 0 ;;
      -h|--help)     usage 0 ;;
      *)             printf 'unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
    esac
    shift
  done

  [[ -n $ONLY && -n $SKIP ]] && die "--only and --skip are mutually exclusive"

  local s
  for s in ${ONLY//,/ } ${SKIP//,/ } ${REDO//,/ }; do
    [[ " ${STAGES[*]} " == *" $s "* ]] || die "unknown stage '$s' (see --list)"
  done

  for s in ${REDO//,/ }; do
    state_clear "$s"
    info "cleared completion mark for '$s'"
    ONLY="${ONLY:+$ONLY,}$s"
  done

  # Before the stage loop, so `--only packages` gets them too.
  load_exclusions

  (( DRY_RUN )) && warn "DRY RUN -- nothing will be changed"

  # A stage is called as a plain command, NOT as `if "stage_$s"; then`. Bash turns
  # `set -e` off for the whole body of a function called as an `if` condition, so
  # that form ran every stage with errors ignored and marked it done as long as its
  # LAST command succeeded -- which is always `did "..."`. On 2026-09-30 that marked
  # stage 20 complete with yay never built (makepkg had no fakeroot) and none of the
  # AUR list installed. Now a failing command stops the run inside its stage, and
  # on_exit reports which stage it was. Not a subshell either: stage 05 exports
  # SSH_AUTH_SOCK for the stages after it, and a subshell would drop that.
  trap on_exit EXIT
  for s in "${STAGES[@]}"; do
    if selected "$s"; then
      CURRENT_STAGE="$s"; STAGE_DEFERRED=0
      "stage_$s"
      CURRENT_STAGE=""
      if (( STAGE_DEFERRED )); then
        DEFERRED+=("$s")
      else
        state_mark "$s"
      fi
    else
      state_done "$s" && info "stage $s already done -- skipping" \
                      || info "skipping stage $s"
    fi
  done

  if (( ${#DEFERRED[@]} )); then
    printf '\n%sDeferred until X:%s %s\n' "$C_BOLD$C_YEL" "$C_RESET" "${DEFERRED[*]}"
    printf '  Log out and back in once first (so PAM creates and unlocks the login\n'
    printf '  keyring), then startx, open a terminal and run:\n\n'
    printf '    %s --resume\n' "$0"
  fi

  printf '\n%sbootstrap complete.%s Work through the stage-90 checklist before trusting the box.\n' \
    "$C_BOLD$C_GRN" "$C_RESET"

  # The idempotency report. On an already-provisioned machine a full run must
  # reach here with nothing counted; anything else names a stage that still acts
  # unconditionally. This is the whole test, and it needs no extra tooling.
  if (( DRY_RUN )); then
    if (( DID_COUNT == 0 )); then
      printf '%sIDEMPOTENT:%s a real run would change nothing on this machine.\n' \
        "$C_BOLD$C_GRN" "$C_RESET"
    else
      printf '%sa real run would make %d change(s).%s\n' \
        "$C_BOLD$C_YEL" "$DID_COUNT" "$C_RESET"
    fi
  elif (( DID_COUNT == 0 )); then
    printf '%sIDEMPOTENT:%s nothing changed -- every stage found the machine already correct.\n' \
      "$C_BOLD$C_GRN" "$C_RESET"
  else
    printf '%s%d change(s) applied.%s Re-run to confirm it now settles at zero.\n' \
      "$C_BOLD$C_YEL" "$DID_COUNT" "$C_RESET"
  fi
}

main "$@"
