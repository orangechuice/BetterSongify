#!/bin/bash
#
#
# BetterSongify local installer for macOS.
# Builds this repository and installs dist/BetterSongify.js into Spotify.app.
#
# Usage:
#   ./install-macos.sh            interactive menu
#   ./install-macos.sh install    build and install or update
#   ./install-macos.sh reinstall  remove completely, then build and install fresh
#   ./install-macos.sh remove     remove completely
#
set -euo pipefail

CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; GRAY=$'\033[90m'; RESET=$'\033[0m'

info()    { echo " ${CYAN}[i]${RESET} $1"; }
success() { echo " ${GREEN}[✓]${RESET} $1"; }
warn()    { echo " ${YELLOW}[!]${RESET} $1"; }
error()   { echo " ${RED}[×]${RESET} $1"; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUNDLE_FILE="$SCRIPT_DIR/dist/BetterSongify.js"
SCRIPT_TAG='<script src="BetterSongify.js"></script>'
# Legacy injections (BetterSpotify, SpotifyLyrics); scrubbed on install/remove
LEGACY_SCRIPT_TAG_1='<script src="BetterSpotify.js"></script>'
LEGACY_SCRIPT_TAG_2='<script src="SpotifyLyrics.js"></script>'

logo() {
    echo "${CYAN} ____       _   _             ____              _   _  __       ${RESET}"
    echo "${CYAN}| __ )  ___| |_| |_ ___ _ __ / ___| _ __   ___ | |_(_)/ _|_   _ ${RESET}"
    echo "${CYAN}|  _ \\ / _ \\ __| __/ _ \\ '__|\\___ \\| '_ \\ / _ \\| __| | |_| | | |${RESET}"
    echo "${CYAN}| |_) |  __/ |_| ||  __/ |    ___) | |_) | (_) | |_| |  _| |_| |${RESET}"
    echo "${CYAN}|____/ \\___|\\__|\\__\\___|_|   |____/| .__/ \\___/ \\__|_|_|  \\__, |${RESET}"
    echo "${CYAN}                                   |_|                    |___/ ${RESET}"
    echo ""
    echo "${GRAY} BetterSongify Local Installer for macOS ${RESET}"
    echo "${GRAY}---------------------------------------------------${RESET}"
}

find_spotify() {
    local candidates=("/Applications/Spotify.app" "$HOME/Applications/Spotify.app")
    for app in "${candidates[@]}"; do
        if [ -e "$app/Contents/Resources/Apps/xpui.spa" ]; then
            echo "$app"
            return 0
        fi
    done

    local found
    found=$(mdfind "kMDItemCFBundleIdentifier == 'com.spotify.client'" 2>/dev/null | head -n 1 || true)
    if [ -n "$found" ] && [ -e "$found/Contents/Resources/Apps/xpui.spa" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

build_bundle() {
    info "Building local BetterSongify bundle..."
    if ! command -v npm >/dev/null 2>&1; then
        error "npm was not found. Install Node.js/npm first."
        exit 1
    fi

    (cd "$SCRIPT_DIR" && npm run build)

    if [ ! -f "$BUNDLE_FILE" ]; then
        error "Build did not produce $BUNDLE_FILE"
        exit 1
    fi

    success "Built $BUNDLE_FILE"
}

get_better_songify_js() {
    local dest="$1"
    build_bundle
    info "Using local built bundle: dist/BetterSongify.js"
    cp "$BUNDLE_FILE" "$dest"
}

quit_spotify() {
    info "Stopping Spotify to unlock core files..."
    osascript -e 'quit app "Spotify"' >/dev/null 2>&1 || true
    sleep 2
    pkill -x Spotify 2>/dev/null || true
}

repack_spa() {
    local src_dir="$1" out_zip="$2"
    rm -f "$out_zip"
    (cd "$src_dir" && zip -q -r "$out_zip" . -x ".DS_Store" -x "*/.DS_Store")
}

choose_operation() {
    local choice="${1:-}"
    case "$choice" in
        install|i|I) echo "I" ;;
        remove|uninstall|r|R) echo "R" ;;
        reinstall|ri|RI|x|X) echo "RI" ;;
        "")
            echo " Please select an operation:" >&2
            echo "   ${GREEN}[I] Install or Update BetterSongify${RESET}" >&2
            echo "   ${YELLOW}[X] Reinstall (remove, then install fresh)${RESET}" >&2
            echo "   ${RED}[R] Remove completely${RESET}" >&2
            echo "" >&2
            local answer attempts=0
            while true; do
                if [ "$attempts" -ge 5 ]; then
                    warn "No valid input received. Defaulting to Install." >&2
                    echo "I"
                    return 0
                fi
                read -r -p " > Selection (I/X/R): " answer || { echo "I"; return 0; }
                answer=$(echo "$answer" | tr '[:lower:]' '[:upper:]' | xargs)
                if [ "$answer" = "I" ] || [ "$answer" = "R" ]; then
                    echo "$answer"
                    return 0
                fi
                if [ "$answer" = "X" ]; then
                    echo "RI"
                    return 0
                fi
                attempts=$((attempts + 1))
            done
            ;;
        *)
            error "Unknown option: $choice (use 'install', 'reinstall', or 'remove')" >&2
            exit 1
            ;;
    esac
}

