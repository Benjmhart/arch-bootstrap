# arch-bootstrap

Rebuilds a workstation's **user-space environment** on top of an Arch install that
already boots and has working hardware.

It is deliberately *not* a "reinstall my machine" script. It installs applications,
toolchains, dotfiles and user services. It **detects** hardware and tells you what it
would install, rather than replaying one machine's driver set onto another.

## Why the split matters

The obvious way to write this is `pacman -Qqe > pkglist.txt` on the old box and
`pacman -S - < pkglist.txt` on the new one. That fails in two directions at once:

- On **different** hardware it installs the wrong drivers — an AMD box's
  `xf86-video-amdgpu` and `vulkan-radeon` on an Intel laptop, `intel-ucode` on an
  AMD chip.
- On the **same** hardware it duplicates what the Arch installer already did.

So the package list is split in two:

| File | Role |
|---|---|
| `pkglist-userspace.txt` | installed verbatim by stage 10 — safe to replay anywhere |
| `pkglist-aur.txt` | AUR packages, installed by stage 20 |
| `pkglist-hardware.txt` | **reference only** — what the box these lists came from needed, so the detection stage has something to check itself against |

Stage 15 inspects the actual machine (CPU vendor, `lspci`, `/sys/firmware/efi`,
`/proc/asound/cards`, RAM size), reports what it found and what it *would* install,
and asks before acting. NVIDIA and hybrid graphics are never guessed at — they go to
the manual checklist, because "open vs proprietary vs nouveau" is a real decision.

Substitute your own package lists; the detection logic is independent of them.

## Usage

```sh
git clone https://github.com/you/arch-bootstrap.git
cd arch-bootstrap
./bootstrap.sh --dry-run     # see everything it would do, change nothing
./bootstrap.sh               # for real
```

On first run it will ask for your dotfiles remote and a few paths, and write them to
`bootstrap.conf` (gitignored, mode 600). Nothing personal lives in the script itself.

```
--list           show stages and which are already done
--dry-run        print what would happen, change nothing
--resume         skip stages already recorded complete
--only a,b       run just these stages
--skip a,b       run everything except these
--redo a         clear a stage's completion mark and re-run it
--yes            assume yes for optional prompts
--reset-state    forget all completion marks
```

## Stopping and restarting

Every stage is idempotent, and completion is recorded per-stage in
`${XDG_STATE_HOME:-~/.local/state}/arch-bootstrap/completed-stages`.

This matters more than it sounds. Bootstrapping a machine involves dropping to
another TTY to check something, or discovering you need to fix a remote before the
clone will work. Ctrl-C out, do what you need, and run `./bootstrap.sh --resume` —
finished stages will not repeat. If a stage fails it is *not* marked done, so a
resume picks up exactly where it broke.

`--redo services` is the intended way to regenerate a unit after an upgrade changes
the paths underneath it.

## Interactive steps

Some things cannot be automated, and the script stops and walks you through them
rather than printing a checklist at the end and hoping:

- **Registering an SSH public key** with your git host (stage 05). If you have no key
  it offers to generate one, prints the public half, and waits — then re-checks, up
  to three times.
- **Unlocking your password vault** (stage 35).
- **`ob login` and `ob sync-setup`** for Obsidian sync (stage 55), including listing
  the available remote vaults so you can pick one, and a `sync-status` check
  afterwards.

Each pause accepts Enter to continue or `s` to skip that step.

## Stages

```
00-preflight   Arch? network? sudo? config file? Writes bootstrap.conf on first run.
05-ssh         HARD GATE. Everything below needs SSH auth to your git host.
10-packages    pacman -S --needed from pkglist-userspace.txt
15-hardware    DETECT and report: microcode, GPU, boot mode, audio, bluetooth, RAM
20-aur         build yay from source first, then the rest of the AUR list
25-toolchains  rustup, stack, go, nvm+node (pinned), mise, luarocks, gem
30-dotfiles    bare clone, collision-safe checkout into $HOME, fix repo config
35-secrets     clone the secrets repo; prompt to unlock the vault
40-session     login shell, NetworkManager, font cache, .xinitrc check
50-xmonad      stack build + xmonad --recompile  (slow: GHC from scratch)
55-obsidian    interactive: ob login, sync-setup, sync-status
60-services    GENERATE systemd user units against resolved paths, then enable
80-verify      self-check every stage's observable result
90-manual      printed checklist of what a script must not automate
```

Stages that do not apply are skipped, not failed: no `OBSIDIAN_VAULT` set means the
Obsidian stages no-op, no `$XMONAD_DIR` means stage 50 no-ops.

## Two things worth stealing even if you don't use this

**Generate units, don't restore them.** A systemd user unit that hardcodes
`/home/you/.nvm/versions/node/v24.15.0/bin/node` works exactly until your next nvm
upgrade. Stage 60 globs for the current version and writes the unit against what it
finds, backing up any existing copy. Re-running that one stage is the repair.

**`XDG_CONFIG_HOME` must be exported before anything reads config.** If you use a
non-standard config root, this is the single easiest thing to get wrong — apps
silently scatter into `~/.config` and your dotfiles appear not to work. Note the
exception the script handles for you: systemd user units live in
`~/.config/systemd/user` *regardless*, because systemd does not honour
`XDG_CONFIG_HOME` for unit lookup.

## What it deliberately does not do

Partitioning, bootloader, user creation, and entering any secret. It checks for
these and fails loudly rather than pretending.

The terminal dependency of the whole chain is your vault's master password, which
comes from your memory. Worth confirming you have an out-of-band account recovery
route that is *not* inside the vault — otherwise total-loss recovery deadlocks:
git-host access lives in the vault, and the vault lives in a repo that needs
git-host access.

## Status

The hardware detection, preflight, toolchain, session and service stages have been
exercised on a live machine via `--dry-run`. The stages that can only run on a
genuinely fresh install — packages, AUR, dotfiles checkout, secrets, xmonad build —
have not yet been run end to end. Treat the first real run as a test.

## License

MIT. See [LICENSE](LICENSE).
