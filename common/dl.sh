#!/system/bin/sh
##############################################################################
#  Vanadium WebView & Browser Installer - resilient download engine
#  (sourced by common/install.sh and action.sh - do not execute directly)
#
#  Goals
#    * never leave a corrupt/truncated file behind that later gets mounted as a
#      system APK (that is how a "download hiccup" turns into a boot problem)
#    * survive flaky mobile data: resume partial downloads, detect stalled
#      transfers, retry transient failures, rotate between mirrors
#    * work on Magisk, KernelSU (Next) and APatch, and with whatever download
#      tools the device actually has (the bundled static curl is preferred)
#    * keep HTTPS certificate verification ON. Engines that cannot verify TLS
#      are only used when the user explicitly opts in (see below).
#
#  Engines (tried in this order, first success wins)
#    1. curl, default profile            - one attempt per mirror
#    2. curl, alternate network profiles - DoH / c-ares DNS / capath / HTTP1.1,
#       each one only if this curl build really supports it (probed offline)
#    3. wget (busybox or a system wget)  - only if it can verify certificates
#    4. wget, unverified                 - ONLY with an explicit opt-in
#
#  The shipped static curl has no c-ares, so the --dns-servers profile stays
#  disabled unless a curl with c-ares is placed at bin/curl.local.
#
#  Opt-in for unverified fallback download (not recommended):
#       touch /data/adb/vanadium-webview-allow-insecure-download
#    or export VWB_ALLOW_INSECURE=1
#
#  Everything is overridable through the environment, mostly for testing:
#    VWB_CURL, VWB_WGET, VWB_UNZIP, VWB_VERIFY=full|quick, VWB_MAX_ATTEMPTS,
#    VWB_CONNECT_TIMEOUT, VWB_STALL_SPEED, VWB_STALL_TIME, VWB_CURL_RETRY,
#    VWB_MIN_RESUME, VWB_DOH_URL, VWB_DOH_URL2, VWB_NS_SERVERS, VWB_CAPATH,
#    VWB_TEST_HTTP=1 (drop the https-only restriction, used by the test suite)
##############################################################################

VWB_VERSION="1.3.0"
VWB_INSECURE_MARKER="/data/adb/vanadium-webview-allow-insecure-download"

# tunables (override *before* sourcing this file if you need to)
: "${VWB_CONNECT_TIMEOUT:=20}"     # seconds to establish the connection
: "${VWB_CURL_RETRY:=3}"           # curl's internal retries per attempt
: "${VWB_STALL_SPEED:=1024}"       # abort when slower than this many bytes/s
: "${VWB_STALL_TIME:=60}"          # ... sustained for this many seconds
: "${VWB_MIN_RESUME:=262144}"      # resume only files bigger than 256 KiB
: "${VWB_MAX_ATTEMPTS:=14}"        # hard cap on network attempts per file
: "${VWB_VERIFY:=full}"            # full = unzip -t, quick = central directory only
: "${VWB_WGET_TIMEOUT:=1800}"      # total wall clock limit for one wget attempt
: "${VWB_DOH_URL:=https://1.1.1.1/dns-query}"
: "${VWB_DOH_URL2:=https://8.8.8.8/dns-query}"
: "${VWB_NS_SERVERS:=1.1.1.1,1.0.0.1}"

# Scratch file for capability probes and for capturing engine stderr. Callers
# (install.sh, action.sh) point this at their own staging directory; otherwise
# pick a writable spot, falling back to /dev/null.
if [ -z "${VWB_ERRFILE:-}" ]; then
    for d in "${TMPDIR:-}" /dev/tmp /data/local/tmp /tmp; do
        [ -n "$d" ] || continue
        if [ -d "$d" ] && [ -w "$d" ]; then
            VWB_ERRFILE="$d/.vwb-stderr.$$"
            break
        fi
    done
    : "${VWB_ERRFILE:=/dev/null}"
fi

##############################################################################
# logging / helpers
##############################################################################

