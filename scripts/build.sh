#!/bin/zsh
set -euo pipefail
repo_dir=${0:A:h:h}
build_dir="$repo_dir/build"
dist_dir="$repo_dir/dist"
package_dir="$build_dir/WhatsAppCall.dynamiclakeplugin"
version=$(/usr/bin/plutil -extract version raw -- "$repo_dir/plugin.json")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo 'Invalid version' >&2; exit 1; }
/bin/mkdir -p "$build_dir" "$dist_dir"
# Only replace this plugin's generated package; preserve older release archives.
/bin/rm -rf "$package_dir"
/bin/mkdir -p "$package_dir/Assets"
module_cache=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$module_cache"' EXIT
sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
for architecture in arm64 x86_64; do
    /usr/bin/xcrun swiftc -parse-as-library -O \
        -target "$architecture-apple-macos14.2" -sdk "$sdk_path" \
        -module-cache-path "$module_cache" \
        "$repo_dir/Sources/WhatsAppCallPlugin.swift" \
        -o "$build_dir/whatsapp-call-monitor-$architecture"
done
/usr/bin/lipo -create "$build_dir/whatsapp-call-monitor-arm64" \
    "$build_dir/whatsapp-call-monitor-x86_64" -output "$package_dir/whatsapp-call-monitor"
/bin/chmod 755 "$package_dir/whatsapp-call-monitor"
/bin/cp "$repo_dir/plugin.json" "$repo_dir/WhatsAppCallIcon.png" "$repo_dir/README.md" \
    "$repo_dir/THIRD_PARTY_NOTICES.md" "$package_dir/"
/bin/cp "$repo_dir/Assets/WhatsAppLightIcon.png" "$repo_dir/Assets/provenance.json" "$package_dir/Assets/"
archive="$dist_dir/WhatsAppCall-$version.dynamiclakeplugin.zip"
/usr/bin/ditto -c -k --keepParent "$package_dir" "$archive"
(cd "$dist_dir" && /usr/bin/shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
echo "Built $package_dir"
echo "Archive $archive"
/usr/bin/lipo -archs "$package_dir/whatsapp-call-monitor"
