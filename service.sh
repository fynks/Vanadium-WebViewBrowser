#!/system/bin/sh
##############################################################################
#  Vanadium WebView & Browser Installer - late_start service
#
#  Runs after every boot (Magisk: late_start service, KernelSU Next: same
#  stage through the boot scripts). Keeps this short: the boot does not wait
#  for long running work here.
#    1. repair a module that was left half swapped by an interrupted update
#    2. drop the .backup rollback copies once the new APKs survived a reboot
#    3. make sure the bundled curl (used by the action script) is executable
##############################################################################

MODDIR=${0%/*}
[ -d "$MODDIR" ] || exit 0
[ -d "$MODDIR/system" ] || exit 0

PATH="/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk:/data/adb/ap/bin:$PATH"
export PATH

if [ -f "$MODDIR/common/swap.sh" ]; then
    . "$MODDIR/common/swap.sh"
else
    # module from before the update support existed - nothing to repair
    restore_missing_apks() { return 0; }
    purge_backup() { return 0; }
fi

# 1./2. rollback + clean up (no-op unless an update ran)
restore_missing_apks
purge_backup

# 3. permissions: some ROMs remount or reset the module tree
[ -f "$MODDIR/bin/curl" ] && chmod 0755 "$MODDIR/bin/curl" 2>/dev/null
[ -f "$MODDIR/action.sh" ] && chmod 0755 "$MODDIR/action.sh" 2>/dev/null
chmod 0644 "$MODDIR"/system/app/*/*.apk 2>/dev/null
chmod 0644 "$MODDIR"/system/product/app/*/*.apk 2>/dev/null
chmod 0644 "$MODDIR"/system/overlay/*.apk 2>/dev/null
chmod 0644 "$MODDIR"/system/*/overlay/*.apk 2>/dev/null

exit 0
