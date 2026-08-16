#!/usr/bin/env python3
"""Extract real item icons for the dashboard's bag grid.

Chain (each link verified live 2026-08-16):
  item_id -> mangos.item_template.display_id (patch-aware, highest <= 10)
  display_id -> ItemDisplayInfo.dbc field 5 (InventoryIcon name)
  icon name -> <assets>/interface/icons/<lowercase>.blp (converted client tree)
  BLP -> PNG via Pillow (PIL's BlpImagePlugin reads 1.12 BLP2 natively)

Deviation from the stdlib-only generator rule, sanctioned by monofuel's
"please use images" (2026-08-16): Pillow does the BLP decode. Run through the
Makefile target `item-icons`, which supplies it via nix. Everything else is
stdlib + the shared Dbc reader from gen_quest_data.

Output: system/static/icons/item_<id>.png (56x56 RGBA) and a deterministic
manifest system/static/icons/manifest.tsv (id, icon name, status), sorted by
id. Idempotent: existing PNGs are kept unless --force. By default only the
item ids actually present on the realm are converted (~160 today); --all does
the full item_template (not needed yet, slower).
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_quest_data import Dbc, DEFAULT_CONTAINER, WOW_PATCH  # noqa: E402

ICON_FIELD = 5  # ItemDisplayInfo string field carrying InventoryIcon (verified)
ICON_SIZE = 56


def sql(container: str, database: str, query: str) -> list[list[str]]:
    out = subprocess.run(
        ["docker", "exec", container, "mariadb", "-umangos", "-pmangos",
         database, "-N", "-B", "-e", query],
        capture_output=True, text=True, check=True,
    ).stdout
    return [line.split("\t") for line in out.splitlines() if line]


def live_item_ids(container: str) -> list[int]:
    rows = sql(container, "characters",
               "SELECT DISTINCT item_id FROM character_inventory "
               "WHERE item_id > 0 ORDER BY item_id")
    return [int(r[0]) for r in rows]


def display_ids(container: str, ids: list[int]) -> dict[int, int]:
    if not ids:
        return {}
    id_list = ",".join(str(i) for i in ids)
    rows = sql(container, "mangos",
               "SELECT entry, display_id FROM item_template "
               "WHERE entry IN (%s) AND patch <= %d "
               "ORDER BY entry, patch" % (id_list, WOW_PATCH))
    out: dict[int, int] = {}
    for entry, display in rows:  # later (higher-patch) rows overwrite earlier
        out[int(entry)] = int(display)
    return out


def icon_names(dbc_path: str) -> dict[int, str]:
    dbc = Dbc(dbc_path)
    out: dict[int, str] = {}
    for i in range(dbc.count):
        row = dbc.ints(i)
        name = dbc.string(row[ICON_FIELD])
        if name:
            out[row[0]] = name
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dbc-dir", default="/home/monofuel/src/wow-coworld/"
                    "monofuel-vanilla-wow/local_data/vmangos-5875-data/dbc")
    ap.add_argument("--icons-dir", default="/home/monofuel/src/wow-coworld/"
                    "monofuel-vanilla-wow/player/assets/interface/icons")
    ap.add_argument("--out-dir", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "system", "static", "icons"))
    ap.add_argument("--container", default=DEFAULT_CONTAINER)
    ap.add_argument("--all", action="store_true",
                    help="every item_template entry, not just live bags")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        sys.exit("Pillow missing — run via `make item-icons` (nix supplies it)")
    from PIL import Image

    if args.all:
        rows = sql(args.container, "mangos",
                   "SELECT DISTINCT entry FROM item_template "
                   "WHERE patch <= %d ORDER BY entry" % WOW_PATCH)
        ids = [int(r[0]) for r in rows]
    else:
        ids = live_item_ids(args.container)
    displays = display_ids(args.container, ids)
    icons = icon_names(os.path.join(args.dbc_dir, "ItemDisplayInfo.dbc"))

    os.makedirs(args.out_dir, exist_ok=True)
    manifest: list[tuple[int, str, str]] = []
    converted = kept = missing = 0
    for item_id in ids:
        display = displays.get(item_id, 0)
        icon = icons.get(display, "")
        png = os.path.join(args.out_dir, "item_%d.png" % item_id)
        if not icon:
            manifest.append((item_id, "", "no-icon-name"))
            missing += 1
            continue
        blp = os.path.join(args.icons_dir, icon.lower() + ".blp")
        if not os.path.isfile(blp):
            manifest.append((item_id, icon, "blp-missing"))
            missing += 1
            continue
        if os.path.isfile(png) and not args.force:
            manifest.append((item_id, icon, "kept"))
            kept += 1
            continue
        try:
            img = Image.open(blp).convert("RGBA")
            img = img.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
            img.save(png)
            manifest.append((item_id, icon, "converted"))
            converted += 1
        except Exception as exc:  # a bad BLP is a fallback cell, not a crash
            manifest.append((item_id, icon, "decode-error:%s" % exc))
            missing += 1

    manifest.sort()
    with open(os.path.join(args.out_dir, "manifest.tsv"), "w") as fh:
        fh.write("# item_id\ticon\tstatus — regenerate: make item-icons\n")
        for item_id, icon, status in manifest:
            fh.write("%d\t%s\t%s\n" % (item_id, icon, status))
    print("icons: %d converted, %d kept, %d without (of %d items)"
          % (converted, kept, missing, len(ids)))


if __name__ == "__main__":
    main()
