#!/usr/bin/env python3
"""Builds GlucOS's bundled food list from FSANZ's AUSNUT 2023 data files.

    python3 scripts/food/build_ausnut.py <download dir> <output json>

Inputs (from https://www.foodstandards.gov.au/science-data/food-nutrient-databases/ausnut/data-files):
  - AUSNUT 2023 - Food nutrient profiles.xlsx   (per 100 g values)
  - AUSNUT 2023 - Food measures.xlsx            (household measures with gram weights)

AUSNUT 2023 is © Food Standards Australia New Zealand, licensed CC BY 4.0. GlucOS keeps only
each food's name, available carbohydrate per 100 g and its measures.

Carbs: "available carbohydrate, without sugar alcohols" when present (what carb counting uses;
it leaves out fibre, and sugar alcohols barely raise glucose), else "with sugar alcohols".
"""
import json
import re
import sys
from pathlib import Path

import openpyxl


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", str(s or "").lower()).strip()


def sheet_rows(path):
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    print(f"== {path.name}: sheets {wb.sheetnames}")
    best = None
    for ws in wb.worksheets:
        rows = list(ws.iter_rows(values_only=True))
        # The header row is the first one that names the food.
        for i, row in enumerate(rows[:30]):
            cells = [norm(c) for c in row]
            if any("food name" in c or c == "name" for c in cells) and any("key" in c or "id" in c or "code" in c for c in cells):
                data = rows[i + 1:]
                print(f"   sheet {ws.title!r}: header row {i}, {len(data)} data rows")
                print("   headers:", [str(c) for c in row])
                for sample in data[:3]:
                    print("   sample:", sample)
                if best is None or len(data) > len(best[1]):
                    best = ([str(c or "") for c in row], data)
                break
    if best is None:
        sys.exit(f"no header row found in {path}")
    return best


def find(headers, *needles, avoid=()):
    for i, h in enumerate(headers):
        n = norm(h)
        if all(x in n for x in needles) and not any(a in n for a in avoid):
            return i
    return None


def main(src, out):
    src = Path(src)
    files = {p.name.lower(): p for p in src.rglob("*.xlsx")}
    def pick(*words):
        for name, p in files.items():
            if all(w in name for w in words):
                return p
        sys.exit(f"missing file with {words} in {sorted(files)}")
    prof = pick("nutrient profiles")
    meas = pick("measures")

    h, rows = sheet_rows(prof)
    key_i = find(h, "key") if find(h, "key") is not None else find(h, "food", "id")
    name_i = find(h, "food name")
    carb_i = find(h, "available carbohydrate", "without sugar alcohol")
    carb_label = "without sugar alcohols"
    if carb_i is None:
        carb_i = find(h, "available carbohydrate", "with sugar alcohol")
        carb_label = "with sugar alcohols"
    if carb_i is None:
        carb_i = find(h, "available carbohydrate")
        carb_label = "available"
    print("profile columns:", h[key_i], "|", h[name_i], "|", h[carb_i])
    foods = {}
    for r in rows:
        if r is None or r[key_i] is None or r[name_i] is None:
            continue
        try:
            carbs = float(r[carb_i])
        except (TypeError, ValueError):
            continue
        foods[str(r[key_i]).strip()] = {"name": " ".join(str(r[name_i]).split()), "carbs": round(carbs, 2), "measures": []}

    h, rows = sheet_rows(meas)
    mkey = find(h, "key") if find(h, "key") is not None else find(h, "food", "id")
    mdesc = find(h, "measure", "description")
    if mdesc is None:
        mdesc = find(h, "measure", avoid=("weight", "gram", "number", "id", "key"))
    mqty = find(h, "quantity") if find(h, "quantity") is not None else find(h, "number")
    mgrams = find(h, "weight") if find(h, "weight") is not None else find(h, "gram")
    print("measure columns:", h[mkey], "|", h[mdesc], "|", None if mqty is None else h[mqty], "|", h[mgrams])
    count = 0
    for r in rows:
        if r is None or r[mkey] is None:
            continue
        f = foods.get(str(r[mkey]).strip())
        if f is None:
            continue
        try:
            grams = float(r[mgrams])
        except (TypeError, ValueError):
            continue
        if grams <= 0:
            continue
        desc = " ".join(str(r[mdesc] or "").split())
        if mqty is not None and r[mqty] not in (None, "", 1, 1.0):
            q = r[mqty]
            q = int(q) if isinstance(q, float) and q.is_integer() else q
            desc = f"{q} {desc}".strip()
        if not desc:
            continue
        f["measures"].append([desc, round(grams, 1)])
        count += 1

    out_rows = [[k, f["name"], f["carbs"], f["measures"]] for k, f in sorted(foods.items(), key=lambda kv: kv[1]["name"].lower())]
    doc = {
        "source": "AUSNUT 2023",
        "attribution": "Food Standards Australia New Zealand (AUSNUT 2023), licensed CC BY 4.0",
        "licenceURL": "https://creativecommons.org/licenses/by/4.0/",
        "carbs": f"Available carbohydrate {carb_label}, grams per 100 g",
        "foods": out_rows,
    }
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"wrote {len(out_rows)} foods, {count} measures to {out}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
