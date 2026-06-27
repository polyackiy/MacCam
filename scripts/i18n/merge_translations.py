#!/usr/bin/env python3
"""Merge translation files into MacCam's String Catalogs.

Usage:
    python3 scripts/i18n/merge_translations.py <translations-dir>

<translations-dir> holds `tr_<lang>.json` files (e.g. `tr_fr.json`,
`tr_zh-Hans.json`), each a flat JSON object mapping an English **source string**
to its translation. The source strings are the keys of
`MacCam/Localizable.xcstrings` plus the English values of
`MacCam/InfoPlist.xcstrings`.

For every entry the matching catalog string gains a `<lang>` localization with
state `translated`. Existing localizations are preserved; a localizable source
string not yet in the catalog is created. To add a new language later, drop a
`tr_<lang>.json` next to the others and re-run.

The String Catalogs (`*.xcstrings`) remain the source of truth — this is just a
bulk-edit helper so large translation batches stay well-formed JSON. Re-running a
`tr_<lang>.json` overwrites that language's units (other languages are preserved),
so don't re-run after hand-editing a language directly in the catalog.
"""
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOCALIZABLE = os.path.join(ROOT, "MacCam", "Localizable.xcstrings")
INFO_PLIST = os.path.join(ROOT, "MacCam", "InfoPlist.xcstrings")


def set_unit(entry, lang, value):
    entry.setdefault("localizations", {})[lang] = {
        "stringUnit": {"state": "translated", "value": value}
    }


def write_catalog(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def main(translations_dir):
    loc = json.load(open(LOCALIZABLE, encoding="utf-8"))
    info = json.load(open(INFO_PLIST, encoding="utf-8"))

    # Map an InfoPlist English value back to its plist key (so a translation keyed
    # by the English description lands on the right NS*UsageDescription entry).
    info_by_en = {}
    for k, v in info["strings"].items():
        en = v.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
        if en is not None:
            info_by_en[en] = k

    for path in sorted(glob.glob(os.path.join(translations_dir, "tr_*.json"))):
        lang = os.path.basename(path)[len("tr_"):-len(".json")]
        translations = json.load(open(path, encoding="utf-8"))
        for source, value in translations.items():
            if source in info_by_en:
                set_unit(info["strings"][info_by_en[source]], lang, value)
            else:
                set_unit(loc["strings"].setdefault(source, {}), lang, value)

    write_catalog(LOCALIZABLE, loc)
    write_catalog(INFO_PLIST, info)
    print("merged translations from", translations_dir)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
