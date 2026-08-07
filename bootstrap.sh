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
XMONAD_DIR="${XMONAD_DIR:-$HOME/.xmonad}"
OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-}"            # optional; leave empty to skip obsidian
NODE_MAJOR="${NODE_MAJOR:-24}"
KEYXFER_URL="${KEYXFER_URL:-}"                  # optional SSH key-transfer helper binary
CONFIG_HOME_OVERRIDE="${CONFIG_HOME_OVERRIDE:-}" # set if you use a non-standard XDG dir
LOGIN_SHELL="${LOGIN_SHELL:-zsh}"

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

BOOTSTRAP_CONFIG="${BOOTSTRAP_CONFIG:-$SCRIPT_DIR/bootstrap.conf}"
# shellcheck disable=SC1090
[[ -f $BOOTSTRAP_CONFIG ]] && . "$BOOTSTRAP_CONFIG"

# ---------------------------------------------------------------------------
# A non-standard XDG_CONFIG_HOME must be exported BEFORE anything else runs, or
# applications scatter their config into ~/.config and the dotfiles never take
# effect. This is the single easiest thing to get wrong.
# ---------------------------------------------------------------------------
[[ -n $CONFIG_HOME_OVERRIDE ]] && export XDG_CONFIG_HOME="$CONFIG_HOME_OVERRIDE"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/arch-bootstrap"
STATE_FILE="$STATE_DIR/completed-stages"

DRY_RUN=0
ASSUME_YES=0
RESUME=0
ONLY=""
SKIP=""
REDO=""

STAGES=(preflight ssh packages hardware aur toolchains dotfiles secrets
        session xmonad obsidian services verify manual)

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
  else
    "$@"
  fi
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

  local dotfiles secrets vault confighome shell_pref
  read -r -p "  Dotfiles git remote (bare repo, e.g. git@github.com:you/dotfiles.git): " \
    dotfiles </dev/tty
  read -r -p "  Secrets git remote (blank to skip that stage): " secrets </dev/tty
  read -r -p "  Obsidian vault path (blank to skip Obsidian stages) [$HOME/vault]: " \
    vault </dev/tty
  read -r -p "  Non-standard XDG_CONFIG_HOME (blank for the default ~/.config): " \
    confighome </dev/tty
  read -r -p "  Preferred login shell [zsh]: " shell_pref </dev/tty

  cat > "$BOOTSTRAP_CONFIG" <<EOF
# arch-bootstrap local configuration -- generated $(date -Iseconds)
# This file is gitignored. It holds machine- and person-specific values so that
# bootstrap.sh itself can stay publishable.

DOTFILES_REMOTE="${dotfiles}"
SECRETS_REMOTE="${secrets}"
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

  # shellcheck disable=SC1090
  . "$BOOTSTRAP_CONFIG"
  [[ -n ${CONFIG_HOME_OVERRIDE:-} ]] && export XDG_CONFIG_HOME="$CONFIG_HOME_OVERRIDE"
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

  [[ -n $DOTFILES_REMOTE ]] \
    && ok "dotfiles remote configured" \
    || warn "DOTFILES_REMOTE unset -- stage 30 will be skipped"
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

  local -a keys=()
  mapfile -t keys < <(list_private_keys)
  local k
  for k in "${keys[@]}"; do ok "private key present: $(basename "$k")"; done

  # No key at all: offer to make one, then walk the user through registering it.
  #
  # Getting this wrong is expensive in a specific way -- offering to generate a
  # key on a machine that already has one, which then also gets presented for
  # registration while the real key sits unused.
  if (( ${#keys[@]} == 0 )) && ! (( DRY_RUN )); then
    warn "no SSH private key found in ~/.ssh"
    if confirm "generate a new ed25519 keypair now?"; then
      run_interactive ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)"
      mapfile -t keys < <(list_private_keys)
    fi
  fi

  local tries=0
  while ! ssh_auth_works; do
    (( DRY_RUN )) && { info "(dry run -- skipping the auth gate)"; return 0; }
    (( ++tries > 3 )) && break

    # BEFORE blaming registration: a locked key looks exactly like an
    # unregistered one to the probe, because the probe cannot prompt. Try to
    # unlock first, and only fall through to "register it" if that fails or is
    # declined. Getting this order wrong tells the user to re-register a key that
    # is already registered, repeatedly, and never asks for the passphrase.
    if ssh_try_unlock "${keys[@]}"; then
      continue
    fi

    printf '\n'
    local pub
    for k in "${keys[@]}"; do
      pub="$k.pub"
      [[ -f $pub ]] || continue
      printf '%s  public key (%s):%s\n' "$C_BOLD" "$(basename "$pub")" "$C_RESET"
      sed 's/^/        /' "$pub"
    done

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
    return 0
  fi

  (( DRY_RUN )) && return 0
  cat >&2 <<'EOF'

  Nothing below this stage can work -- the dotfiles and secrets remotes are SSH.

  Fix the key, then re-run. Completed stages will not repeat.
EOF
  die "SSH authentication to the git host failed"
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
      BOOTSTRAP_AGENT_PID="${SSH_AGENT_PID:-}"
      trap bootstrap_agent_cleanup EXIT
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
  local remote="${DOTFILES_REMOTE:-}" host out
  [[ -z $remote ]] && return 1
  host="${remote#*@}"; host="${host%%:*}"
  [[ -z $host ]] && return 1
  out="$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T "git@$host" 2>&1 || true)"
  grep -qiE 'successfully authenticated|You.ve successfully|logged in as' <<<"$out"
}

# --------------------------------------------------------------------------- 10

stage_packages() {
  stage_banner "10 packages -- user-space only"

  info "installing from pkglist-userspace.txt -- no kernel, microcode, GPU or firmware"

  local -a all=() want=() missing=()
  mapfile -t all < <(grep -vE '^[[:space:]]*(#|$)' "$SCRIPT_DIR/pkglist-userspace.txt")
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
                   | head -1 | tr -d '[]' | cut -d: -f1 | tr 'A-F' 'a-f')"

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
    # shellcheck disable=SC2086
    run yay -S --needed --noconfirm "${missing[@]}"
    did "${#missing[@]} AUR package(s) installed"
  fi
}

