# K10 Battery

**See the battery level of your Keychron K10 Pro on macOS, in the menu bar and in Apple's own Batteries widget.**

Over Bluetooth, the Keychron K10 Pro never tells your Mac how much charge is left. A Logitech mouse or AirPods show up in the Batteries widget, but the K10 doesn't, and the only way to check is **Fn + B** on the keyboard itself.

K10 Battery fixes that with two parts:

1. **A small firmware addition** for the keyboard, built on Keychron's own open-source QMK firmware. It sends the battery level to the Mac.
2. **A macOS menu bar app** that receives it, shows it in the menu bar, and registers the keyboard with macOS so it appears in the **Batteries widget** next to your other devices.

> Community project. Not affiliated with or endorsed by Keychron. Flashing firmware is at your own risk, though it is easy to undo (see [Going back to stock](#going-back-to-stock-firmware)).

---

## Contents

- [Compatibility](#compatibility)
- [How it works](#how-it-works)
- [What you need](#what-you-need)
- [Step 1 – Get the firmware](#step-1--get-the-firmware)
- [Step 2 – Flash the keyboard](#step-2--flash-the-keyboard)
- [Step 3 – Install the app](#step-3--install-the-app)
- [Step 4 – Grant permission and check it works](#step-4--grant-permission-and-check-it-works)
- [Using it](#using-it)
- [Troubleshooting](#troubleshooting)
- [Going back to stock firmware](#going-back-to-stock-firmware)
- [Limitations and caveats](#limitations-and-caveats)
- [Privacy](#privacy)
- [Repository layout](#repository-layout)
- [Related work](#related-work)
- [License](#license)

---

## Compatibility

| Keyboard | Layout / backlight | USB Product ID | Status |
|---|---|---|---|
| K10 Pro | ISO, RGB | `0x02A1` | ✅ **Tested on hardware** |
| K10 Pro | ANSI, RGB | `0x02A0` | Builds; not yet tested on hardware |
| K10 Pro | JIS, RGB | `0x02A2` | Builds; not yet tested on hardware |
| K10 Pro | ANSI, white | `0x02A3` | Builds; not yet tested on hardware |
| K10 Pro | ISO, white | `0x02A4` | Builds; not yet tested on hardware |
| K10 Pro | JIS, white | `0x02A5` | Builds; not yet tested on hardware |

Not sure which one you have? On your Mac, open  → **About This Mac** → **More Info…** → **System Report** → **Bluetooth** (or **USB** when connected by cable) and look for *Keychron K10 Pro* and its **Product ID**.

- **macOS:** 14 Sonoma or newer. Tested on macOS 27.2 (Apple Silicon).
- **Connection:** the battery level is sent over **Bluetooth**. On cable the keyboard runs on USB power, so there's nothing to report.
- **Other Keychron "Pro" boards** use the same Bluetooth chip (CKBT51), so the firmware part should port easily, but only the K10 Pro is supported here.

---

## How it works

```
 Keychron K10 Pro                                Mac
┌──────────────────────────┐   Bluetooth   ┌────────────────────────────────┐
│ STM32 (QMK firmware)     │               │ K10 Battery.app                │
│  battery_broadcast.c     │   key report  │  reads the K10's HID reports   │
│  reads battery %  ───────┼──────────────▶│  decodes the battery marker    │
│  as reserved key codes   │               │        │                       │
│ CKBT51 Bluetooth module  │               │        ├─▶ menu bar: 68 %      │
│  (closed firmware)       │               │        └─▶ registers a power   │
└──────────────────────────┘               │            source with macOS   │
                                           │            → Batteries widget  │
                                           └────────────────────────────────┘
```

**The problem.** The keyboard has two chips. The main chip runs open-source QMK firmware and knows the battery level: it uses it for Fn + B. The Bluetooth chip (Keychron CKBT51) has closed firmware and gives the host no way to read the battery level. Its HID descriptor has no battery field, and it zeroes the "reserved" byte of keyboard reports. That rules out the obvious hiding places.

**The trick.** About once a minute while you type, the firmware sends one extra keyboard report made of HID usages that the USB HID specification marks as **reserved** (`0xA5–0xAF`, `0xDE`, `0xDF`). No operating system maps them to a key, so nothing is typed. A release follows ~30 ms later.

| Key slot | Value | Meaning |
|---|---|---|
| 1 | `0xDF` / `0xDE` | marker: on battery / USB power connected (charging) |
| 2 | `0xA5` + tens | tens digit (0–10) |
| 3 | `0xA5` + units | units digit (0–9) |

For example, 68% on battery is sent as `DF AB AD`.

The firmware sends this only **over Bluetooth**, only when **no key is held**, and only if you've typed **in the last 5 minutes**, so it never keeps the keyboard awake on its own.

**The Mac side.** The app opens the K10 through IOKit HID (that's why it needs the *Input Monitoring* permission) and looks only for that exact pattern. It then:

- shows the level in the **menu bar**, with a median of the last 5 readings to smooth out voltage jitter;
- registers a Bluetooth **accessory power source** with macOS (`IOPSCreatePowerSource`), the same mechanism that puts the MX Master and AirPods into Apple's **Batteries widget** and into `pmset -g accps`;
- sends a **notification at 15%**.

---

## What you need

- A Keychron **K10 Pro** (see [Compatibility](#compatibility)) and a **USB-C data cable**
- A small tool to press the reset button: a toothpick, SIM tool or straightened paper clip
- Optional: a keycap puller
- On the Mac:
  - **Xcode Command Line Tools**, to build the app: `xcode-select --install`
  - **Homebrew** and **dfu-util**, to flash: `brew install dfu-util`
  - **Docker Desktop**, only if you build the firmware yourself

---

## Step 1 – Get the firmware

### Option A – Download (easiest)

Download the `.bin` for your variant from the [latest release](../../releases/latest), for example `k10_pro_iso_rgb_battery.bin`. Each release lists SHA-256 checksums; check yours with:

```bash
shasum -a 256 k10_pro_iso_rgb_battery.bin
```

### Option B – Build it yourself

This needs Docker running. The script downloads Keychron's official source at a pinned commit, adds `battery_broadcast.c` to the stock VIA keymap, and compiles it in the official QMK container:

```bash
git clone https://github.com/ljbergmann/k10-battery.git
cd k10-battery
./firmware/build-firmware.sh iso/rgb     # or: ansi/rgb, iso/white, ... or: all
```

The result is in `firmware/build/`. The first run takes a few minutes while it downloads the source and container.

---

## Step 2 – Flash the keyboard

> ⚠️ **Flashing resets your VIA / Keychron Launcher key remaps and macros to defaults.** Note them down first. Bluetooth pairings are stored in the Bluetooth chip and **are kept**.

**Find the switches** on the back edge of the keyboard, next to the USB-C port:

- **OS switch** (Mac / Windows): leave it where it is.
- **Mode switch** (Bluetooth / Off / Cable): set it to **Cable**.

**Put the keyboard into DFU (flashing) mode:**

1. **Unplug** the USB cable from the keyboard.
2. **Pull off the spacebar keycap.** Lift it straight up, gently, so the stabilizers come off evenly. Underneath, on the circuit board, there's a small **reset button**.
3. **Press and hold** the reset button with your toothpick or SIM tool.
4. While holding it, **plug the cable back in** (directly into the Mac if you can; docks and hubs can be unreliable for this). **Release after about 2 seconds.**
5. The keyboard should stay **completely dark**: no backlight, no LEDs. That's DFU mode. If the backlight comes on, it booted normally; unplug and try again.

**Flash:**

```bash
./firmware/flash.sh k10_pro_iso_rgb_battery.bin
```

The script waits until it sees the keyboard in DFU mode, then flashes (about 10 seconds) and restarts it. You should see `File downloaded successfully` and `Done`.

**Finish:**

1. Unplug the cable and put the spacebar back on.
2. Set the mode switch to **Bluetooth**. The keyboard reconnects to your Mac by itself.

---

## Step 3 – Install the app

```bash
cd k10-battery/app
./build.sh
cp -R "K10 Battery.app" /Applications/
open "/Applications/K10 Battery.app"
```

`build.sh` compiles the app with `swiftc`; no Xcode project is needed. On first launch from `/Applications`, it turns on **Launch at login** automatically. You can turn that off in its menu.

> **About signing:** if you have an *Apple Development* certificate in your keychain, `build.sh` signs with it, so macOS remembers the Input Monitoring permission across rebuilds. Without one it falls back to an ad-hoc signature. That works too, but after **every rebuild** you have to remove K10 Battery from *Input Monitoring* (select it, click **−**) and allow it again.

---

## Step 4 – Grant permission and check it works

1. On first launch, macOS asks to allow **Input Monitoring** for K10 Battery. Click **Open System Settings** and switch **K10 Battery** on. If macOS offers **Quit & Reopen**, accept.
   - No prompt? Click the keyboard icon in the menu bar → **Open Input Monitoring Settings…**
2. **Type on the K10 over Bluetooth** for a minute. After reconnecting, the keyboard first takes ~15 voltage samples (up to ~45 s), then sends its first reading during a short pause in typing.
3. The **menu bar** now shows e.g. `⌨︎ 🔋 68%`, and **Keychron K10 Pro** appears in the **Batteries widget**.

To add the widget: right-click the desktop → **Edit Widgets…**, or open Notification Center and click **Edit Widgets**, then add **Batteries**.

You can also check from Terminal:

```bash
pmset -g accps
# -Keychron K10 Pro (id=…)   68%; discharging present: true
```

---

## Using it

- **Menu bar:** keyboard icon, battery icon and percentage; a ⚡ means charging. Click it for details: connection, level, when it was last updated, a launch-at-login switch, and Quit.
- **Batteries widget:** lists *Keychron K10 Pro* while the keyboard is connected and the app is running.
- **Low battery:** a notification at **15%** (once per discharge).
- **Charging:** plug in the cable *while the switch is on Bluetooth* and the level shows as charging. On **Cable** mode the keyboard is a USB keyboard and no battery is reported.
- **Idle:** after ~5 minutes without typing, the keyboard stops sending (to save battery). The app keeps the last value and shows how old it is; the next reading comes shortly after you start typing again.
- **Fn + B** on the keyboard still works as before.

---

## Troubleshooting

**The menu bar shows "–" or "Waiting for the keyboard to report…"**
- Make sure you're on **Bluetooth** (not Cable) and **type for a minute**. Readings are only sent while you're typing.
- Check **System Settings → Privacy & Security → Input Monitoring → K10 Battery** is **on**. If you rebuilt the app with an ad-hoc signature, the switch may be **on but stale**: remove the entry with **−**, relaunch the app, and allow it again.
- Run the probe from Terminal. Your terminal app needs Input Monitoring permission too:
  ```bash
  swift tools/k10-battery-probe.swift
  ```
  It prints `BATTERY REPORT: 68% …` once the keyboard sends one. If it never does, the firmware isn't the K10 Battery build; reflash.

**The flash script waits forever.** The keyboard isn't in DFU mode. It must stay **dark** after plugging in. Hold the reset button *before* plugging in, plug in directly (not through a dock), and try another cable; some USB-C cables are charge-only.

**The Batteries widget doesn't list the keyboard but the menu bar does.** The widget can be slow to refresh; remove and re-add it. Check `pmset -g accps`: if the K10 is listed there, macOS has it.

**I noticed something odd while typing (a beep, stray character) about once a minute.** That would mean an app reacts to the reserved key codes. Please [open an issue](../../issues) with the app name and macOS version. You can [go back to stock](#going-back-to-stock-firmware) anytime.

---

## Going back to stock firmware

- **Keychron's official firmware:** download it for your model from [keychron.com](https://www.keychron.com/pages/firmware-and-json-files-of-the-keychron-qmk-k-pro-and-k-max-series-keyboards) (or use [Keychron Launcher](https://launcher.keychron.com)), then flash it the same way:
  ```bash
  ./firmware/flash.sh <keychron-firmware>.bin
  ```
- **Uninstall the app:** quit it from its menu, delete `/Applications/K10 Battery.app`, and remove it from *Input Monitoring* and *Login Items* in System Settings.

---

## Limitations and caveats

- **Approximate level.** The percentage comes from Keychron's own voltage-based estimate, the same one Fn + B uses. It moves in steps and depends on the backlight load.
- **Updates once a minute, only while typing.** This is by design, to avoid waking the keyboard.
- **Keychron firmware updates remove it.** Re-flash K10 Battery after installing an official update.
- **Uses an undeclared macOS API.** `IOPSCreatePowerSource` is exported by IOKit and documented in `IOPSKeys.h`, but its prototype isn't in the public headers. A future macOS could change it; the menu bar display would keep working.
- **Reserved HID usages.** macOS has no mapping for them and ignores them; this was confirmed on macOS 27.2. Other systems (Windows, Linux, iPadOS) and remapping tools such as Karabiner-Elements haven't been tested.
- **A key pressed within ~60 ms after a broadcast** may be released early by the follow-up release report. It's rare, and the next key event corrects it.

---

## Privacy

- The app reads input reports **from the K10 Pro only**, and only to find the battery pattern described above. Key data is **never stored, logged or transmitted**. The app has no network code.
- It stores just the last level, charging state and timestamp (in `~/Library/Preferences/local.k10battery.plist`).

---

## Repository layout

```
app/
  Sources/            SwiftUI menu bar app
    HIDBatteryReader.swift      reads & decodes the K10's HID reports
    BatteryModel.swift          smoothing, persistence, notifications, login item
    PowerSourcePublisher.swift  registers the keyboard with macOS (Batteries widget)
    App.swift                   menu bar UI
  Info.plist
  build.sh            builds "K10 Battery.app"
firmware/
  battery_broadcast.c QMK code added to Keychron's stock VIA keymap
  build-firmware.sh   builds .bin files (Docker, pinned Keychron source)
  flash.sh            flashes a .bin via dfu-util
tools/
  k10-battery-probe.swift   troubleshooting probe
```

---

## Related work

- **[bkovacev/keychron-macos](https://github.com/bkovacev/keychron-macos)** solves the same problem for the K10 Pro and K/Q Pro boards, independently and earlier. Its [research notes](https://github.com/bkovacev/keychron-macos/blob/main/docs/RESEARCH.md) are an excellent deep dive into the CKBT51 and the macOS power-source registry. It differs from K10 Battery in a few ways:
  - it sends the level as an unassigned *Consumer* usage instead of reserved keyboard usages;
  - it also reads exact voltage over the cable via raw HID;
  - it adds backlight control from macOS.

  If you want those features, have a look.
- **[thementalcoding/keychron-pro-firmware](https://github.com/thementalcoding/keychron-pro-firmware)**: community Bluetooth reliability fixes for CKBT51 Pro boards (not battery related).

---

## License

**GPL-2.0-or-later.** The firmware part is derived from Keychron's QMK firmware (GPL-2.0-or-later), and the whole project uses the same license; see [LICENSE](LICENSE).

Keychron and K10 Pro are trademarks of Keychron. This project is not affiliated with Keychron.
