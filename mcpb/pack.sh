#!/bin/bash
# Packs mcpb/ into build/Swivel.mcpb, or the path given (a zip with manifest.json at its root), for Claude Desktop:
# Settings → General → Agents → Install in Claude Desktop (build.sh ships it in the app), `open -a Claude Swivel.mcpb`,
# or Claude's Settings → Extensions → Advanced settings → Install Extension….
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-build/Swivel.mcpb}" in
    /*) OUT="${1:-build/Swivel.mcpb}" ;;
    *) OUT="$PWD/${1:-build/Swivel.mcpb}" ;;
esac
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp mcpb/manifest.json "$STAGE/"
mkdir "$STAGE/server"
cp mcpb/server/swivel-mcp "$STAGE/server/"
chmod 755 "$STAGE/server/swivel-mcp"
sips -s format png -Z 256 Resources/Swivel.icns --out "$STAGE/icon.png" >/dev/null
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$STAGE" && /usr/bin/zip -q -r -X "$OUT" manifest.json icon.png server)
echo "Packed $OUT"
