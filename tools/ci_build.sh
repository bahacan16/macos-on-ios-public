#!/bin/bash
# Convert + sign a Mac app into an installable .ipa on a Mac with no device attached, e.g. a GitHub
# Actions macOS runner (.github/workflows/ios-build.yml). Installing and reading the console then
# happen from any Windows/Linux PC over USB instead of devicectl: docs/no-mac.md.
# usage: tools/ci_build.sh [probe | <Mac.app> | <https URL of a .zip/.dmg/.tar.* holding one>]
# env: P12_BASE64 P12_PASSWORD PROFILE_BASE64  your Apple Development certificate and a development
#        profile listing your device (unset: ad-hoc signed dry run that checks the conversion, no .ipa)
#      BUNDLE_ID     default: the profile's App ID, or $BUNDLE_PREFIX.<name> under a wildcard profile
#      CONVERT_ARGS  passed to convert_app.py (README "Converting any Mac app")
#      OUT           output dir (default $T/out): <name>.ipa, convert.log
set -eo pipefail
cd "$(dirname "$0")/.."
SRC=${1:-probe}
T=${T:-${TMPDIR:-/tmp/}macos-on-ios}
OUT=${OUT:-$T/out}; mkdir -p "$T" "$OUT"; OUT=$(cd "$OUT" && pwd)
die() { echo "::error::$*"; exit 1; }
b64() {  # stdin base64 (plain, or certutil -encode output with BEGIN/END lines) -> bytes
  python3 -I -c 'import base64, re, sys
sys.stdout.buffer.write(base64.b64decode(re.sub(r"-----[^-]*-----|\s", "", sys.stdin.read())))'
}

# 1. The Mac app
case $SRC in
  probe)
    # Xcode 26+ ships the Metal compiler as a separate download
    xcrun -sdk macosx metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain
    UDID=- TEAM=- IDENTITY=- T=$T probe/build.sh mac
    MAC_APP=$T/MacProbe.app ;;
  https://*)
    d=$T/download; rm -rf "$d"; mkdir -p "$d/x" "$d/app"
    curl -fsSL --retry 3 -o "$d/file" "$SRC" || die "download failed: $SRC"
    if unzip -tqq "$d/file" >/dev/null 2>&1; then ditto -x -k "$d/file" "$d/x"
    elif tar -tf "$d/file" >/dev/null 2>&1; then tar -xf "$d/file" -C "$d/x"
    else  # disk image; "yes" accepts a license agreement if the image shows one
      { yes || true; } | PAGER='cat' hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$d/x" "$d/file" >/dev/null \
        || die "not a .zip, .tar or disk image: $SRC"
    fi
    apps=$(find "$d/x" -maxdepth 3 -type d -name '*.app' -prune)
    [ -n "$apps" ] || die "no .app inside $SRC (installer .pkg files aren't supported)"
    app=${apps%%$'\n'*}
    ditto "$app" "$d/app/$(basename "$app")"
    hdiutil detach "$d/x" -quiet 2>/dev/null || true
    MAC_APP=$d/app/$(basename "$app") ;;
  *) MAC_APP=$SRC ;;
esac
PL=$MAC_APP/Contents/Info.plist
[ -f "$PL" ] || die "$MAC_APP is not a Mac app (no Contents/Info.plist)"
NAME=$(basename "$MAC_APP" .app)
ID_NAME=$(printf %s "$NAME" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
BIN=$MAC_APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$PL")
ARCHS=$(lipo -archs "$BIN")
case " $ARCHS " in *" arm64 "*) ;; *) die "$NAME has no arm64 code ($ARCHS): Intel-only apps can't run" ;; esac
if otool -arch arm64 -l "$BIN" | grep -E '^ +cryptid 1$' >/dev/null; then
  die "$NAME is encrypted (Mac App Store build); use the developer's direct download"
fi
for jit in "Electron Framework.framework" libjvm.dylib libcoreclr.dylib libmonosgen-2.0.dylib; do
  [ -z "$(find "$MAC_APP/Contents" -name "$jit" -print -quit)" ] ||
    echo "::warning::$NAME bundles $jit: its runtime needs JIT, which iOS forbids (README Limits)"
done
echo "$NAME ($ARCHS)"

# 2. Signing material
S=$T/signing; rm -rf "$S"; mkdir -p "$S"
trap 'rm -rf "$S"; [ -z "$KC" ] || security delete-keychain "$KC" 2>/dev/null || true' EXIT
if [ -n "$P12_BASE64" ]; then
  [ -n "$PROFILE_BASE64" ] || die "P12_BASE64 is set but PROFILE_BASE64 isn't"
  printf %s "$P12_BASE64" | b64 > "$S/cert.p12"
  printf %s "$PROFILE_BASE64" | b64 > "$S/profile.mobileprovision"
  KC=$S/ci.keychain-db; KCPW=$(uuidgen)
  security create-keychain -p "$KCPW" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KCPW" "$KC"
  # intermediate CA of Apple Development certificates, so codesign can embed the full chain
  if curl -fsSL --retry 3 -o "$S/wwdr.cer" https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer; then
    security import "$S/wwdr.cer" -k "$KC" >/dev/null || true
  fi
  if ! security import "$S/cert.p12" -k "$KC" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null 2>"$S/import.err"; then
    # a .p12 made with OpenSSL 3 (e.g. on Windows) uses AES, which the keychain may refuse: re-pack it
    OSSL=$(brew --prefix openssl@3 2>/dev/null)/bin/openssl; [ -x "$OSSL" ] || OSSL=openssl
    "$OSSL" pkcs12 -in "$S/cert.p12" -passin env:P12_PASSWORD -nodes -out "$S/id.pem" 2>/dev/null ||
      die "can't open the .p12 (wrong P12_PASSWORD?): $(cat "$S/import.err")"
    "$OSSL" pkcs12 -export -legacy -in "$S/id.pem" -passout env:P12_PASSWORD -out "$S/legacy.p12" 2>/dev/null ||
      "$OSSL" pkcs12 -export -in "$S/id.pem" -passout env:P12_PASSWORD -out "$S/legacy.p12"
    rm -f "$S/id.pem"
    security import "$S/legacy.p12" -k "$KC" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
  fi
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
  # shellcheck disable=SC2046  # the existing search list, one keychain path per word
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  IDS=$(security find-identity -v -p codesigning "$KC")
  IDENTITY=$(echo "$IDS" | awk '$1 == "1)" {print $2}')
  [ -n "$IDENTITY" ] || die "no valid signing identity in the .p12: $(security find-identity -p codesigning "$KC")"
  echo "identity: $(echo "$IDS" | awk '$1 == "1)"' | cut -d'"' -f2)"

  security cms -D -i "$S/profile.mobileprovision" > "$S/profile.plist" || die "PROFILE_BASE64 isn't a .mobileprovision"
  eval "$(python3 -I - "$S/profile.plist" "$IDENTITY" <<'PY'
