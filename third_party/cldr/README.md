# CLDR locale projections

Faithful projections of Unicode CLDR data (release **48.2.0**,
https://cldr.unicode.org), one JSON per locale, holding only the fields
moss's locale layer uses: number symbols + the decimal/currency patterns,
month/day names, am/pm markers, the medium/long date and medium time
patterns, and per-currency symbol + fraction digits.

The full CLDR distribution is tens of megabytes; these projections are a
few hundred bytes each. `tools/cldrgen` distills them into the compact
binary `assets/locale/cldr.db` that ships in the image and that the
running system can swap live (see the locale service). Every value here
comes verbatim from CLDR — the projection only selects fields, it does not
edit them.

Regenerate with `tools/cldr-fetch.sh` (fetches the upstream CLDR JSON and
re-projects); the fetch is offline of the hermetic build, exactly like the
runtime auto-updater's fetch.

Source: unicode-org/cldr-json, packages cldr-numbers-full, cldr-dates-full,
cldr-core (supplemental/currencyData.json for fraction digits).