# Use the installer's ui_print() when it exists (Magisk/KernelSU install
# context), fall back to plain echo (action.sh, manual runs, tests).
if command -v ui_print >/dev/null 2>&1; then
    vwb_log() { ui_print "$1"; }
else
    vwb_log() { echo "$1"; }
fi
vwb_warn() { vwb_log "! $1"; }
vwb_err()  { vwb_log "!! $1"; }

vwb_size() { # vwb_size <file> -> byte count (0 when missing)
    s=$(wc -c < "$1" 2>/dev/null | tr -dc '0-9')
    [ -n "$s" ] && echo "$s" || echo 0
}

vwb_host() { # vwb_host <url> -> host part, for readable logs
    echo "$1" | sed -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|/.*$||'
}

vwb_human() { # bytes -> human readable
    awk -v b="$1" 'BEGIN{
        split("B KiB MiB GiB", u, " ");
        i = 1;
        while (b >= 1024 && i < 4) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
    }' 2>/dev/null || echo "$1 B"
}

vwb_rc_hint() { # curl exit code -> what to try next (helps users and support)
    case "$1" in
        2)   echo "invalid option for this curl build" ;;
        3)   echo "malformed URL" ;;
        5|6) echo "DNS resolution failed (try a different DNS/network)" ;;
        7)   echo "could not connect (network down, captive portal, port blocked)" ;;
        18)  echo "transfer interrupted - will resume" ;;
        22)  echo "HTTP error, e.g. 403/404 (mirror moved or rate limited)" ;;
        28)  echo "timed out / transfer stalled - will resume" ;;
        33)  echo "server does not support resuming - restarting this file" ;;
        35)  echo "TLS handshake failed (SSL interception or blocked endpoint)" ;;
        56)  echo "network receive error - will resume" ;;
        60)  echo "TLS certificate verification failed" ;;
        77)  echo "cannot read CA certificates" ;;
        92)  echo "HTTP/2 protocol error (network middleware interfering)" ;;
        *)   echo "curl failure" ;;
    esac
}

##############################################################################
# tool discovery
##############################################################################