import datetime, hashlib, plistlib, shlex, sys
p = plistlib.load(open(sys.argv[1], "rb"))
ent = p["Entitlements"]
out = {"TEAM": p["TeamIdentifier"][0], "APPID": ent["application-identifier"].split(".", 1)[1],
       "PNAME": p.get("Name", ""), "EXPIRES": p["ExpirationDate"].strftime("%Y-%m-%d"),
       "DEVICES": str(len(p.get("ProvisionedDevices", []))),
       "ENTS": " ".join(sorted(k for k, v in ent.items() if v is True)),
       "PROBLEM": ""}
if p.get("ProvisionsAllDevices"):
    out["PROBLEM"] = "this is an enterprise profile; use a development profile from your own team (README Legal)"
elif ent.get("get-task-allow") is not True:
    out["PROBLEM"] = "not a development profile (iOS App Development); ad hoc/App Store profiles don't fit"
elif p["ExpirationDate"] < datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):  # plistlib: naive UTC
    out["PROBLEM"] = f"the profile expired on {out['EXPIRES']}"
elif sys.argv[2] not in {hashlib.sha1(c).hexdigest().upper() for c in p["DeveloperCertificates"]}:
    out["PROBLEM"] = "the profile doesn't include the .p12's certificate; regenerate it with that certificate selected"
for k, v in out.items():
    print(f"PROFILE_{k}={shlex.quote(v)}")
PY
)"
  # shellcheck disable=SC2154  # PROFILE_* come from the eval above
  [ -z "$PROFILE_PROBLEM" ] || die "$PROFILE_PROBLEM"
  TEAM=$PROFILE_TEAM
  echo "profile: $PROFILE_PNAME, team $TEAM, App ID $PROFILE_APPID, $PROFILE_DEVICES device(s), expires $PROFILE_EXPIRES"
  case $PROFILE_APPID in
    *\*) prefix=${PROFILE_APPID%\*}
         BID=${BUNDLE_ID:-${prefix:-${BUNDLE_PREFIX:-com.example}.}$ID_NAME}
         case $BID in "$prefix"*) ;; *) die "bundle id $BID doesn't fit the profile's App ID $PROFILE_APPID" ;; esac ;;
    *)   BID=${BUNDLE_ID:-$PROFILE_APPID}
         [ "$BID" = "$PROFILE_APPID" ] || die "bundle id $BID doesn't fit the profile's App ID $PROFILE_APPID" ;;
  esac
  prev=
  for a in $CONVERT_ARGS; do
    if [ "$prev" = --entitlement ]; then
      case " $PROFILE_ENTS " in *" $a "*) ;; *) die "the profile lacks $a (add the capability to an explicit App ID, regenerate the profile)" ;; esac
    fi
    prev=$a
  done
else
  echo "::warning::no signing secrets: ad-hoc signed dry run, no .ipa (docs/no-mac.md)"
  IDENTITY=-; TEAM=DRYRUN; BID=${BUNDLE_ID:-${BUNDLE_PREFIX:-com.example}.$ID_NAME}
  : > "$S/profile.mobileprovision"
fi

# 3. Convert + package
APP=$T/$BID/$NAME.app
# shellcheck disable=SC2086  # CONVERT_ARGS is a list of options
python3 -I -u tools/convert_app.py "$MAC_APP" "$APP" "$BID" --profile "$S/profile.mobileprovision" \
  --identity "$IDENTITY" --team "$TEAM" $CONVERT_ARGS 2>&1 | tee "$OUT/convert.log"
if [ "$IDENTITY" != - ]; then
  rm -rf "$T/ipa"; mkdir -p "$T/ipa/Payload"
  ditto "$APP" "$T/ipa/Payload/$NAME.app"
  rm -f "$OUT/$NAME.ipa"; (cd "$T/ipa" && zip -qryX "$OUT/$NAME.ipa" Payload)
  echo "-> $OUT/$NAME.ipa ($(du -h "$OUT/$NAME.ipa" | cut -f1)), bundle id $BID"
fi
if [ -n "$GITHUB_STEP_SUMMARY" ]; then
  { echo "### $NAME -> \`$BID\`"
    [ "$IDENTITY" = - ] && echo "Dry run (no signing secrets): conversion only, no .ipa."
    [ "$IDENTITY" = - ] || echo "Profile **$PROFILE_PNAME** (team $TEAM), expires $PROFILE_EXPIRES."
    echo; echo '```'; grep -E '^(shim |[0-9]+ Mach-O|aligned|replaced)' "$OUT/convert.log" || true; echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