# --------------------------------------------------------------------------- 25

stage_toolchains() {
  stage_banner "25 toolchains"

  # rustup / stack / go / ruby / python-pip / luarocks / mise arrive from pacman in
  # stage 10. What they still need is per-user initialisation.

  if have rustup; then
    if rustup show 2>/dev/null | grep -q 'no active toolchain'; then
      run rustup default stable
      did "rust: stable toolchain installed"
    else
      ok "rust: toolchain already set"
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

  have go && ok "go present ($(go version))" || warn "go missing"

  # nvm is NOT a pacman package -- it is a shell function installed by script.
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s $NVM_DIR/nvm.sh ]]; then
    ok "nvm present at $NVM_DIR"
  else
    info "installing nvm"
    run bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
    did "nvm installed"
  fi

  if (( DRY_RUN )) && [[ -s $NVM_DIR/nvm.sh ]]; then
    # Sourcing nvm and asking `nvm ls` is read-only, so the dry run can answer
    # this properly instead of always claiming it would install. It used to print
    # "would run: nvm install 24" on a machine that already had v24.
    set +u; # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    if nvm ls --no-colors "$NODE_MAJOR" >/dev/null 2>&1; then
      ok "node v$NODE_MAJOR already installed"
    else
      printf '%s  would run:%s nvm install %s\n' "$C_DIM" "$C_RESET" "$NODE_MAJOR"
      did "node v$NODE_MAJOR installed"
    fi
    set -u
  elif (( DRY_RUN )); then
    printf '%s  would run:%s nvm install %s\n' "$C_DIM" "$C_RESET" "$NODE_MAJOR"
    did "node v$NODE_MAJOR installed"
  elif [[ -s $NVM_DIR/nvm.sh ]]; then
    # nvm is a function, not a binary -- must be sourced, and it trips `set -u`.
    set +u; # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"

    # `nvm install` on an already-installed version is close to a no-op, but it
    # still resolves the version index over the network on every run. Ask locally.
    if nvm ls --no-colors "$NODE_MAJOR" >/dev/null 2>&1; then
      ok "node v$NODE_MAJOR already installed"
    else
      nvm install "$NODE_MAJOR"
      did "node v$NODE_MAJOR installed"
    fi

    if [[ "$(nvm alias default --no-colors 2>/dev/null)" == *"v$NODE_MAJOR."* ]]; then
      ok "nvm default alias already -> v$NODE_MAJOR"
    else
      nvm alias default "$NODE_MAJOR" >/dev/null
      did "nvm default alias set to v$NODE_MAJOR"
    fi

    nvm use "$NODE_MAJOR" >/dev/null
    ok "node $(node --version) active (pinned to v$NODE_MAJOR)"

    if [[ -n $OBSIDIAN_VAULT ]]; then
      npm ls -g --depth 0 2>/dev/null | grep -q obsidian-headless \
        && ok "obsidian-headless already installed" \
        || { npm install -g obsidian-headless && did "obsidian-headless installed"; }
    fi
    set -u
  fi

  local t
  for t in mise luarocks gem starship; do
    have "$t" && ok "$t present" || warn "$t missing"
  done

  install_self_distributed_binaries
}

