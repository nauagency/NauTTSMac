#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_name="Nau TTS Mac.app"
build_root="$repo_root/dist/macos"
app_path="$build_root/$app_name"
contents="$app_path/Contents"
iconset="$build_root/AppIcon.iconset"
square_icon="$build_root/AppIcon-square.png"
source_icon="$repo_root/assets/nau-tts-mac-icon.png"

swift build --package-path "$repo_root" -c release

rm -rf "$app_path" "$iconset" "$square_icon"
mkdir -p "$contents/MacOS" "$contents/Resources" "$iconset"
cp "$repo_root/.build/release/NauTTSMac" "$contents/MacOS/NauTTSMac"
cp "$repo_root/macos/Info.plist" "$contents/Info.plist"
cp "$repo_root/macos/builtin-voices.json" "$contents/Resources/builtin-voices.json"
mkdir -p "$contents/Resources/DefaultVoices"
cp "$repo_root/macos/default-voices/voices.json" "$contents/Resources/DefaultVoices/voices.json"
cp "$repo_root/macos/default-voices/Voices/"* "$contents/Resources/DefaultVoices/"
/usr/libexec/PlistBuddy -c "Set :NauTTSProjectRoot $repo_root" "$contents/Info.plist"

cp "$source_icon" "$square_icon"

for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -s format png -z "$size" "$size" "$square_icon" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z "$double" "$double" "$square_icon" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"
rm -rf "$iconset" "$square_icon"

codesign --force --deep --sign - "$app_path"

if [[ "${1:-}" == "--install" ]]; then
    if [[ -w "/Applications" ]]; then
        install_dir="/Applications"
    else
        install_dir="$HOME/Applications"
        mkdir -p "$install_dir"
    fi
    ditto "$app_path" "$install_dir/$app_name"
    touch "$install_dir/$app_name"
    echo "$install_dir/$app_name"
else
    echo "$app_path"
fi