vwb_init() { # vwb_init -> populates VWB_CURL_BIN, VWB_WGET, VWB_UNZIP, ...
    vwb_log "- Preparing download engine (helper v$VWB_VERSION)"

    # --- busybox (applet multiplexer used by both Magisk and KernelSU Next) ---
    VWB_BUSYBOX=""
    if [ -n "${VWB_BUSYBOX_OVERRIDE:-}" ]; then
        # explicit override: use that busybox, and nothing else
        [ -x "$VWB_BUSYBOX_OVERRIDE" ] && VWB_BUSYBOX="$VWB_BUSYBOX_OVERRIDE"
    else
        for c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox \
                 /data/adb/ap/bin/busybox $(command -v busybox 2>/dev/null); do
            [ -n "$c" ] && [ -x "$c" ] && { VWB_BUSYBOX="$c"; break; }
        done
    fi

    # --- curl: bundled static build first (self-contained, verifies TLS) -----
    # bin/curl.local lets a user drop in a newer static curl without rebuilding
    # the module; bin/curl is the one shipped inside curl.zip / curl64.zip.
    VWB_CURL_BIN=""
    no_curl=""
    case "${VWB_CURL:-}" in
        none|NONE|0|-|false) no_curl=1 ;;   # VWB_CURL=none forces the wget path
    esac
    candidates=""
    [ -n "${VWB_CURL:-}" ] && [ "$no_curl" != "1" ] && candidates="$VWB_CURL"
    if [ -n "${MODPATH:-}" ]; then
        candidates="$candidates $MODPATH/bin/curl.local $MODPATH/bin/curl"
    fi
    if [ -n "${MODDIR:-}" ]; then
        candidates="$candidates $MODDIR/bin/curl.local $MODDIR/bin/curl"
    fi
    if [ "$no_curl" != "1" ]; then
        candidates="$candidates $(command -v curl 2>/dev/null)"
    fi
    for c in $candidates; do
        [ -n "$c" ] || continue
        case "$c" in none|NONE|0|-|false) continue ;; esac
        [ -x "$c" ] || continue
        if "$c" -V >/dev/null 2>&1; then VWB_CURL_BIN="$c"; break; fi
        vwb_warn "ignoring $c (cannot execute - wrong ABI or unsupported kernel?)"
    done

    if [ -n "$VWB_CURL_BIN" ]; then
        VWB_CURL_VER=$("$VWB_CURL_BIN" -V 2>/dev/null | head -n 1)
        vwb_log "- curl: $VWB_CURL_BIN"
        vwb_log "  $VWB_CURL_VER"
    else
        vwb_warn "no usable curl binary found, falling back to wget"
    fi

    # --- wget fallback (busybox/toybox). Kept as a command string on purpose --
    VWB_WGET=""
    if [ -n "$VWB_BUSYBOX" ] && "$VWB_BUSYBOX" wget --help >/dev/null 2>&1; then
        VWB_WGET="$VWB_BUSYBOX wget"
    elif command -v wget >/dev/null 2>&1; then
        if wget --help >/dev/null 2>&1 || wget -h >/dev/null 2>&1; then
            VWB_WGET="wget"
        fi
    fi

    # --- unzip (for extracting the bundled curl and verifying downloads) -----
    VWB_UNZIP=""
    for c in ${VWB_UNZIP_OVERRIDE:-} $(command -v unzip 2>/dev/null); do
        [ -n "$c" ] && [ -x "$c" ] && { VWB_UNZIP="$c"; break; }
    done
    if [ -z "$VWB_UNZIP" ] && [ -n "$VWB_BUSYBOX" ]; then
        if "$VWB_BUSYBOX" unzip --help >/dev/null 2>&1; then
            VWB_UNZIP="$VWB_BUSYBOX unzip"
        fi
    fi

    VWB_CACERT=""
    for c in ${VWB_CACERT:-} /system/etc/security/cacert.pem /system/etc/cacerts.pem; do
        [ -n "$c" ] && [ -f "$c" ] && { VWB_CACERT="$c"; break; }
    done
    if [ -z "${VWB_CAPATH:-}" ]; then
        for c in /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts; do
            [ -d "$c" ] && { VWB_CAPATH="$c"; break; }
        done
    fi

    if [ -n "$VWB_CURL_BIN" ]; then
        vwb_probe_profiles
        vwb_build_curl_opts
    fi

    vwb_probe_unzip
    return 0
}

vwb_probe_unzip() { # find out what the archiver on this device can do
    VWB_UNZIP_MODE=none
    if [ -z "$VWB_UNZIP" ]; then
        vwb_warn "no unzip available: downloads are only checked by size and file header"
        return 0
    fi
    # An unsupported option makes these tools print their usage text; a file
    # that simply does not exist does not.
    t_probe=$($VWB_UNZIP -t "/.vwb-probe-$$" 2>&1)
    case "$t_probe" in
        *Usage*|*usage:*|*nrecognized*|*"nvalid option"*|*"nknown option"*) t_ok=0 ;;
        *) t_ok=1 ;;
    esac
    l_probe=$($VWB_UNZIP -l "/.vwb-probe-$$" 2>&1)
    case "$l_probe" in
        *Usage*|*usage:*|*nrecognized*|*"nvalid option"*|*"nknown option"*) l_ok=0 ;;
        *) l_ok=1 ;;
    esac
    if [ "$l_ok" = "0" ]; then
        VWB_UNZIP_MODE=none
        vwb_warn "this unzip cannot list archives: downloads are only checked by size and file header"
    elif [ "$t_ok" = "0" ]; then
        VWB_UNZIP_MODE=list
        vwb_log "- note: this unzip cannot test archives, using structure checks only"
    else
        VWB_UNZIP_MODE=full
    fi
    return 0
}

