#!/bin/sh
# Assemble Daeva.app (and optionally Daeva.dmg) from this checkout.
#
#   scripts/build-app.sh            -> build/Daeva.app
#   scripts/build-app.sh --dmg      -> also build/Daeva-<version>.dmg
#
# Bundles the launcher, a standalone Python, daeva_engine, the compat tool, and the
# payload below. D3DMetal and Valve's DLLs are fetched on the user's Mac instead.
#
# Payload (defaults are local copies; CI passes its own):
#   ENGINE_TARBALL  patched engine Libraries tarball (sha256 pinned in engine.lock.json)
#   STEAM_EXE       steam_helper port (sha256 pinned)
#   CPUID_DYLIB     compat_cpuid.dylib built from aion2-wine-compat
set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/build"
app="$out/Daeva.app"
version="${DAEVA_VERSION:-$(cat "$repo/VERSION")}"
support="$HOME/Library/Application Support"
ENGINE_TARBALL="${ENGINE_TARBALL:-$support/Daeva/cache/4.7.903-daeva-Libraries.tar.gz}"
STEAM_EXE="${STEAM_EXE:-$support/notproton/bridge/steam.exe}"
CPUID_DYLIB="${CPUID_DYLIB:-$support/Daeva/gamefixes/compat_cpuid.dylib}"

PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.13.16%2B20261003-aarch64-apple-darwin-install_only.tar.gz"
PY_SHA="d8975d7df4f08f7b1c7aafcdfacbddcec3d366415f2c1a72b2466b6850815933"

pin() { python3 -c "import json,sys; d=json.load(open('$repo/engine.lock.json')); print(eval(sys.argv[1]))" "$1"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
need() { [ "$(sha "$1")" = "$2" ] || { echo "sha256 mismatch: $1" >&2; exit 1; }; }

echo "==> verifying payload"
need "$ENGINE_TARBALL" "$(pin "d['bridge_engine']['sha256']")"
need "$STEAM_EXE" "$(pin "d['bridge_files']['steam.exe']")"
[ -f "$CPUID_DYLIB" ] || { echo "missing $CPUID_DYLIB" >&2; exit 1; }

echo "==> building launcher"
swift build --package-path "$repo/gui" -c release --arch arm64
bin="$(swift build --package-path "$repo/gui" -c release --arch arm64 --show-bin-path)/Daeva"

echo "==> assembling $app"
rm -rf "${app:?}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/daeva/payload"
cp "$bin" "$app/Contents/MacOS/Daeva"
res="$app/Contents/Resources"

cache="$out/cache"
mkdir -p "$cache"
py="$cache/python-$PY_SHA.tar.gz"
[ -f "$py" ] && [ "$(sha "$py")" = "$PY_SHA" ] || curl -fsSL -o "$py" "$PY_URL"
need "$py" "$PY_SHA"
tar -xzf "$py" -C "$res"            # -> Resources/python

d="$res/daeva"
cp -R "$repo/bin" "$repo/compat" "$d/"
rsync -a --exclude __pycache__ "$repo/daeva_engine" "$d/"
cp "$repo/engine.lock.json" "$d/"
cp "$ENGINE_TARBALL" "$d/payload/engine.tar.gz"
cp "$STEAM_EXE" "$d/payload/steam.exe"
cp "$CPUID_DYLIB" "$d/payload/compat_cpuid.dylib"
mkdir -p "$d/licenses"
cp "$repo"/licenses/* "$d/licenses/"

echo "==> icon"
swift "$repo/scripts/make-icon.swift" "$cache/icon.png"
iconset="$cache/Daeva.iconset"
rm -rf "${iconset:?}"; mkdir -p "$iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s "$cache/icon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$cache/icon.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$res/Daeva.icns"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Daeva</string>
  <key>CFBundleDisplayName</key><string>Daeva</string>
  <key>CFBundleIdentifier</key><string>dev.nachtlamb.daeva</string>
  <key>CFBundleExecutable</key><string>Daeva</string>
  <key>CFBundleIconFile</key><string>Daeva</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version#v}</string>
  <key>CFBundleVersion</key><string>${version#v}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>DaevaUpdateRepo</key><string>${DAEVA_UPDATE_REPO:-nachtlamb/daeva}</string>
  <key>DiscordClientID</key><string>${DISCORD_CLIENT_ID:-1562519574694330388}</string>
</dict></plist>
EOF

echo "==> signing (${DAEVA_SIGN_IDENTITY:-ad-hoc})"
codesign --force --deep --options runtime --timestamp=none -s "${DAEVA_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"

if [ "${1:-}" = "--dmg" ]; then
    dmg="$out/Daeva-${version#v}.dmg"
    stage="$out/dmg"
    rm -rf "${stage:?}" "$dmg"
    mkdir -p "$stage"
    cp -R "$app" "$stage/"
    ln -s /Applications "$stage/Applications"
    echo "==> $dmg"
    hdiutil create -volname "Daeva" -srcfolder "$stage" -fs APFS -format ULFO -ov "$dmg" >/dev/null
    rm -rf "${stage:?}"
    shasum -a 256 "$dmg"
fi
echo "==> done: $app"