# Tools that are neither pacman, AUR, cargo nor npm: single binaries published by
# their upstream and updated in place. Installing them here rather than committing
# them to a dotfiles repo keeps a self-updating binary from leaving the repo
# permanently dirty, and keeps the repo from carrying a large blob per version.
install_self_distributed_binaries() {
  # herdr -- terminal multiplexer. Referenced by xmonad's startup hook
  # (spawnOnOnce "2" "alacritty -e herdr"), so a machine without it fails at login
  # with "command not found".
  [[ -n ${HERDR_MANIFEST:-} ]] || HERDR_MANIFEST="https://herdr.dev/latest.json"

  if have herdr; then
    ok "herdr present ($(herdr --version 2>/dev/null | head -1))"
    info "it self-updates: run 'herdr update' when you want a newer build"
    return 0
  fi

  if (( DRY_RUN )); then
    printf '%s  would run:%s install herdr from %s\n' "$C_DIM" "$C_RESET" "$HERDR_MANIFEST"
    return 0
  fi

  local arch asset
  case "$(uname -m)" in
    x86_64)         arch=linux-x86_64  ;;
    aarch64|arm64)  arch=linux-aarch64 ;;
    *) warn "no herdr build for $(uname -m) -- skipping"; return 0 ;;
  esac

  info "resolving herdr $arch from $HERDR_MANIFEST"
  # Deliberately no jq dependency -- this runs before much is installed.
  asset="$(curl -fsSL "$HERDR_MANIFEST" 2>/dev/null \
           | grep -o "\"$arch\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
           | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')"

  if [[ -z $asset ]]; then
    warn "could not resolve a herdr download URL -- install it by hand"
    todo "see https://herdr.dev"
    return 0
  fi

  mkdir -p "$HOME/.local/bin"
  if curl -fsSL "$asset" -o "$HOME/.local/bin/herdr.tmp"; then
    chmod +x "$HOME/.local/bin/herdr.tmp"
    mv "$HOME/.local/bin/herdr.tmp" "$HOME/.local/bin/herdr"
    ok "herdr installed ($("$HOME/.local/bin/herdr" --version 2>/dev/null | head -1))"
  else
    rm -f "$HOME/.local/bin/herdr.tmp"
    warn "herdr download failed from $asset"
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

stage_secrets() {
  stage_banner "35 secrets"

  if [[ -z $SECRETS_REMOTE ]]; then
    info "SECRETS_REMOTE not set -- skipping"
    return 0
  fi

  local fresh_clone=0
  if [[ -d $SECRETS_DIR ]]; then
    ok "$SECRETS_DIR already cloned"
  else
    run git clone "$SECRETS_REMOTE" "$SECRETS_DIR"
    did "cloned secrets repo"
    fresh_clone=1
  fi

  (( DRY_RUN )) || {
    local kdbx
    kdbx="$(find "$SECRETS_DIR" -maxdepth 2 -name '*.kdbx' 2>/dev/null | head -1)"
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
}

# --------------------------------------------------------------------------- 40

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
  stage_banner "55 obsidian -- interactive sync setup"

  if [[ -z $OBSIDIAN_VAULT ]]; then
    info "OBSIDIAN_VAULT not set -- skipping"
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

stage_services() {
  stage_banner "60 services -- systemd user units"

  # NOTE: user units live in ~/.config/systemd/user. systemd does NOT honour
  # XDG_CONFIG_HOME for unit lookup, so this path stays .config even on a box
  # with a non-standard config root. This bites people constantly.
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
    warn "run the toolchains stage first, then: ./bootstrap.sh --redo services"
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
# Re-run \`./bootstrap.sh --redo services\` after any nvm upgrade.
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
    todo "run the obsidian stage first, then: $0 --redo services"
  else
    warn "logged in, but $OBSIDIAN_VAULT is not bound to a remote vault."
    warn "Starting the daemon now would restart it every 30s indefinitely."
    todo "bind it first:  $0 --redo obsidian    then:  $0 --redo services"
  fi

  # If a previous run already enabled it, it is crash-looping right now. Say so
  # and offer to stop it -- leaving a unit to wake up every 30s forever is worse
  # than a stopped one, especially on a laptop.
  if systemctl --user is-enabled --quiet obsidian-sync.service 2>/dev/null; then
    local st; st="$(systemctl --user is-active obsidian-sync.service 2>/dev/null || true)"
    warn "obsidian-sync is already enabled and currently '$st' -- it cannot succeed yet"
    if confirm "stop and disable it until the vault is bound?"; then
      run systemctl --user disable --now obsidian-sync.service
      did "obsidian-sync stopped and disabled (re-enable with --redo services once bound)"
    fi
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

  if [[ -n $OBSIDIAN_VAULT ]]; then
    check "obsidian auth token"         "[ -f '$XDG_CONFIG_HOME/obsidian-headless/auth_token' ]"
    check "obsidian-sync unit active"   "systemctl --user is-active obsidian-sync.service"
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

  for s in "${STAGES[@]}"; do
    if selected "$s"; then
      if "stage_$s"; then
        state_mark "$s"
      else
        warn "stage '$s' did not complete cleanly -- not marking it done"
        printf '\n%sStopped at stage %s.%s Fix the problem and re-run:\n\n' \
          "$C_BOLD$C_YEL" "$s" "$C_RESET"
        printf '    %s --resume\n\n' "$0"
        printf 'Completed stages will not repeat.\n'
        exit 1
      fi
    else
      state_done "$s" && info "stage $s already done -- skipping" \
                      || info "skipping stage $s"
    fi
  done

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
