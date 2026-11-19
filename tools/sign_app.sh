#!/bin/bash
# Re-sign the patched bundle and zip it into an IPA.
#   sign_app.sh <workdir> <profile.mobileprovision> <codesign-identity> <out.ipa>
set -euo pipefail
WORK="$(cd "${1:?workdir}" && pwd)"; PROF="${2:?profile}"; ID="${3:?identity}"; OUT="${4:?out.ipa}"
APP="$WORK/Payload/dynamite.app"
[ -d "$APP" ] || { echo "no app in $WORK"; exit 1; }
T="$WORK/.sign_tmp"; rm -rf "$T"; mkdir -p "$T"
security cms -D -i "$PROF" > "$T/prof.plist"
python3 -I - "$T/prof.plist" "$T/ents.plist" "$APP/Info.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb")); e = p["Entitlements"]
bid = plistlib.load(open(sys.argv[3], "rb"))["CFBundleIdentifier"]
appid = e["application-identifier"]
if not appid.endswith("." + bid) and not appid.endswith(".*"):
    sys.exit("profile app id %s does not match bundle id %s" % (appid, bid))
keep = {k: e[k] for k in ("application-identifier", "com.apple.developer.team-identifier", "get-task-allow") if k in e}
plistlib.dump(keep, open(sys.argv[2], "wb"), fmt=plistlib.FMT_XML)
print("profile ok: %s | expires %s" % (appid, p["ExpirationDate"]))
PY
cp "$PROF" "$APP/embedded.mobileprovision"
[ -f "$APP/Frameworks/OfflineRating.dylib" ] && codesign -f -s "$ID" --timestamp=none "$APP/Frameworks/OfflineRating.dylib"
codesign -f -s "$ID" --timestamp=none "$APP/Frameworks/UnityFramework.framework"
codesign -f -s "$ID" --timestamp=none --entitlements "$T/ents.plist" "$APP"
codesign --verify --deep --strict "$APP"
rm -rf "$T"
rm -f "$OUT"; (cd "$WORK" && zip -qry "$OUT" Payload)
echo "signed + packed: $OUT"
