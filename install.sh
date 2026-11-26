#!/bin/bash
# Instala (o actualiza) Txispa y la abre.
#   curl -fsSL https://raw.githubusercontent.com/davidpedrosamorales-dotcom/txispa/main/install.sh | bash
set -euo pipefail

REPO="davidpedrosamorales-dotcom/txispa"
BASE="${TXISPA_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

# Idioma: el del Mac (español, catalán, gallego o euskera → español; si no, inglés)
lang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | tr -d ' ",')
case "$lang" in es*|ca*|gl*|eu*) ES=1 ;; *) ES=0 ;; esac
t() { if [ "$ES" = 1 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

say() { printf '\033[1;38;5;209m›\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "$(t "Txispa solo funciona en macOS." "Txispa only runs on macOS.")"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || fail "$(t "Txispa necesita macOS 15 o posterior (tienes $(sw_vers -productVersion))." "Txispa needs macOS 15 or later (you have $(sw_vers -productVersion)).")"

# Dónde instalar: donde ya esté (también con su nombre antiguo, Chispa); si no, en /Applications (o en ~/Applications si no se puede escribir allí)
if [ -d "/Applications/Txispa.app" ] || [ -d "/Applications/Chispa.app" ]; then DEST="/Applications"
elif [ -d "$HOME/Applications/Txispa.app" ] || [ -d "$HOME/Applications/Chispa.app" ]; then DEST="$HOME/Applications"
elif [ -w "/Applications" ]; then DEST="/Applications"
else DEST="$HOME/Applications"; mkdir -p "$DEST"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "$(t "Descargando Txispa…" "Downloading Txispa…")"
curl -fsSL -o "$TMP/Txispa.zip" "$BASE/Txispa.zip" || fail "$(t "No se pudo descargar Txispa.zip." "Couldn't download Txispa.zip.")"
curl -fsSL -o "$TMP/Txispa.zip.sha256" "$BASE/Txispa.zip.sha256" || fail "$(t "No se pudo descargar la huella SHA-256." "Couldn't download the SHA-256 checksum.")"

say "$(t "Comprobando la descarga…" "Checking the download…")"
expected=$(awk '{print $1}' "$TMP/Txispa.zip.sha256")
actual=$(shasum -a 256 "$TMP/Txispa.zip" | awk '{print $1}')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "$(t "La descarga no coincide con su huella SHA-256. No se instala nada." "The download doesn't match its SHA-256 checksum. Nothing was installed.")"

ditto -x -k "$TMP/Txispa.zip" "$TMP/app"
[ -d "$TMP/app/Txispa.app" ] || fail "$(t "El archivo descargado no contiene Txispa.app." "The download doesn't contain Txispa.app.")"
version=$(defaults read "$TMP/app/Txispa.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")

if pgrep -x Txispa >/dev/null || pgrep -x Chispa >/dev/null; then
  say "$(t "Cerrando la Txispa que estaba abierta…" "Closing the running Txispa…")"
  pkill -x Txispa || true
  pkill -x Chispa || true     # nombre antiguo
  sleep 1
fi

say "$(t "Instalando Txispa ${version} en ${DEST}…" "Installing Txispa ${version} in ${DEST}…")"
rm -rf "$DEST/Txispa.app"
# Antes se llamaba Chispa: se quita la app antigua (los ajustes y permisos se conservan)
if [ -d "$DEST/Chispa.app" ]; then
  say "$(t "Chispa ahora se llama Txispa: quito la app antigua (tus ajustes se conservan)…" "Chispa is now called Txispa: removing the old app (your settings are kept)…")"
  rm -rf "$DEST/Chispa.app"
fi
ditto "$TMP/app/Txispa.app" "$DEST/Txispa.app"

say "$(t "Abriendo Txispa…" "Opening Txispa…")"
open "$DEST/Txispa.app"
printf '\n\033[1;32m✓\033[0m %s\n' "$(t "Txispa ${version} instalada en ${DEST}. Sigue los pasos de la ventana de bienvenida." "Txispa ${version} installed in ${DEST}. Follow the steps in the welcome window.")"
