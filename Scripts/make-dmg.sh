#!/bin/bash
# Builds a drag-to-install disk image: dist/SFTPsurf-<version>.dmg
#
# The image contains the app, an Applications alias, and a background that lines
# up with the icons Finder is told to place. Layout is applied to a read-write
# image and the result is then compressed, which is the only reliable order:
# Finder writes the arrangement into .DS_Store on the mounted volume.
#
# Usage:
#   Scripts/make-dmg.sh [output-dir]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/SFTPsurf.app"
OUT_DIR="${1:-$ROOT/dist}"
VOLUME_NAME="SFTPsurf"

# Icon geometry, in points from the window content's top-left. These must match
# the constants at the top of make-dmg-background.swift.
ICON_SIZE=110
TEXT_SIZE=12
APP_ICON_POS="{175, 205}"
APPS_ICON_POS="{525, 205}"
WINDOW_WIDTH=700
WINDOW_HEIGHT=440
# Finder window bounds include the title bar, so the window is placed with its
# top-left off-screen-safe at (200, 120).
WINDOW_BOUNDS="{200, 120, $((200 + WINDOW_WIDTH)), $((120 + WINDOW_HEIGHT))}"

fail() {
    echo "    ! $*" >&2
    exit 1
}

[[ -x /usr/bin/hdiutil ]] || fail "hdiutil is required"

# --- Version comes from the app itself, so the two cannot drift ----------------
# Deliberately not defaulted: a guessed version would end up in a filename that
# claims something the app inside does not.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/Resources/Info.plist" 2>/dev/null)"
[[ -n "$VERSION" ]] || fail "could not read CFBundleShortVersionString from Resources/Info.plist"

BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$ROOT/Resources/Info.plist" 2>/dev/null)"
DMG="$OUT_DIR/SFTPsurf-$VERSION.dmg"

mkdir -p "$OUT_DIR"

if [[ ! -d "$APP" ]]; then
    echo "==> App not built; running bundle.sh first"
    "$ROOT/Scripts/bundle.sh" release >/dev/null || fail "bundle.sh failed"
fi

echo "==> Building SFTPsurf-$VERSION.dmg"

STAGING="$(mktemp -d)"
RW_IMAGE="$(mktemp -u).dmg"
MOUNT_POINT=""
DETACH_NEEDED=0

