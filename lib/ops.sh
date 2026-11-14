# lib/ops.sh: the shared helpers for every script that asks Ben for a password or reports to him: tools/fleet (fpush)
# and the one-off scripts Claude writes ($OPS/<host>-<topic>-<date>.sh). ~/.local/lib/ops.sh (dotfiles) links here.
#   . ~/.local/lib/ops.sh || exit 1
# Ben's rules (2026-11-14), every script, always:
#  1. Passwords have fixed names (SECRET_NAMES below) and every prompt uses that name, with what it is for.
#  2. Each password is asked once per run (a NEW one, being set, is typed twice to confirm: new_secret) and reused for every machine and step (ask_secret caches it).
#  3. A wrong password is caught and asked again, where that costs nothing. The login password is checked with
#     unix_chkpwd (pam_unix's own helper: no pam_faillock count, unlimited tries) BEFORE it reaches sudo, whose
#     failures lock it (3 in 15 min). The keyring unlock refuses a wrong one without any lockout too.
#  4. Lines that need Ben stand out: green ok, yellow ATTENTION, red FAILED, each with a fixed prefix
#     (ok / !! / !!!) so `grep '!!'` finds them in the log, colour or not. Emoji for fun, progress bars for waits.

# --- 4. output ------------------------------------------------------------------------------------------------------
_ops_colors() { _G=$'\e[1;32m' _Y=$'\e[1;33m' _R=$'\e[1;31m' _B=$'\e[1;36m' _0=$'\e[0m'; }
if [[ -t 1 || -n ${OPS_COLOR:-} ]]; then _ops_colors; else _G="" _Y="" _R="" _B="" _0=""; fi
step()   { printf '\n%s▶  %s  %s%s\n' "$_B" "$(date +%T)" "$*" "$_0"; }
ok()     { printf '%sok   ✅ %s%s\n' "$_G" "$*" "$_0"; }
note()   { printf '     %s\n' "$*"; }
attn()   { printf '%s!!   ⚠️  ATTENTION: %s%s\n' "$_Y" "$*" "$_0"; }
fail()   { printf '%s!!!  ❌ FAILED: %s%s\n' "$_R" "$*" "$_0"; exit 1; }
finish() { printf '\n%s🎉 %s%s\n' "$_G" "$*" "$_0"; }
# ops_log NAME: everything from here also goes to $OPS/NAME.log, colours kept (read it with `less -R`).
ops_log() { OPS_LOG=$OPS/$1.log; OPS_COLOR=1; _ops_colors; exec > >(tee -a "$OPS_LOG") 2>&1; step "🦄 start (log: $OPS_LOG)"; }

# bar CUR TOTAL [LABEL]: a progress bar redrawn in place on the terminal; the finished bar is printed as a normal line
# (so the log keeps it). Without a terminal (tests, cron) only the finished line appears.
bar() {
  local c=$1 n=$2 w=24 f a b s; (( n > 0 )) || n=1; (( c > n )) && c=$n; f=$(( c * w / n ))
  printf -v a '%*s' "$f" ''; printf -v b '%*s' $(( w - f )) ''
  s="${a// /█}${b// /░} $(( c * 100 / n ))%  $c/$n ${3:-}"
  { printf '\r\e[K%s' "$s" >/dev/tty; } 2>/dev/null
  if (( c >= n )); then { printf '\r\e[K' >/dev/tty; } 2>/dev/null; printf '%s📊 %s%s\n' "$_B" "$s" "$_0"; fi
}
# bar_clear: wipe the bar's line before printing something else mid-wait.
bar_clear() { { printf '\r\e[K' >/dev/tty; } 2>/dev/null; }

# --- 1. the names ---------------------------------------------------------------------------------------------------
declare -A SECRET_NAMES=(
  [login]="login password (user ben: sudo and the keyring; the same on every machine)"
  [disk]="disk passphrase (LUKS, at boot)"
  [pin]="YubiKey PIN (FIDO2)"
  [fleetkey]="fleet key passphrase (fpush's ssh key, ~/.ssh/id_ed25519_fleet)"
  [vault]="KeePassXC master password (Passwords.kdbx)"
)
declare -A _SECRET=()

