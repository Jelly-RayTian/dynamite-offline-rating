# Third-party materials and credits

Nothing below is covered by this repository's license (see `LICENSE`); each item stays under its owner's terms.

## Chart constants - `data/charts.csv`
Compiled from the community spreadsheet **"Dynamite b20计算器.xlsx"** (spreadsheet by *eeeeastown*; its formula is credited
there to *QWERTY1151*'s sheet and its chart data to *AXIS5*'s sheet). It lists 397 ranked charts (constant D between 11.0 and 17.0)
with their full-R values. The contents are the community's work; they are included here only so the tool can work offline.
`native/orp_chart_table.inc` is generated from it.
**Scope of the data:** it only contains what the community had measured **when the official servers shut down (June 2022)**.
Charts imported afterwards have no constant (they are shown as unrated until you add one).

## The rating formula
`R = trunc(max(acc*50, acc^8 * D^3 - D^2.8))` is a community reconstruction (not an official formula). The expression appears in the
**ExplodeX** private-server project (`Dyfused/ExplodeX`, no license file, file `goodbird/GoodBirdOracle.kt`). Only the mathematical
expression was taken; the code in this repository is an independent implementation. It was checked against the table above and
against in-game results quoted in community articles (see `docs/TECHNICAL_NOTES.md`).

## Research sources (read for understanding; no code from them is in this repository)
- `Dyfused/Explode-Kotlin` (AGPL-3.0) - private server; its rating code was studied, and **none of its code is included here**.
- Bilibili articles by *光羽隹雪 (DraXon)* (cv17024921), *Crazy_Bull* (cv16847763), *东城eastown* (cv16981243) - used as evidence
  for how the rating behaves (integer results, truncation, best-20 sum).
- `EDTA-gif/dynamite-charts-repository` - community backup the game's file layout was learned from.

## Tools used (not included)
- Il2CppDumper by Perfare (MIT) - to recover class and method names from the game's IL2CPP metadata.
- Xcode / Apple SDKs and the system SQLite library.

## The game
**Dynamite** (iOS client 1.0.2, build 59), its code, charts, music and artwork belong to their owners (e.g. Tuner Games) and to the
Unity Technologies runtime it is built on. This project is not affiliated with them. It only modifies a copy of the game that the
user supplies.