cleanup() {
    if [[ "$DETACH_NEEDED" == "1" && -n "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGING"
    rm -f "$RW_IMAGE"
}
trap cleanup EXIT

# A leftover volume of the same name would push the new one to "/Volumes/… 1",
# which breaks the AppleScript below.
for existing in /Volumes/"$VOLUME_NAME" /Volumes/"$VOLUME_NAME "1; do
    [[ -d "$existing" ]] && hdiutil detach "$existing" -force >/dev/null 2>&1
done

# --- 1. Stage the contents -----------------------------------------------------
echo "==> Staging"
cp -R "$APP" "$STAGING/"
# Strip any extended attributes from the copy, which would otherwise travel into
# the image as provenance noise.
xattr -cr "$STAGING/SFTPsurf.app" 2>/dev/null || true

mkdir -p "$STAGING/.background"
swift "$ROOT/Scripts/make-dmg-background.swift" "$STAGING/.background/background.png" >/dev/null \
    || fail "could not generate the background image"

# --- 2. Build a read-write image ----------------------------------------------
echo "==> Creating the disk image"
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$RW_IMAGE" >/dev/null 2>&1 || fail "hdiutil create failed"

# --- 3. Mount it and apply the Finder layout ---------------------------------
echo "==> Mounting to apply the layout"
hdiutil attach "$RW_IMAGE" -nobrowse -readwrite >/dev/null 2>&1 \
    || fail "could not mount the read-write image"
DETACH_NEEDED=1

MOUNT_POINT="$(hdiutil info | awk -v img="$RW_IMAGE" '
    $0 ~ img { found = 1 }
    found && /\/Volumes\// { print $NF; exit }
')"

if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
    # Fall back to the conventional location.
    MOUNT_POINT="/Volumes/$VOLUME_NAME"
fi
[[ -d "$MOUNT_POINT" ]] || fail "could not find the mounted volume"

# The Applications alias is a symlink, so it costs nothing and always points at
# the real folder on whatever machine opens the image.
ln -sf /Applications "$MOUNT_POINT/Applications"

# --- 4. Ask Finder to arrange the window -------------------------------------
# This is what makes the image look designed rather than like a folder. It needs
# Automation permission for Finder; if that is unavailable the image is still
# perfectly usable, just plainer, so a failure here is reported and survived.
LAYOUT_APPLIED=0
if [[ -n "${SFTPsurf_SKIP_LAYOUT:-}" ]]; then
    # Requested explicitly, typically in CI where Finder automation is not
    # available. The image is complete and correct; the two icons just end up
    # wherever Finder puts them.
    echo "==> Skipping the Finder icon arrangement (SFTPsurf_SKIP_LAYOUT is set)"
else
echo "==> Arranging icons (this needs Automation permission for Finder)"
layout_error="$(osascript <<APPLESCRIPT 2>&1
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to $WINDOW_BOUNDS
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to $TEXT_SIZE
        set background picture of viewOptions to file ".background:background.png"
        set position of item "SFTPsurf.app" of container window to $APP_ICON_POS
        set position of item "Applications" of container window to $APPS_ICON_POS
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
)"

if [[ -n "$layout_error" ]]; then
    echo "    ! Finder layout was not applied:" >&2
    echo "      $(echo "$layout_error" | head -2 | tr '\n' ' ')" >&2
    echo "      The image will still work; the icons will just be unplaced." >&2
else
    LAYOUT_APPLIED=1
fi
fi

# --- 5. Finder view settings ---------------------------------------------------
# The window's background picture and icon positions are both stored in
# .DS_Store. Normally Finder writes it in the step above, but it cannot on a CI
# runner that has no Automation grant. Falling back to the copy kept in
# Resources/dmg means the image still opens looking arranged rather than as a
# plain folder. Regenerate that copy with Scripts/make-dmg.sh on a machine that
# can reach Finder whenever the background or the icon positions change.
if [[ "$LAYOUT_APPLIED" != "1" ]]; then
    if [[ -f "$ROOT/Resources/dmg/DS_Store" ]]; then
        echo "==> Applying the stored Finder view settings"
        cp "$ROOT/Resources/dmg/DS_Store" "$MOUNT_POINT/.DS_Store" \
            || fail "could not write .DS_Store"
    else
        echo "    ! no stored view settings; the window will not be arranged" >&2
    fi
fi

# --- 6. Volume icon -----------------------------------------------------------
# Deliberately copied *after* the Finder step above. Setting a background picture
# on the window makes Finder rewrite the volume's metadata, and it deletes
# .VolumeIcon.icns while doing so. Copying it afterwards is the difference between
# a disk image with a custom volume icon and one without.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$MOUNT_POINT/.VolumeIcon.icns" \
        || fail "could not write the volume icon"
    # Tells Finder to use .VolumeIcon.icns for this volume.
    SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
fi

# .DS_Store is written asynchronously, so give Finder a moment before detaching.
sleep 2
sync

echo "==> Detaching"
hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1
DETACH_NEEDED=0

# --- 7. Compress --------------------------------------------------------------
echo "==> Compressing"
rm -f "$DMG"
hdiutil convert "$RW_IMAGE" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG" >/dev/null 2>&1 || fail "hdiutil convert failed"

if [[ ! -f "$DMG" ]]; then
    fail "no image was produced at $DMG"
fi

# --- 8. Verify by reading the finished image back ----------------------------
echo "==> Verifying"
VERIFY_POINT="$(mktemp -d)"
verify_failures=""

if hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$VERIFY_POINT" >/dev/null 2>&1; then
    [[ -d "$VERIFY_POINT/SFTPsurf.app" ]] || verify_failures+="SFTPsurf.app is missing; "
    [[ -x "$VERIFY_POINT/SFTPsurf.app/Contents/MacOS/SFTPsurf" ]] || verify_failures+="the executable is missing; "
    [[ -L "$VERIFY_POINT/Applications" ]] || verify_failures+="the Applications alias is missing; "
    [[ -f "$VERIFY_POINT/.background/background.png" ]] || verify_failures+="the background is missing; "
    [[ -f "$VERIFY_POINT/.VolumeIcon.icns" ]] || verify_failures+="the volume icon is missing; "
    # Required either way: it holds both the background picture and the icon
    # positions, so without it the image opens as a plain folder.
    [[ -f "$VERIFY_POINT/.DS_Store" ]] || verify_failures+="the Finder view settings are missing; "

    if ! codesign --verify "$VERIFY_POINT/SFTPsurf.app" 2>/dev/null; then
        verify_failures+="the app's signature does not validate; "
    fi

    # The version and build inside the image must be the ones in the filename.
    image_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$VERIFY_POINT/SFTPsurf.app/Contents/Info.plist" 2>/dev/null || echo "?")"
    [[ "$image_version" == "$VERSION" ]] || verify_failures+="version is $image_version, expected $VERSION; "

    image_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$VERIFY_POINT/SFTPsurf.app/Contents/Info.plist" 2>/dev/null || echo "?")"
    [[ "$image_build" == "$BUILD" ]] || verify_failures+="build is $image_build, expected $BUILD; "

    echo "    mounted contents:"
    ls -A "$VERIFY_POINT" | sed 's/^/      /'

    hdiutil detach "$VERIFY_POINT" >/dev/null 2>&1 || hdiutil detach "$VERIFY_POINT" -force >/dev/null 2>&1
else
    verify_failures="the image could not be mounted; "
fi
rmdir "$VERIFY_POINT" 2>/dev/null || true

if [[ -n "$verify_failures" ]]; then
    fail "verification failed: ${verify_failures%; }"
fi

# --- 9. Report ----------------------------------------------------------------
SIZE="$(du -h "$DMG" | awk '{print $1}')"
CHECKSUM="$(shasum -a 256 "$DMG" | awk '{print $1}')"

echo ""
echo "==> Done"
echo "    version:  $VERSION ($BUILD)"
echo "    image:    $DMG"
echo "    size:     $SIZE"
echo "    sha256:   $CHECKSUM"
echo ""
echo "    Open it with:  open \"$DMG\""
echo ""
echo "    Note: the app is ad-hoc signed and the image is not notarised, so on"
echo "    another Mac Gatekeeper will report an unidentified developer. Users"
echo "    there can right-click the app and choose Open, or run:"
echo "      xattr -d com.apple.quarantine /Applications/SFTPsurf.app"
echo "    Distributing without that warning needs a Developer ID certificate"
echo "    and a notarytool submission."