logo

SPOTIFY_APP="${SPOTIFY_APP:-}"
[ -n "$SPOTIFY_APP" ] || SPOTIFY_APP=$(find_spotify) || {
    echo ""
    error "Spotify core files not found!"
    echo "     ${YELLOW}Install Spotify from https://www.spotify.com/download${RESET}"
    exit 1
}

SPOTIFY_APPS_DIR="$SPOTIFY_APP/Contents/Resources/Apps"
SPA_FILE="$SPOTIFY_APPS_DIR/xpui.spa"
BACKUP_FILE="$SPOTIFY_APPS_DIR/xpui.spa.bak"

if [ ! -w "$SPOTIFY_APPS_DIR" ]; then
    error "No write permission for $SPOTIFY_APPS_DIR"
    echo "     ${YELLOW}Re-run this installer with sudo:${RESET}"
    echo "     ${YELLOW}sudo \"$0\" ${1:-}${RESET}"
    exit 1
fi

CHOICE=$(choose_operation "${1:-}")
echo ""

TEMP_FOLDER=$(mktemp -d /tmp/BetterSongify_Extraction.XXXXXX)
OUTPUT_ZIP="$TEMP_FOLDER.zip"
cleanup() { rm -rf "$TEMP_FOLDER" "$OUTPUT_ZIP"; }
trap cleanup EXIT

rollback() {
    warn "Rolling back changes and restoring original files..."
    if [ -f "$1" ]; then
        cp -f "$1" "$SPA_FILE"
        success "Rollback successful."
    fi
}

