#!/bin/bash
# Instala (o actualiza) Chispa y la abre.
#   curl -fsSL https://raw.githubusercontent.com/davidpedrosamorales-dotcom/chispa/main/install.sh | bash
set -euo pipefail

REPO="davidpedrosamorales-dotcom/chispa"
BASE="${CHISPA_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

say() { printf '\033[1;38;5;209m›\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Chispa solo funciona en macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || fail "Chispa necesita macOS 15 o posterior (tienes $(sw_vers -productVersion))."

# Dónde instalar: donde ya esté; si no, en /Applications (o en ~/Applications si no se puede escribir allí)
if [ -d "/Applications/Chispa.app" ]; then DEST="/Applications"
elif [ -d "$HOME/Applications/Chispa.app" ]; then DEST="$HOME/Applications"
elif [ -w "/Applications" ]; then DEST="/Applications"
else DEST="$HOME/Applications"; mkdir -p "$DEST"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Descargando Chispa…"
curl -fsSL -o "$TMP/Chispa.zip" "$BASE/Chispa.zip" || fail "No se pudo descargar Chispa.zip."
curl -fsSL -o "$TMP/Chispa.zip.sha256" "$BASE/Chispa.zip.sha256" || fail "No se pudo descargar la huella SHA-256."

say "Comprobando la descarga…"
expected=$(awk '{print $1}' "$TMP/Chispa.zip.sha256")
actual=$(shasum -a 256 "$TMP/Chispa.zip" | awk '{print $1}')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "La descarga no coincide con su huella SHA-256. No se instala nada."

ditto -x -k "$TMP/Chispa.zip" "$TMP/app"
[ -d "$TMP/app/Chispa.app" ] || fail "El archivo descargado no contiene Chispa.app."
version=$(defaults read "$TMP/app/Chispa.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")

if pgrep -x Chispa >/dev/null; then
  say "Cerrando la Chispa que estaba abierta…"
  pkill -x Chispa || true
  sleep 1
fi

say "Instalando Chispa ${version} en ${DEST}…"
rm -rf "$DEST/Chispa.app"
ditto "$TMP/app/Chispa.app" "$DEST/Chispa.app"

say "Abriendo Chispa…"
open "$DEST/Chispa.app"
printf '\n\033[1;32m✓\033[0m Chispa %s instalada en %s. Sigue los pasos de la ventana de bienvenida.\n' "$version" "$DEST"
