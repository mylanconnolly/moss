#!/usr/bin/env python3
"""Project raw CLDR JSON (numbers, ca-gregorian, currencies, supplemental)
into the small third_party/cldr/<tag>.json files tools/cldrgen reads. Every
value is copied verbatim from CLDR; this only selects fields."""
import json, sys
src, dst, rel = sys.argv[1], sys.argv[2], sys.argv[3]
LOCS = {"en": ("en-US", "USD"), "de": ("de-DE", "EUR"), "fr": ("fr-FR", "EUR"), "ja": ("ja-JP", "JPY")}
CURS = ["USD", "EUR", "JPY"]
for loc, (tag, defcur) in LOCS.items():
    n = json.load(open(f"{src}/{loc}-numbers.json"))["main"][loc]["numbers"]
    ns = n["defaultNumberingSystem"]
    s = n[f"symbols-numberSystem-{ns}"]
    ca = json.load(open(f"{src}/{loc}-cagreg.json"))["main"][loc]["dates"]["calendars"]["gregorian"]
    cu = json.load(open(f"{src}/{loc}-curr.json"))["main"][loc]["numbers"]["currencies"]
    fr = json.load(open(f"{src}/currencyData.json"))["supplemental"]["currencyData"]["fractions"]
    def frac(c): return int(fr.get(c, {}).get("_digits", fr["DEFAULT"]["_digits"]))
    days = ca["days"]["format"]["abbreviated"]
    proj = {
        "tag": tag, "cldr": rel, "numberSystem": ns,
        "symbols": {"decimal": s["decimal"], "group": s["group"], "minus": s["minusSign"]},
        "decimalPattern": n[f"decimalFormats-numberSystem-{ns}"]["standard"],
        "currencyPattern": n[f"currencyFormats-numberSystem-{ns}"]["standard"],
        "monthsAbbr": [ca["months"]["format"]["abbreviated"][str(i)] for i in range(1, 13)],
        "monthsWide": [ca["months"]["format"]["wide"][str(i)] for i in range(1, 13)],
        "daysAbbr": [days[k] for k in ("sun", "mon", "tue", "wed", "thu", "fri", "sat")],
        "am": ca["dayPeriods"]["format"]["abbreviated"]["am"],
        "pm": ca["dayPeriods"]["format"]["abbreviated"]["pm"],
        "dateMedium": ca["dateFormats"]["medium"], "dateLong": ca["dateFormats"]["long"],
        "timeMedium": ca["timeFormats"]["medium"], "defaultCurrency": defcur,
        "currencies": {c: {"symbol": cu[c].get("symbol", c), "frac": frac(c)} for c in CURS},
    }
    json.dump(proj, open(f"{dst}/{tag}.json", "w"), ensure_ascii=False, indent=1)