vwb_build_curl_opts() { # common options shared by every curl attempt
    proto="--proto =https --proto-redir =https"
    [ "${VWB_TEST_HTTP:-0}" = "1" ] && proto=""   # test suite runs a local http server
    VWB_CURL_OPTS="--fail --location --show-error --progress-bar"
    VWB_CURL_OPTS="$VWB_CURL_OPTS $proto"
    VWB_CURL_OPTS="$VWB_CURL_OPTS --connect-timeout $VWB_CONNECT_TIMEOUT"
    VWB_CURL_OPTS="$VWB_CURL_OPTS --retry $VWB_CURL_RETRY --retry-delay 2"
    VWB_CURL_OPTS="$VWB_CURL_OPTS --retry-connrefused --retry-max-time 300"
    VWB_CURL_OPTS="$VWB_CURL_OPTS --speed-limit $VWB_STALL_SPEED --speed-time $VWB_STALL_TIME"
    VWB_CURL_OPTS="$VWB_CURL_OPTS --keepalive-time 30 --globoff"
    return 0
}

vwb_curl_supports() { # vwb_curl_supports "<option and its value>" -> 0 if usable
    # A cheap, offline capability probe: an option this build does not know
    # makes curl exit 2 straight away; connecting to 127.0.0.1:1 never leaves
    # the device, so this is safe to run on a phone with no network.
    errf="$VWB_ERRFILE"
    # shellcheck disable=SC2086  # $1 is an option list that must be split
    "$VWB_CURL_BIN" $1 --max-time 3 -o /dev/null "https://127.0.0.1:1/vwb-probe" 2>"$errf"
    rc=$?
    [ "$rc" = "2" ] && return 1
    grep -qiE "does not support|doesn't support|is unknown|unrecognized|unrecognised" "$errf" 2>/dev/null && return 1
    return 0
}

vwb_probe_profiles() { # decide which extra curl profiles this build can do
    VWB_PROFILE_DOH=0
    VWB_PROFILE_ARES=0
    VWB_PROFILE_HTTP1=0
    [ -n "$VWB_ERRFILE" ] || return 0

    # c-ares is required for --dns-servers; curl prints "c-ares/x.y.z" in -V
    if "$VWB_CURL_BIN" -V 2>/dev/null | head -n 1 | grep -q "c-ares/"; then
        vwb_curl_supports "--dns-servers $VWB_NS_SERVERS" && VWB_PROFILE_ARES=1
    fi
    vwb_curl_supports "--doh-url $VWB_DOH_URL" && VWB_PROFILE_DOH=1
    vwb_curl_supports "--http1.1" && VWB_PROFILE_HTTP1=1
    return 0
}

vwb_insecure_allowed() { # is the unverified-fallback escape hatch unlocked?
    [ "${VWB_ALLOW_INSECURE:-0}" = "1" ] && return 0
    [ -e "$VWB_INSECURE_MARKER" ] && return 0
    return 1
}

##############################################################################
# verification - the safety net that keeps corrupt APKs out of /system
##############################################################################

vwb_verify() { # vwb_verify <file> <min_bytes> <label> [quiet]
    f=$1; min=$2; label=$3; quiet=$4
    size=$(vwb_size "$f")
    if [ ! -f "$f" ] || [ "$size" -lt "$min" ]; then
        [ -n "$quiet" ] || vwb_warn "$label: too small ($size < $min bytes)"
        return 1
    fi
    # ZIP/APK magic. A captive portal or error page lands here as "<!DOCTYPE".
    magic=$(head -c 2 "$f" 2>/dev/null)
    if [ "$magic" != "PK" ]; then
        [ -n "$quiet" ] || vwb_warn "$label: not a ZIP archive (starts with '$magic') - captive portal or error page?"
        return 1
    fi
    # VWB_UNZIP_MODE says what the archiver on this device can actually do
    # (probed once in vwb_init): "full" = CRC test + listing, "list" = listing
    # only, "none" = no usable archiver, size and magic only.
    case "${VWB_UNZIP_MODE:-none}" in
        full)
            if [ "$VWB_VERIFY" = "full" ]; then
                # CRC check of every entry: catches truncation and mid-transfer corruption
                $VWB_UNZIP -t "$f" >/dev/null 2>&1 || {
                    [ -n "$quiet" ] || vwb_warn "$label: ZIP integrity test failed (truncated or corrupt)"
                    return 1
                }
            fi
            $VWB_UNZIP -l "$f" 2>/dev/null | grep -q "AndroidManifest.xml" || {
                [ -n "$quiet" ] || vwb_warn "$label: archive has no AndroidManifest.xml"
                return 1
            }
            ;;
        list)
            # this archiver cannot check checksums, but listing still stops a
            # stray ZIP (an update package, a ROM zip, ...) from being mounted
            $VWB_UNZIP -l "$f" 2>/dev/null | grep -q "AndroidManifest.xml" || {
                [ -n "$quiet" ] || vwb_warn "$label: archive has no AndroidManifest.xml"
                return 1
            }
            ;;
        none)
            # no usable archiver: PK magic + minimum size is all we have
            ;;
    esac
    [ -n "$quiet" ] || vwb_log "  verified $label ($(vwb_human "$size"))"
    return 0
}

