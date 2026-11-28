#!/usr/bin/env bash
# comms-check -- daily 07:30 on beast-arch: the morning /comms-check, so Ben's reply drafts wait for him (Ben
# 2026-11-27; station-maintenance fleet 53). The logic is personal-comms' own script (personal-comms 2f3ea52): it
# prompts that repo's idle Claude pane, retries for 2 h, always exits 0. Drafts are saved, nothing is sent.
exec "$HOME/projects/personal-comms/bin/comms-check-morning"
