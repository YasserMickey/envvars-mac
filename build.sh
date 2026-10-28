#!/bin/bash
# Builds EnvVars.app from the Swift sources. Needs Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install"
  exit 1
fi

APP="EnvVars.app"
SOURCES=(Sources/*.swift)
rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {  # $1 = arch
  swiftc -parse-as-library -O -target "$1-apple-macos13.0" \
    -framework SwiftUI -framework AppKit \
    -o "build/EnvVars-$1" "${SOURCES[@]}"
}

echo "Compiling (this takes a minute)..."
if compile arm64 && compile x86_64; then
  lipo -create -output "$APP/Contents/MacOS/EnvVars" build/EnvVars-arm64 build/EnvVars-x86_64
  echo "Built a universal app (Apple Silicon + Intel)."
else
  echo "Universal build failed; building for this Mac only."
  swiftc -parse-as-library -O -framework SwiftUI -framework AppKit \
    -o "$APP/Contents/MacOS/EnvVars" "${SOURCES[@]}"
fi

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
rm -rf build

echo
echo "Done: $(pwd)/$APP"
echo "Open it with:  open EnvVars.app   (or drag it to your Applications folder)"
