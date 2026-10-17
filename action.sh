#!/system/bin/sh
##############################################################################
#  Vanadium WebView & Browser Installer - KernelSU Next action script
#
#  KernelSU Next (3.x) shows an "Action" button for every module that ships an
#  action.sh. Here it updates the Vanadium prebuilts inside the module to the
#  newest build from the configured GrapheneOS branch - no reflash, no reboot
#  during the download, and nothing is replaced unless all three APKs were
#  downloaded *and* verified.
#
#  It can also be run by hand:
#      su -c sh /data/adb/modules/Vanadium-WebViewBrowser/action.sh
#
#  Exit codes: 0 = updated, 1 = failed (module untouched), 2 = download failed
##############################################################################

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/Vanadium-WebViewBrowser
[ -f "$MODDIR/common/dl.sh" ] || {
    echo "!! $MODDIR/common/dl.sh is missing - reinstall the module"
    exit 1
}

# Module scripts run with a minimal environment (the manager or init), so make
# sure system tools and the KernelSU/Magisk binaries are reachable.
PATH="/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk:/data/adb/ap/bin:$PATH"
export PATH
# install.sh reads MODPATH and ARCH; export them so the sourced helpers see them
MODPATH="$MODDIR"
[ -n "${ARCH:-}" ] || ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)
export MODPATH ARCH

# shellcheck source=common/dl.sh
. "$MODDIR/common/dl.sh"
# helpers only - VWB_SOURCE_ONLY keeps install.sh from starting an install
# shellcheck disable=SC2034
VWB_SOURCE_ONLY=1
# shellcheck source=common/install.sh
. "$MODDIR/common/install.sh"
unset VWB_SOURCE_ONLY
# shellcheck source=common/swap.sh
. "$MODDIR/common/swap.sh"

# scratch area for this run; VWB_ERRFILE is consumed by common/dl.sh
VWB_STAGE="$MODDIR/.stage"
# shellcheck disable=SC2034
VWB_ERRFILE="$VWB_STAGE/stderr"

banner() {
    vwb_log "============================================"
    vwb_log " Vanadium WebView & Browser - update"
    vwb_log "============================================"
    vwb_log "- Module:      $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
    vwb_log "- Source:      $VWB_REF / $VWB_ARCHDIR"
    old=$(dumpsys package app.vanadium.webview 2>/dev/null | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -n 1)
    vwb_log "- Installed:   ${old:-unknown}"
    vwb_log " "
}

# Fail early when the module was left half swapped by an interrupted run.
restore_missing_apks

rm -rf "$VWB_STAGE"
mkdir -p "$VWB_STAGE" || { echo "!! cannot create $VWB_STAGE"; exit 1; }

banner
vwb_init
setup_bundled_curl
if [ -z "${VWB_CURL:-}" ] && [ "$VWB_CURL_BIN" != "$MODDIR/bin/curl" ] &&
   [ -x "$MODDIR/bin/curl" ] && "$MODDIR/bin/curl" -V >/dev/null 2>&1; then
    VWB_CURL_BIN="$MODDIR/bin/curl"
    vwb_build_curl_opts
    vwb_probe_profiles
    vwb_log "- bundled curl ready: $("$VWB_CURL_BIN" -V 2>/dev/null | head -n 1)"
fi

check_space "$MODDIR" || exit 1

vwb_log "- Downloading the latest Vanadium build"
if ! fetch_vanadium_set "$VWB_STAGE/new"; then
    vwb_err "update aborted - the installed Vanadium was not touched"
    rm -rf "$VWB_STAGE"
    exit 2
fi

# Everything is downloaded and verified, swap it in one file at a time.
# An interruption from here on is repaired by service.sh on the next boot
# (or by the next run of this action).
vwb_log "- Replacing the installed APKs"
failed=0
for f in $(vwb_module_apks); do
    # only touch the layout this module actually uses
    dir=$(dirname "$f")
    [ -d "$dir" ] || continue
    name=$(basename "$f")
    case "$name" in
        VanadiumTrichromeLibrary.apk) src="$VWB_STAGE/new/TrichromeLibrary.apk" ;;
        VanadiumWebView.apk)          src="$VWB_STAGE/new/TrichromeWebView.apk" ;;
        VanadiumBrowser.apk)          src="$VWB_STAGE/new/TrichromeChrome.apk" ;;
        *) continue ;;
    esac
    if swap_apk "$src" "$f"; then
        vwb_log "  replaced $name"
    else
        vwb_warn "could not replace $name"
        failed=1
    fi
done

if [ "$failed" = "1" ]; then
    vwb_err "the APK swap did not complete - run the action again or reflash the module"
    rm -rf "$VWB_STAGE/new"
    exit 1
fi

# Refresh the package manager copies as well (same call as during install).
for f in $(vwb_module_apks); do
    [ -f "$f" ] || continue
    case "$f" in
        *VanadiumTrichromeLibrary.apk) pkg=app.vanadium.trichromelibrary; label="Trichrome library" ;;
        *VanadiumWebView.apk)          pkg=app.vanadium.webview;           label="WebView" ;;
        *VanadiumBrowser.apk)          pkg=app.vanadium.browser;           label="Browser" ;;
        *) continue ;;
    esac
    pm_install "$f" "$label" "$pkg"
done

# Record what is now mounted, so the module list shows it.
record_version

rm -rf "$VWB_STAGE"

new=$(dumpsys package app.vanadium.webview 2>/dev/null | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -n 1)
vwb_log " "
vwb_log "============================================"
vwb_log " Update finished"
vwb_log "============================================"
[ -n "$new" ] && vwb_log "- Vanadium WebView: $new"
vwb_log "- Reboot to let the mounted system apps pick up the new build"
vwb_log "- The previous APKs are kept in .backup until the next boot;"
vwb_log "  remove them manually to free space if you need it right now."
exit 0
