#!/usr/bin/env bash
# testvm-idle -- on surfboard, every 2 min: shut down a test VM nobody is using (tools/testvm idle: no lease renewed in
# 10 min and no ssh/VNC connection from a client younger than 2 h). station-maintenance fleet 37/39, Ben 2026-11-18.
exec "$(dirname "$(readlink -f "$0")")/../../tools/testvm" idle