if [ "$CHOICE" = "R" ] || [ "$CHOICE" = "RI" ]; then
    EMERGENCY_BACKUP="$SPA_FILE.uninst.bak"
    trap 'error "UNINSTALLATION FAILED"; rollback "$EMERGENCY_BACKUP"; rm -f "$EMERGENCY_BACKUP"; cleanup' ERR

    quit_spotify

    info "Preparing removal..."
    cp -f "$SPA_FILE" "$EMERGENCY_BACKUP"

    info "Unpacking Spotify UI..."
    unzip -qo "$SPA_FILE" -d "$TEMP_FOLDER"

    if [ ! -f "$TEMP_FOLDER/index.html" ]; then
        error "index.html was not found inside the package."
        exit 1
    fi

    info "Scrubbing injected local BetterSongify script tag..."
    if grep -Fqi "$SCRIPT_TAG" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_1" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_2" "$TEMP_FOLDER/index.html"; then
        perl -0777 -pi -e 's{<script src="(?:BetterSongify|BetterSpotify|SpotifyLyrics)\.js"></script>}{}gi' "$TEMP_FOLDER/index.html"
        success "Cleared script injection."
    else
        warn "No local BetterSongify script tag found — may already be removed."
    fi

    if [ -f "$TEMP_FOLDER/BetterSongify.js" ] || [ -f "$TEMP_FOLDER/BetterSpotify.js" ] || [ -f "$TEMP_FOLDER/SpotifyLyrics.js" ]; then
        rm -f "$TEMP_FOLDER/BetterSongify.js" "$TEMP_FOLDER/BetterSpotify.js" "$TEMP_FOLDER/SpotifyLyrics.js"
        success "Deleted local BetterSongify.js asset."
    else
        warn "BetterSongify.js not found in package — may already be removed."
    fi

    info "Repacking clean application..."
    repack_spa "$TEMP_FOLDER" "$OUTPUT_ZIP"
    mv -f "$OUTPUT_ZIP" "$SPA_FILE"
    rm -f "$EMERGENCY_BACKUP" "$BACKUP_FILE"

    if [ "$CHOICE" = "RI" ]; then
        trap - ERR
        success "BetterSongify removed. Reinstalling fresh..."
        rm -rf "$TEMP_FOLDER"
        mkdir -p "$TEMP_FOLDER"
        echo ""
    else
        trap cleanup EXIT
        success "BetterSongify was fully removed. Restarting Spotify..."
        open -a Spotify
    fi
fi

if [ "$CHOICE" = "I" ] || [ "$CHOICE" = "RI" ]; then
    trap 'error "INSTALLATION FAILED"; rollback "$BACKUP_FILE"; cleanup' ERR

    quit_spotify

    info "Unpacking Spotify user interface..."
    unzip -qo "$SPA_FILE" -d "$TEMP_FOLDER"

    if [ ! -f "$TEMP_FOLDER/index.html" ]; then
        error "Failed to locate Spotify app layout."
        exit 1
    fi

    if { grep -Fqi "$SCRIPT_TAG" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_1" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_2" "$TEMP_FOLDER/index.html"; } && [ -f "$BACKUP_FILE" ]; then
        info "Existing local BetterSongify installation detected — keeping original backup."
    else
        info "Creating application backup..."
        cp -f "$SPA_FILE" "$BACKUP_FILE"
    fi

    if grep -Fqi "$LEGACY_SCRIPT_TAG_1" "$TEMP_FOLDER/index.html" || grep -Fqi "$LEGACY_SCRIPT_TAG_2" "$TEMP_FOLDER/index.html" || [ -f "$TEMP_FOLDER/BetterSpotify.js" ] || [ -f "$TEMP_FOLDER/SpotifyLyrics.js" ]; then
        info "Migrating pre-rename installation — scrubbing old injection..."
        perl -0777 -pi -e 's{<script src="(?:BetterSpotify|SpotifyLyrics)\.js"></script>}{}gi' "$TEMP_FOLDER/index.html"
        rm -f "$TEMP_FOLDER/BetterSpotify.js" "$TEMP_FOLDER/SpotifyLyrics.js"
    fi

    info "Deploying built local BetterSongify bundle..."
    get_better_songify_js "$TEMP_FOLDER/BetterSongify.js"

    info "Linking local BetterSongify.js into Spotify startup..."
    if grep -Fqi "$SCRIPT_TAG" "$TEMP_FOLDER/index.html"; then
        success "BetterSongify script tag is already active."
    else
        perl -0777 -pi -e 's{</body>}{<script src="BetterSongify.js"></script></body>}i' "$TEMP_FOLDER/index.html"
        success "Successfully linked local BetterSongify.js."
    fi

    info "Recompiling Spotify application package..."
    repack_spa "$TEMP_FOLDER" "$OUTPUT_ZIP"
    mv -f "$OUTPUT_ZIP" "$SPA_FILE"

    trap cleanup EXIT
    success "Installation complete. Booting Spotify..."
    open -a Spotify

    echo ""
    echo "${GRAY}Note: Spotify updates can overwrite BetterSongify. Re-run this installer after Spotify updates.${RESET}"
fi

echo ""
echo "${GRAY}You can safely close this terminal.${RESET}"
