/* Copyright 2026 ljbergmann
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "quantum.h"

/* ---------------------------------------------------------------------------
 * Battery broadcast for the macOS menu bar app (K10 Battery).
 *
 * The CKBT51 Bluetooth module offers no battery channel to the host, and it
 * zeroes the reserved byte of keyboard reports, so the level is sent as a
 * short "press" of HID usages that the USB HID spec marks as RESERVED in the
 * Keyboard page (0xA5-0xAF, 0xDE-0xDF). No OS maps these to anything, so
 * nothing is typed. The press is released ~30 ms later.
 *
 *   keys[0] = 0xDE (charging) or 0xDF (on battery)   -> marker
 *   keys[1] = 0xA5 + tens  (0..10)
 *   keys[2] = 0xA5 + units (0..9)
 *   mods = 0, keys[3..5] = 0
 *
 * Sent only over Bluetooth, only when no key/modifier is held, only while
 * the keyboard is being used (activity in the last 5 min) so it never keeps
 * the keyboard or the link awake on its own.
 * ------------------------------------------------------------------------ */
#ifdef KC_BLUETOOTH_ENABLE
#    include "ckbt51.h"
#    include "bluetooth.h"
#    include "transport.h"
#    include "battery.h"
#    include "lpm.h"
#    include "report_buffer.h"

#    define BATT_BCAST_INTERVAL_MS 60000  // regular broadcast
#    define BATT_BCAST_FIRST_MS 4000      // first one after (re)connect
#    define BATT_BCAST_ACTIVE_MS 300000   // stop when idle this long
#    define BATT_BCAST_QUIET_MS 250       // no key events for this long
#    define BATT_RELEASE_MS 30            // release the marker after this

#    define BATT_USAGE_BASE 0xA5          // reserved 0xA5..0xAF
#    define BATT_MARK_CHARGING 0xDE       // reserved
#    define BATT_MARK_BATTERY 0xDF        // reserved

static uint32_t batt_bcast_timer   = 0;
static uint32_t batt_release_timer = 0;
static uint8_t  batt_release_left  = 0;
static bool     batt_bcast_sent    = false;
static bool     batt_was_conn      = false;

static void batt_send_raw(uint8_t k0, uint8_t k1, uint8_t k2) {
    uint8_t report[8] = {0, 0, k0, k1, k2, 0, 0, 0}; // mods, reserved, keys[6]
    ckbt51_send_keyboard(report);
}

static void batt_bcast_send(void) {
    uint8_t pct = battery_get_percentage();
    if (pct > 100) pct = 100;
    batt_send_raw(usb_power_connected() ? BATT_MARK_CHARGING : BATT_MARK_BATTERY,
                  BATT_USAGE_BASE + pct / 10, BATT_USAGE_BASE + pct % 10);
    batt_release_left  = 2; // send the release twice for safety
    batt_release_timer = timer_read32();
}

void housekeeping_task_user(void) {
    // Pending release of the marker "press" - always runs first.
    if (batt_release_left && timer_elapsed32(batt_release_timer) >= BATT_RELEASE_MS) {
        batt_send_raw(0, 0, 0);
        batt_release_left--;
        batt_release_timer = timer_read32();
        return;
    }
    if (batt_release_left) return;

    bool conn = get_transport() == TRANSPORT_BLUETOOTH && bluetooth_get_state() == BLUETOOTH_CONNECTED;

    if (conn && !batt_was_conn) {
        batt_bcast_timer = timer_read32();
        batt_bcast_sent  = false;
    }
    batt_was_conn = conn;
    if (!conn) return;

    uint32_t due = batt_bcast_sent ? BATT_BCAST_INTERVAL_MS : BATT_BCAST_FIRST_MS;
    if (timer_elapsed32(batt_bcast_timer) < due) return;

    if (battery_power_on_sample()) return;                            // voltage not settled yet
    if (last_input_activity_elapsed() > BATT_BCAST_ACTIVE_MS) return; // idle: stay quiet
    if (last_input_activity_elapsed() < BATT_BCAST_QUIET_MS) return;  // typing right now
    if (has_anykey(keyboard_report) || has_anymod()) return;          // something held
    if (!report_buffer_is_empty()) return;                            // queued reports pending

    batt_bcast_send();
    batt_bcast_sent  = true;
    batt_bcast_timer = timer_read32();
}
#endif
