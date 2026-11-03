#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$root/../dist/desktop}"
mkdir -p "$out" "$root/../dist/module-cache"
out="$(cd "$out" && pwd)"
export CLANG_MODULE_CACHE_PATH="$root/../dist/module-cache"

bundle() {
  local name="$1" identifier="$2" source="$3"
  local app="$out/$name.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  local sources=("$source")
  if [ "$name" = "Swarm Desktop" ]; then sources=("$root/Core.swift" "$root/Bridge.swift" "$source"); fi
  swiftc -O -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -framework AppKit -framework ApplicationServices "${sources[@]}" -o "$app/Contents/MacOS/$name"
  /usr/bin/python3 - "$app/Contents/Info.plist" "$name" "$identifier" "$root/../dist/bridge" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleName=sys.argv[2], CFBundleDisplayName=sys.argv[2],
        CFBundleExecutable=sys.argv[2], CFBundleIdentifier=sys.argv[3],
        CFBundlePackageType='APPL', CFBundleShortVersionString='0.2.0', CFBundleVersion='2',
        SwarmBridgeDirectory=sys.argv[4],
        LSMinimumSystemVersion='13.0', NSHighResolutionCapable=True,
        NSAppTransportSecurity=dict(NSAllowsLocalNetworking=True)), f)
PY
  if [ "$name" = "Swarm Desktop" ]; then
    cp "$root/action-schema.json" "$root/planner-system.txt" "$app/Contents/Resources/"
  fi
  codesign --force --sign - "$app"
}
bundle "Swarm Desktop" "com.infinitule.swarm.desktop" "$root/main.swift"
bundle "Swarm Practice" "com.infinitule.swarm.practice" "$root/practice/main.swift"
swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$root/Core.swift" "$root/tests/main.swift" -o "$root/../dist/validate-actions"
"$root/../dist/validate-actions"
codesign --verify --deep --strict "$out/Swarm Desktop.app"
codesign --verify --deep --strict "$out/Swarm Practice.app"
printf 'Built: %s\n' "$out/Swarm Desktop.app" "$out/Swarm Practice.app"
