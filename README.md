# Vanadium WebView & Browser Installer

A Magisk / KernelSU-Next / APatch module that replaces the system WebView with
[Vanadium WebView](https://github.com/GrapheneOS/Vanadium) and installs the
Vanadium Browser.

## Features
- Installs Vanadium Trichrome Library, Vanadium WebView and Vanadium Browser
- Registers the WebView provider through an RRO overlay (`config_webview_packages`)
- Works on Magisk, KernelSU / KernelSU Next and APatch, ARM64 and ARM
- **Verified downloads**: every APK is size-checked, tested as a ZIP archive and
  only then moved into `/system`, so a bad connection can never mount a broken
  WebView
- **Resumable downloads**: interrupted transfers continue where they stopped,
  stalled connections are detected and retried, and three GitLab endpoints plus
  DoH/DNS fallbacks are used when a mobile network misbehaves
- **KernelSU Next action button**: update Vanadium in place from the module list,
  no reflash and no re-download of the whole module
- **Atomic updates**: new APKs are swapped in by rename and the previous ones are
  kept as a rollback copy until the next successful boot

## Prerequisites
- Android 10+ (API level 29 or higher)
- Magisk (v20.4+), KernelSU / KernelSU Next or APatch
- Magic Mount, OverlayFS or a ROM that reads `/system` overlays
- Internet connection (Wi-Fi recommended, mobile data is supported but slower)
- ~500 MB of free space on `/data` during installation

## Installation
1. Download the latest release of this module.
2. Flash it in the Magisk / KernelSU Next / APatch manager.
   On the command line: `ksud module install /sdcard/Vanadium-WebViewBrowser.zip`
3. Reboot your device.
4. Go to Settings → Developer options → **WebView implementation**.
5. Select **Vanadium WebView**.
6. Enjoy.

If the module aborts with a download error nothing is installed and your current
WebView keeps working — just retry (preferably on Wi-Fi).

## Updating Vanadium without reflashing
KernelSU Next shows an **Action** button for this module (Magisk/APatch users can
run the script manually):

```
su -c sh /data/adb/modules/Vanadium-WebViewBrowser/action.sh
```

It downloads the newest prebuilt APKs from the configured branch, verifies them
and swaps them into the module. The old APKs are kept as `.backup` until the
next boot, so an interrupted update can always be repaired by `service.sh`.
**Reboot afterwards** — the running system keeps using the previously mounted
APKs until the next boot.

## What changed in v1.3.0
The module keeps doing exactly what it did before (same files, same locations,
same overlay), the download and boot paths around it were hardened:

| Area | Before | Now |
| --- | --- | --- |
| Download engine | one curl call per mirror, `--dns-servers` on every attempt | engine ladder: bundled curl → system curl → busybox/toybox wget, rotating mirrors, DoH / `--dns-servers` / `--capath` / HTTP1.1 only when the binary actually supports it |
| Failure handling | a partial file could still be used if it was non-empty | size + ZIP header + full CRC (`unzip -t`) check before a file is accepted |
| Mobile data | no resume, no stall detection, 15 s wasted on unsupported DNS flags | resume (`-C -`), stalled transfers aborted after 60 s, transient errors retried, progress bar in the install log |
| Broken downloads | truncated APK could end up mounted | never promoted, partials cleaned up, install aborts cleanly |
| Package install | 400 MB copied to `/data/local/tmp` and never removed | streaming install (`pm install -S`), copy fallback, staging always cleaned |
| Boot safety | — | `service.sh` repairs a half-finished update and removes the rollback copies after a successful boot |
| Uninstall | WebView implementation could be left pointing at a package that no longer exists | the framework is switched back to a valid provider before the packages are removed |
| Manager integration | — | KernelSU Next `action.sh` (update button), installed Vanadium version shown in the module description |
| Verification | manual | `tools/test-downloader.sh` (86 checks) + `shellcheck` + BusyBox-ash syntax checks, all wired into GitHub Actions |

### About the bundled curl
`bin/curl64.zip` / `bin/curl.zip` contain a statically linked curl
(8.3.0-DEV, built with OpenSSL/BoringSSL, HTTP/2 and HTTP/3, no c-ares). It is
extracted to `bin/curl` and used first because it is self-contained and verifies
TLS certificates against `/system/etc/security/cacerts`. If it cannot run on
your device (wrong ABI, unusual kernel), the installer falls back to the
system `curl` and then to `wget` — a newer build can be dropped in without
rebuilding the module:

```
# replace the bundled curl inside the module, then re-run the action script
su -c 'cp /sdcard/curl /data/adb/modules/Vanadium-WebViewBrowser/bin/curl.local'
su -c 'chmod 755 /data/adb/modules/Vanadium-WebViewBrowser/bin/curl.local'
```

## Troubleshooting
**WebView implementation list is empty or has no Vanadium entry**
The overlay was not picked up. Check that a `*/overlay` directory exists on your
device (`/system/product/overlay`, `/system/system_ext/overlay`, `/system/overlay`
or `/system/vendor/overlay`); the installer aborts if it cannot find one. Reboot
once more, then re-check the list.

**Vanadium WebView is listed, but the device still uses Google WebView**
Select it manually in Developer options. On some ROMs the choice is reset by the
framework on the first boot after the module is installed.

**Download fails on mobile data**
Retry with Wi-Fi, or keep the screen on and retry — the engine resumes from the
partial file, so an interrupted 200 MB download does not start over. The install
log names the reason (`DNS resolution failed`, `HTTP error 403/404`,
`TLS handshake failed`, `transfer stalled`, ...).

**Everything fails although the network works**
Some carrier proxies break HTTP/2 or hijack DNS. The engine already retries with
DoH (`https://1.1.1.1/dns-query`) and with `--http1.1`, but a corporate or
captive-portal network can still block the endpoints. As a last resort, the
module can be told to use an engine that cannot verify TLS certificates
(**not recommended**, it can expose you to a man-in-the-middle attack):

```
su -c 'touch /data/adb/vanadium-webview-allow-insecure-download'
```

Remove that file again as soon as the install succeeded.

**After uninstalling the module the apps are still installed**
They are reinstalled as normal apps by the package manager. The uninstall script
removes them once the device is booted (`/data/local/tmp/vanadium-webview-uninstall.log`);
if that fails, uninstall `app.vanadium.browser`, `app.vanadium.webview` and
`app.vanadium.trichromelibrary` manually.

## Advanced options
Environment variables understood by the installer and by `action.sh`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `VWB_REF` | `17` | GrapheneOS branch of the prebuilt APKs |
| `VWB_ARCHDIR` | `arm64-multilib` / `arm-multilib` | prebuilt directory (all three files always come from one directory) |
| `VWB_RAW_BASE`, `VWB_BLOB_BASE`, `VWB_API_BASE` | GitLab endpoints | mirrors; must all serve the same branch |
| `VWB_CURL` | auto | curl binary to use; `none` forces the wget path |
| `VWB_CAPATH`, `VWB_CACERT` | auto-detected | CA directory/file for curl or wget |
| `VWB_DOH_URL`, `VWB_DOH_URL2` | `https://1.1.1.1/dns-query`, `https://8.8.8.8/dns-query` | DNS-over-HTTPS endpoints |
| `VWB_NS_SERVERS` | `1.1.1.1,1.0.0.1` | DNS servers for the c-ares profile |
| `VWB_STALL_SPEED`, `VWB_STALL_TIME` | `1024`, `60` | abort a transfer that is slower than N B/s for N s |
| `VWB_CONNECT_TIMEOUT`, `VWB_CURL_RETRY` | `20`, `3` | per-attempt timeout and retries |
| `VWB_MIN_RESUME` | `262144` | minimum partial size before resuming |
| `VWB_MAX_ATTEMPTS` | `14` | hard cap of network attempts per file |
| `VWB_VERIFY` | `full` | `full` = `unzip -t` (CRC) check, `quick` = header/central directory only |
| `VWB_ALLOW_INSECURE` | unset | set to `1` for the same opt-in as the marker file |
| `VWB_TMP_STAGE` | `/data/local/tmp/vanadium-stage` | where the copy-fallback staging happens |

Example: install a different GrapheneOS branch without editing any file

```
su -c 'VWB_REF=17 VWB_ARCHDIR=arm64-multilib sh /data/adb/modules/Vanadium-WebViewBrowser/action.sh'
```

## Development
```
busybox ash -n common/dl.sh                  # syntax check with Android's shell
shellcheck -s sh -S warning *.sh common/*.sh tools/*.sh
busybox ash tools/test-downloader.sh         # 86 checks against a local mirror
sh tools/build-zip.sh                        # build the flashable module zip
```
`tools/test-downloader.sh` starts `tools/test-server.py` (good mirror, dead
mirror, captive portal page, truncated payload, stalling connection, archivers
with and without `-t`/`-l`) and stub `pm`/`getprop`/`dumpsys` binaries, then
runs the real module code — a full `install.sh` run, the `customize.sh` entry
point, the APK swap with rollback, the failure paths and `action.sh` end to end —
without touching a device. It needs `curl`, `unzip` and `python3`.

Every push and pull request runs the same checks through
`.github/workflows/ci.yml` (shellcheck, BusyBox-ash syntax check, the test
suite and a module-zip build).

## Known issues
- A few ROMs reset the WebView provider selection after the module is installed;
  select Vanadium WebView again in Developer options.
- The bundled curl is an older static build (see above). It works on 4 KiB page
  kernels; if a future device refuses to run it, the installer falls back to the
  system downloaders automatically.

## Credits
- Original module: WebView Changer by Lordify (https://gitlab.com/Lordify/webview-changer)
- GrapheneOS – for Vanadium
- topjohnwu – for Magisk
- Tiann / KernelSU-Next team – for KernelSU Next
- Zackptg5 – for MMT-Extended and the static curl builds
- F3FFO – for Open WebView module

## License
This project is licensed under the GNU General Public License v2.0 **or later**
(GPL-2.0-or-later). You are free to modify and redistribute it under the same
terms.

See the full [LICENSE](LICENSE) file for details.
