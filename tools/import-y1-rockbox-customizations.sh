#!/usr/bin/env bash
set -Eeuo pipefail

# Import the Y1's actual Rockbox themes, supporting image/font assets and
# config.cfg into the same version-controlled overlay used by the installer.
# This is a one-way import: it never changes the connected device.
# Intentionally does NOT import tagnavi_user.config (the repo is authoritative).

usage() {
  cat <<'USAGE'
Usage:
  tools/import-y1-rockbox-customizations.sh --from-adb [--no-stage]
  tools/import-y1-rockbox-customizations.sh --from-dir PATH [--no-stage]

PATH must be the device's .rockbox directory (for example:
  "/Volumes/NO NAME/.rockbox").

Imports config.cfg and these resource directories:
  themes/ wps/ icons/ fonts/ backdrops/

Excludes macOS AppleDouble files (._*), .DS_Store and generated *.gc
font glyph caches. Never imports the tag database or runtime state.
Any tracked tagnavi_user.config is left untouched.

By default imports are staged in Git but NOT committed. --no-stage only
updates working-tree files.
USAGE
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

MODE=''
SOURCE=''
STAGE=true
while (( $# )); do
  case "$1" in
    --from-adb)
      [[ -z "$MODE" ]] || fail 'Choose exactly one input source.'
      MODE=adb
      ;;
    --from-dir)
      [[ -z "$MODE" ]] || fail 'Choose exactly one input source.'
      (( $# >= 2 )) || fail 'Missing directory after --from-dir.'
      MODE=dir
      SOURCE="$2"
      shift
      ;;
    --no-stage) STAGE=false ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
  shift
done
[[ -n "$MODE" ]] || { usage >&2; exit 2; }

command -v git >/dev/null || fail 'git is required.'
command -v rsync >/dev/null || fail 'rsync is required.'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
  fail 'This script must be inside your Rockbox Git repository.'
[[ -f "$REPO_ROOT/apps/main.c" ]] || fail 'Not a Rockbox source repository.'
DEST_REL='custom/y1/.rockbox'
DEST="$REPO_ROOT/$DEST_REL"

TMP_ROOT=''
cleanup() {
  if [[ -n "$TMP_ROOT" ]]; then rm -rf "$TMP_ROOT"; fi
}
trap cleanup EXIT

if [[ "$MODE" == adb ]]; then
  command -v adb >/dev/null || fail 'adb is required for --from-adb.'
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rockbox-import.XXXXXX")"
  SOURCE="$TMP_ROOT/.rockbox"
  mkdir -p "$SOURCE"

  info 'Pulling theme assets and settings from /sdcard/.rockbox'
  for section in themes wps icons fonts backdrops; do
    if adb shell "[ -d '/sdcard/.rockbox/$section' ]" >/dev/null 2>&1; then
      adb pull "/sdcard/.rockbox/$section" "$SOURCE/" >/dev/null ||
        fail "Failed to pull $section from Y1."
    else
      printf 'Skipping missing device directory: %s\n' "$section"
    fi
  done
  if adb shell '[ -f /sdcard/.rockbox/config.cfg ]' >/dev/null 2>&1; then
    adb pull /sdcard/.rockbox/config.cfg "$SOURCE/config.cfg" >/dev/null ||
      fail 'Could not pull config.cfg.'
  else
    fail '/sdcard/.rockbox/config.cfg was not found on the device.'
  fi
else
  [[ -d "$SOURCE" ]] || fail "Directory not found: $SOURCE"
  SOURCE="$(cd "$SOURCE" && pwd)"
fi

[[ "$SOURCE" != "$DEST" ]] || fail 'Source and destination must differ.'
[[ -f "$SOURCE/config.cfg" ]] || fail "Missing $SOURCE/config.cfg"

mkdir -p "$DEST"
info 'Importing active config.cfg'
cp "$SOURCE/config.cfg" "$DEST/config.cfg"

for section in themes wps icons fonts backdrops; do
  if [[ -d "$SOURCE/$section" ]]; then
    info "Importing $section/"
    mkdir -p "$DEST/$section"
    rsync -a \
      --exclude='._*' \
      --exclude='.DS_Store' \
      --exclude='*.gc' \
      "$SOURCE/$section/" "$DEST/$section/"
  fi
done

if [[ "$STAGE" == true ]]; then
  info 'Staging imported files (without committing)'
  # Stage only paths imported by this script: not tagnavi_user.config.
  paths=("$DEST_REL/config.cfg")
  for section in themes wps icons fonts backdrops; do
    [[ -d "$DEST/$section" ]] && paths+=("$DEST_REL/$section")
  done
  ( cd "$REPO_ROOT" && git add -A -- "${paths[@]}" )
else
  info 'Import completed without staging'
fi

info 'Imported customizations'
printf 'Destination: %s\n' "$DEST"
printf 'Source configuration: %s\n' "$SOURCE/config.cfg"
printf 'Unrelated database/navigation and playback files were not touched.\n'
printf 'Review with: git status --short -- %s\n' "$DEST_REL"
