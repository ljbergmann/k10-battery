#!/usr/bin/env bash
# Flashes a firmware .bin onto a Keychron K10 Pro that is in DFU mode.
#
#   ./firmware/flash.sh firmware/build/k10_pro_iso_rgb_battery.bin
#
# Put the keyboard in DFU mode first (see README, "Flashing"):
#   switch to Cable, unplug, hold the reset button under the spacebar,
#   plug in, release after ~2 s - the keyboard stays dark.
# Needs: dfu-util (brew install dfu-util)
set -euo pipefail
BIN=${1:-}
[[ -f "$BIN" ]] || { echo "usage: $0 <firmware.bin>"; exit 1; }
command -v dfu-util >/dev/null || { echo "dfu-util missing: brew install dfu-util"; exit 1; }

echo "Waiting for the keyboard in DFU mode (Ctrl-C to cancel)..."
until dfu-util -l 2>/dev/null | grep -q '0483:df11'; do sleep 1; done

echo "Flashing $BIN"
dfu-util -a 0 -d 0483:df11 -s 0x08000000:leave -D "$BIN"
echo "Done. Unplug, put the spacebar back, switch to Bluetooth."
