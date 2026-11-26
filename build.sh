#!/bin/zsh
# Compila Txispa (Apple Silicon + Intel) y deja Txispa.app y Txispa.zip en build/
# Solo necesita las Command Line Tools de Xcode:  xcode-select --install
set -e
cd "${0:A:h}"
rm -rf build && mkdir -p build/Txispa.app/Contents/{MacOS,Resources}
echo "Compilando para Apple Silicon…"
swiftc -O -target arm64-apple-macos15.0 main.swift -o build/Txispa.arm64
echo "Compilando para Intel…"
swiftc -O -target x86_64-apple-macos15.0 main.swift -o build/Txispa.x86_64
lipo -create build/Txispa.arm64 build/Txispa.x86_64 -output build/Txispa.app/Contents/MacOS/Txispa
rm build/Txispa.arm64 build/Txispa.x86_64
cp Info.plist build/Txispa.app/Contents/
cp claude-hook.sh build/Txispa.app/Contents/Resources/
chmod +x build/Txispa.app/Contents/Resources/claude-hook.sh
codesign -s - --force --identifier local.chispa build/Txispa.app
(cd build && ditto -c -k --norsrc --noextattr --keepParent Txispa.app Txispa.zip && shasum -a 256 Txispa.zip > Txispa.zip.sha256)
echo "Listo: build/Txispa.app  (y build/Txispa.zip + Txispa.zip.sha256 para publicar)"