vwb_promote() { # move a verified .part file into its final place
    mv -f "$1" "$2" 2>/dev/null || { cp -f "$1" "$2" 2>/dev/null && rm -f "$1"; }
    [ -f "$2" ] || return 1
    chmod 0644 "$2" 2>/dev/null
    return 0
}

##############################################################################
# curl attempts
##############################################################################

vwb_curl_try() { # vwb_curl_try <profile> <dest> <url> <min_bytes> <label>
    prof=$1; dest=$2; url=$3; min=$4; label=$5
    [ -n "$VWB_CURL_BIN" ] || return 1

    part="$dest.part"
    extra=""
    case "$prof" in
        default) : ;;
        doh)     extra="--doh-url $VWB_DOH_URL" ;;
        doh2)    extra="--doh-url $VWB_DOH_URL2" ;;
        ares)    extra="--dns-servers $VWB_NS_SERVERS" ;;
        capath)  extra="--capath $VWB_CAPATH" ;;
        h1)      extra="--http1.1" ;;
    esac

    resume=""
    psz=$(vwb_size "$part")
    if [ "$psz" -ge "$VWB_MIN_RESUME" ]; then
        resume="-C -"
        note="resume from $(vwb_human "$psz")"
    else
        rm -f "$part"
        note="fresh"
    fi

    vwb_log "  [$VWB_N/$VWB_TOTAL] curl/$prof @ $(vwb_host "$url") ($note)"
    # shellcheck disable=SC2086  # option strings are intentionally split here
    "$VWB_CURL_BIN" $VWB_CURL_OPTS $extra $resume -o "$part" "$url"
    rc=$?
    if [ "$rc" != "0" ]; then
        vwb_warn "curl exit $rc: $(vwb_rc_hint "$rc")"
        return 1
    fi

    if ! vwb_verify "$part" "$min" "$label"; then
        rm -f "$part"   # wrong content: resuming it would only corrupt further
        return 2
    fi
    vwb_promote "$part" "$dest"
}

##############################################################################
# wget attempts (fallback engine)
##############################################################################

: "${VWB_WATCHDOG_INTERVAL:=15}"   # seconds between wget progress checks
: "${VWB_WATCHDOG_STRIKES:=2}"     # checks without progress before aborting

# A process that has exited becomes a zombie until it is reaped, and `kill -0`
# still succeeds on zombies - so ask /proc for the real state instead.
vwb_alive() {
    [ -d "/proc/$1" ] || return 1
    st=$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)
    [ "$st" != "Z" ]
}

