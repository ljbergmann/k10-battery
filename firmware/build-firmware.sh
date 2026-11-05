#!/usr/bin/env bash
# Builds the K10 Battery firmware for a Keychron K10 Pro.
#
#   ./firmware/build-firmware.sh iso/rgb        # one variant
#   ./firmware/build-firmware.sh all            # all six variants
#
# Variants: ansi/rgb ansi/white iso/rgb iso/white jis/rgb jis/white
# Needs: git, Docker (uses the official ghcr.io/qmk/qmk_cli image).
# Output: firmware/build/k10_pro_<variant>_battery.bin
set -euo pipefail

# Keychron's official QMK source (branch bluetooth_playground), pinned.
KEYCHRON_REPO=https://github.com/Keychron/qmk_firmware.git
KEYCHRON_COMMIT=618127a725a1773e85f13455602cf6f72ab4de17
QMK_IMAGE=ghcr.io/qmk/qmk_cli:latest

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/firmware/.qmk"
OUT="$ROOT/firmware/build"
ALL="ansi/rgb ansi/white iso/rgb iso/white jis/rgb jis/white"

VARIANTS=${1:-}
if [[ -z "$VARIANTS" ]]; then
  echo "usage: $0 <variant|all>   (variants: $ALL)"; exit 1
fi
[[ "$VARIANTS" == all ]] && VARIANTS=$ALL
for v in $VARIANTS; do
  [[ " $ALL " == *" $v "* ]] || { echo "unknown variant: $v"; exit 1; }
done

# 1. Fetch Keychron's source at the pinned commit (once).
if [[ ! -d "$WORK/.git" ]]; then
  echo "==> Fetching Keychron QMK source @ ${KEYCHRON_COMMIT:0:7}"
  git init -q "$WORK"
  git -C "$WORK" remote add origin "$KEYCHRON_REPO"
  git -C "$WORK" fetch -q --depth 1 origin "$KEYCHRON_COMMIT"
  git -C "$WORK" checkout -q FETCH_HEAD
  git -C "$WORK" submodule update -q --init --recursive --depth 1
fi

mkdir -p "$OUT"
for v in $VARIANTS; do
  # 2. New keymap "battery" = Keychron's stock VIA keymap + battery_broadcast.c
  KM="$WORK/keyboards/keychron/k10_pro/$v/keymaps"
  rm -rf "$KM/battery"
  cp -R "$KM/via" "$KM/battery"
  cp "$ROOT/firmware/battery_broadcast.c" "$KM/battery/"
  printf '\nSRC += battery_broadcast.c\n' >> "$KM/battery/rules.mk"

  # 3. Compile inside the official QMK container.
  echo "==> Building keychron/k10_pro/$v:battery"
  docker run --rm -v "$WORK":/qmk_firmware -w /qmk_firmware "$QMK_IMAGE" sh -c "
    /opt/uv/tools/qmk/bin/python3 -m pip install -q -r requirements.txt >/dev/null 2>&1
    make -s keychron/k10_pro/$v:battery" | grep -E 'error|warning:|Creating binary' || true

  name="keychron_k10_pro_${v//\//_}_battery.bin"
  [[ -f "$WORK/$name" ]] || { echo "build failed for $v"; exit 1; }
  mv "$WORK/$name" "$OUT/k10_pro_${v//\//_}_battery.bin"
  echo "    -> firmware/build/k10_pro_${v//\//_}_battery.bin"
done
