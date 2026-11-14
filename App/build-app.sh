#!/bin/bash
set -e

# ============================================================
# 化形 HuaXing —— App Bundle Builder
# 构建根包 (huaxingctl) + App 子包 (huaxing GUI)，
# 然后把两个二进制 + Info.plist + 资源打包成 .app bundle。
# ============================================================

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/App"

APP_NAME="化形"
APP_BUNDLE="HuaXing.app"
BUNDLE_ID="im.yufei.huaxing"

ROOT_BUILD="$ROOT_DIR/.build/release"
APP_BUILD="$APP_DIR/.build/release"
BUNDLE_DIR="$ROOT_BUILD/$APP_BUNDLE"

echo "============================================"
echo " 化形 HuaXing — App Bundle Builder"
echo "============================================"

# 1. Build root package (huaxingctl)
echo ""
echo "[1/4] Building root package (huaxingctl)..."
cd "$ROOT_DIR"
swift build -c release --disable-sandbox -Xswiftc -disable-sandbox

# 2. Build App sub-package (huaxing GUI)
echo ""
echo "[2/4] Building App sub-package (huaxing GUI)..."
cd "$APP_DIR"
swift build -c release --disable-sandbox -Xswiftc -disable-sandbox

# 3. Create app bundle structure
echo ""
echo "[3/4] Assembling app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

# Copy executables — GUI + CLI 都在 bundle 里
cp "$APP_BUILD/huaxing" "$BUNDLE_DIR/Contents/MacOS/"
cp "$ROOT_BUILD/huaxingctl" "$BUNDLE_DIR/Contents/MacOS/"
echo "  ✓ huaxing (GUI)"
echo "  ✓ huaxingctl (CLI)"

# Copy Info.plist
cp "$ROOT_DIR/Resources/Info.plist" "$BUNDLE_DIR/Contents/"
echo "  ✓ Info.plist"

# Copy SwiftPM resource bundles (if any)
for bundle in "$APP_BUILD"/*.bundle; do
    [ -d "$bundle" ] || continue
    rm -rf "$BUNDLE_DIR/Contents/Resources/$(basename "$bundle")"
    cp -R "$bundle" "$BUNDLE_DIR/Contents/Resources/"
    echo "  ✓ $(basename "$bundle")"
done

# Copy icon (if present)
if [ -f "$ROOT_DIR/Resources/huaxing.icns" ]; then
    cp "$ROOT_DIR/Resources/huaxing.icns" "$BUNDLE_DIR/Contents/Resources/"
    echo "  ✓ huaxing.icns"
fi

# 4. Ad-hoc sign
echo ""
echo "[4/4] Codesigning..."
codesign --force --deep --sign - "$BUNDLE_DIR"
echo "  ✓ signed"

# Done
echo ""
echo "============================================"
echo " ✅ App bundle created: $BUNDLE_DIR"
echo "============================================"
echo ""
echo "To run:"
echo "  open $BUNDLE_DIR"
echo ""
echo "To install system-wide:"
echo "  sudo cp -r $BUNDLE_DIR /Applications/"
echo ""
echo "CLI companion lives at:"
echo "  $BUNDLE_DIR/Contents/MacOS/huaxingctl"
