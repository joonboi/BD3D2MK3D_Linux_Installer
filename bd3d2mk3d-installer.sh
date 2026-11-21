#!/usr/bin/env bash
# BD3D2MK3D installer. Run as a regular desktop user with sudo access.
set -Eeuo pipefail
umask 022

PREFIX="${BD3D_PREFIX:-$HOME/.wine-bd3d2mk3d}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/bd3d2mk3d-installer"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/bd3d2mk3d-installer"
SECTION="Preflight"
TMP=""

[[ $EUID -ne 0 ]] || { echo 'Run as your regular desktop user, not root.' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'This installer requires x86_64.' >&2; exit 1; }
[[ "$PREFIX" == /* && "$PREFIX" != / ]] || { echo 'Use an absolute application prefix path.' >&2; exit 1; }

mkdir -p "$STATE" "$CACHE"
RUN_LOG="$STATE/run-$(date +%Y%m%d-%H%M%S)-$$.log"
exec > >(tee -a "$RUN_LOG") 2>&1
ln -sf "$(basename "$RUN_LOG")" "$STATE/latest.log"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bd3d2mk3d.XXXXXXXX")
cleanup() { [[ -z "$TMP" ]] || rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'rc=$?; printf "\nERROR: %s\nLine: %s\nExit: %s\nCommand: %s\nLog: %s\n" "$SECTION" "$LINENO" "$rc" "$BASH_COMMAND" "$RUN_LOG" >&2; exit "$rc"' ERR
log() { printf '[BD3D2MK3D] %s\n' "$*"; }
step() { SECTION="$*"; printf '\n[BD3D2MK3D] %s\n' "$SECTION"; }
die() { log "ERROR: $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
need() { has "$1" || die "Required command unavailable: $1"; }

need sudo
sudo -v
[[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] || die 'Run from your logged-in graphical desktop.'
if [[ -e "$PREFIX" && ! -O "$PREFIX" ]]; then die "Prefix is not owned by this user: $PREFIX"; fi
if [[ -f "$PREFIX/system.reg" ]] && grep -q '^#arch=win32' "$PREFIX/system.reg"; then
    die 'Existing prefix is 32-bit. It has not been changed; choose a different BD3D_PREFIX.'
fi

for entry in apt-get dnf zypper pacman apk xbps-install; do
    if has "$entry"; then PM="$entry"; break; fi
done
[[ -n ${PM:-} ]] || die 'No supported package manager found.'
log "Package manager: $PM"
log "Prefix: $PREFIX"
log "Log: $RUN_LOG"

pkg_install() {
    case "$PM" in
        apt-get) sudo env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "$@" ;;
        dnf) sudo dnf -q install -y "$@" ;;
        zypper) sudo zypper --quiet --non-interactive install "$@" ;;
        pacman) sudo pacman -S --needed --noconfirm --quiet "$@" ;;
        apk) sudo apk add --quiet "$@" ;;
        xbps-install) sudo xbps-install -y "$@" >/dev/null ;;
    esac
}

pkg_available() {
    case "$PM" in
        apt-get) apt-cache policy "$1" | grep -Eq 'Candidate: [^ (]' ;;
        dnf) dnf -q list --available "$1" >/dev/null 2>&1 || rpm -q "$1" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive search --match-exact "$1" | grep -Fq " $1 " ;;
        pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
        apk) apk search -x "$1" | grep -q . ;;
        xbps-install) xbps-query -R "$1" >/dev/null 2>&1 ;;
    esac
}

first_package() {
    local p
    for p in "$@"; do
        if pkg_available "$p"; then pkg_install "$p"; return; fi
    done
    die "No configured repository provides any of: $*"
}

step 'Refresh package metadata'
case "$PM" in
    apt-get) sudo apt-get -qq update ;;
    dnf) sudo dnf -q makecache --refresh ;;
    zypper) sudo zypper --quiet --non-interactive refresh ;;
    pacman) sudo pacman -Syu --noconfirm --quiet ;;
    apk) sudo apk update --quiet ;;
    xbps-install) sudo xbps-install -S >/dev/null ;;
esac

step 'Install base dependencies'
pkg_install curl ca-certificates jq wget cabextract unzip
if ! has xdg-user-dir; then
    case "$PM" in
        apk) pkg_install xdg-user-dirs ;;
        *) if pkg_available xdg-user-dirs; then pkg_install xdg-user-dirs; fi ;;
    esac
fi
if ! has 7z && ! has 7zz; then
    case "$PM" in
        apt-get) first_package 7zip p7zip-full ;;
        dnf) first_package 7zip p7zip ;;
        *) first_package 7zip p7zip ;;
    esac
fi
if has 7zz; then SEVEN=$(command -v 7zz); else SEVEN=$(command -v 7z); fi
for c in curl jq wget cabextract unzip sha256sum; do need "$c"; done

fetch() {
    local url="$1" target="$2"
    curl --proto '=https' --proto-redir '=https' -fL --retry 3 \
        --connect-timeout 30 --max-time 1800 -o "$target.part" "$url" || return $?
    [[ -s "$target.part" ]] || die "Empty download: $url"
    mv -f "$target.part" "$target"
}

step 'Install or locate Wine'
if ! has wine; then pkg_install wine; fi
need wine
WINE=$(command -v wine)
WINE_VERSION=$("$WINE" --version)
log "$WINE_VERSION"
if has wineserver; then SERVER=$(command -v wineserver); else
    SERVER=''
    for candidate in "$(dirname "$(readlink -f "$WINE")")/wineserver" \
        /usr/lib/wine/wineserver /usr/lib64/wine/wineserver \
        /usr/lib/x86_64-linux-gnu/wine/wineserver; do
        if [[ -x "$candidate" ]]; then SERVER="$candidate"; break; fi
    done
fi
[[ -n "$SERVER" ]] || die 'Cannot locate wineserver for the selected Wine installation.'
log "Wine: $WINE"
log "Wineserver: $SERVER"
"$SERVER" --version
export WINE
export WINESERVER="$SERVER"

step 'Install or locate Winetricks'
if has winetricks && winetricks --version; then
    log 'Reusing existing Winetricks.'
else
    if [[ "$PM" == apk ]]; then
        log 'APK: install upstream Winetricks directly; no APK package lookup or install.'
        fetch https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks "$TMP/winetricks"
        bash -n "$TMP/winetricks"
        sudo mkdir -p /usr/local/bin
        sudo cp "$TMP/winetricks" /usr/local/bin/winetricks
        sudo chmod 0755 /usr/local/bin/winetricks
        export PATH="/usr/local/bin:$PATH"
        hash -r
    elif pkg_available winetricks; then
        pkg_install winetricks
    else
        fetch https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks "$TMP/winetricks"
        bash -n "$TMP/winetricks"
        sudo mkdir -p /usr/local/bin
        sudo cp "$TMP/winetricks" /usr/local/bin/winetricks
        sudo chmod 0755 /usr/local/bin/winetricks
        export PATH="/usr/local/bin:$PATH"
        hash -r
    fi
fi
need winetricks
winetricks --version

step 'Resolve Wine-compatible Mono and Gecko versions'
if [[ "$WINE_VERSION" =~ wine-([0-9]+\.[0-9]+(\.[0-9]+)?)(-rc[0-9]+)? ]]; then
    WINE_TAG="wine-${BASH_REMATCH[1]}${BASH_REMATCH[3]:-}"
else
    die "Cannot resolve upstream Wine version from: $WINE_VERSION"
fi
fetch "https://raw.githubusercontent.com/wine-mirror/wine/$WINE_TAG/dlls/appwiz.cpl/addons.c" "$TMP/addons.c"
MONO_VERSION=$(sed -n 's/^#define MONO_VERSION "\([0-9.]*\)".*/\1/p' "$TMP/addons.c")
GECKO_VERSION=$(sed -n 's/^#define GECKO_VERSION "\([0-9.]*\)".*/\1/p' "$TMP/addons.c")
[[ "$MONO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Cannot determine compatible Mono version; refusing to guess.'
[[ "$GECKO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Cannot determine compatible Gecko version; refusing to guess.'
MONO_SHA=$(sed -n 's/^#define MONO_SHA "\([a-fA-F0-9]*\)".*/\1/p' "$TMP/addons.c" | head -n 1)
mapfile -t GECKO_HASHES < <(sed -n 's/^#define GECKO_SHA "\([a-fA-F0-9]*\)".*/\1/p' "$TMP/addons.c")
[[ "$MONO_SHA" =~ ^[a-fA-F0-9]{64}$ && ${#GECKO_HASHES[@]} -eq 2 ]] || die 'Unexpected upstream checksum definitions.'
for h in "${GECKO_HASHES[@]}"; do [[ "$h" =~ ^[a-fA-F0-9]{64}$ ]] || die 'Invalid Gecko checksum.'; done
log "Source tag: $WINE_TAG; Mono: $MONO_VERSION; Gecko: $GECKO_VERSION"

export WINEPREFIX="$PREFIX"
export WINEARCH=win64
unset WINEDLLOVERRIDES
export WINEDEBUG="${BD3D_WINEDEBUG:--all}"

shared_has() {
    local component="$1" version="$2" arch="$3" root dir
    for root in /usr/share/wine /usr/local/share/wine /usr/lib/wine /usr/lib64/wine \
        /opt/wine-stable/share/wine /opt/wine-devel/share/wine /opt/wine-staging/share/wine; do
        if [[ "$component" == mono ]]; then
            dir="$root/mono/wine-mono-$version"
            if [[ -d "$dir" ]] && [[ -n $(find "$dir" -name mscorlib.dll -type f -print -quit) ]]; then return 0; fi
        else
            dir="$root/gecko/wine-gecko-$version-$arch"
            if [[ -d "$dir" ]] && [[ -n $(find "$dir" -name xul.dll -type f -print -quit) ]]; then return 0; fi
        fi
    done
    return 1
}

prefix_has() {
    local component="$1" version="$2" arch="$3" dir
    [[ -f "$PREFIX/system.reg" ]] || return 1
    if [[ "$component" == mono ]]; then
        dir="$PREFIX/drive_c/windows/mono"
        if [[ -d "$dir" ]] && [[ -n $(find "$dir" -name mscorlib.dll -print -quit) ]]; then
            if awk -v ver="$version" 'BEGIN { RS="\n[[]" }
                /Wine Mono Runtime/ && index($0, "\"DisplayVersion\"=\"" ver "\"") { found=1 }
                END { exit !found }' "$PREFIX/system.reg"; then return 0; fi
        fi
    else
        if [[ "$arch" == x86 ]]; then dir="$PREFIX/drive_c/windows/syswow64/gecko";
        else dir="$PREFIX/drive_c/windows/system32/gecko"; fi
        [[ -d "$dir" ]] && [[ -n $(find "$dir" -path "*$version*" -name xul.dll -print -quit) ]] && return 0
    fi
    return 1
}

component_has() { shared_has "$@" || prefix_has "$@"; }

step 'Check native Wine support packages on this package-manager branch'
for component in mono gecko; do
    if [[ "$component" == mono ]]; then ver="$MONO_VERSION";
    else ver="$GECKO_VERSION"; fi
    if component_has "$component" "$ver" x86 && \
       { [[ "$component" == mono ]] || component_has "$component" "$ver" x86_64; }; then
        log "Reusing compatible Wine $component."
        continue
    fi
    case "$PM:$component" in
        dnf:gecko) candidates=(mingw32-wine-gecko mingw64-wine-gecko wine-gecko) ;;
        *) candidates=("wine-$component") ;;
    esac
    for p in "${candidates[@]}"; do
        if pkg_available "$p"; then pkg_install "$p"; fi
    done
done

cache_msi() {
    local component="$1" version="$2" arch="$3" digest="$4"
    local name="wine-$component-$version-$arch.msi" target
    target="$CACHE/wine-$component-$version-$arch.msi"
    if [[ -f "$target" ]] && printf '%s %s\n' "$digest" "$target" | sha256sum -c - >/dev/null 2>&1; then
        log "Reusing verified $name"
    else
        fetch "https://dl.winehq.org/wine/wine-$component/$version/$name" "$target"
        printf '%s %s\n' "$digest" "$target" | sha256sum -c -
    fi
    mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/wine"
    cp "$target" "${XDG_CACHE_HOME:-$HOME/.cache}/wine/$name"
}

step 'Prepare missing Mono and Gecko installers'
if ! component_has mono "$MONO_VERSION" x86; then cache_msi mono "$MONO_VERSION" x86 "$MONO_SHA"; fi
if ! component_has gecko "$GECKO_VERSION" x86; then cache_msi gecko "$GECKO_VERSION" x86 "${GECKO_HASHES[0]}"; fi
if ! component_has gecko "$GECKO_VERSION" x86_64; then cache_msi gecko "$GECKO_VERSION" x86_64 "${GECKO_HASHES[1]}"; fi

WINEDLLOVERRIDES='mscoree,mshtml=' "$WINE" wineboot -u >/dev/null 2>&1
"$SERVER" -w >/dev/null 2>&1

install_component() {
    local component="$1" version="$2" arch="$3"
    if component_has "$component" "$version" "$arch"; then
        log "Available: Wine $component $version ($arch)"
        return
    fi
    "$WINE" msiexec /i "$CACHE/wine-$component-$version-$arch.msi" /qn /norestart >/dev/null 2>&1
    "$SERVER" -w >/dev/null 2>&1
    component_has "$component" "$version" "$arch" || die "Wine $component $version ($arch) failed file verification."
}

step 'Install and verify Mono and Gecko in the application environment'
install_component mono "$MONO_VERSION" x86
install_component gecko "$GECKO_VERSION" x86
install_component gecko "$GECKO_VERSION" x86_64
"$WINE" wineboot -u >/dev/null 2>&1
"$SERVER" -w >/dev/null 2>&1
"$WINE" reg query 'HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall' /s > "$STATE/wine-components-registry.log" 2>/dev/null
log 'Mono/Gecko checks passed (compatible shared/prefix files, not application functional tests).'

step 'Install core fonts'
winetricks -q corefonts
"$SERVER" -w

step 'Install and verify Windows Java'
JAVA_WIN='C:\\Java\\bin\\java.exe'
if [[ -f "$PREFIX/drive_c/Java/bin/java.exe" ]] && "$WINE" "$JAVA_WIN" -version > "$STATE/java-verify.log" 2>&1; then
    log 'Reusing working Java in C:\\Java.'
else
    JAVA_URL=''
    for version in {40..21}; do
        url="https://download.oracle.com/java/$version/latest/jdk-${version}_windows-x64_bin.exe"
        if curl --proto '=https' -fsIL --connect-timeout 15 --max-time 30 "$url" >/dev/null; then JAVA_URL="$url"; break; fi
    done
    [[ -n "$JAVA_URL" ]] || die 'No downloadable Windows Java installer found.'
    fetch "$JAVA_URL" "$TMP/java-installer.exe"
    printf '%s\r\n' 'INSTALL_SILENT=Enable' 'INSTALLDIR=C:\\Java' 'AUTO_UPDATE=Disable' 'REBOOT=Disable' > "$TMP/java-install.cfg"
    CFG_WIN=$("$WINE" winepath -w "$TMP/java-install.cfg" | tr -d '\r')
    JAVA_RC=0
    "$WINE" "$TMP/java-installer.exe" /s "INSTALLCFG=$CFG_WIN" > "$STATE/java-install.log" 2>&1 || JAVA_RC=$?
    log "Java installer exit status: $JAVA_RC (may be non-zero under Wine; Java is verified below)"
    "$SERVER" -w
    [[ -f "$PREFIX/drive_c/Java/bin/java.exe" ]] || die 'Java executable was not installed in C:\\Java.'
    "$WINE" "$JAVA_WIN" -version > "$STATE/java-verify.log" 2>&1
fi
cat "$STATE/java-verify.log"
"$WINE" reg add 'HKCU\\Environment' /v JAVA_HOME /t REG_SZ /d 'C:\\Java' /f >/dev/null 2>&1

# BD3D2MK3D runs "java" by name, so C:\Java\bin must be on Wine's system PATH.
ensure_java_on_path() {
    local key='HKLM\\System\\CurrentControlSet\\Control\\Session Manager\\Environment'
    local current new
    current=$("$WINE" reg query "$key" /v PATH 2>/dev/null | tr -d '\r' \
        | sed -n 's/^[[:space:]]*PATH[[:space:]]*REG_[A-Z_]*[[:space:]]*//p' | head -n 1) || true
    [[ -n "$current" ]] || current='%SystemRoot%\\system32;%SystemRoot%;%SystemRoot%\\system32\\wbem'
    if printf '%s\n' "$current" | tr ';' '\n' | grep -qixF 'C:\\Java\\bin'; then
        log 'C:\\Java\\bin is already on the Wine system PATH.'
    else
        new="C:\\Java\\bin;$current"
        "$WINE" reg add "$key" /v PATH /t REG_EXPAND_SZ /d "$new" /f >/dev/null 2>&1
        log 'Added C:\\Java\\bin to the Wine system PATH.'
    fi
    "$SERVER" -k || true
    sleep 2
}

step 'Put Java on the Wine PATH and verify by name'
ensure_java_on_path
WHERE_OUT=$("$WINE" cmd /c 'where java' 2>&1 | tr -d '\r') || true
printf '%s\n' "$WHERE_OUT" | grep -qiF 'C:\\Java\\bin\\java.exe' \
    || die "java is not resolvable by name from a fresh Wine process. Output: $WHERE_OUT"
NAME_OUT=$("$WINE" cmd /c 'java -version' 2>&1 | tr -d '\r') || true
printf '%s\n' "$NAME_OUT" | grep -Eqi '(java|openjdk) version' \
    || die "Running 'java -version' by name failed. Output: $NAME_OUT"
printf '%s\n' "$NAME_OUT" | grep -Ei '(java|openjdk) version' | head -n 1
log 'Java resolves by name from a fresh Wine process.'

step 'Install AviSynth+ silently'
fetch https://api.github.com/repos/AviSynth/AviSynthPlus/releases/latest "$TMP/avisynth-release.json"
AVISYNTH_URL=$(jq -r '[.assets[] | select(.name | test("^AviSynthPlus_.*\\.exe$")) | select(.name | test("xp";"i") | not)] | sort_by(if (.name | contains("vcredist")) then 0 else 1 end) | .[0].browser_download_url // empty' "$TMP/avisynth-release.json")
[[ "$AVISYNTH_URL" == https://github.com/AviSynth/AviSynthPlus/* ]] || die 'No suitable upstream AviSynth+ installer found.'
fetch "$AVISYNTH_URL" "$TMP/avisynth-installer.exe"
AVS_LOG_WIN=$("$WINE" winepath -w "$STATE/avisynth-setup.log" | tr -d '\r')
"$WINE" "$TMP/avisynth-installer.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- "/LOG=$AVS_LOG_WIN" > "$STATE/avisynth-install.log" 2>&1
"$SERVER" -w
[[ -n $(find "$PREFIX/drive_c/windows" -iname avisynth.dll -print -quit) ]] || die 'AviSynth installer completed but avisynth.dll was not found.'
log 'AviSynth installer/file check passed; application-level functionality still requires testing.'

step 'Download and extract BD3D2MK3D'
fetch https://download.videohelp.com/r0lZ/BD3D2AVS/BD3D2MK3D.7z "$TMP/BD3D2MK3D.7z"
mkdir -p "$TMP/application"
"$SEVEN" x -y -bso0 -bsp0 "-o$TMP/application" "$TMP/BD3D2MK3D.7z"
APP_EXE=$(find "$TMP/application" -type f -iname BD3D2MK3D.exe -print -quit)
[[ -n "$APP_EXE" ]] || die 'BD3D2MK3D.exe is absent from the archive.'
APP_DIR="$PREFIX/drive_c/BD3D2MK3D"
mkdir -p "$APP_DIR"
cp -R "$(dirname "$APP_EXE")/." "$APP_DIR/"
ICON=applications-multimedia
if fetch https://softradar.com/static/products/bd3d2mk3d/bd3d2mk3d-logo.jpg "$TMP/logo.jpg"; then
    cp "$TMP/logo.jpg" "$APP_DIR/logo.jpg"
    ICON="$APP_DIR/logo.jpg"
else
    log 'Optional icon download failed; using desktop theme icon.'
fi

step 'Create application and desktop launchers'
WRAPPER="$PREFIX/launch-bd3d2mk3d.sh"
{
    printf '#!/usr/bin/env bash\nset -e\n'
    printf 'export WINEPREFIX=%q\n' "$PREFIX"
    printf 'export WINEARCH=win64\nexport WINEDEBUG=-all\n'
    printf 'cd %q\n' "$APP_DIR"
    printf 'exec %q %q "$@"\n' "$WINE" "$APP_DIR/BD3D2MK3D.exe"
} > "$WRAPPER"
chmod 0755 "$WRAPPER"

# Desktop Exec quoting is not shell quoting; escape reserved characters explicitly.
EXEC_WRAPPER=${WRAPPER//\\/\\\\}
EXEC_WRAPPER=${EXEC_WRAPPER//\"/\\\"}
EXEC_WRAPPER=${EXEC_WRAPPER//\$/\\\$}
EXEC_WRAPPER=${EXEC_WRAPPER//\`/\\\`}
EXEC_WRAPPER=${EXEC_WRAPPER//%/%%}
APPLICATIONS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPLICATIONS"
cat > "$APPLICATIONS/bd3d2mk3d.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=BD3D2MK3D
Comment=BD3D2MK3D through Wine
Exec=$EXEC_WRAPPER
Icon=$ICON
Terminal=false
Categories=AudioVideo;
EOF

DESKTOP="$HOME/Desktop"
if has xdg-user-dir; then
    DESKTOP=$(xdg-user-dir DESKTOP)
fi
if [[ -n "$DESKTOP" && "$DESKTOP" != "$HOME" ]]; then
    mkdir -p "$DESKTOP"
    cp "$APPLICATIONS/bd3d2mk3d.desktop" "$DESKTOP/BD3D2MK3D.desktop"
    chmod 0755 "$DESKTOP/BD3D2MK3D.desktop"
fi

step 'Installation complete'
log "Wine: $WINE_VERSION"
log "Mono: $MONO_VERSION"
log "Gecko: $GECKO_VERSION (x86 and x86_64)"
log "Java runtime execution and by-name PATH resolution verified."
log "AviSynth installer and file presence checked; encoding functionality not yet tested."
log "Launch: $WRAPPER"
log "Logs: $STATE"
log 'Reruns preserve the existing prefix; Java and Wine components are reused when detected.'
log 'Installation completed successfully.'