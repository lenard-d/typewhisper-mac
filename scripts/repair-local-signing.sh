#!/bin/bash
set -euo pipefail
umask 077

usage() {
    cat <<'EOF'
Inspect an installed local TypeWhisper build:
  scripts/repair-local-signing.sh --check [--app /Applications/TypeWhisper.app]

Create a repaired copy without changing or starting the source app:
  scripts/repair-local-signing.sh --app APP --output NEW_APP \
    --identity CERTIFICATE_SHA1 --team-id TEAM_ID

Use a valid Apple Development identity from:
  security find-identity -v -p codesigning

NEW_APP must not exist. This helper does not install the copy, change Keychain
items, or reset macOS permissions. Provisioned and production apps are rejected.
See docs/local-permission-repair.md before replacing an installed app.
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

app=/Applications/TypeWhisper.app
output=
identity=
team_id=
check=false
while (($#)); do
    case "$1" in
        --check) check=true; shift ;;
        --app|--output|--identity|--team-id)
            (($# >= 2)) || fail "Missing value for $1"
            case "$1" in
                --app) app=$2 ;;
                --output) output=$2 ;;
                --identity) identity=$2 ;;
                --team-id) team_id=$2 ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ $(uname -s) == Darwin ]] || fail 'This helper requires macOS.'
