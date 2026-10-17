#!/system/bin/sh
##############################################################################
#  Vanadium WebView & Browser Installer - module installation entry point
#
#  Runs inside the Magisk / KernelSU-Next / APatch module installer, which
#  already extracted the zip into $MODPATH and defined ui_print/abort.
#  The real work happens in common/install.sh (downloads, verification,
#  package manager, overlay).
##############################################################################

# The manager (Magisk / KernelSU Next / APatch) defines abort() and ui_print()
# before sourcing this file. Define harmless fallbacks so a manual run
# ("sh customize.sh") behaves the same way instead of silently continuing.
if ! command -v abort >/dev/null 2>&1; then
    abort() { echo "!! $1"; exit 1; }
fi
if ! command -v ui_print >/dev/null 2>&1; then
    ui_print() { echo "$1"; }
fi

# --- sanity checks, before anything is written to the device ---------------
# $API and $ARCH are set by the installer (Magisk's util_functions.sh and
# KernelSU-Next's installer.sh both use exactly these names); fall back to
# getprop in case a future manager stops exporting them.
[ -n "$API" ] || API=$(getprop ro.build.version.sdk 2>/dev/null)
[ -n "$ARCH" ] || ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)

if [ "${API:-0}" -lt 29 ]; then
    abort "Android 10+ (API 29) is required, this device reports API ${API:-unknown}"
fi
case "$ARCH" in
    arm|arm64|armeabi*|armv7*|aarch64|arm64-v8a) : ;;
    *) abort "Unsupported CPU architecture: ${ARCH:-unknown} (arm/arm64 only)" ;;
esac

# --- MMT-style top level partitions -> $MODPATH/system/<partition> ---------
# (kept from the original module, only made tolerant of missing directories)
for part in product vendor system_ext; do
    src="$MODPATH/$part"
    if [ -d "$src" ]; then
        mkdir -p "$MODPATH/system/$part" || abort "cannot create system/$part"
        cp -a "$src"/* "$MODPATH/system/$part" 2>/dev/null
        rm -rf "$src"
    fi
done

# --- downloads + installation ---------------------------------------------
if ! . "$MODPATH/common/install.sh"; then
    abort "Vanadium installation failed - the module was NOT installed, your previous WebView is untouched"
fi

# --- what to do next ------------------------------------------------------
echo " "
echo "After the reboot:"
echo "  1) Settings -> About phone -> tap 'OS version' 7 times to unlock developer options"
echo "  2) Settings -> Additional settings -> Developer options"
echo "  3) WebView implementation -> choose 'Vanadium WebView'"
echo "  4) Open the Vanadium Browser from the app drawer"
echo " "
echo "If Vanadium does not show up in the WebView list, see the Troubleshooting"
echo "section of the module README (overlay partition, signature, WebView reset)."
echo " "
