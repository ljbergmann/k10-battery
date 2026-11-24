#!/usr/bin/env python3
"""Calibrate the K10 Battery voltage -> percent curve from a real discharge.

Idea: a keyboard draws roughly the same power per hour of use, so the real
remaining charge at any moment is proportional to the *active* hours still
left until the keyboard shuts itself off. Run this after the keyboard has
died once on battery, then (optionally) again after a full charge-to-empty.

    python3 tools/calibrate.py                       # uses the app's history
    python3 tools/calibrate.py history.json --end 2026-11-24T12:00:00Z

Input:  ~/Library/Application Support/K10 Battery/history.json
Output: a Swift table to paste into app/Sources/BatteryMath.swift, plus a
        comparison against Keychron's straight-line estimate.

Voltage: samples from firmware v1.0 carry no voltage. Keychron's percentage is
a known function of the (load-compensated) voltage, so it is inverted here.
That is exactly the voltage newer firmware sends, so both line up.
"""
import argparse
import datetime as dt
import json
import os
import sys

HISTORY = os.path.expanduser("~/Library/Application Support/K10 Battery/history.json")
ACTIVE_GAP_H = 0.25   # gaps longer than this between samples = keyboard not in use
FULL_MV, EMPTY_MV, SHUTDOWN_MV = 4100, 3500, 3300  # Keychron firmware constants


def keychron_pct_to_mv(p):
    """Inverse of battery_get_percentage() in Keychron's battery.c."""
    if p >= 20:
        return EMPTY_MV + (p - 20) * (FULL_MV - EMPTY_MV) / 80
    return SHUTDOWN_MV + p * (EMPTY_MV - SHUTDOWN_MV) / 20


GENERIC = [(3.30, 0), (3.61, 5), (3.69, 10), (3.71, 15), (3.73, 20), (3.75, 25), (3.77, 30),
           (3.79, 35), (3.80, 40), (3.82, 45), (3.84, 50), (3.85, 55), (3.87, 60), (3.91, 65),
           (3.95, 70), (3.98, 75), (4.02, 80), (4.08, 85), (4.11, 90), (4.15, 95), (4.20, 100)]


def generic_pct(mv):
    """Same mapping as BatteryMath.percent (generic curve on Keychron's 3.3-4.1 V window)."""
    v = 3.30 + (mv / 1000 - 3.30) * 0.90 / 0.80
    if v <= GENERIC[0][0]:
        return 0.0
    for (a, pa), (b, pb) in zip(GENERIC, GENERIC[1:]):
        if v <= b:
            return pa + (v - a) / (b - a) * (pb - pa)
    return 100.0


def load(path):
    s = json.load(open(path))
    for x in s:
        x["t"] = dt.datetime.fromisoformat(x["date"].replace("Z", "+00:00"))
        if x.get("millivolts") is None:
            x["millivolts"] = keychron_pct_to_mv(x["percent"])
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("history", nargs="?", default=HISTORY)
    ap.add_argument("--end", help="shutdown time (ISO); default: last on-battery sample")
    ap.add_argument("--top-pct", type=float,
                    help="real %% at the first sample, if the stretch didn't start full "
                         "(default: estimated by extrapolating the measured rate)")
    a = ap.parse_args()

    s = load(a.history)
    # the last on-battery stretch: after the last charging sample before the end
    end_idx = max(i for i, x in enumerate(s) if not x["charging"])
    start_idx = end_idx
    while start_idx > 0 and not s[start_idx - 1]["charging"]:
        start_idx -= 1
    run = s[start_idx:end_idx + 1]
    end_t = dt.datetime.fromisoformat(a.end.replace("Z", "+00:00")) if a.end else run[-1]["t"]

    # cumulative active hours
    act, rows = 0.0, []
    for prev, cur in zip([run[0]] + run, run):
        g = (cur["t"] - prev["t"]).total_seconds() / 3600
        if 0 < g <= ACTIVE_GAP_H:
            act += g
        rows.append((act, cur["millivolts"], cur["percent"]))
    tail = (end_t - run[-1]["t"]).total_seconds() / 3600
    total_active = act + min(max(tail, 0), ACTIVE_GAP_H)

    full_run = run[0]["millivolts"] >= FULL_MV - 10
    if full_run:
        top = 100.0
    elif a.top_pct:
        top = a.top_pct
    else:
        # The run didn't start full, so the real % at its start is unknown.
        # Use the generic Li-ion curve for that single point; it is most
        # trustworthy in the upper range. Everything below is measured.
        top = generic_pct(run[0]["millivolts"])
    hours_per_pct = total_active / top

    # bucket by voltage (10 mV), real % = remaining active hours / hours per %
    buckets = {}
    for h, mv, _ in rows:
        real = (total_active - h) / hours_per_pct
        buckets.setdefault(round(mv / 10) * 10, []).append(real)
    pts = sorted((mv, sum(v) / len(v)) for mv, v in buckets.items())
    # enforce monotonic (higher voltage -> higher %)
    mono, best = [], -1.0
    for mv, p in pts:
        best = max(best, p)
        mono.append((mv, best))
    # anchor end points
    table = [(SHUTDOWN_MV, 0.0)] + [(mv, p) for mv, p in mono if SHUTDOWN_MV < mv < FULL_MV] + [(FULL_MV, 100.0)]
    # thin to ~every 25 mV
    thin, last = [], -999
    for mv, p in table:
        if mv - last >= 25 or mv in (SHUTDOWN_MV, FULL_MV):
            thin.append((mv, p)); last = mv

    print(f"stretch: {run[0]['t']:%Y-%m-%d} -> {end_t:%Y-%m-%d %H:%M}, {len(run)} samples")
    print(f"active use: {total_active:.1f} h; start {run[0]['millivolts']:.0f} mV "
          f"(Keychron {run[0]['percent']}%), assumed real start {top:.0f}%"
          f"{'' if full_run else ' (partial run - re-run after a full cycle)'}")
    print(f"=> a full charge lasts about {hours_per_pct * 100:.0f} h of typing\n")
    print("  mV    calibrated  Keychron")
    for mv, p in thin:
        kc = 100 if mv >= FULL_MV else (20 + (mv - EMPTY_MV) * 80 / 600 if mv >= EMPTY_MV else (mv - SHUTDOWN_MV) * 20 / 200)
        print(f"  {mv:>4}  {p:6.0f} %    {kc:5.0f} %")
    print("\n// Swift: paste into BatteryMath.calibrated")
    print("static let calibrated: [(mv: Int, p: Double)] = [")
    print("    " + ", ".join(f"({mv}, {p:.1f})" for mv, p in thin) + ",")
    print("]")
    print(f"static let hoursPerPercent = {hours_per_pct:.3f}  // active typing hours per 1 %")


if __name__ == "__main__":
    sys.exit(main())