[[ -d "$app" ]] || fail "App not found: $app"
app=$(cd "$app" && pwd -P)
repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
plist_buddy=/usr/libexec/PlistBuddy
[[ $("$plist_buddy" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") == com.typewhisper.mac ]] ||
    fail 'Expected the release bundle ID com.typewhisper.mac.'

bundles=(
    'Contents/PlugIns/TypeWhisperTranscribeAction.appex'
    'Contents/PlugIns/TypeWhisperWidgetExtension.appex'
    'Contents/XPCServices/TypeWhisperICloudBridge.xpc'
    '.'
)
templates=(
    "$repo_root/TypeWhisperTranscribeAction/TypeWhisperTranscribeAction.entitlements"
    "$repo_root/TypeWhisperWidgetExtension/TypeWhisperWidgetExtension.entitlements"
    ''
    "$repo_root/TypeWhisper/Resources/TypeWhisper.entitlements"
)

for relative in "${bundles[@]}"; do
    bundle="$app/$relative"
    [[ -d "$bundle" && ! -L "$bundle" && ! -L "$bundle/Contents/Info.plist" ]] ||
        fail "Unsupported bundle layout: $relative"
    if $check; then
        printf '\n%s\n' "$bundle"
        codesign -dv "$bundle" 2>&1
        "$plist_buddy" -c 'Print :AppGroupIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true
        codesign -d --entitlements :- "$bundle" 2>/dev/null
    fi
done
codesign --verify --deep --strict "$app"
if $check; then
    [[ -z "$output$identity$team_id" ]] || fail '--check cannot be used with repair options.'
    exit 0
fi

[[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || fail '--identity must be a certificate SHA-1 hash.'
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || fail '--team-id must be the ten-character certificate Team ID.'
identity=$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')
identity_entry=$(security find-identity -v -p codesigning | grep -F "$identity" || true)
[[ "$identity_entry" == *'"Apple Development:'* ]] || fail 'A valid Apple Development signing identity is required.'
[[ -n "$output" && "$output" == *.app && ! -e "$output" && ! -L "$output" ]] ||
    fail '--output must be a new .app path.'
output_parent=$(cd "$(dirname "$output")" && pwd -P)
output="$output_parent/$(basename "$output")"
case "$output/" in
    "$app/"*|/Applications/*|"$HOME/Applications/"*)
        fail 'Choose a staging path outside the source app and Applications folders.' ;;
esac
[[ -z $(find "$app" -name embedded.provisionprofile -print -quit) ]] ||
    fail 'Provisioned apps need the release signing workflow.'
signing_details=$(codesign -dv "$app" 2>&1)
[[ "$signing_details" != *'Authority=Developer ID Application:'* ]] ||
    fail 'Use the official release workflow for a Developer ID app.'

work=$(mktemp -d "$output_parent/.typewhisper-signing.XXXXXX")
cleanup() { find -P "$work" -depth -delete; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
staged="$work/TypeWhisper.app"
group_id="$team_id.com.typewhisper.mac"

# Preserve existing entitlements. Use repo defaults only when a bundle has none.
for index in "${!bundles[@]}"; do
    bundle="$app/${bundles[$index]}"
    entitlements="$work/entitlements-$index.plist"
    codesign -d --entitlements :- "$bundle" > "$entitlements" 2>/dev/null
    if [[ -s "$entitlements" ]]; then
        plutil -lint "$entitlements" >/dev/null
    fi
    if [[ ! -s "$entitlements" ]] || [[ $(plutil -p "$entitlements") == $'{\n}' ]]; then
        if [[ -n "${templates[$index]}" ]]; then
            cp "${templates[$index]}" "$entitlements"
        else
            plutil -create xml1 "$entitlements"
        fi
    fi
    plutil -lint "$entitlements" >/dev/null
    xml=$(plutil -convert xml1 -o - "$entitlements")
    case "$xml" in
        *'<key>com.apple.developer.'*|*'<key>keychain-access-groups</key>'*|*'<key>application-identifier</key>'*|*'<key>com.apple.application-identifier</key>'*)
            fail 'Registered capabilities need the release signing workflow; no copy was installed.' ;;
    esac
    if [[ $index != 0 ]]; then
        if "$plist_buddy" -c 'Print :com.apple.security.application-groups:1' "$entitlements" >/dev/null 2>&1; then
            fail 'Multiple App Groups need a manual review before signing.'
        fi
        previous_group=$("$plist_buddy" -c 'Print :com.apple.security.application-groups:0' "$entitlements" 2>/dev/null || true)
        case "$previous_group" in
            ''|'$(APP_GROUP_ID)'|*.com.typewhisper.mac) ;;
            *) fail "Unexpected App Group: $previous_group" ;;
        esac
        "$plist_buddy" -c 'Delete :com.apple.security.application-groups' "$entitlements" 2>/dev/null || true
        "$plist_buddy" -c 'Add :com.apple.security.application-groups array' "$entitlements"
        "$plist_buddy" -c "Add :com.apple.security.application-groups:0 string $group_id" "$entitlements"
    fi
done

ditto "$app" "$staged"
# Sign inner bundles first. Do not use --deep to sign nested code.
for index in "${!bundles[@]}"; do
    bundle="$staged/${bundles[$index]}"
    if [[ $index != 0 ]]; then
        "$plist_buddy" -c 'Delete :AppGroupIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true
        "$plist_buddy" -c "Add :AppGroupIdentifier string $group_id" "$bundle/Contents/Info.plist"
    fi
    codesign --force --sign "$identity" --options runtime \
        --entitlements "$work/entitlements-$index.plist" "$bundle"
    details=$(codesign -dv "$bundle" 2>&1)
    [[ "$details" == *"TeamIdentifier=$team_id"* ]] || fail 'Certificate and requested Team ID do not match.'

    # Strip signatures from disposable executable copies to check code equality.
    executable=$("$plist_buddy" -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")
    cp "$app/${bundles[$index]}/Contents/MacOS/$executable" "$work/original-code"
    cp "$bundle/Contents/MacOS/$executable" "$work/repaired-code"
    codesign --remove-signature "$work/original-code"
    codesign --remove-signature "$work/repaired-code"
    cmp -s "$work/original-code" "$work/repaired-code" || fail 'Executable code changed.'
done
codesign --verify --deep --strict "$staged"
[[ ! -e "$output" && ! -L "$output" ]] || fail 'Output appeared during signing; refusing to replace it.'
mv -n "$staged" "$output"
[[ ! -e "$staged" ]] || fail 'Output was not moved; another file may occupy the path.'
printf '\nVerified repair copy: %s\nTeam ID: %s\nApp Group: %s\n' "$output" "$team_id" "$group_id"
printf 'Source app unchanged. Follow docs/local-permission-repair.md to install and test.\n'
