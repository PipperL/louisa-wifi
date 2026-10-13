#!/usr/bin/env python3
"""Sanity-check a freshly scraped stores.json before it can reach the app.

    check_stores.py NEW.json [--old OLD.json] [--report report.md] [--meta meta.json]

Hard checks fail the run (exit 1) so the old data stays in place. Soft checks
only go into the report, which becomes the body of the data-update PR.
The app repeats the hard checks before it applies downloaded data.
"""
import argparse
import datetime
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path

MIN_STORES = 400
MIN_RATIO = 0.9          # of the previous count
MAX_NO_COORDS = 0.15
LAT, LNG = (21, 26.5), (118, 122.5)


def hard_checks(stores, old):
    errors = []
    if not isinstance(stores, list):
        return ["top level is not a list"]
    fields = {"name": str, "address": str, "phone": str, "lat": (int, float), "lng": (int, float), "passwords": list}
    for i, s in enumerate(stores):
        if not isinstance(s, dict):
            errors.append(f"#{i}: not an object")
            continue
        for k, t in fields.items():
            if not isinstance(s.get(k), t):
                errors.append(f"#{i} {s.get('name', '?')}: bad field {k!r}")
    if errors:
        return errors

    names = [s["name"].strip() for s in stores]
    if any(not n for n in names):
        errors.append("empty store name")
    dup = [n for n, c in Counter(names).items() if c > 1]
    if dup:
        errors.append(f"duplicate names: {dup}")

    if len(stores) < MIN_STORES:
        errors.append(f"only {len(stores)} stores (< {MIN_STORES})")
    if old is not None and len(stores) < MIN_RATIO * len(old):
        errors.append(f"only {len(stores)} stores, previous had {len(old)} (< {MIN_RATIO:.0%})")

    for s in stores:
        pws = s["passwords"]
        if not pws:
            errors.append(f"{s['name']}: no password candidates")
        for p in pws:
            if not (isinstance(p, str) and p.isascii() and p.isdigit() and 8 <= len(p) <= 63):
                errors.append(f"{s['name']}: bad password candidate (not 8-63 digits)")
        lat, lng = s["lat"], s["lng"]
        if not (lat == 0 and lng == 0) and not (LAT[0] < lat < LAT[1] and LNG[0] < lng < LNG[1]):
            errors.append(f"{s['name']}: coordinates outside Taiwan ({lat}, {lng})")

    no_coords = sum(1 for s in stores if s["lat"] == 0 and s["lng"] == 0)
    if stores and no_coords / len(stores) > MAX_NO_COORDS:
        errors.append(f"{no_coords}/{len(stores)} stores without coordinates (> {MAX_NO_COORDS:.0%})")
    return errors


def soft_checks(stores, old):
    notes = []
    by_name = {s["name"]: s for s in stores}
    if old is not None:
        old_by_name = {s["name"]: s for s in old}
        added = sorted(set(by_name) - set(old_by_name))
        removed = sorted(set(old_by_name) - set(by_name))
        changed = sorted(n for n in set(by_name) & set(old_by_name)
                         if by_name[n]["passwords"] != old_by_name[n]["passwords"])
        notes.append(("新增的門市", added))
        notes.append(("移除的門市", removed))
        notes.append(("密碼候選有變動", changed))

    names = [s["name"] for s in stores]
    notes.append(("名稱帶括號或營業狀態", [n for n in names if re.search(r"[()（）]|即將開幕|暫停", n)]))
    notes.append(("名稱沒有以「門市」結尾", [n for n in names if not n.endswith("門市")]))
    odd = [f"{s['name']}：{s['phone']}" for s in stores
           if re.search(r"#|分機|ext|轉|/|、|,", s["phone"], re.I) or re.sub(r"\D", "", s["phone"]).startswith("09")]
    notes.append(("電話格式不標準（分機、手機、多支號碼）", odd))
    notes.append(("沒有座標", [s["name"] for s in stores if s["lat"] == 0 and s["lng"] == 0]))
    dup_phone = [p for p, c in Counter(s["phone"] for s in stores).items() if c > 1]
    notes.append(("電話重複", dup_phone))
    return notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("new")
    ap.add_argument("--old")
    ap.add_argument("--report")
    ap.add_argument("--meta")
    args = ap.parse_args()

    raw = Path(args.new).read_bytes()
    try:
        stores = json.loads(raw)
    except ValueError as e:
        stores, errors = None, [f"invalid JSON: {e}"]
    old = json.loads(Path(args.old).read_bytes()) if args.old and Path(args.old).exists() else None
    if stores is not None:
        errors = hard_checks(stores, old)

    lines = [f"## 門市資料檢查：{len(stores) if isinstance(stores, list) else '?'} 間"
             + (f"（上一版 {len(old)} 間）" if old is not None else "")]
    if errors:
        lines += ["", "### ❌ 硬性檢查沒有通過（不會更新資料）", *[f"- {e}" for e in errors[:50]]]
    else:
        lines += ["", "### ✅ 硬性檢查全部通過"]
        for title, items in soft_checks(stores, old):
            lines += ["", f"### {title}（{len(items)}）"]
            lines += [f"- {i}" for i in items[:100]] or ["- 無"]
            if len(items) > 100:
                lines.append(f"- …另外 {len(items) - 100} 筆")
    report = "\n".join(lines) + "\n"
    if args.report:
        Path(args.report).write_text(report, encoding="utf-8")
    print(report)

    if errors:
        sys.exit(1)
    if args.meta:
        meta = {"updated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "count": len(stores), "sha256": hashlib.sha256(raw).hexdigest()}
        Path(args.meta).write_text(json.dumps(meta, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