vwb_wget_try() { # vwb_wget_try <secure|insecure> <dest> <url> <min_bytes> <label>
    mode=$1; dest=$2; url=$3; min=$4; label=$5
    [ -n "$VWB_WGET" ] || return 1

    part="$dest.part"
    rm -f "$part"                     # this engine has no resume support here
    extra=""
    [ "$mode" = "insecure" ] && extra="--no-check-certificate"
    [ -n "$VWB_CACERT" ] && extra="$extra --ca-certificate=$VWB_CACERT"
    [ "$VWB_TEST_HTTP" = "1" ] && extra="$extra --no-check-certificate"

    vwb_log "  [$VWB_N/$VWB_TOTAL] wget/$mode @ $(vwb_host "$url")"

    # wget has no stall detection, so run it under a watchdog and abort when
    # the output file stops growing. Keeps a bad network from hanging setup.
    : > "$VWB_ERRFILE"
    # shellcheck disable=SC2086
    $VWB_WGET -q $extra -O "$part" "$url" 2>"$VWB_ERRFILE" &
    wpid=$!
    waited=0
    strikes=0
    last=-1
    while vwb_alive "$wpid"; do
        sleep "$VWB_WATCHDOG_INTERVAL"
        waited=$((waited + VWB_WATCHDOG_INTERVAL))
        now=$(vwb_size "$part")
        if [ "$now" = "$last" ]; then
            strikes=$((strikes + 1))
            if [ "$strikes" -ge "$VWB_WATCHDOG_STRIKES" ]; then
                vwb_warn "wget stopped making progress - aborting attempt"
                kill "$wpid" 2>/dev/null
                sleep 1
                vwb_alive "$wpid" && kill -9 "$wpid" 2>/dev/null
                break
            fi
        else
            strikes=0
        fi
        last="$now"
        if [ "$waited" -ge "$VWB_WGET_TIMEOUT" ]; then
            vwb_warn "wget exceeded $VWB_WGET_TIMEOUT s - aborting attempt"
            kill "$wpid" 2>/dev/null
            break
        fi
    done
    wait "$wpid" 2>/dev/null
    rc=$?

    if [ -s "$VWB_ERRFILE" ]; then
        errtext=$(cat "$VWB_ERRFILE" 2>/dev/null)
        case "$errtext" in
            *"certificate validation not implemented"*|*"not verifying"*|*"certificate verify failed"*)
                if [ "$mode" = "secure" ]; then
                    vwb_warn "this wget cannot verify TLS certificates"
                    return 3
                fi
                ;;
        esac
    fi
    [ "$rc" = "0" ] || { vwb_warn "wget exit $rc"; return 1; }

    if ! vwb_verify "$part" "$min" "$label"; then
        rm -f "$part"
        return 2
    fi
    vwb_promote "$part" "$dest"
}

##############################################################################
# attempt plan
##############################################################################

# Prints "<engine> <profile> <url>" lines, ordered from "most likely to work
# with verified TLS" to "last resort". Building the plan up front keeps the
# attempt count bounded and makes the log easy to follow.
vwb_build_plan() { # vwb_build_plan <phase> <url...>
    phase=$1; shift
    for u in "$@"; do
        case "$phase" in
            1) echo "curl default $u" ;;
            2) [ "$VWB_PROFILE_DOH" = "1" ] && echo "curl doh $u"
               [ "$VWB_PROFILE_DOH" = "1" ] && echo "curl doh2 $u"
               [ "$VWB_PROFILE_ARES" = "1" ] && echo "curl ares $u"
               [ -n "$VWB_CAPATH" ] && echo "curl capath $u"
               [ "$VWB_PROFILE_HTTP1" = "1" ] && echo "curl h1 $u" ;;
            3) [ -n "$VWB_WGET" ] && echo "wget secure $u" ;;
            4) [ -n "$VWB_WGET" ] && echo "wget insecure $u" ;;
        esac
    done
}

vwb_attempt() { # vwb_attempt <engine> <profile> <url> <dest> <min> <label>
    engine=$1; prof=$2; url=$3; dest=$4; min=$5; label=$6
    VWB_N=$((VWB_N + 1))
    case "$engine" in
        curl) vwb_curl_try "$prof" "$dest" "$url" "$min" "$label" ;;
        wget) vwb_wget_try "$prof" "$dest" "$url" "$min" "$label" ;;
    esac
}

