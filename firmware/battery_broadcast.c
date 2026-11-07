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
 * Battery broadcast for the macOS app "K10 Battery".
 *
 * The CKBT51 Bluetooth module offers no battery channel to the host, and it
 * zeroes the reserved byte of keyboard reports. So the level is sent as a
 * short "press" of HID usages that the USB HID Usage Tables mark as RESERVED
 * in the Keyboard page (0xA5-0xAF, 0xDE-0xDF). No OS maps these to anything,
 * so nothing is typed. ~30 ms later the real key state is restored.
 *
 *   keys[0] = 0xDE (USB power / charging) or 0xDF (on battery)   marker
 *   keys[1] = 0xA5 + tens of percent    (0..10)
 *   keys[2] = 0xA5 + units of percent   (0..9)
 *   keys[3..5] = battery voltage as three base-11 digits (0xA5 + digit):
 *              d = (millivolts - 3000) / 2, d = keys[3]*121 + keys[4]*11 + keys[5]
 *   mods = 0
 *
 * When it is sent:
 *   - over Bluetooth only, never while a key or modifier is held;
 *   - every 60 s while the keyboard is in use (activity in the last 5 min),
 *     first one ~4 s after (re)connecting;
 *   - on request: when the host switches the Kana LED from off to on
 *     (the app does this on launch / wake / when its menu is opened).
 * It never wakes the keyboard or keeps the link alive on its own.
 * ------------------------------------------------------------------------ */
#ifdef KC_BLUETOOTH_ENABLE
#    include "ckbt51.h"
#    include "bluetooth.h"
#    include "transport.h"
#    include "battery.h"
#    include "lpm.h"
#    include "report_buffer.h"

#    define BATT_BCAST_INTERVAL_MS 60000  // regular broadcast while in use
#    define BATT_BCAST_FIRST_MS 4000      // first one after (re)connect
#    define BATT_BCAST_ACTIVE_MS 300000   // stop when idle this long
#    define BATT_BCAST_QUIET_MS 250       // no key events for this long
#    define BATT_REQUEST_QUIET_MS 50      // on-request: shorter quiet period
#    define BATT_RELEASE_MS 30            // restore real key state after this

#    define BATT_USAGE_BASE 0xA5          // reserved 0xA5..0xAF (11 symbols)
#    define BATT_MARK_CHARGING 0xDE       // reserved
#    define BATT_MARK_BATTERY 0xDF        // reserved
#    define BATT_MV_BASE 3000
#    define BATT_MV_MAX_CODE 1330         // 11^3 - 1

static uint32_t batt_bcast_timer   = 0;
static uint32_t batt_release_timer = 0;
static uint8_t  batt_release_left  = 0;
static bool     batt_bcast_sent    = false;
static bool     batt_was_conn      = false;
static bool     batt_requested     = false;

static void batt_send(const uint8_t keys[6]) {
    uint8_t report[8] = {0}; // mods, reserved, keys[6]
    memcpy(report + 2, keys, 6);
    ckbt51_send_keyboard(report);
}

/* Re-send the keyboard's real 6KRO state (not just "all released"), so a key
 * pressed during the marker window is never released early. With NKRO the
 * 6KRO report is unused and empty, which is also what we send then. */
static void batt_restore(void) {
    uint8_t report[8] = {0};
#    ifdef NKRO_ENABLE
    if (!keymap_config.nkro)
#    endif
        memcpy(report, &keyboard_report->mods, sizeof(report));
    ckbt51_send_keyboard(report);
}

static void batt_bcast_send(void) {
    uint8_t  pct = battery_get_percentage();
    uint16_t mv  = battery_get_voltage();
    if (pct > 100) pct = 100;
    uint16_t d = mv > BATT_MV_BASE ? (mv - BATT_MV_BASE) / 2 : 0;
    if (d > BATT_MV_MAX_CODE) d = BATT_MV_MAX_CODE;

    uint8_t keys[6] = {
        usb_power_connected() ? BATT_MARK_CHARGING : BATT_MARK_BATTERY,
        BATT_USAGE_BASE + pct / 10,
        BATT_USAGE_BASE + pct % 10,
        BATT_USAGE_BASE + d / 121,
        BATT_USAGE_BASE + (d / 11) % 11,
        BATT_USAGE_BASE + d % 11,
    };
    batt_send(keys);
    batt_release_left  = 2; // restore twice for safety
    batt_release_timer = timer_read32();
}

/* Host request: Kana LED off -> on. */
bool led_update_user(led_t led_state) {
    static bool last_kana = false;
    if (led_state.kana && !last_kana) batt_requested = true;
    last_kana = led_state.kana;
    return true;
}

void housekeeping_task_user(void) {
    // Pending restore of the real key state - always runs first.
    if (batt_release_left) {
        if (timer_elapsed32(batt_release_timer) >= BATT_RELEASE_MS) {
            batt_restore();
            batt_release_left--;
            batt_release_timer = timer_read32();
        }
        return;
    }

    bool conn = get_transport() == TRANSPORT_BLUETOOTH && bluetooth_get_state() == BLUETOOTH_CONNECTED;

    if (conn && !batt_was_conn) {
        batt_bcast_timer = timer_read32();
        batt_bcast_sent  = false;
    }
    batt_was_conn = conn;
    if (!conn) {
        batt_requested = false;
        return;
    }

    if (battery_power_on_sample()) return;                   // voltage not settled yet
    if (has_anykey(keyboard_report) || has_anymod()) return; // something held
    if (!report_buffer_is_empty()) return;                   // queued reports pending

    uint32_t idle = last_input_activity_elapsed();
    if (batt_requested) {
        if (idle < BATT_REQUEST_QUIET_MS) return;
        batt_requested = false;
    } else {
        uint32_t due = batt_bcast_sent ? BATT_BCAST_INTERVAL_MS : BATT_BCAST_FIRST_MS;
        if (timer_elapsed32(batt_bcast_timer) < due) return;
        if (idle > BATT_BCAST_ACTIVE_MS) return; // idle: stay quiet
        if (idle < BATT_BCAST_QUIET_MS) return;  // typing right now
    }

    batt_bcast_send();
    batt_bcast_sent  = true;
    batt_bcast_timer = timer_read32();
}
#endif
