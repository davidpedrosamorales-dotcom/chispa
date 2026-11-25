#!/bin/zsh
# Compila Chispa (Apple Silicon + Intel) y deja Chispa.app y Chispa.zip en build/
# Solo necesita las Command Line Tools de Xcode:  xcode-select --install
set -e
cd "${0:A:h}"
rm -rf build && mkdir -p build/Chispa.app/Contents/{MacOS,Resources}
echo "Compilando para Apple Silicon…"
swiftc -O -target arm64-apple-macos15.0 main.swift -o build/Chispa.arm64
echo "Compilando para Intel…"
swiftc -O -target x86_64-apple-macos15.0 main.swift -o build/Chispa.x86_64
lipo -create build/Chispa.arm64 build/Chispa.x86_64 -output build/Chispa.app/Contents/MacOS/Chispa
rm build/Chispa.arm64 build/Chispa.x86_64
cp Info.plist build/Chispa.app/Contents/
cp claude-hook.sh build/Chispa.app/Contents/Resources/
chmod +x build/Chispa.app/Contents/Resources/claude-hook.sh
codesign -s - --force --identifier local.chispa build/Chispa.app
(cd build && ditto -c -k --norsrc --noextattr --keepParent Chispa.app Chispa.zip)
echo "Listo: build/Chispa.app  (y build/Chispa.zip para publicar)"