##############################################################################
# public entry point
##############################################################################

# vwb_fetch <dest> <min_bytes> <label> <url...>
# Downloads to <dest>.part, verifies it, then moves it to <dest>.
vwb_fetch() {
    VWB_DEST=$1; VWB_MIN=$2; VWB_LABEL=$3; shift 3
    VWB_URLS="$*"
    VWB_N=0
    stall=0
    lastsize=-1

    [ -n "$VWB_URLS" ] || { vwb_err "$VWB_LABEL: no download URL configured"; return 1; }

    # Keep a previously verified download (e.g. setup was re-run after a reboot)
    if [ -f "$VWB_DEST" ] && vwb_verify "$VWB_DEST" "$VWB_MIN" "$VWB_LABEL" quiet; then
        vwb_log "- $VWB_LABEL already downloaded and verified, skipping"
        return 0
    fi
    # ... and a partial file that turned out to be complete after all
    if [ -f "$VWB_DEST.part" ] && vwb_verify "$VWB_DEST.part" "$VWB_MIN" "$VWB_LABEL" quiet; then
        vwb_log "- $VWB_LABEL was already fully downloaded, using it"
        vwb_promote "$VWB_DEST.part" "$VWB_DEST" && return 0
    fi

    # The plan is written to a file so the loop below runs in this shell (a
    # pipeline would run in a subshell and lose the counters).
    plan="$VWB_DEST.plan"
    : > "$plan" || { vwb_err "$VWB_LABEL: cannot write the attempt plan"; return 1; }
    for u in $VWB_URLS; do
        for ph in 1 2 3; do
            vwb_build_plan "$ph" "$u" >> "$plan"
        done
    done
    if vwb_insecure_allowed; then
        for u in $VWB_URLS; do
            vwb_build_plan 4 "$u" >> "$plan"
        done
    else
        vwb_log "  (unverified fallback disabled - create $VWB_INSECURE_MARKER to allow it)"
    fi

    VWB_TOTAL=$(grep -c . "$plan")
    vwb_log "- Downloading $VWB_LABEL (min $(vwb_human "$VWB_MIN"), up to $VWB_TOTAL attempts)"

    ok=0
    while read -r engine prof url; do
        [ -n "$url" ] || continue
        if [ "$VWB_N" -ge "$VWB_MAX_ATTEMPTS" ]; then
            vwb_warn "attempt limit ($VWB_MAX_ATTEMPTS) reached for $VWB_LABEL"
            break
        fi

        vwb_attempt "$engine" "$prof" "$url" "$VWB_DEST" "$VWB_MIN" "$VWB_LABEL"
        rc=$?

        if [ "$rc" = "0" ]; then
            ok=1
            break
        fi

        # wget that cannot verify certificates: mention it once, it only gets
        # used again in stage 4 when the user explicitly opted in.
        if [ "$rc" = "3" ] && ! vwb_insecure_allowed; then
            vwb_warn "skipping unverified wget (opt in with the marker file to allow it)"
        fi

        # Resume bookkeeping: if two attempts in a row bring no new bytes the
        # partial file is useless (mirror mismatch, server without ranges...).
        if [ "$rc" != "2" ]; then
            now=$(vwb_size "$VWB_DEST.part")
            if [ "$now" = "$lastsize" ]; then
                stall=$((stall + 1))
                if [ "$stall" -ge 2 ]; then
                    vwb_warn "no progress while resuming - restarting this download"
                    rm -f "$VWB_DEST.part"
                    stall=0
                    lastsize=-1
                fi
            else
                stall=0
                lastsize=$now
            fi
        else
            stall=0
            lastsize=-1
        fi
        sleep 3
    done < "$plan"
    rm -f "$plan"

    if [ "$ok" = "1" ]; then
        vwb_log "- $VWB_LABEL ready: $(vwb_human "$(vwb_size "$VWB_DEST")")"
        return 0
    fi

    vwb_err "$VWB_LABEL: all download attempts failed"
    return 1
}
