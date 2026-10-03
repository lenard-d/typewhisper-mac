# Repeated permissions in a local macOS build

Use this guide when a custom TypeWhisper build repeatedly asks for Keychain
access or access to data from other apps. Check the actual installed bundle,
usually `/Applications/TypeWhisper.app`. A checkout or an Xcode build can have a
different signature.

This procedure repairs local signing. It does not repair every possible
permission problem. For an official Developer ID release, use
`scripts/archive_release.sh` and `scripts/check_release_signing.sh` instead.

## What happened on 2026-10-03

The installed custom build, version 1.7.0, had two problems:

- It used ad-hoc signing with no Team ID and no signed entitlements. Keychain
  access rules referred to other signing identities or older code hashes.
- Its `AppGroupIdentifier` was `.com.typewhisper.mac`, with no Team ID prefix.
  Writes to `~/Library/Group Containers/.com.typewhisper.mac/widgetData.json`
  triggered the request to access data from other apps.

The user selected "Immer erlauben" for Keychain access, but requests returned.
The app-data request was a separate issue. macOS can grant that access only for
the current process. It resets when the app quits. See Apple's
[privacy session, App sandbox chapter](https://developer.apple.com/videos/play/wwdc2023/10053/).

We kept the executable code and repaired the signature, entitlements, and App
Group metadata. We used an existing Apple Development certificate and its actual
Team ID. Main app, widget, Finder action, and XPC helper used the same signer.
Main app, widget, and XPC helper used `TEAM_ID.com.typewhisper.mac` in both
`Info.plist` and the signed App Group entitlement.

The local XPC helper had no iCloud entitlements or provisioning profile before
the repair. We added only its App Group entitlement. This did not add production
iCloud support. Do not remove iCloud capabilities from a provisioned release.

Verification passed:

- Strict recursive signature verification passed.
- All four executable files were identical after stripping signatures from
  disposable copies.
- Two full quit/start cycles produced no repeated Keychain or app-data requests.
- A short CLI transcription succeeded with the configured provider.
- The user confirmed that microphone dictation recorded and inserted text.

The repaired signature matched saved OpenRouter and Groq access rules. The user
completed the final macOS dialogs, which restored local API access. OpenRouter
transcription worked. We did not change inactive provider entries or claim that
every saved Keychain item matched the new signer. The temporary app backup was
deleted only after verification.

## Inspect before changing anything

From the repository root, run:

```bash
scripts/repair-local-signing.sh --check --app /Applications/TypeWhisper.app
security find-identity -v -p codesigning
```

The check is read-only. It prints signer, Team ID, App Group metadata, and signed
entitlements for the main app and the three known nested bundles. It also runs
`codesign --verify --deep --strict`. A valid signature alone does not prove that
the signer or App Group is correct. Ad-hoc signing can pass that check.

Look for `Signature=adhoc`, `TeamIdentifier=not set`, missing entitlements, or an
App Group without the correct team prefix. The same group must appear in the
main app, widget, and XPC helper. The Finder action does not need that group.

If these settings are correct, inspect the specific Keychain item's access rules
in Keychain Access. A locked login keychain or a rule for another signer requires
a different diagnosis. Do not read or print API keys during inspection.

## Create a repair copy

Use a valid Apple Development identity from `security find-identity`. Pass its
40-character SHA-1 hash. Get the Team ID from the certificate's subject `OU`
field, or from a known bundle signed with that certificate. The identifier in
parentheses in the certificate name is not necessarily the Team ID.

To inspect a certificate's public subject and expiration date:

```bash
security find-certificate -c 'Apple Development: YOUR_CERTIFICATE_NAME' -p |
  openssl x509 -noout -subject -dates
```

Replace the placeholders below. Keep `repair_dir` in the same shell for the
installation and cleanup steps.

```bash
repair_dir=$(mktemp -d /private/tmp/typewhisper-permission-repair.XXXXXX)
scripts/repair-local-signing.sh \
  --app /Applications/TypeWhisper.app \
  --output "$repair_dir/TypeWhisper.app" \
  --identity YOUR_40_CHARACTER_CERTIFICATE_SHA1 \
  --team-id YOUR_TEAM_ID
```

The helper preserves existing entitlements and uses repository defaults when
they are absent. It repairs the single TypeWhisper App Group, signs inner bundles
first, checks each Team ID, compares executable code, and verifies the complete
bundle. It leaves the source app and user data unchanged. It creates no backup
because this step changes only a new copy.

The helper rejects Developer ID apps, embedded provisioning profiles, registered
capabilities such as iCloud or Keychain access groups, unexpected or multiple
App Groups, and unknown bundle layouts. It will not overwrite an output path or
write a repair copy into an Applications folder. Use the release workflow or
review those cases manually. It requires no new tool installation.

## Install and verify

Do this only when the installed app is the intended target and the repair copy
passed all checks. Quit TypeWhisper from its menu. Confirm that no process is
still running from `/Applications/TypeWhisper.app` before copying files.

Replacing the installed bundle needs a temporary rollback copy. Back up only
the app bundle. This signing repair does not change history, recordings,
preferences, or stored secrets.

```bash
ditto /Applications/TypeWhisper.app "$repair_dir/Original.app"
ditto "$repair_dir/TypeWhisper.app" /Applications/TypeWhisper.app
codesign --verify --deep --strict /Applications/TypeWhisper.app
cmp "$repair_dir/TypeWhisper.app/Contents/MacOS/TypeWhisper" \
  /Applications/TypeWhisper.app/Contents/MacOS/TypeWhisper
open /Applications/TypeWhisper.app
```

Enter the login keychain password only in the macOS dialog and select
"Immer erlauben" for the expected TypeWhisper item. Existing microphone,
Accessibility, or folder permissions may need one final approval after the
signer changes. Do not pass passwords to the helper. Do not reset all TCC
permissions or delete Keychain items to avoid the dialog.

Quit and start the installed app twice. Then record a short dictation and check
that it inserts the text. Confirm that neither the Keychain nor app-data request
returns. The CLI `status` command can check the configured engine, but it does
not replace a microphone and text insertion test.

If the test fails, quit TypeWhisper and restore the rollback copy:

```bash
ditto "$repair_dir/Original.app" /Applications/TypeWhisper.app
codesign --verify --deep --strict /Applications/TypeWhisper.app
open /Applications/TypeWhisper.app
```

After successful verification, delete only the temporary directory created
above. First confirm that `repair_dir` points to this repair session:

```bash
case "$repair_dir" in
  /private/tmp/typewhisper-permission-repair.??????)
    find -P "$repair_dir" -depth -delete ;;
  *) printf 'Unexpected repair directory; keep it and inspect the path.\n' >&2 ;;
esac
```

## Prevent another occurrence

Keep a certificate-backed signing identity and the correct App Group in future
local builds. Do not re-sign each update ad hoc. An ad-hoc designated requirement
depends on the code hash, so a new build can stop matching saved Keychain rules.
See Apple's [code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Set `DEVELOPMENT_TEAM` in `CodeSigning.local.xcconfig` and check the resulting
bundle. `CodeSigning.xcconfig` derives `APP_GROUP_ID` from that Team ID. Build
settings alone do not prove that entitlements reached the installed app. For
macOS App Groups, see Apple's [App Group guidance](https://developer.apple.com/forums/thread/758375).

Certificate expiration or a change of signer can require new access approval.
Apple Development signing is for local use. It does not replace Developer ID
signing, provisioning, or notarization for releases.
