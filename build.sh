#!/bin/bash
# Builds Swivel.app into ./build
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
# The shipped executable drops local symbols (about 3 MB each for the app and its helper); build/Swivel.dSYM keeps
# them, so crash reports from this build can still be symbolicated (`atos -o build/Swivel.dSYM/... -l <load address>`).
mkdir -p build
rm -rf build/Swivel.dSYM
dsymutil .build/release/Swivel -o build/Swivel.dSYM
EXECUTABLE=build/Swivel-stripped
cp .build/release/Swivel "$EXECUTABLE"
strip -x "$EXECUTABLE"
APP=build/Swivel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/Swivel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Swivel.icns "$APP/Contents/Resources/Swivel.icns"
# Licences of vendored third-party data (Mac Doctor), inside the signature.
mkdir -p "$APP/Contents/Resources/ThirdParty"
cp ThirdParty/ClearDisk/LICENSE "$APP/Contents/Resources/ThirdParty/ClearDisk-LICENSE.txt"
# The approved Real-ESRGAN model runs through Core ML; ship model data and licences, never conversion tools.
cp -R .build/release/Swivel_UpscaleModel.bundle "$APP/Contents/Resources/Swivel_UpscaleModel.bundle"
cp ThirdParty/RealESRGAN/LICENSE "$APP/Contents/Resources/ThirdParty/RealESRGAN-LICENSE.txt"
cp ThirdParty/RealESRGAN/LICENSE-BasicSR.txt "$APP/Contents/Resources/ThirdParty/RealESRGAN-BasicSR-LICENSE.txt"
cp ThirdParty/RealESRGAN/NOTICE "$APP/Contents/Resources/ThirdParty/RealESRGAN-NOTICE.txt"
# The Claude Desktop extension (Settings → General → Agents → Install in Claude Desktop). Its launcher starts the
# installed app, so the bundle holds no second copy of Swivel.
mcpb/pack.sh "$APP/Contents/Resources/Swivel.mcpb" >/dev/null
# The agent tool server's own background-only app (`Swivel --mcp` execs it; see MCPStdio.handOffToHelper): the same
# executable under another bundle identifier, so Launch Services never takes the server for Swivel.app.
HELPER="$APP/Contents/Helpers/Swivel MCP.app"
mkdir -p "$HELPER/Contents/MacOS"
cp "$EXECUTABLE" "$HELPER/Contents/MacOS/Swivel"
cp Resources/Info.plist "$HELPER/Contents/Info.plist"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $APP_ID.mcp" \
    -c "Set :CFBundleName Swivel MCP" \
    -c "Set :CFBundleDisplayName Swivel MCP" \
    -c "Delete :CFBundleIconFile" \
    -c "Delete :LSUIElement" \
    -c "Add :LSBackgroundOnly bool true" \
    -c "Add :SwivelAppIdentifier string $APP_ID" \
    "$HELPER/Contents/Info.plist" 2>/dev/null || true
# Hardened runtime: no DYLD_* injection or unsigned libraries in the shipped app. Don't add entitlements that
# re-enable either (allow-dyld-environment-variables, disable-library-validation). The helper is signed first.
codesign --force --options runtime --sign - "$HELPER" >/dev/null
codesign --force --options runtime --sign - "$APP" >/dev/null
echo "Built $APP"
