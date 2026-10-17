#!/system/bin/sh
##############################################################################
#  Vanadium WebView & Browser Installer - uninstall script
#
#  Runs when the module is removed (KernelSU Next executes it while the
#  manager removes the module, Magisk right before deleting the directory).
#  It must be self contained: no other module file is sourced here.
#
#  It is backgrounded on purpose. Both managers run this script *blocking*
#  (KernelSU Next: ScriptWait::Forever, possibly during boot) and delete the
#  module directory right after it returns - uninstalling the package manager
#  copies can only happen once the device is fully booted.
#
#  What it does:
#    1. waits (bounded) for boot completion
#    2. makes sure the WebView implementation is not left pointing at Vanadium
#       - otherwise every app using WebView would break after the packages
#       are gone
#    3. uninstalls the Vanadium packages the installer added
#    4. removes leftovers from older versions (/data/local/tmp staging)
#
#  Log: /data/local/tmp/vanadium-webview-uninstall.log and logcat tag vwb
##############################################################################

PATH="/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk:/data/adb/ap/bin:$PATH"
export PATH

LOG="/data/local/tmp/vanadium-webview-uninstall.log"

vwb() { # $1 = message
    echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) $1" >> "$LOG" 2>/dev/null
    command -v log >/dev/null 2>&1 && log -t vwb "$1" 2>/dev/null
    return 0
}

wait_boot_completed() {
    n=0
    while [ "$n" -lt 120 ]; do            # at most 120 * 5 s = 10 minutes
        [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && return 0
        sleep 5
        n=$((n + 1))
    done
    return 1
}

# Point the framework at another WebView provider before Vanadium disappears.
# `cmd webviewupdate` is available since Android 7 and accepts root callers.
retarget_webview() {
    command -v cmd >/dev/null 2>&1 || return 0
    current=$(cmd webviewupdate get-current-webview-package 2>/dev/null | tr -d '\r')
    case "$current" in
        app.vanadium.*) : ;;
        *) return 0 ;;
    esac
    for candidate in com.google.android.webview com.android.webview \
                     com.google.android.webview.beta com.google.android.webview.dev; do
        if pm list packages 2>/dev/null | grep -q "package:$candidate"; then
            if cmd webviewupdate set-webview-implementation "$candidate" >/dev/null 2>&1; then
                vwb "WebView implementation switched from $current to $candidate"
                return 0
            fi
        fi
    done
    vwb "could not switch away from $current - select a WebView manually in developer options"
    return 1
}

remove_package() { # best effort, several strategies for different ROMs
    pkg=$1
    pm list packages 2>/dev/null | grep -q "package:$pkg" || return 0
    if pm uninstall --user 0 "$pkg" >/dev/null 2>&1; then
        vwb "uninstalled $pkg (user 0)"
        return 0
    fi
    if pm uninstall "$pkg" >/dev/null 2>&1; then
        vwb "uninstalled $pkg"
        return 0
    fi
    if cmd package uninstall "$pkg" >/dev/null 2>&1; then
        vwb "uninstalled $pkg (cmd package)"
        return 0
    fi
    vwb "could not uninstall $pkg - remove it manually or reboot"
    return 1
}

cleanup() {
    retarget_webview
    sleep 3
    remove_package app.vanadium.browser
    remove_package app.vanadium.webview
    remove_package app.vanadium.trichromelibrary
    rm -rf /data/local/tmp/vanadium-stage 2>/dev/null
    rm -f /data/adb/vanadium-webview-allow-insecure-download 2>/dev/null
    vwb "uninstall finished"
}

# Never block the manager: do the work in the background and exit right away.
( wait_boot_completed || vwb "boot completion timed out, continuing anyway"
  sleep 3
  cleanup
) &

exit 0
