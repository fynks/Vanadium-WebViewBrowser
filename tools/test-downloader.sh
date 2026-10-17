#!/system/bin/sh
##############################################################################
#  Vanadium WebView & Browser Installer - test suite for the download engine
#
#  Runs on a Linux/macOS dev machine, not on the phone. Everything happens
#  against a local HTTP server plus stub `pm`/`getprop`/`dumpsys` binaries, so
#  the real module code paths are exercised without touching a device.
#
#  Usage:  busybox ash tools/test-downloader.sh
#          sh tools/test-downloader.sh
#
#  Covered: mirror rotation, captive portal rejection, truncated payloads,
#  stall detection + resume, reuse of partial files, per-file integrity
#  checks, the verified/unverified engine gate, and the complete
#  install flow (streaming install, copy fallback, failure path).
##############################################################################

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vwb-test.XXXXXX")
PORT=$((20000 + ($$ % 20000)))
ASH="busybox ash"
command -v busybox >/dev/null 2>&1 || ASH="sh"

PASSED=0
FAILED=0
SERVER_PID=""
LASTLOG=""
LASTSECTION="setup"

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

pass() { PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$1"; }
# (gh_annotate is defined further down; this placeholder keeps early failures
#  from breaking on shells without the real helper yet)

# GitHub understands lines of the form ::error::message ; encoding the newlines
# keeps the whole message (check name, section, log tail) in one annotation.
gh_annotate() { # gh_annotate <error|warning|notice> <message>
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    kind=$1
    msg=$(printf '%s' "$2" | tr -d '\r' | sed -e 's/%/%25/g' \
          | awk 'BEGIN{ORS=""} {gsub(/\n/,"%0A"); print (NR>1 ? "%0A" : "") $0} END{print ""}')
    printf '::%s::%s\n' "$kind" "$msg"
}

fail() {
    FAILED=$((FAILED + 1))
    printf '  FAIL  %s\n' "$1"
    detail=""
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        printf '        log: %s\n' "$2"
        detail=$(tail -c 3000 "$2" | sed 's/^/          /')
    fi
    gh_annotate error "${LASTSECTION:-tests}: $1
$detail"
}
section() { LASTSECTION="$1"; printf '\n== %s\n' "$1"; }
ok()   { pass "$1"; }
nok()  { fail "$1" "${2:-}"; }

# check <description> <command...> ; reports pass/fail from the exit status
check() {
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc" "$LASTLOG"; fi
}
check_not() {
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then fail "$desc" "$LASTLOG"; else pass "$desc"; fi
}
hash_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
# assert_hash <file> <expected file with sha> <description>
assert_hash() {
    if [ ! -f "$1" ]; then nok "$3 (missing)"; return; fi
    if [ "$(hash_of "$1")" = "$(cat "$2")" ]; then pass "$3"; else nok "$3 (sha mismatch)"; fi
}
in_log() { grep -q "$1" "$LASTLOG" 2>/dev/null && pass "$2" || fail "$2" "$LASTLOG"; }

# --------------------------------------------------------------------------
section "preparing assets, stubs and the local mirror"
mkdir -p "$WORK/assets" "$WORK/bin" "$WORK/logs" "$WORK/tmp"

python3 - "$WORK/assets" <<'PY'
import os, sys, zipfile
out = sys.argv[1]
def make_apk(path, manifest_pad, data_pad):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        z.writestr("AndroidManifest.xml", b"M" * manifest_pad)
        z.writestr("classes.dex", b"D" * 4096)
        z.writestr("resources.arsc", os.urandom(data_pad))
make_apk(os.path.join(out, "TrichromeLibrary.apk"), 64 * 1024, 8 * 1024)
make_apk(os.path.join(out, "TrichromeWebView.apk"), 128 * 1024, 1500 * 1024)
make_apk(os.path.join(out, "TrichromeChrome.apk"), 64 * 1024, 128 * 1024)
PY
for f in TrichromeLibrary TrichromeWebView TrichromeChrome; do
    hash_of "$WORK/assets/$f.apk" > "$WORK/assets/$f.sha"
done
apk_count=0
for f in "$WORK/assets"/*.apk; do [ -f "$f" ] && apk_count=$((apk_count + 1)); done
printf '  fake APKs: %s\n' "$apk_count"

cat > "$WORK/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
    ro.product.cpu.abi)    echo arm64-v8a ;;
    ro.build.version.sdk)  echo 35 ;;
    sys.boot_completed)    echo 1 ;;
    "")                    echo "ro.product.cpu.abi=arm64-v8a" ;;
esac
exit 0
EOF
cat > "$WORK/bin/dumpsys" <<'EOF'
#!/bin/sh
echo "  versionName=99.1.2.3"
exit 0
EOF
cat > "$WORK/bin/pm" <<'EOF'
#!/bin/sh
# stand-in for `pm install`; records what the installer asked for
echo "pm $*" >> "$FAKE_PM_LOG"
case "$1" in
    list) echo "package:app.vanadium.webview"; exit 0 ;;
    install) ;;
    *) exit 0 ;;
esac
shift
streaming=0; size=0; path=""
while [ $# -gt 0 ]; do
    case "$1" in
        -S)  streaming=1; size=$2; shift 2 ;;
        --install-location) shift 2 ;;
        -*) shift ;;
        *) path=$1; shift ;;
    esac
done
if [ -n "${FAKE_PM_FAIL:-}" ]; then
    echo "Failure [INSTALL_FAILED_TEST]"
    exit 1
fi
if [ "$streaming" = "1" ]; then
    cat > "$FAKE_PM_STREAMED"; echo "Success (streamed $size bytes)"; exit 0
fi
if [ -n "$path" ] && [ -f "$path" ]; then
    cp "$path" "$FAKE_PM_STREAMED"; echo "Success ($path)"; exit 0
fi
echo "Failure [INSTALL_FAILED_INVALID_APK]"
exit 1
EOF
# a wget that admits it cannot verify certificates (the security gate test)
cat > "$WORK/bin/wget" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -O) out=$2; shift 2 ;;
        --help|-h) echo "wget: fake test engine"; exit 0 ;;
        *) shift ;;
    esac
done
echo "wget: TLS certificate validation not implemented" >&2
[ -n "$out" ] || exit 1
cat "$FAKE_WGET_SOURCE" > "$out"
exit 0
EOF
chmod 0755 "$WORK/bin/getprop" "$WORK/bin/dumpsys" "$WORK/bin/pm" "$WORK/bin/wget"

find_tool() { # find_tool <name> [extra absolute candidates...]
    tool=$1; shift
    for c in "$(command -v "$tool" 2>/dev/null)" "$@" "/usr/bin/$tool" "/bin/$tool"; do
        [ -n "$c" ] || continue
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

REAL_CURL=$(find_tool curl) || { echo "!! curl is required for the tests"; exit 1; }
REAL_UNZIP=$(find_tool unzip) || {
    # the module itself copes without unzip (size + header checks only), but
    # the verification tests cannot, so refuse to run a misleading suite
    echo "!! unzip is required for the tests (apt-get install unzip)"
    gh_annotate error "unzip is missing on this machine - install it before running the test suite"
    exit 1
}
printf '  engines: %s , %s\n' "$REAL_CURL" "$REAL_UNZIP"

python3 "$HERE/test-server.py" "$PORT" "$WORK/assets" > "$WORK/logs/server.log" 2>&1 &
SERVER_PID=$!
ready=0
i=0
while [ "$i" -lt 50 ]; do
    if "$REAL_CURL" -s -o /dev/null "http://127.0.0.1:$PORT/missing/ping"; then ready=1; break; fi
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.2; i=$((i + 1))
done
if [ "$ready" != "1" ]; then
    echo "!! the local test mirror did not start on port $PORT"
    cat "$WORK/logs/server.log" 2>/dev/null
    gh_annotate error "test mirror failed to start on port $PORT (python3/socket problem on this machine)"
    exit 1
fi
printf '  mirror on http://127.0.0.1:%s\n' "$PORT"

# environment shared by every case: fast timeouts, the host curl/unzip, http
REPO="$REPO" WORK="$WORK" PORT="$PORT"
export REPO WORK PORT
export VWB_TEST_HTTP=1 VWB_CURL_RETRY=0 VWB_CONNECT_TIMEOUT=3 \
       VWB_MIN_RESUME=1024 VWB_STALL_SPEED=100000 VWB_STALL_TIME=2 \
       VWB_WATCHDOG_INTERVAL=1 VWB_WATCHDOG_STRIKES=2 VWB_WGET_TIMEOUT=20 \
       VWB_CURL="$REAL_CURL" VWB_UNZIP="$REAL_UNZIP" \
       VWB_ERRFILE="$WORK/logs/stderr" \
       PATH="$WORK/bin:$PATH"
export FAKE_PM_LOG="$WORK/logs/pm.log"
export FAKE_PM_STREAMED="$WORK/logs/streamed.apk"
export VWB_TMP_STAGE="$WORK/tmp/vanadium-stage"

# Environment report: a CI failure is much easier to read when the log says
# which download tools (and which capabilities) the machine actually has.
tool_report=$(sh -c '. "$REPO/common/dl.sh"
    vwb_init >/dev/null 2>&1
    printf "unzip=%s mode=%s\n" "${VWB_UNZIP:-none}" "${VWB_UNZIP_MODE:-none}"
    printf "curl=%s\n" "${VWB_CURL_BIN:-none}"
    printf "wget=%s\n" "${VWB_WGET:-none}"
    printf "busybox=%s\n" "${VWB_BUSYBOX:-none}"
    printf "capath=%s cacert=%s\n" "${VWB_CAPATH:-none}" "${VWB_CACERT:-none}"
    printf "profiles: doh=%s ares=%s http1=%s\n" "${VWB_PROFILE_DOH:-?}" "${VWB_PROFILE_ARES:-?}" "${VWB_PROFILE_HTTP1:-?}"
' 2>&1)
printf '%s\n' "$tool_report" | sed 's/^/  /'
command -v python3 >/dev/null 2>&1 && printf '  python3=%s\n' "$(python3 -V 2>&1)"
printf '  shell=%s\n' "$ASH"
printf '  path=%s\n' "$PATH"
gh_annotate notice "environment: $(printf '%s' "$tool_report" | tr '\n' ' ')"

# run <logname> [extra env assignments...] -- <shell snippet>
run() {
    name=$1; shift
    LASTLOG="$WORK/logs/$name.log"
    $ASH -c "$*" > "$LASTLOG" 2>&1
    rc=$?
    return "$rc"
}

##############################################################################
section "1. happy path"
LASTLOG="$WORK/logs/t1.log"
if $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    vwb_fetch \"\$WORK/t1.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/good/TrichromeWebView.apk\" \
        \"http://127.0.0.1:\$PORT/good2/TrichromeWebView.apk\"" > "$LASTLOG" 2>&1; then
    pass "fetch succeeded"
else
    fail "fetch failed" "$LASTLOG"
fi
assert_hash "$WORK/t1.apk" "$WORK/assets/TrichromeWebView.sha" "downloaded payload is byte identical"
check_not "no leftover .part file" test -f "$WORK/t1.apk.part"

##############################################################################
section "2. first mirror is dead, second one works"
LASTLOG="$WORK/logs/t2.log"
if $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    vwb_fetch \"\$WORK/t2.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/missing/TrichromeLibrary.apk\" \
        \"http://127.0.0.1:\$PORT/good/TrichromeLibrary.apk\"" > "$LASTLOG" 2>&1; then
    pass "fell through to the working mirror"
else
    fail "mirror fallback failed" "$LASTLOG"
fi
in_log "HTTP error" "logged the failing mirror"
assert_hash "$WORK/t2.apk" "$WORK/assets/TrichromeLibrary.sha" "fallback mirror delivered the right bytes"

##############################################################################
section "3. captive portal page is rejected"
LASTLOG="$WORK/logs/t3.log"
if VWB_MAX_ATTEMPTS=2 $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    vwb_fetch \"\$WORK/t3.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/html/TrichromeWebView.apk\"" > "$LASTLOG" 2>&1; then
    fail "HTML payload was accepted"
else
    pass "fetch failed as expected"
fi
in_log "not a ZIP archive" "identified the captive portal page"
check_not "nothing was left in place" test -f "$WORK/t3.apk"
check_not "partial file was cleaned up" test -f "$WORK/t3.apk.part"

##############################################################################
section "4. truncated payload is rejected"
LASTLOG="$WORK/logs/t4.log"
if VWB_MAX_ATTEMPTS=2 $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    echo \"DBG unzip=[\$VWB_UNZIP] mode=[\$VWB_UNZIP_MODE] verify=[\$VWB_VERIFY]\"
    vwb_fetch \"\$WORK/t4.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/trunc/TrichromeWebView.apk\"" > "$LASTLOG" 2>&1; then
    fail "truncated payload was accepted"
else
    pass "fetch failed as expected"
fi
in_log "integrity" "integrity check reported the truncation"
check_not "truncated file was not promoted" test -f "$WORK/t4.apk"

##############################################################################
section "5. stalled connection, then resume from the healthy mirror"
LASTLOG="$WORK/logs/t5.log"
if $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    vwb_fetch \"\$WORK/t5.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/stall/TrichromeWebView.apk\" \
        \"http://127.0.0.1:\$PORT/good/TrichromeWebView.apk\"" > "$LASTLOG" 2>&1; then
    pass "recovered from the stalled transfer"
else
    fail "stall recovery failed" "$LASTLOG"
fi
in_log "timed out / transfer stalled" "stall detected through the speed limits"
in_log "resume from" "the next attempt resumed instead of restarting"
assert_hash "$WORK/t5.apk" "$WORK/assets/TrichromeWebView.sha" "resumed download is byte identical"

##############################################################################
section "6. complete .part file from an interrupted run is reused"
LASTLOG="$WORK/logs/t6.log"
cp "$WORK/assets/TrichromeChrome.apk" "$WORK/t6.apk.part"
if $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    vwb_fetch \"\$WORK/t6.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/missing/TrichromeChrome.apk\"" > "$LASTLOG" 2>&1; then
    pass "used the existing partial file"
else
    fail "complete .part file was not reused" "$LASTLOG"
fi
in_log "already fully downloaded" "logged the reuse"
assert_hash "$WORK/t6.apk" "$WORK/assets/TrichromeChrome.sha" "promoted file is byte identical"

##############################################################################
section "7. per-file verification"
LASTLOG="$WORK/logs/t7.log"
out=$($ASH -c ". \$REPO/common/dl.sh
    vwb_init
    head -c 100 /dev/zero > \"\$WORK/tiny.bin\"
    head -c 9000 /dev/urandom > \"\$WORK/random.bin\"
    printf '%s' '<!DOCTYPE html><html>hi</html>' > \"\$WORK/page.bin\"
    vwb_verify \"\$WORK/tiny.bin\" 4096 x quiet && echo tiny:ACCEPT || echo tiny:REJECT
    vwb_verify \"\$WORK/random.bin\" 4096 x quiet && echo random:ACCEPT || echo random:REJECT
    vwb_verify \"\$WORK/page.bin\" 4096 x quiet && echo html:ACCEPT || echo html:REJECT
    vwb_verify \"\$WORK/assets/TrichromeLibrary.apk\" 4096 x quiet && echo good:ACCEPT || echo good:REJECT
" 2>&1)
case "$out" in *"tiny:REJECT"*)   pass "too small rejected" ;;      *) fail "size check ($out)" ;; esac
case "$out" in *"random:REJECT"*) pass "non-ZIP rejected" ;;        *) fail "magic check ($out)" ;; esac
case "$out" in *"html:REJECT"*)   pass "HTML page rejected" ;;      *) fail "HTML check ($out)" ;; esac
case "$out" in *"good:ACCEPT"*)   pass "valid APK accepted" ;;      *) fail "valid APK rejected ($out)" ;; esac

##############################################################################
section "8. unverified engines are locked behind the opt-in marker"
LASTLOG="$WORK/logs/t8.log"
if VWB_CURL=none VWB_BUSYBOX_OVERRIDE=/nonexistent FAKE_WGET_SOURCE="$WORK/assets/TrichromeLibrary.apk" \
   $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    echo \"DBG wget=[\$VWB_WGET] busybox=[\$VWB_BUSYBOX] curl=[\$VWB_CURL_BIN] errfile=[\$VWB_ERRFILE]\"
    echo \"DBG stub=[$(command -v wget)]\"
    vwb_fetch \"\$WORK/t8.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/good/TrichromeLibrary.apk\"" > "$LASTLOG" 2>&1; then
    fail "unverified engine was used without opt-in"
else
    pass "wget that cannot verify TLS is refused"
fi
in_log "skipping unverified wget" "the refusal is explained in the log"
check_not "no file accepted" test -f "$WORK/t8.apk"

LASTLOG="$WORK/logs/t8b.log"
if VWB_CURL=none VWB_BUSYBOX_OVERRIDE=/nonexistent VWB_ALLOW_INSECURE=1 \
   FAKE_WGET_SOURCE="$WORK/assets/TrichromeLibrary.apk" \
   $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    vwb_fetch \"\$WORK/t8b.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/good/TrichromeLibrary.apk\"" > "$LASTLOG" 2>&1; then
    pass "opt-in marker unlocks the unverified fallback"
else
    fail "opt-in did not unlock wget" "$LASTLOG"
fi
assert_hash "$WORK/t8b.apk" "$WORK/assets/TrichromeLibrary.sha" "fallback delivered the payload"

##############################################################################
section "8b. limited archivers on the device"
cat > "$WORK/bin/unzip_no_t" <<EOF
#!/bin/sh
for a in "\$@"; do
    case "\$a" in
        -t) echo "unzip: unrecognized option: t" >&2; exit 1 ;;
    esac
done
exec $REAL_UNZIP "\$@"
EOF
cat > "$WORK/bin/unzip_no_t_no_l" <<EOF
#!/bin/sh
for a in "\$@"; do
    case "\$a" in
        -t|-l) echo "unzip: unrecognized option: \$a" >&2; exit 1 ;;
    esac
done
exec $REAL_UNZIP "\$@"
EOF
chmod 0755 "$WORK/bin/unzip_no_t" "$WORK/bin/unzip_no_t_no_l"

LASTLOG="$WORK/logs/t8c.log"
if VWB_UNZIP_OVERRIDE="$WORK/bin/unzip_no_t" $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    echo \"MODE=\$VWB_UNZIP_MODE\"
    vwb_fetch \"\$WORK/t8c.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/good/TrichromeWebView.apk\"" > "$LASTLOG" 2>&1; then
    pass "download works without unzip -t support"
else
    fail "limited archiver broke the download" "$LASTLOG"
fi
check "archiver capability detected as list-only" grep -q "MODE=list" "$LASTLOG"
assert_hash "$WORK/t8c.apk" "$WORK/assets/TrichromeWebView.sha" "payload still verified by structure"

LASTLOG="$WORK/logs/t8d.log"
if VWB_UNZIP_OVERRIDE="$WORK/bin/unzip_no_t_no_l" $ASH -c ". \$REPO/common/dl.sh
    vwb_init
    echo \"MODE=\$VWB_UNZIP_MODE\"
    vwb_fetch \"\$WORK/t8d.apk\" 4096 'test payload' \
        \"http://127.0.0.1:\$PORT/good/TrichromeWebView.apk\"" > "$LASTLOG" 2>&1; then
    pass "download works with an archiver that can only extract"
else
    fail "minimal archiver broke the download" "$LASTLOG"
fi
check "archiver capability detected as none" grep -q "MODE=none" "$LASTLOG"
assert_hash "$WORK/t8d.apk" "$WORK/assets/TrichromeWebView.sha" "size and header checks were enough"

##############################################################################
# the complete installer, with fake APKs served by the local mirror
prepare_module() {
    rm -rf "$1"
    mkdir -p "$1/bin" "$1/common" "$1/Overlay" "$1/system" "$1/tools"
    cp "$REPO/common/dl.sh" "$REPO/common/install.sh" "$REPO/common/swap.sh" "$1/common/"
    cp "$REPO/action.sh" "$REPO/service.sh" "$REPO/uninstall.sh" "$REPO/customize.sh" "$1/"
    cp "$REPO/module.prop" "$1/module.prop"
    : > "$1/system/.placeholder"
    head -c 2048 /dev/urandom > "$1/Overlay/WebViewOverlay29.apk"
    python3 - "$WORK/fakezip" <<'PY'
import os, sys, zipfile
d = sys.argv[1]
os.makedirs(os.path.join(d, "arm64"), exist_ok=True)
with open(os.path.join(d, "arm64", "curl"), "w") as fh:
    fh.write("#!/bin/sh\nexit 1\n")
PY
    rm -f "$WORK/curl64.zip"
    (cd "$WORK/fakezip" && python3 -c "
import zipfile; z=zipfile.ZipFile('$WORK/curl64.zip','w'); z.write('arm64/curl'); z.close()")
    cp "$WORK/curl64.zip" "$1/bin/curl64.zip"
    cp "$WORK/curl64.zip" "$1/bin/curl.zip"
}

installer_env() { # installer_env <module dir> <raw base> <blob base> <api base>
    export VWB_OVERLAY_PATH=system/product/overlay/
    export MIN_LIB=4096 MIN_WEBVIEW=4096 MIN_BROWSER=4096
    export VWB_REF=17 VWB_ARCHDIR=arm64-multilib
    export VWB_RAW_BASE="$2" VWB_BLOB_BASE="$3" VWB_API_BASE="$4"
    export ARCH=arm64 API=35
    export MODPATH="$1" MODDIR="$1"
}
run_installer() { # run_installer <module dir> <log>
    MODPATH="$1" $ASH -c '. "$MODPATH/common/install.sh"' > "$2" 2>&1
}

section "9. full install (streaming package install)"
MP="$WORK/modpath"
prepare_module "$MP"
: > "$WORK/logs/pm.log"
LASTLOG="$WORK/logs/t9.log"
installer_env "$MP" "http://127.0.0.1:$PORT/good" "http://127.0.0.1:$PORT/missing" "http://127.0.0.1:$PORT/good2"
if run_installer "$MP" "$LASTLOG"; then
    pass "installer reported success"
else
    fail "installer failed" "$LASTLOG"
fi
assert_hash "$MP/system/app/VanadiumWebView/VanadiumWebView.apk" "$WORK/assets/TrichromeWebView.sha" "WebView APK in place"
assert_hash "$MP/system/app/VanadiumTrichromeLibrary/VanadiumTrichromeLibrary.apk" "$WORK/assets/TrichromeLibrary.sha" "library APK in place"
assert_hash "$MP/system/app/VanadiumBrowser/VanadiumBrowser.apk" "$WORK/assets/TrichromeChrome.sha" "browser APK in place"
check "overlay installed" test -f "$MP/system/product/overlay/WebViewOverlay.apk"
check_not ".placeholder cleaned up" test -f "$MP/system/.placeholder"
check_not "bundled zips cleaned up" test -f "$MP/bin/curl64.zip"
check_not "Overlay source directory cleaned up" test -d "$MP/Overlay"
check_not "tools directory does not ship into the module" test -d "$MP/tools"
check_not "staging directory removed" test -d "$MP/.stage"
check_not "no leftovers in the fallback temp dir" test -d "$VWB_TMP_STAGE"
if grep -qE "cannot run on this device|no unzip available, cannot extract" "$LASTLOG"; then
    pass "unusable bundled curl handled gracefully"
else
    fail "the installer did not report the unusable bundled curl" "$LASTLOG"
fi
check "build info recorded in module.prop" grep -q "99.1.2.3" "$MP/module.prop"
if [ "$(grep -c '^pm install' "$WORK/logs/pm.log" 2>/dev/null)" = "3" ]; then
    pass "package manager called for all three APKs"
else
    fail "expected 3 pm install calls, got: $(tr '\n' '|' < "$WORK/logs/pm.log" 2>/dev/null)"
fi
check "streaming install (-S) was used" grep -q "install.*-S" "$WORK/logs/pm.log"
check "streamed payload reached the package manager" cmp -s "$WORK/logs/streamed.apk" "$WORK/assets/TrichromeChrome.apk"

section "10. failed download leaves nothing half installed"
MP="$WORK/modpath_fail"
prepare_module "$MP"
LASTLOG="$WORK/logs/t10.log"
installer_env "$MP" "http://127.0.0.1:$PORT/missing" "http://127.0.0.1:$PORT/missing" "http://127.0.0.1:$PORT/missing"
if VWB_MAX_ATTEMPTS=1 run_installer "$MP" "$LASTLOG"; then
    fail "installer claimed success without downloads"
else
    pass "installer failed as expected"
fi
in_log "installation failed" "failure was reported"
check_not "no APK mounted" test -f "$MP/system/app/VanadiumWebView/VanadiumWebView.apk"
check_not "staging directory removed" test -d "$MP/.stage"
if find "$MP" -name '*.part' 2>/dev/null | grep -q .; then
    fail "partial files left behind"
else
    pass "no partial files left behind"
fi

section "11. copy-to-temp fallback when the streaming install fails"
MP="$WORK/modpath_copy"
prepare_module "$MP"
LASTLOG="$WORK/logs/t11.log"
installer_env "$MP" "http://127.0.0.1:$PORT/good" "http://127.0.0.1:$PORT/good" "http://127.0.0.1:$PORT/good"
if FAKE_PM_FAIL=1 run_installer "$MP" "$LASTLOG"; then
    pass "installer still succeeds when pm install fails"
else
    fail "installer failed when it should not" "$LASTLOG"
fi
in_log "INSTALL_FAILED_TEST" "package manager failure was reported"
in_log "Vanadium files are ready" "the download/mount stage is unaffected"
check_not "fallback staging directory cleaned" test -d "$VWB_TMP_STAGE"
check_not "no stray APKs in the temp stage" test -f "$VWB_TMP_STAGE/VanadiumWebView.apk"

##############################################################################
section "12. APK swap, rollback and backup clean up"
MP="$WORK/modpath_swap"
prepare_module "$MP"
mkdir -p "$MP/system/app/VanadiumWebView"
printf 'OLD WEBVIEW' > "$MP/system/app/VanadiumWebView/VanadiumWebView.apk"
printf 'NEW WEBVIEW' > "$WORK/new_webview.apk"
# shellcheck disable=SC2034,SC1091
LASTLOG="$WORK/logs/t12.log"
if MODDIR="$MP" $ASH -c '. "$WORK/new_webview.apk" 2>/dev/null; . "$REPO/common/swap.sh"
    swap_apk "$WORK/new_webview.apk" "$MODDIR/system/app/VanadiumWebView/VanadiumWebView.apk"' > "$LASTLOG" 2>&1; then
    [ "$(cat "$MP/system/app/VanadiumWebView/VanadiumWebView.apk")" = "NEW WEBVIEW" ] &&
        pass "target APK replaced" || fail "APK not replaced"
    [ "$(cat "$MP/.backup/VanadiumWebView.apk" 2>/dev/null)" = "OLD WEBVIEW" ] &&
        pass "previous APK kept as rollback" || fail "no rollback copy"
else
    fail "swap_apk failed" "$LASTLOG"
fi

# an interrupted update: the target is gone, the rollback copy is there
rm -f "$MP/system/app/VanadiumWebView/VanadiumWebView.apk"
LASTLOG="$WORK/logs/t12b.log"
MODDIR="$MP" $ASH -c '. "$REPO/common/swap.sh"; restore_missing_apks; purge_backup' > "$LASTLOG" 2>&1
[ "$(cat "$MP/system/app/VanadiumWebView/VanadiumWebView.apk" 2>/dev/null)" = "OLD WEBVIEW" ] &&
    pass "interrupted swap was repaired from the rollback copy" || fail "rollback repair failed"
check_not "backup removed once everything is in place" test -d "$MP/.backup"

# a half finished swap must NOT be cleaned up (the APK would be lost)
mkdir -p "$MP/.backup"
printf 'STALE' > "$MP/.backup/VanadiumBrowser.apk"
printf '%s' "$MP/system/app/VanadiumBrowser/VanadiumBrowser.apk" > "$MP/.backup/VanadiumBrowser.apk.path"
MODDIR="$MP" $ASH -c '. "$REPO/common/swap.sh"; purge_backup' > /dev/null 2>&1
check "backup preserved while a file is still missing" test -d "$MP/.backup"

##############################################################################
section "13. KernelSU Next action script, end to end"
MP="$WORK/modpath_action"
prepare_module "$MP"
mkdir -p "$MP/system/app/VanadiumTrichromeLibrary" "$MP/system/app/VanadiumWebView" "$MP/system/app/VanadiumBrowser"
printf 'OLD LIB'   > "$MP/system/app/VanadiumTrichromeLibrary/VanadiumTrichromeLibrary.apk"
printf 'OLD WV'    > "$MP/system/app/VanadiumWebView/VanadiumWebView.apk"
printf 'OLD BROWSER' > "$MP/system/app/VanadiumBrowser/VanadiumBrowser.apk"
LASTLOG="$WORK/logs/t13.log"
export VWB_RAW_BASE="http://127.0.0.1:$PORT/good"
export VWB_BLOB_BASE="http://127.0.0.1:$PORT/missing"
export VWB_API_BASE="http://127.0.0.1:$PORT/good2"
if MODPATH="$MP" MODDIR="$MP" sh "$MP/action.sh" > "$LASTLOG" 2>&1; then
    pass "action.sh finished successfully"
else
    fail "action.sh failed (rc=$?)" "$LASTLOG"
fi
assert_hash "$MP/system/app/VanadiumWebView/VanadiumWebView.apk" "$WORK/assets/TrichromeWebView.sha" "WebView updated in place"
assert_hash "$MP/system/app/VanadiumTrichromeLibrary/VanadiumTrichromeLibrary.apk" "$WORK/assets/TrichromeLibrary.sha" "library updated in place"
assert_hash "$MP/system/app/VanadiumBrowser/VanadiumBrowser.apk" "$WORK/assets/TrichromeChrome.sha" "browser updated in place"
check "old APKs kept for rollback" grep -q "OLD WV" "$MP/.backup/VanadiumWebView.apk"
check_not "staging directory removed" test -d "$MP/.stage"
in_log "Update finished" "the summary was printed"
in_log "Reboot" "the reboot hint was printed"

LASTLOG="$WORK/logs/t13b.log"
export VWB_RAW_BASE="http://127.0.0.1:$PORT/missing"
export VWB_BLOB_BASE="http://127.0.0.1:$PORT/missing"
export VWB_API_BASE="http://127.0.0.1:$PORT/missing"
cp "$MP/system/app/VanadiumWebView/VanadiumWebView.apk" "$WORK/before_failed_action.apk"
if VWB_MAX_ATTEMPTS=1 MODPATH="$MP" MODDIR="$MP" sh "$MP/action.sh" > "$LASTLOG" 2>&1; then
    fail "action.sh reported success without a working mirror"
else
    pass "action.sh failed cleanly"
fi
check "installed APK untouched after the failed update" \
    cmp -s "$WORK/before_failed_action.apk" "$MP/system/app/VanadiumWebView/VanadiumWebView.apk"
check_not "no staging leftovers after the failure" test -d "$MP/.stage"

##############################################################################
section "14. customize.sh entry point"
MP="$WORK/modpath_custom"
prepare_module "$MP"

LASTLOG="$WORK/logs/t14a.log"
if API=28 ARCH=arm64 MODPATH="$MP" $ASH "$MP/customize.sh" > "$LASTLOG" 2>&1; then
    fail "Android 9 was accepted"
else
    pass "install on an unsupported Android version is refused"
fi
in_log "Android 10+" "the version requirement is explained"
check_not "refused run did not install anything" test -d "$MP/system/app"

LASTLOG="$WORK/logs/t14b.log"
if API=35 ARCH=mips MODPATH="$MP" $ASH "$MP/customize.sh" > "$LASTLOG" 2>&1; then
    fail "unsupported architecture was accepted"
else
    pass "unsupported architecture is refused"
fi
in_log "Unsupported CPU architecture" "the architecture is named in the message"

LASTLOG="$WORK/logs/t14c.log"
installer_env "$MP" "http://127.0.0.1:$PORT/good" "http://127.0.0.1:$PORT/missing" "http://127.0.0.1:$PORT/good2"
if MODPATH="$MP" $ASH "$MP/customize.sh" > "$LASTLOG" 2>&1; then
    pass "customize.sh installs on a supported device"
else
    fail "customize.sh failed on the happy path" "$LASTLOG"
fi
assert_hash "$MP/system/app/VanadiumWebView/VanadiumWebView.apk" "$WORK/assets/TrichromeWebView.sha" "APK placed through customize.sh"
in_log "WebView implementation" "the follow-up instructions were printed"
check_not "no staging leftovers" test -d "$MP/.stage"

##############################################################################
printf '\n==========================================\n'
printf ' passed: %s   failed: %s\n' "$PASSED" "$FAILED"
printf '==========================================\n'

# keep every log for CI (uploaded as an artifact) and for local debugging
if [ -n "${VWB_TEST_LOG_DIR:-}" ]; then
    mkdir -p "$VWB_TEST_LOG_DIR" 2>/dev/null
    cp "$WORK/logs/"* "$VWB_TEST_LOG_DIR/" 2>/dev/null
    printf 'passed=%s failed=%s\n' "$PASSED" "$FAILED" > "$VWB_TEST_LOG_DIR/summary.txt"
fi

if [ "$FAILED" != "0" ]; then
    gh_annotate error "download engine tests: $FAILED of $((PASSED + FAILED)) checks failed (see the log above)"
    exit 1
fi
gh_annotate notice "download engine tests: all $PASSED checks passed"
exit 0
