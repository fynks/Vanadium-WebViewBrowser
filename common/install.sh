#!/system/bin/sh
##############################################################################
#  Vanadium WebView & Browser Installer - install stage
#
#  Sourced by customize.sh during module installation, and reused by action.sh
#  for in-place updates after boot. Everything it needs is in common/dl.sh.
#
#  What it does (unchanged from the original module):
#    1. Trichrome library, WebView and Browser APKs are downloaded from the
#       GrapheneOS prebuilt repository into $MODPATH/system/{app,product/app}/..
#    2. the APKs are installed with the package manager as well, so the apps
#       work right away and can be updated later
#    3. an RRO overlay registers app.vanadium.webview as a WebView provider
#
#  What is new (see README "Robust downloads"):
#    * every download is verified (size + ZIP structure + CRC) before it is
#      moved into /system, so a bad connection can never install a broken
#      WebView
#    * transfers resume instead of restarting, stall detection aborts dead
#      connections, mirrors rotate, and DoH/DNS-server profiles are used when
#      the device network hijacks DNS
#    * the package manager step uses streaming installs (no more 400 MB of
#      leftovers in /data/local/tmp) with the old copy-to-temp as fallback
##############################################################################

[ -n "$MODPATH" ] || MODPATH=${0%/*}/..
if [ ! -f "$MODPATH/common/dl.sh" ]; then
    echo "!! common/dl.sh is missing, cannot continue"
    return 1 2>/dev/null || exit 1
fi
. "$MODPATH/common/dl.sh"

# ---------------------------------------------------------------- source URLs
# GrapheneOS publishes the Vanadium prebuilts in the platform_external_vanadium
# repository. All three files have to come from the same directory and branch,
# otherwise the Trichrome library and the WebView would not match each other,
# so the branch/dir are changed as a unit (env override or the defaults below).
GITLAB_PROJECT="grapheneos/platform_external_vanadium"
: "${VWB_REF:=17}"
: "${VWB_ARCHDIR:=}"

if [ -z "${VWB_ARCHDIR:-}" ]; then
    case "${ARCH:-$(getprop ro.product.cpu.abi 2>/dev/null)}" in
        arm|armeabi*|armv7*) VWB_ARCHDIR=arm-multilib ;;    # 32 bit only devices
        *)                   VWB_ARCHDIR=arm64-multilib ;;  # arm64, incl. 32 bit app support
    esac
fi
# The three endpoints below serve the very same file from the same branch, so
# rotating between them cannot mix versions. They are overridable for mirrors
# and for the test suite (tools/test-downloader.sh).
: "${VWB_RAW_BASE:=https://gitlab.com/$GITLAB_PROJECT/-/raw/$VWB_REF/prebuilt/$VWB_ARCHDIR}"
: "${VWB_BLOB_BASE:=https://gitlab.com/$GITLAB_PROJECT/-/blob/$VWB_REF/prebuilt/$VWB_ARCHDIR}"
: "${VWB_API_BASE:=https://gitlab.com/api/v4/projects/grapheneos%2Fplatform_external_vanadium/repository/files/prebuilt%2F$VWB_ARCHDIR}"

# Minimum plausible sizes - only meant to reject error pages and truncated
# files, the real integrity check is the ZIP test in vwb_verify().
: "${MIN_LIB:=1048576}"        # 1 MiB
: "${MIN_WEBVIEW:=20971520}"   # 20 MiB
: "${MIN_BROWSER:=10485760}"   # 10 MiB

# URL list for one file of the prebuilt set: raw, blob (redirect) and API
# endpoints of the same branch - three independent chances with identical
# content, so switching between them can never mix versions.
vwb_urls_for() { # <file name> -> space separated URL list
    echo "$VWB_RAW_BASE/$1 $VWB_BLOB_BASE/$1?raw=true $VWB_API_BASE/$1/raw?ref=$VWB_REF"
}

# ------------------------------------------------------------- bundled helpers
# The module ships a static curl (bin/curl64.zip for arm64, bin/curl.zip for
# 32 bit). It is extracted into bin/curl and kept there, so action.sh can use
# it too. A user supplied bin/curl.local always wins (see common/dl.sh).
setup_bundled_curl() {
    cb="$MODPATH/bin/curl"
    if [ -x "$cb" ] && "$cb" -V >/dev/null 2>&1; then
        return 0
    fi
    case "$ARCH" in
        arm) zips="bin/curl.zip" ;;
        *)   zips="bin/curl64.zip bin/curl.zip" ;;
    esac
    for z in $zips; do
        [ -f "$MODPATH/$z" ] || continue
        if [ -z "$VWB_UNZIP" ]; then
            vwb_warn "no unzip available, cannot extract $z"
            return 1
        fi
        if $VWB_UNZIP -o -j "$MODPATH/$z" -d "$MODPATH/bin" >/dev/null 2>&1 && [ -f "$cb" ]; then
            chmod 0755 "$cb"
            if "$cb" -V >/dev/null 2>&1; then
                vwb_log "- bundled curl extracted from $z"
                return 0
            fi
            vwb_warn "bundled curl from $z cannot run on this device"
            rm -f "$cb"
        else
            vwb_warn "could not extract $z"
        fi
    done
    return 1
}

# Download the whole prebuilt set into a directory. Returns non-zero when any
# of the three files could not be fetched, in which case *nothing* is used:
# mixing library/WebView/Browser versions would break WebView.
fetch_vanadium_set() { # fetch_vanadium_set <directory>
    dir=$1
    mkdir -p "$dir" || return 1
    # shellcheck disable=SC2046
    vwb_fetch "$dir/TrichromeLibrary.apk" "$MIN_LIB" "Vanadium Trichrome library" \
        $(vwb_urls_for TrichromeLibrary.apk) || {
        vwb_err "could not download the Trichrome library - see the hints above"
        return 1
    }
    # shellcheck disable=SC2046
    vwb_fetch "$dir/TrichromeWebView.apk" "$MIN_WEBVIEW" "Vanadium WebView" \
        $(vwb_urls_for TrichromeWebView.apk) || {
        vwb_err "could not download the WebView - see the hints above"
        return 1
    }
    # shellcheck disable=SC2046
    vwb_fetch "$dir/TrichromeChrome.apk" "$MIN_BROWSER" "Vanadium Browser" \
        $(vwb_urls_for TrichromeChrome.apk) || {
        vwb_err "could not download the Browser - see the hints above"
        return 1
    }
    return 0
}

# The APK set is large; running out of space halfway through an install is a
# bad experience, so ask the filesystem first. Below a third of the target the
# install is refused, below the target the user only gets a warning.
check_space() { # check_space <path> [needed MiB]
    need=${2:-900}
    command -v df >/dev/null 2>&1 || return 0
    free=$(df -k "$1" 2>/dev/null | tail -n 1 | awk '{print $4}' 2>/dev/null | tr -dc '0-9')
    [ -n "$free" ] || return 0
    freemb=$((free / 1024))
    if [ "$freemb" -lt "$((need / 3))" ]; then
        vwb_err "only ${freemb} MiB free on the data partition, at least $((need / 3)) MiB are required"
        return 1
    fi
    if [ "$freemb" -lt "$need" ]; then
        vwb_warn "only ${freemb} MiB free, ~${need} MiB recommended for a full update"
    fi
    return 0
}

# ------------------------------------------------------------------- overlay
# The overlay has to live on a partition the framework reads overlays from.
resolve_overlay_path() {
    if [ -n "${VWB_OVERLAY_PATH:-}" ]; then
        OVERLAY_PATH="$VWB_OVERLAY_PATH"
    elif [ -d /system/product/overlay ]; then
        OVERLAY_PATH=system/product/overlay/
    elif [ -d /system_ext/overlay ]; then
        OVERLAY_PATH=system/system_ext/overlay/
    elif [ -d /system/overlay ]; then
        OVERLAY_PATH=system/overlay/
    elif [ -d /system/vendor/overlay ]; then
        OVERLAY_PATH=system/vendor/overlay/
    else
        vwb_err "no overlay partition found on this device"
        return 1
    fi
    [ -f "$MODPATH/Overlay/WebViewOverlay29.apk" ] || {
        vwb_err "Overlay/WebViewOverlay29.apk is missing from the module"
        return 1
    }
    return 0
}

# ------------------------------------------------------------ package manager
vwb_pkg_version() { # versionName of an installed package, empty when unknown
    command -v dumpsys >/dev/null 2>&1 || return 0
    dumpsys package "$1" 2>/dev/null | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -n 1
}

# Install one APK. Streaming install first (no temporary copy, nothing has to
# be readable by system_server), then the classic copy to /data/local/tmp.
# A failure is reported but never aborts the installation: the magic mounted
# system app still works, and the message tells the user what to do.
pm_install() { # pm_install <apk> <label> <package>
    apk=$1; label=$2; pkg=$3
    if ! command -v pm >/dev/null 2>&1; then
        vwb_warn "$label: 'pm' is not available, skipping package install"
        return 1
    fi
    size=$(vwb_size "$apk")
    log="$VWB_STAGE/pm-install.log"

    vwb_log "- Installing $label with the package manager"
    if pm install --install-location 1 -r -S "$size" <"$apk" >"$log" 2>&1; then
        ver=$(vwb_pkg_version "$pkg")
        vwb_log "  $label installed${ver:+ as $ver}"
        return 0
    fi
    vwb_warn "$label: streaming install failed ($(tail -n 1 "$log" 2>/dev/null))"

    # Fallback: the APK must be readable by the package installer, hence the
    # copy into /data/local/tmp (removed again in the clean up below).
    stage=${VWB_TMP_STAGE:-/data/local/tmp/vanadium-stage}
    mkdir -p "$stage" 2>/dev/null
    chmod 0755 "$stage" 2>/dev/null
    tmp="$stage/$(basename "$apk")"
    if cp -f "$apk" "$tmp" 2>/dev/null; then
        chmod 0644 "$tmp" 2>/dev/null
        if pm install --install-location 1 -r "$tmp" >"$log" 2>&1; then
            ver=$(vwb_pkg_version "$pkg")
            vwb_log "  $label installed${ver:+ as $ver}"
            rm -f "$tmp"
            return 0
        fi
        vwb_warn "$label: install failed: $(tail -n 1 "$log" 2>/dev/null)"
        rm -f "$tmp"
    else
        vwb_warn "$label: could not stage the APK for installation"
    fi
    return 1
}

# --------------------------------------------------------------- module.prop
# Store the Vanadium version that is actually mounted in the module
# description, so the KernelSU/Magisk module list shows what is installed.
record_version() {
    ver=$(vwb_pkg_version app.vanadium.webview)
    [ -n "$ver" ] || ver=$(vwb_pkg_version app.vanadium.browser)
    [ -n "$ver" ] || return 0
    ver=$(printf '%s' "$ver" | tr -cd 'A-Za-z0-9._+-')
    [ -n "$ver" ] || return 0
    desc="Change your system WebView with Vanadium WebView and install Vanadium Browser. | Vanadium $ver ($VWB_ARCHDIR)"
    if [ -f "$MODPATH/module.prop" ]; then
        cp -f "$MODPATH/module.prop" "$VWB_STAGE/module.prop.bak" 2>/dev/null
        sed -e "s#^description=.*#description=$desc#" "$MODPATH/module.prop" > "$VWB_STAGE/module.prop.new" 2>/dev/null &&
            mv -f "$VWB_STAGE/module.prop.new" "$MODPATH/module.prop" 2>/dev/null &&
            vwb_log "- Recorded Vanadium $ver in module.prop"
    fi
    return 0
}

# --------------------------------------------------------------------- main
install_vanadium() {
    [ -n "$ARCH" ] || ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)
    case "$ARCH" in
        arm64|aarch64|arm64-v8a) ARCH=arm64 ;;
        arm|armeabi*|armv7*)     ARCH=arm ;;
    esac
    [ -n "$API" ] || API=$(getprop ro.build.version.sdk 2>/dev/null)

    if [ "${API:-0}" -lt 29 ]; then
        vwb_err "Android 10+ (API 29) is required, this device reports API $API"
        return 1
    fi
    case "$ARCH" in
        arm|arm64) : ;;
        *) vwb_err "unsupported CPU architecture: $ARCH"; return 1 ;;
    esac
    [ "$ARCH" = "arm" ] && vwb_warn "32 bit device: GrapheneOS prebuilts are 64 bit oriented, expect problems"

    VWB_STAGE="$MODPATH/.stage"
    rm -rf "$VWB_STAGE"
    mkdir -p "$VWB_STAGE" || { vwb_err "cannot create staging directory"; return 1; }
    # shellcheck disable=SC2034  # consumed by common/dl.sh
    VWB_ERRFILE="$VWB_STAGE/stderr"

    vwb_init
    setup_bundled_curl
    # vwb_init may have run before the bundled curl existed on disk; refresh
    if [ -z "${VWB_CURL:-}" ] && [ "$VWB_CURL_BIN" != "$MODPATH/bin/curl" ] &&
       [ -x "$MODPATH/bin/curl" ] && "$MODPATH/bin/curl" -V >/dev/null 2>&1; then
        VWB_CURL_BIN="$MODPATH/bin/curl"
        vwb_build_curl_opts
        vwb_probe_profiles
        vwb_log "- bundled curl ready: $("$VWB_CURL_BIN" -V 2>/dev/null | head -n 1)"
    fi

    resolve_overlay_path || { rm -rf "$VWB_STAGE"; return 1; }
    vwb_log "- Overlay target: $OVERLAY_PATH"

    if getprop 2>/dev/null | grep -qi lineage; then
        TLP=/system/product/app/VanadiumTrichromeLibrary
        WVP=/system/product/app/VanadiumWebView
        BRP=/system/product/app/VanadiumBrowser
    else
        TLP=/system/app/VanadiumTrichromeLibrary
        WVP=/system/app/VanadiumWebView
        BRP=/system/app/VanadiumBrowser
    fi
    mkdir -p "$MODPATH$TLP" "$MODPATH$WVP" "$MODPATH$BRP"

    tar="$VWB_STAGE/TrichromeLibrary.apk"
    wav="$VWB_STAGE/TrichromeWebView.apk"
    brw="$VWB_STAGE/TrichromeChrome.apk"

    check_space "$MODPATH" || { rm -rf "$VWB_STAGE"; return 1; }
    fetch_vanadium_set "$VWB_STAGE" || { rm -rf "$VWB_STAGE"; return 1; }

    # Move everything into place only after all three files verified: a partial
    # install would mix library/WebView versions.
    mv -f "$tar" "$MODPATH$TLP/VanadiumTrichromeLibrary.apk" || { vwb_err "cannot place the library"; return 1; }
    mv -f "$wav" "$MODPATH$WVP/VanadiumWebView.apk"          || { vwb_err "cannot place the WebView"; return 1; }
    mv -f "$brw" "$MODPATH$BRP/VanadiumBrowser.apk"          || { vwb_err "cannot place the Browser"; return 1; }
    chmod 0644 "$MODPATH$TLP"/*.apk "$MODPATH$WVP"/*.apk "$MODPATH$BRP"/*.apk 2>/dev/null

    pm_install "$MODPATH$TLP/VanadiumTrichromeLibrary.apk" "Trichrome library" "app.vanadium.trichromelibrary"
    pm_install "$MODPATH$WVP/VanadiumWebView.apk" "WebView" "app.vanadium.webview"
    pm_install "$MODPATH$BRP/VanadiumBrowser.apk" "Browser" "app.vanadium.browser"

    mkdir -p "$MODPATH/$OVERLAY_PATH" || { vwb_err "cannot create $OVERLAY_PATH"; return 1; }
    if cp -f "$MODPATH/Overlay/WebViewOverlay29.apk" "$MODPATH/$OVERLAY_PATH/WebViewOverlay.apk"; then
        chmod 0644 "$MODPATH/$OVERLAY_PATH/WebViewOverlay.apk"
        vwb_log "- WebView provider overlay installed"
    else
        vwb_err "could not install the WebView overlay"
        return 1
    fi

    record_version

    rm -rf "$VWB_STAGE"
    return 0
}

# action.sh sources this file with VWB_SOURCE_ONLY=1 to reuse the helpers
# (setup_bundled_curl, vwb_urls_for, pm_install, ...) without installing.
if [ "${VWB_SOURCE_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

install_vanadium
VWB_RESULT=$?

# ---------------------------------------------------------------- clean up
# bin/curl and common/ are kept on purpose: action.sh needs them for updates.
# tools/ is developer material that has no business in the installed module.
cleanup() {
    rm -rf "$MODPATH/bin/"*.zip "$MODPATH/system/.placeholder" \
           "$MODPATH/Overlay" "$MODPATH/tools" "$MODPATH/.stage"
    rm -rf "${VWB_TMP_STAGE:-/data/local/tmp/vanadium-stage}" 2>/dev/null
    rm -rf /data/local/tmp/vanadium-stage 2>/dev/null
    rm -rf /dev/tmp/vanadium-stage 2>/dev/null
}
cleanup

if [ "$VWB_RESULT" != "0" ]; then
    vwb_err "installation failed - nothing was mounted, the previous WebView stays active"
    vwb_log "Tips: connect to Wi-Fi, or place a newer static curl at bin/curl.local"
else
    vwb_log "- Vanadium files are ready to be mounted"
fi

# customize.sh sources this file, so returning propagates the status there
case "$0" in
    *install.sh) exit "$VWB_RESULT" ;;
    *)           return "$VWB_RESULT" 2>/dev/null || exit "$VWB_RESULT" ;;
esac
