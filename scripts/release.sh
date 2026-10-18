#!/usr/bin/env bash
# Builds DevInbox.app for release and writes DevInbox.dmg, appcast.xml and
# notes.md to .build/release/.
#
# Usage: scripts/release.sh [--app PATH] [--unsigned]
#   --app PATH   package an existing DevInbox.app instead of building one
#   --unsigned   don't sign the DMG, so SPARKLE_PRIVATE_KEY isn't needed
set -euo pipefail

version_prefix="0.1"
repository="YYYasin19/DevInbox"
minimum_system_version="26.0"
sparkle_version="2.10.0"
sparkle_sha256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"

cd "$(dirname "$0")/.."

app=""
sign=true
while (($#)); do
    case "$1" in
        --app) app="${2:?--app needs a path}"; shift 2 ;;
        --unsigned) sign=false; shift ;;
        *) echo "usage: scripts/release.sh [--app PATH] [--unsigned]" >&2; exit 64 ;;
    esac
done

if $sign && [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "error: SPARKLE_PRIVATE_KEY is not set (use --unsigned for a dry run)" >&2
    exit 1
fi

build_number=$(git rev-list --count HEAD)
version="$version_prefix.$build_number"
out=.build/release
echo "Releasing DevInbox $version ($build_number)"

if [[ -z "$app" ]]; then
    mise exec -- tuist generate --no-open
    xcodebuild -workspace DevInbox.xcworkspace -scheme DevInbox -configuration Release \
        -derivedDataPath .build/DerivedData-release -destination 'generic/platform=macOS' \
        MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" -quiet build
    app=.build/DerivedData-release/Build/Products/Release/DevInbox.app
    built=true
else
    built=false
fi

# Sparkle compares sparkle:version with the installed CFBundleVersion. If the
# bundle doesn't carry the build number, every check would offer this update again.
plist="$app/Contents/Info.plist"
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
bundle_short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
if [[ "$bundle_version" != "$build_number" || "$bundle_short_version" != "$version" ]]; then
    message="$app is $bundle_short_version ($bundle_version), expected $version ($build_number)"
    if $built; then
        echo "error: $message" >&2
        exit 1
    fi
    echo "warning: $message" >&2
fi

rm -rf "$out"
mkdir -p "$out"
dmg="$out/DevInbox.dmg"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
chmod 755 "$staging"
# Extended attributes such as FinderInfo break the code signature check.
ditto --norsrc --noextattr --noacl "$app" "$staging/DevInbox.app"
ln -s /Applications "$staging/Applications"
# hdiutil create fails intermittently ("Resource busy", "image not recognized").
for attempt in 1 2 3; do
    if hdiutil create -volname DevInbox -srcfolder "$staging" -format UDZO -ov "$dmg"; then
        break
    fi
    if ((attempt == 3)); then
        exit 1
    fi
    sleep 5
done
length=$(stat -f %z "$dmg")

signature_attribute=""
if $sign; then
    sparkle_dir=".build/sparkle-$sparkle_version"
    sign_update="$sparkle_dir/bin/sign_update"
    if [[ ! -x "$sign_update" ]]; then
        archive="$sparkle_dir.tar.xz"
        curl -fsSL -o "$archive" \
            "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
        # sign_update gets the private key, so only run the binary we checked.
        echo "$sparkle_sha256  $archive" | shasum -a 256 -c --quiet
        mkdir -p "$sparkle_dir"
        tar -xJf "$archive" -C "$sparkle_dir" ./bin/sign_update
        rm "$archive"
    fi
    # sign_update's error messages can contain the key, so they stay unprinted.
    if ! signature=$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - -p "$dmg"); then
        echo "error: sign_update failed; SPARKLE_PRIVATE_KEY must be the output of generate_keys -x" >&2
        exit 1
    fi
    signature_attribute=" sparkle:edSignature=\"$signature\""
fi

previous_tag=$(git describe --tags --abbrev=0 --match 'v*' --exclude "v$version" HEAD 2>/dev/null || true)
subjects=$(git log --no-merges --format=%s "${previous_tag:+$previous_tag..}HEAD")
html_items=$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|.*|<li>&</li>|' <<<"$subjects")
sed 's/^/- /' <<<"$subjects" >"$out/notes.md"

cat >"$out/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>DevInbox</title>
        <link>https://github.com/$repository</link>
        <description>Updates for DevInbox</description>
        <language>en</language>
        <item>
            <title>DevInbox $version</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$build_number</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$minimum_system_version</sparkle:minimumSystemVersion>
            <description><![CDATA[<ul>
$html_items
</ul>]]></description>
            <enclosure url="https://github.com/$repository/releases/download/v$version/DevInbox.dmg" length="$length" type="application/octet-stream"$signature_attribute/>
        </item>
    </channel>
</rss>
EOF

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "version=$version" >>"$GITHUB_OUTPUT"
fi
echo "Wrote $dmg, $out/appcast.xml and $out/notes.md${previous_tag:+ (changes since $previous_tag)}"
