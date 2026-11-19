# Technical notes

What is known about the Dynamite iOS client, how this project hooks into it, and how well each part has been verified.

Target build: **Dynamite 1.0.2 (build 59)**, bundle id `com.tunergames.dynamite`, IPA sha256
`2c2686dbc7b205298360bf71f8826168905b71f1c4c6c6cd81db0c142a92bd69`. Nothing here is guaranteed to work on any other build:
the patcher refuses to touch a binary that differs from the one described below.

## 1. The game

- Unity 2020.1.2f1, **IL2CPP**, arm64 only. `global-metadata.dat` is the standard version 24.2 (not encrypted); the binary is not FairPlay-encrypted.
- The main executable `dynamite` (68 KB) is only a launcher. All game code is in `Frameworks/UnityFramework.framework/UnityFramework` (23 MB).
- The `__TEXT` segment has vmaddr 0, so an RVA from Il2CppDumper equals the file offset and the in-memory offset from the image base.
- `UnityFramework` exports the whole `il2cpp_*` C API (230 symbols), which is how this project reads and writes managed objects at runtime.

## 2. How a finished chart is recorded (client side)

The server is gone; the client used to talk GraphQL to its own backend. The rating is computed **on the server** (`submitAfterPlay` returns
`RThisMonth`), so no rating formula exists in the client.

- `NewMarkUpload.AfterPlayUploadAsync(score, perfect, good, miss, bleed, mirror, alive, ...)` is called by the result screens
  (`UI0MarkView.Start`, `UI1MarkView.APUpload`, `FailureCanvas.Start` with `alive = false`). It receives everything needed, **before** any network
  access, and nothing on the way to it checks for a login or a connection.
- `NewMarkUpload.lastChartId` (static string) holds a **truncated chart file path**, e.g. `Song(Charter)/Song_GIG`, not an id.
  `ChartInfoManager.Difficulty` is unreliable (reads 0 for a GIGA chart).
- The song index `Documents/__rena_index_2` is plain text (`B.<uuid>`, `N?title`, `H?GIGA,15;`, `M?<map path>`, `C?<cover path>`, `R?1` = ranked).
  Matching `lastChartId` as a prefix of a `M?` path gives the real title, difficulty class, level and uuid.

## 3. The rating

`R = trunc( max( acc * 50 , acc^8 * D^3 - D^2.8 ) )`, `acc = (P + G/2) / (P + G + M)`; overall Rating = sum of the best result of each of the best 20 charts.

This is a **community reconstruction, not the official formula**. Evidence:

