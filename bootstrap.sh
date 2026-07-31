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
# Every stage is idempotent. Completion is recorded per-stage, so you can Ctrl-C out
# to another TTY, do something by hand, and re-run -- finished stages will not repeat.

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
did()   { (( DRY_RUN )) || ok "$*"; }

confirm() {
  (( ASSUME_YES )) && return 0
  (( DRY_RUN ))    && return 1
  local reply
  read -r -p "$(printf '%s  ?   %s %s [y/N] ' "$C_YEL" "$C_RESET" "$1")" reply </dev/tty
  [[ $reply == [yY]* ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

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
  local reply
  read -r -p "$(printf '\n%s  ?   %s Done? [Enter=yes / s=skip this step] ' \
    "$C_YEL" "$C_RESET")" reply </dev/tty
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
  "$@" </dev/tty >/dev/tty 2>&1 || return $?
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

  local found=0 k
  for k in "$HOME"/.ssh/id_*; do
    [[ -e $k ]] || continue
    [[ -f $k && $k != *.pub ]] && { found=1; ok "private key present: $(basename "$k")"; }
  done

  # No key at all: offer to make one, then walk the user through registering it.
  if ! (( found )) && ! (( DRY_RUN )); then
    warn "no SSH private key found in ~/.ssh"
    if confirm "generate a new ed25519 keypair now?"; then
      run_interactive ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)"
      found=1
    fi
  fi

  local tries=0
  while ! ssh_auth_works; do
    (( DRY_RUN )) && { info "(dry run -- skipping the auth gate)"; return 0; }
    (( ++tries > 3 )) && break

    printf '\n'
    if [[ -f $HOME/.ssh/id_ed25519.pub ]]; then
      printf '%s  your public key:%s\n' "$C_BOLD" "$C_RESET"
      sed 's/^/        /' "$HOME/.ssh/id_ed25519.pub"
    elif [[ -f $HOME/.ssh/id_rsa.pub ]]; then
      printf '%s  your public key:%s\n' "$C_BOLD" "$C_RESET"
      sed 's/^/        /' "$HOME/.ssh/id_rsa.pub"
    fi

    pause_for "Register that public key with your git host." \
      "GitHub: https://github.com/settings/keys -> New SSH key" \
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

# Derive the host from the configured remote so this works for any git host,
# not just GitHub. ssh -T exits non-zero even on success, hence the tolerance.
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
  run sudo pacman -Syu --needed --noconfirm - < "$SCRIPT_DIR/pkglist-userspace.txt"
  did "user-space repo packages installed"

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
    elif grep -qi 'nvidia' <<<"$gpu"; then
      warn "NVIDIA detected. Never guessed here -- open vs proprietary vs nouveau is a"
      warn "real decision with real tradeoffs. Deferred to stage 90."
    elif grep -Eqi 'amd|ati|radeon' <<<"$gpu"; then
      info "GPU: AMD -> mesa vulkan-radeon xf86-video-amdgpu (or plain modesetting)"
      detected+=(mesa vulkan-radeon xf86-video-amdgpu)
      if pacman -Qq ollama >/dev/null 2>&1; then
        info "ollama installed and GPU is AMD -> ollama-vulkan is the accelerated variant"
        detected+=(ollama-vulkan)
      fi
    elif grep -qi 'intel' <<<"$gpu"; then
      info "GPU: Intel -> mesa vulkan-intel (modesetting; xf86-video-intel is usually worse)"
      detected+=(mesa vulkan-intel)
    else
      warn "unrecognised GPU -- deferred to stage 90"
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

  local pkgs
  pkgs="$(grep -vx 'yay' "$SCRIPT_DIR/pkglist-aur.txt" | tr '\n' ' ')"
  info "installing AUR packages: $pkgs"
  # shellcheck disable=SC2086
  run yay -S --needed --noconfirm $pkgs
  did "AUR packages installed"
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
  fi

  if (( DRY_RUN )); then
    printf '%s  would run:%s nvm install %s\n' "$C_DIM" "$C_RESET" "$NODE_MAJOR"
  elif [[ -s $NVM_DIR/nvm.sh ]]; then
    # nvm is a function, not a binary -- must be sourced, and it trips `set -u`.
    set +u; # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm install "$NODE_MAJOR"
    nvm alias default "$NODE_MAJOR"
    nvm use "$NODE_MAJOR"
    ok "node $(node --version) active (pinned to v$NODE_MAJOR)"
    if [[ -n $OBSIDIAN_VAULT ]]; then
      npm ls -g --depth 0 2>/dev/null | grep -q obsidian-headless \
        && ok "obsidian-headless already installed" \
        || { npm install -g obsidian-headless && ok "obsidian-headless installed"; }
    fi
    set -u
  fi

  local t
  for t in mise luarocks gem starship; do
    have "$t" && ok "$t present" || warn "$t missing"
  done
}

# --------------------------------------------------------------------------- 30

stage_dotfiles() {
  stage_banner "30 dotfiles"

  if [[ -z $DOTFILES_REMOTE ]]; then
    warn "DOTFILES_REMOTE is not set in $BOOTSTRAP_CONFIG -- skipping"
    return 0
  fi

  local dot=(git --git-dir="$DOTFILES_DIR" --work-tree="$HOME")

  if [[ -d $DOTFILES_DIR ]]; then
    ok "$DOTFILES_DIR already cloned"
  else
    run git clone --bare "$DOTFILES_REMOTE" "$DOTFILES_DIR"
    did "cloned dotfiles"
  fi

  if (( DRY_RUN )); then
    printf '%s  would run:%s checkout into $HOME, backing up collisions\n' "$C_DIM" "$C_RESET"
  else
    # A bare clone over a fresh $HOME collides with the files useradd created
    # (.bashrc, .bash_profile -- commonly tracked). Back them up, then force.
    if ! "${dot[@]}" checkout 2>/dev/null; then
      local backup="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$backup"
      warn "checkout collided -- backing up existing files to $backup"
      "${dot[@]}" checkout 2>&1 \
        | grep -E '^\s+\.' \
        | awk '{print $1}' \
        | while read -r f; do
            mkdir -p "$backup/$(dirname "$f")"
            mv "$HOME/$f" "$backup/$f"
          done
      "${dot[@]}" checkout
    fi
    ok "dotfiles checked out into \$HOME"
  fi

  # core.bare=true makes git ignore --work-tree for index operations, which is
  # why `<alias> ls-files` returns nothing on a bare dotfiles repo. These two
  # settings are what make day-to-day use behave.
  run "${dot[@]}" config --local status.showUntrackedFiles no
  # A bare clone has no fetch refspec, so origin/master never exists locally and
  # a bare `pull`/`push` fails. Set it so new machines don't inherit that quirk.
  run "${dot[@]}" config --local remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  did "dotfiles repo configured (showUntrackedFiles=no, fetch refspec set)"

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

# --------------------------------------------------------------------------- 35

stage_secrets() {
  stage_banner "35 secrets"

  if [[ -z $SECRETS_REMOTE ]]; then
    info "SECRETS_REMOTE not set -- skipping"
    return 0
  fi

  if [[ -d $SECRETS_DIR ]]; then
    ok "$SECRETS_DIR already cloned"
  else
    run git clone "$SECRETS_REMOTE" "$SECRETS_DIR"
    did "cloned secrets repo"
  fi

  (( DRY_RUN )) || {
    local kdbx
    kdbx="$(find "$SECRETS_DIR" -maxdepth 2 -name '*.kdbx' 2>/dev/null | head -1)"
    [[ -n $kdbx ]] && ok "vault found: $(basename "$kdbx")" \
                   || info "no .kdbx found under $SECRETS_DIR"
  }

  have keepassxc && ok "keepassxc installed" || warn "keepassxc not installed"

  pause_for "Unlock your password vault." \
    "The master password comes from your memory. It is the one step in this" \
    "entire chain that cannot be automated, and everything downstream that" \
    "needs a credential depends on it." || true
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
  if have fc-cache; then
    run fc-cache -f
    did "font cache rebuilt"
  fi

  # X session entry point.
  if [[ -f $HOME/.xinitrc ]]; then
    ok ".xinitrc present ($(grep -cE '^[^#]' "$HOME/.xinitrc" 2>/dev/null || echo 0) active lines)"
  else
    warn "no ~/.xinitrc -- startx will not launch your WM"
    todo "expected it to arrive with the dotfiles; check the tree"
  fi

  # User units must survive logout, or anything you enable dies with the session.
  if loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
    ok "lingering already enabled"
  else
    info "enabling lingering so systemd user units survive logout"
    run sudo loginctl enable-linger "$USER"
    did "lingering enabled"
  fi
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

  if (( DRY_RUN )); then
    printf '%s  would run:%s stack build && xmonad --recompile in %s\n' \
      "$C_DIM" "$C_RESET" "$XMONAD_DIR"
    return 0
  fi

  [[ -f $XMONAD_DIR/stack.yaml.lock ]] \
    && ok "stack.yaml.lock present (build is reproducible)" \
    || warn "no stack.yaml.lock -- the build may resolve different package versions"

  ( cd "$XMONAD_DIR" && stack build )
  ok "xmonad config project compiled"

  if have xmonad; then
    if ( cd "$XMONAD_DIR" && xmonad --recompile ); then
      ok "xmonad --recompile clean"
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
    info "remote vaults available to bind to:"
    run_interactive "$ob" sync-list-remote || warn "could not list remote vaults"

    pause_for "Bind the local vault to a remote." \
      "About to run:  ob sync-setup --path $OBSIDIAN_VAULT" \
      "It will ask which remote vault to connect to. If you have none yet," \
      "skip this and run 'ob sync-create-remote' first." \
      && run_interactive "$ob" sync-setup --path "$OBSIDIAN_VAULT" \
      || warn "sync-setup skipped or failed"
  fi

  run_interactive "$ob" sync-status --path "$OBSIDIAN_VAULT" || \
    warn "sync-status reported a problem -- the daemon may not start cleanly"

  pause_for "Check the desktop app is not also syncing this vault." \
    "If $OBSIDIAN_VAULT/.obsidian/core-plugins.json has \"sync\": true AND you" \
    "ever log the desktop app into Sync, you would have two sync clients on one" \
    "device -- which the docs explicitly forbid. Set it to false." || true
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

  if (( DRY_RUN )); then
    printf '%s  would write:%s %s (ExecStart -> %s/bin/node)\n' \
      "$C_DIM" "$C_RESET" "$unit" "$node_root"
  else
    [[ -f $unit ]] && cp -a "$unit" "$unit.bak-$(date +%Y%m%d-%H%M%S)"
    cat > "$unit" <<EOF
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
    ok "wrote $unit"
  fi

  run systemctl --user daemon-reload

  # Starting before `ob login` has run just crash-loops the unit, so gate on the
  # credential store rather than optimistically enabling.
  if [[ -f $XDG_CONFIG_HOME/obsidian-headless/auth_token ]]; then
    run systemctl --user enable --now obsidian-sync.service
    did "obsidian-sync enabled and started"
  else
    warn "no obsidian-headless auth token -- NOT starting the daemon"
    todo "run the obsidian stage first, then: ./bootstrap.sh --redo services"
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
  check "lingering enabled"             "loginctl show-user '$USER' | grep -q Linger=yes"

  if [[ -n $OBSIDIAN_VAULT ]]; then
    check "obsidian auth token"         "[ -f '$XDG_CONFIG_HOME/obsidian-headless/auth_token' ]"
    check "obsidian-sync unit active"   "systemctl --user is-active obsidian-sync.service"
  fi

  if (( fails )); then
    warn "$fails check(s) failed -- see the stage they belong to, then re-run that stage"
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

usage() { sed -n '3,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
}

main "$@"
