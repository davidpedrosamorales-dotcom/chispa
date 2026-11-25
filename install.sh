#!/bin/bash
# Instala (o actualiza) Chispa y la abre.
#   curl -fsSL https://raw.githubusercontent.com/davidpedrosamorales-dotcom/chispa/main/install.sh | bash
set -euo pipefail

REPO="davidpedrosamorales-dotcom/chispa"
BASE="${CHISPA_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

# Idioma: el del Mac (español, catalán, gallego o euskera → español; si no, inglés)
lang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | tr -d ' ",')
case "$lang" in es*|ca*|gl*|eu*) ES=1 ;; *) ES=0 ;; esac
t() { if [ "$ES" = 1 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

say() { printf '\033[1;38;5;209m›\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "$(t "Chispa solo funciona en macOS." "Chispa only runs on macOS.")"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || fail "$(t "Chispa necesita macOS 15 o posterior (tienes $(sw_vers -productVersion))." "Chispa needs macOS 15 or later (you have $(sw_vers -productVersion)).")"

# Dónde instalar: donde ya esté; si no, en /Applications (o en ~/Applications si no se puede escribir allí)
if [ -d "/Applications/Chispa.app" ]; then DEST="/Applications"
elif [ -d "$HOME/Applications/Chispa.app" ]; then DEST="$HOME/Applications"
elif [ -w "/Applications" ]; then DEST="/Applications"
else DEST="$HOME/Applications"; mkdir -p "$DEST"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "$(t "Descargando Chispa…" "Downloading Chispa…")"
curl -fsSL -o "$TMP/Chispa.zip" "$BASE/Chispa.zip" || fail "$(t "No se pudo descargar Chispa.zip." "Couldn't download Chispa.zip.")"
curl -fsSL -o "$TMP/Chispa.zip.sha256" "$BASE/Chispa.zip.sha256" || fail "$(t "No se pudo descargar la huella SHA-256." "Couldn't download the SHA-256 checksum.")"

say "$(t "Comprobando la descarga…" "Checking the download…")"
expected=$(awk '{print $1}' "$TMP/Chispa.zip.sha256")
actual=$(shasum -a 256 "$TMP/Chispa.zip" | awk '{print $1}')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "$(t "La descarga no coincide con su huella SHA-256. No se instala nada." "The download doesn't match its SHA-256 checksum. Nothing was installed.")"

ditto -x -k "$TMP/Chispa.zip" "$TMP/app"
[ -d "$TMP/app/Chispa.app" ] || fail "$(t "El archivo descargado no contiene Chispa.app." "The download doesn't contain Chispa.app.")"
version=$(defaults read "$TMP/app/Chispa.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")

if pgrep -x Chispa >/dev/null; then
  say "$(t "Cerrando la Chispa que estaba abierta…" "Closing the running Chispa…")"
  pkill -x Chispa || true
  sleep 1
fi

say "$(t "Instalando Chispa ${version} en ${DEST}…" "Installing Chispa ${version} in ${DEST}…")"
rm -rf "$DEST/Chispa.app"
ditto "$TMP/app/Chispa.app" "$DEST/Chispa.app"

say "$(t "Abriendo Chispa…" "Opening Chispa…")"
open "$DEST/Chispa.app"
printf '\n\033[1;32m✓\033[0m %s\n' "$(t "Chispa ${version} instalada en ${DEST}. Sigue los pasos de la ventana de bienvenida." "Chispa ${version} installed in ${DEST}. Follow the steps in the welcome window.")"