- Full R (`acc = 1`): `trunc(D^3 - D^2.8)` reproduces 396 of the 397 values in the community chart table exactly (max error 1).
- Real in-game data points quoted in community articles: `R(17.0, 1991/1997) = 2008` exactly; two further points with D = 15.5 are within 1 R
  (the article's order of the two values looks swapped).
- The game's results are integers and are truncated, not rounded, and depend only on D and accuracy (community observations).
- A separately fitted polynomial from the community agrees with this closed form to < 0.5 R over D 11..17 (used only as a cross-check; not shipped).
- An older cubic fit for the full R is ~330 off on average and was rejected.

Not proven identical to the original; if you have genuine (P, G, M, D, displayed R) samples that disagree, please compare them.

**Chart constants (`data/charts.csv`)** cover only the charts the community had measured when the official servers closed
(June 2022): 397 ranked charts, D 11.0 to 17.0. Charts below D 11 and anything imported later have **no constant** and are shown as unrated.
Add your own in `Documents/OfflineRating/constants.csv` (`title,CLASS,constant`).

## 4. How the module gets into the game

1. `tools/patch_ipa.py` verifies a list of facts about the binary (see `native/orp_patch_config.h`, the single source of truth) and aborts if any differs, then:
   - replaces the **first instruction of four game functions** with `b <stub>`, where `<stub>` is the import stub of a library function the game (almost) never calls;
   - adds a weak `LC_LOAD_WEAK_DYLIB @rpath/OfflineRating.dylib` to the main executable (there is plenty of header padding);
   - copies `OfflineRating.dylib` into `Frameworks/` and sets the bundle id.
2. At runtime the dylib overwrites the **lazy-pointer slot** of each hijacked stub with its own entry point. Only data pages are written; no code page is modified
   after load, which is what iOS allows without JIT.
3. A table-driven trampoline (`native/orp_hook.S`) saves the argument registers, calls `orp_dispatch`, and either runs the displaced original
   instruction and continues in the original function, or returns to the caller directly. A legitimate call of the hijacked import (matched by its
   single known return address) is forwarded untouched.

| site | function | what we do |
|---|---|---|
| 0 | `NewMarkUpload.AfterPlayUploadAsync` | read the result, resolve the chart through the index, store it, show the result card; the original keeps running |
| 1 | `UserManagement.LoginAsync` | local accounts: check name/password, switch the account database, then run the game's own offline login |
| 2 | `UserManagement.RegisterAsync` | same, for the game's register panel |
| 3 | `UI1TitleScreen.JumpRegister` | the "Register" button opened a dead website; show our own registration card instead and drive the game's own `TriggerLogin` |

`LoginAsync` has a built-in offline branch (username `null` builds the `Offline...` user and calls the success callback); the account feature reuses it.
A refused login (wrong password, unknown name) is reported through the game's own `onNetworkError(string)` delegate.

The top-bar R in the game reads `UserManagement.Local.ThisUser.RThisMonth` (`Nullable<int>`, layout `{ int value @0; bool has_value @4 }`);
the module keeps it equal to the active account's total Rating.

## 5. Storage

SQLite, one database per local account under `Documents/OfflineRating/` (`ratings.sqlite3` for the game's `Offline...` user, `accounts/acc_<hash>.sqlite3`
for the others). `plays` is the source of truth; ratings are derived, so changing a constant or the formula only needs a recompute.
Plays imported from a seed file carry a `synthetic` flag, are counted on the board, and can be removed with `seed_clear.txt`.
Account passwords are optional and stored only as `SHA-256(salt:password)`; this protects against casual peeking, nothing more.

## 6. Cover art

`*.jpg.rnx` files are decrypted with **the game's own** `Encrypting.DecryptBytes(byte[])` (AES with constants compiled into the binary, no external
state), called through `il2cpp_runtime_invoke`, exactly as the game's own texture loader does (`File.ReadAllBytes` -> `DecryptBytes` -> `LoadImage`).
No cipher is reimplemented here. The image is shrunk to a thumbnail kept **in memory only**; nothing decrypted is written to disk.

## 7. Verification status

Verified on an iPad Pro (iOS 26.6.2) running the patched, re-signed game (evidence: the module's own device log):
installation and launch; hook installation; capture of real plays (score, judgments, chart); chart resolution through the index; R of real plays
matching the engine; the game's top-bar R following the total; logging in through the game's login screen; switching between local accounts;
creating an account (through the earlier system-dialog version of the registration prompt); the in-overlay registration card appearing and cancelling;
importing seed plays; cover decryption (a 140 144-byte file decrypted to a decodable image); the Best 20 page.

Verified only off-device (macOS arm64 / iOS Simulator): the assembly trampoline (4 sites, argument modification, skip-original, forwarding,
2000-iteration stress), the rating engine against 2000 generated vectors, the store (including migration of an older database), the chart-constant
lookup (397/397), the index parser, and the rendering of every screen.

**Not verified:** submitting a registration through the *current* registration card; how the game's own login screen renders the refusal message for a
wrong password or unknown name; the change-password form; behaviour with other Dynamite builds; any iOS version other than 26.6.2.

## 8. Limits and honesty notes

- The game's own best-score store (`__rena_mark_store_3`) is never touched and is shared by all local accounts.
- Scores of synthetic plays are a cosmetic approximation; the real scoring formula is unknown.
- Free Apple developer accounts sign for 7 days only: the patched app stops launching when its provisioning profile expires and must be re-signed.
