#!/system/bin/sh
##############################################################################
#  Vanadium WebView & Browser Installer - release zip builder
#
#  Packs the flashable module from a checkout, leaving out the developer
#  material that has no place inside an installed module (tools/, docs, VCS).
#
#  Usage:  sh tools/build-zip.sh [output.zip]
#          Default output: Vanadium-WebViewBrowser-<version>.zip in the repo root
##############################################################################

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
VERSION=$(sed -n 's/^version=//p' "$REPO/module.prop" 2>/dev/null)
[ -n "$VERSION" ] || VERSION=unknown
OUT=${1:-"$REPO/Vanadium-WebViewBrowser-$VERSION.zip"}

# every file the installer and the module itself need at runtime
REQUIRED="module.prop customize.sh service.sh action.sh uninstall.sh
common/dl.sh common/install.sh common/swap.sh
bin/curl.zip bin/curl64.zip
Overlay/WebViewOverlay29.apk
META-INF/com/google/android/update-binary
META-INF/com/google/android/updater-script"

missing=0
for f in $REQUIRED; do
    if [ ! -f "$REPO/$f" ]; then
        echo "!! missing from the checkout: $f"
        missing=1
    fi
done
[ "$missing" = "0" ] || { echo "cannot build the module zip"; exit 1; }

echo "- building Vanadium-WebViewBrowser $VERSION"
rm -f "$OUT"

# Prefer the system zip, fall back to python3. Only the runtime files are
# added (an explicit include list), so the developer tree can never leak in.
RUNTIME="module.prop customize.sh service.sh action.sh uninstall.sh LICENSE
common bin/curl.zip bin/curl64.zip Overlay META-INF system"

if command -v zip >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    (cd "$REPO" && zip -q -X -r "$OUT" $RUNTIME) || { echo "!! zip failed"; exit 1; }
else
    echo "!! need either 'zip' or 'python3' to build the module zip"
    exit 1
fi

[ -f "$OUT" ] || { echo "!! no zip was produced"; exit 1; }

# checksum next to the zip, so a downloaded file can be verified before it is
# flashed (sha256sum on Android, or sha256sum -c on a computer)
if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" ) &&
        echo "- checksum: $OUT.sha256"
fi

echo "- checking the result"
fail=0
if command -v unzip >/dev/null 2>&1; then
    listing=$(unzip -l "$OUT" 2>/dev/null)
    for f in $REQUIRED; do
        echo "$listing" | grep -q " $f\$" || { echo "!! not in the zip: $f"; fail=1; }
    done
    if echo "$listing" | grep -q "tools/"; then
        echo "!! developer tools leaked into the zip"; fail=1
    fi
fi
[ "$fail" = "0" ] || exit 1

echo "- done: $OUT"
[ -f "$OUT.sha256" ] && cat "$OUT.sha256" | sed 's/^/  /' 
if command -v unzip >/dev/null 2>&1; then
    echo "- size: $(wc -c < "$OUT" | tr -d ' ') bytes, $(unzip -l "$OUT" | tail -1 | awk '{print $2}') entries"
fi
echo "- flash it with Magisk / KernelSU Next / APatch"