# --- 2. asked once --------------------------------------------------------------------------------------------------
# ask_secret NAME [again]: prints nothing; the secret is in "${_SECRET[NAME]}". Asks only if not already known this run.
# Reads $OPS_SECRET_IN (default the terminal; tools/fleet uses stdin, which its tests feed).
ask_secret() {
  local n=$1 again=${2:-} s
  [[ -n ${SECRET_NAMES[$n]:-} ]] || fail "ask_secret: unknown password name '$n' (add it to SECRET_NAMES)"
  [[ -n ${_SECRET[$n]:-} && -z $again ]] && return 0
  IFS= read -rsp "🔑 ${again:+(again) }${SECRET_NAMES[$n]}: " s <"${OPS_SECRET_IN:-/dev/tty}"; echo >&2
  _SECRET[$n]=$s
}
# new_secret NAME [FOR]: a password being SET (a new disk, a new key): typed twice, and when the two differ it is asked
# again (empty gives up: exit 3). The result is in "${_SECRET[NAME]}". Without a terminal on $OPS_SECRET_IN (tests),
# one line is read and there is no second entry.
new_secret() {
  local n=$1 for=${2:+ for $2} in=${OPS_SECRET_IN:-/dev/tty} a b
  [[ -n ${SECRET_NAMES[$n]:-} ]] || fail "new_secret: unknown password name '$n' (add it to SECRET_NAMES)"
  if ! test -t 0 <"$in"; then IFS= read -r a <"$in" || true; _SECRET[$n]=$a; [[ -n $a ]] && return 0; return 3; fi
  while :; do
    IFS= read -rsp "🔑 NEW ${SECRET_NAMES[$n]}$for: " a <"$in"; echo >&2
    [[ -n $a ]] || { attn "no new ${SECRET_NAMES[$n]%% (*} given: skipped"; return 3; }
    IFS= read -rsp "🔑 the same again, to confirm: " b <"$in"; echo >&2
    [[ $a == "$b" ]] && { _SECRET[$n]=$a; return 0; }
    attn "the two entries differ: once more, both times (empty to give up)"
  done
}
forget_secrets() { local k; for k in "${!_SECRET[@]}"; do _SECRET[$k]=""; done; _SECRET=(); }
trap forget_secrets EXIT

# --- 3. retry -------------------------------------------------------------------------------------------------------
# with_secret NAME TRIES CMD...: runs CMD with the secret on stdin. CMD exits 3 for "wrong password" (asked again, up to
# TRIES times; 0 = until Ben gives up with an empty answer), 0 for success, anything else for another failure (no retry).
with_secret() {
  local n=$1 tries=$2 i=0 rc; shift 2
  ask_secret "$n"
  while :; do
    [[ -z ${_SECRET[$n]} ]] && { attn "no ${SECRET_NAMES[$n]%% (*} given: skipped"; return 3; }
    printf '%s' "${_SECRET[$n]}" | "$@"; rc=$?
    (( rc != 3 )) && return $rc
    i=$((i + 1))
    if (( tries && i >= tries )); then attn "${SECRET_NAMES[$n]%% (*} refused $i time(s): stopping (its limit, to stay clear of a lockout)"; return 3; fi
    attn "that ${SECRET_NAMES[$n]%% (*} was not accepted: try again (empty to give up)"
    ask_secret "$n" again
  done
}

# --- checks that cost nothing ---------------------------------------------------------------------------------------
# check_login [HOST] (secret on stdin): is it the login password, here or on HOST? Exit 0 yes, 3 no, 1 could not check.
# unix_chkpwd is what pam_unix itself runs; called directly it skips pam_faillock, so a wrong one locks nothing.
check_login() {
  local rc
  if [[ -z ${1:-} || $1 == "$(uname -n)" ]]; then { cat; printf '\0'; } | unix_chkpwd "$USER" nullok
  else { cat; printf '\0'; } | ssh -o BatchMode=yes "$1" 'unix_chkpwd "$USER" nullok'; fi
  rc=$?; (( rc == 0 )) && return 0; (( rc == 7 )) && return 3; return 1
}
# login_ok [HOST]: ask for the login password (once per run) until it checks out. Then "${_SECRET[login]}" is right.
login_ok() { with_secret login 0 check_login "${1:-}"; }
# sudo_login: the checked login password into sudo's ticket here (one try, it is already known to be right).
sudo_login() { login_ok || return 3; printf '%s\n' "${_SECRET[login]}" | sudo -S -p '' -k -v 2>/dev/null; }

# keyring_unlock HOST (secret on stdin): unlock HOST's login keyring through gnome-keyring's own D-Bus call (what a
# desktop login does). Exit 0 unlocked (or already was), 3 wrong password, 1 other. No lockout: safe to retry.
# Not `gnome-keyring-daemon --unlock`: that starts a second daemon instead of unlocking the running one (2026-11-14).
_KEYRING_PY='import sys
from gi.repository import Gio, GLib
pw = sys.stdin.buffer.read()
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
S, P, C = "org.freedesktop.secrets", "/org/freedesktop/secrets", "/org/freedesktop/secrets/collection/login"
def call(path, iface, method, args, rtype):
    return bus.call_sync(S, path, iface, method, args, GLib.VariantType(rtype), 0, 10000, None).unpack()
if not call(C, "org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", ("org.freedesktop.Secret.Collection", "Locked")), "(v)")[0]:
    sys.exit(0)
_, session = call(P, "org.freedesktop.Secret.Service", "OpenSession", GLib.Variant("(sv)", ("plain", GLib.Variant("s", ""))), "(vo)")
try:
    call(P, "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface", "UnlockWithMasterPassword",
         GLib.Variant("(o(oayays))", (C, (session, b"", pw, "text/plain"))), "()")
except GLib.Error as e:
    sys.exit(3 if "invalid" in e.message.lower() else 1)
sys.exit(0)'
keyring_unlock() {
  local h=$1 q
  q=$(printf '%q' "$_KEYRING_PY")
  if [[ $h == "$(uname -n)" ]]; then python3 -c "$_KEYRING_PY"
  else ssh -o BatchMode=yes "$h" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus python3 -c $q"; fi
}
keyring_locked() {  # true / false / ?
  ssh -o BatchMode=yes "$1" 'busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked 2>/dev/null | cut -d" " -f2' 2>/dev/null || echo "?"
}
