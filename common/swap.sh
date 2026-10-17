#!/system/bin/sh
##############################################################################
#  Vanadium WebView & Browser Installer - atomic APK replacement
#
#  Sourced by action.sh (KernelSU Next "Action" button, or a manual run) and
#  by service.sh (recovery after a reboot).
#
#  Why this is not just "cp new.apk over old.apk":
#    The module directory is magic mounted, so /system/app/.../X.apk is a bind
#    mount of the file in here. Overwriting the file in place would change what
#    a running WebView reads (crash), while deleting it would leave the module
#    without that app on the next boot. Renaming is safe: the bind mount keeps
#    serving the old inode until the next reboot, and the file that will be
#    mounted is always either the complete old or the complete new APK.
##############################################################################

# logging comes from common/dl.sh when available, otherwise keep it simple
command -v vwb_log  >/dev/null 2>&1 || vwb_log()  { echo "$1"; }
command -v vwb_warn >/dev/null 2>&1 || vwb_warn() { echo "! $1"; }

VWB_BACKUP_DIR="$MODDIR/.backup"

# The files this module manages, in both layouts (LineageOS places them under
# system/product/app, everything else under system/app).
vwb_module_apks() {
    echo "$MODDIR/system/app/VanadiumTrichromeLibrary/VanadiumTrichromeLibrary.apk"
    echo "$MODDIR/system/app/VanadiumWebView/VanadiumWebView.apk"
    echo "$MODDIR/system/app/VanadiumBrowser/VanadiumBrowser.apk"
    echo "$MODDIR/system/product/app/VanadiumTrichromeLibrary/VanadiumTrichromeLibrary.apk"
    echo "$MODDIR/system/product/app/VanadiumWebView/VanadiumWebView.apk"
    echo "$MODDIR/system/product/app/VanadiumBrowser/VanadiumBrowser.apk"
}

# Replace one APK with an already verified file, keeping the old one as a
# rollback copy until the next reboot (service.sh cleans it up).
swap_apk() { # swap_apk <verified new apk> <target path in the module>
    new=$1; target=$2
    name=$(basename "$target")
    dir=$(dirname "$target")

    [ -f "$new" ] || return 1
    mkdir -p "$dir" "$VWB_BACKUP_DIR" || return 1

    # stage the new file next to its target so the final move is a rename
    if ! cp -f "$new" "$dir/.$name.new"; then
        vwb_warn "cannot stage $name next to its target"
        return 1
    fi
    chmod 0644 "$dir/.$name.new"

    if [ -f "$target" ]; then
        echo "$target" > "$VWB_BACKUP_DIR/$name.path"
        mv -f "$target" "$VWB_BACKUP_DIR/$name" 2>/dev/null
    fi

    if mv -f "$dir/.$name.new" "$target"; then
        return 0
    fi

    # something went wrong: put the old APK back
    rm -f "$dir/.$name.new"
    [ -f "$VWB_BACKUP_DIR/$name" ] && mv -f "$VWB_BACKUP_DIR/$name" "$target"
    return 1
}

# Repair a module whose APK vanished in the middle of an update
# (only possible if the swap was interrupted between its two renames).
restore_missing_apks() {
    [ -d "$VWB_BACKUP_DIR" ] || return 0
    for meta in "$VWB_BACKUP_DIR"/*.path; do
        [ -f "$meta" ] || continue
        target=$(cat "$meta" 2>/dev/null)
        [ -n "$target" ] || continue
        name=$(basename "$target")
        if [ ! -f "$target" ] && [ -f "$VWB_BACKUP_DIR/$name" ]; then
            mkdir -p "$(dirname "$target")"
            mv -f "$VWB_BACKUP_DIR/$name" "$target" 2>/dev/null &&
                vwb_log "- restored $name from the rollback copy"
        fi
    done
    return 0
}

# Drop the rollback copies once the new APKs survived a reboot. Keeps 400 MB
# of stale APKs from piling up on the data partition.
purge_backup() {
    [ -d "$VWB_BACKUP_DIR" ] || return 0
    # only purge when every swapped file made it to its final place, i.e.
    # nothing was left half swapped
    missing=0
    for meta in "$VWB_BACKUP_DIR"/*.path; do
        [ -f "$meta" ] || continue
        target=$(cat "$meta" 2>/dev/null)
        [ -f "$target" ] || { missing=1; break; }
    done
    if [ "$missing" = "1" ]; then
        return 0
    fi
    rm -rf "$VWB_BACKUP_DIR"
    return 0
}
