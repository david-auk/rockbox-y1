#!/usr/bin/env bash
set -Eeuo pipefail

# Build and install a custom Innioasis Y1 Rockbox 240p build (320x240).
#
# Run this from anywhere inside the rockbox-y1 Git repository.
#
# Default behavior:
#   - verify build prerequisites
#   - configure target 201 at 320x240
#   - build Rockbox, resources, and APK
#   - sign and verify the APK
#   - back up /sdcard/.rockbox
#   - install the APK as /system/app/org.rockbox.apk
#   - install the freshly built native libraries
#   - sync packaged .rockbox resources
#   - overlay tracked files from custom/y1/.rockbox, when present
#   - verify installed files with SHA-256
#   - reboot the Y1
#
# Options:
#   --setup       Install Homebrew prerequisites and Rockbox Android toolchain
#   --no-backup   Skip backing up /sdcard/.rockbox
#   --no-install  Build/sign only; do not push files or reboot
#   --no-clean    Do not run "make clean" after configure
#   -h, --help    Show usage

SETUP=false
BACKUP=true
INSTALL=true
CLEAN=true

usage() {
  sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --setup)
    SETUP=true
    ;;
  --no-backup)
    BACKUP=false
    ;;
  --no-install)
    INSTALL=false
    ;;
  --no-clean)
    CLEAN=false
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    echo >&2
    usage >&2
    exit 2
    ;;
  esac
  shift
done

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\nWARNING: %s\n' "$*" >&2
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_same_file() {
  local local_file="$1"
  local remote_file="$2"
  local label="$3"
  local verify_dir="$4"
  local verify_name
  local remote_copy
  local pulled_file
  local local_hash
  local remote_hash

  verify_name="verify-$(basename "$remote_file")-$RANDOM"
  remote_copy="/sdcard/.rockbox/custom-install/$verify_name"
  pulled_file="$verify_dir/$verify_name"

  # Copy through root first so verification also works for protected /system
  # and /data/data paths that the adb shell user cannot necessarily read.
  adb shell su -u root -c "cp '$remote_file' '$remote_copy' && chmod 644 '$remote_copy'"
  adb pull "$remote_copy" "$pulled_file" >/dev/null
  adb shell "rm -f '$remote_copy'" >/dev/null 2>&1 || true

  local_hash="$(sha256_file "$local_file")"
  remote_hash="$(sha256_file "$pulled_file")"

  printf '    %-28s local  %s\n' "$label" "$local_hash"
  printf '    %-28s remote %s\n' "$label" "$remote_hash"

  [[ "$local_hash" == "$remote_hash" ]] ||
    die "SHA-256 mismatch for $label ($remote_file)."
}

# Locate repository root regardless of the current working directory.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  die "Run this script from inside your rockbox-y1 Git repository."

[[ -f "$REPO_ROOT/apps/main.c" ]] ||
  die "This does not look like the Rockbox source tree: apps/main.c is missing."
[[ -f "$REPO_ROOT/android/installToolchain.sh" ]] ||
  die "android/installToolchain.sh is missing."

ANDROID_DIR="$REPO_ROOT/android"
BUILD_DIR="$ANDROID_DIR/build"
LIB_DIR="$BUILD_DIR/libs/armeabi"
OUTPUT_APK="$BUILD_DIR/rockbox_240p.apk"

# Optional project-owned Rockbox overrides. Everything inside this directory
# is copied over /sdcard/.rockbox after packaged resources are installed.
PROJECT_ROCKBOX_DIR="$REPO_ROOT/custom/.rockbox"

export ANDROID_SDK_PATH="${ANDROID_SDK_PATH:-$HOME/android-sdk}"
export ANDROID_NDK_PATH="${ANDROID_NDK_PATH:-$HOME/android-ndk-r10e}"
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_PATH}"

log "Repository: $REPO_ROOT"
log "Target: Innioasis Y1 240p (320x240)"

if [[ "$SETUP" == true ]]; then
  require_cmd brew

  log "Installing macOS prerequisites with Homebrew"
  brew list --cask android-platform-tools >/dev/null 2>&1 ||
    brew install --cask android-platform-tools
  brew list openjdk@17 >/dev/null 2>&1 ||
    brew install openjdk@17

  if ! command -v make >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
    die "Apple command-line build tools are missing. Run: xcode-select --install"
  fi

  if [[ ! -d "$ANDROID_SDK_PATH" || ! -d "$ANDROID_NDK_PATH" ]]; then
    log "Installing the Rockbox Android SDK/NDK toolchain"
    (
      cd "$ANDROID_DIR"
      yes | ./installToolchain.sh
    )
  else
    log "Android SDK/NDK already present; skipping installToolchain.sh"
  fi
fi

require_cmd git
require_cmd make
require_cmd shasum

# macOS 27 SDK compatibility:
# Some Command Line Tools installations expose MacOSX27.0.sdk while the
# installed linker/TAPI is too old to understand its arm64e.x1-macos target.
# Rockbox builds several helper programs with the Mac host compiler, so this
# breaks before Android cross-compilation even begins.
select_macos_host_sdk() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0

  local hostcc
  hostcc="$(command -v gcc || true)"
  [[ -n "$hostcc" ]] || die "macOS host compiler 'gcc' (Apple Clang) was not found."

  local probe_dir
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/rockbox-sdk-probe.XXXXXX")"
  printf 'int main(void) { return 0; }\n' >"$probe_dir/probe.c"

  sdk_works() {
    local sdk="$1"
    [[ -d "$sdk" ]] || return 1
    env SDKROOT="$sdk" "$hostcc" \
      "$probe_dir/probe.c" \
      -o "$probe_dir/probe" \
      >/dev/null 2>"$probe_dir/error.log"
  }

  if [[ -n "${SDKROOT:-}" ]] && sdk_works "$SDKROOT"; then
    log "Using requested macOS SDK: $SDKROOT"
    rm -rf "$probe_dir"
    return 0
  fi

  if env -u SDKROOT "$hostcc" \
    "$probe_dir/probe.c" \
    -o "$probe_dir/probe" \
    >/dev/null 2>"$probe_dir/error.log"; then
    rm -rf "$probe_dir"
    return 0
  fi

  log "Default macOS SDK cannot link Rockbox host tools"
  if grep -q 'arm64e\.x1-macos\|tapi error: malformed file\|unknown architecture' \
    "$probe_dir/error.log"; then
    printf '    Detected the macOS 27 SDK / linker compatibility issue.\n'
  else
    printf '    Host compiler error:\n'
    sed 's/^/      /' "$probe_dir/error.log" >&2
  fi

  local sdk
  local candidates=()

  while IFS= read -r sdk; do
    [[ "$(basename "$sdk")" == "MacOSX.sdk" ]] && continue
    candidates+=("$sdk")
  done < <(
    find /Library/Developer/CommandLineTools/SDKs \
      -maxdepth 1 -type d -name 'MacOSX*.sdk' 2>/dev/null | sort -r
  )

  while IFS= read -r sdk; do
    candidates+=("$sdk")
  done < <(
    find /Applications \
      -path '*/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk' \
      -type d 2>/dev/null | sort -r
  )

  for sdk in "${candidates[@]}"; do
    [[ "$(basename "$sdk")" == MacOSX27* ]] && continue

    if sdk_works "$sdk"; then
      export SDKROOT="$sdk"
      log "Using compatible macOS host SDK: $SDKROOT"
      rm -rf "$probe_dir"
      return 0
    fi
  done

  printf '\nCould not find an installed macOS SDK that can link native host tools.\n' >&2
  printf 'Installed CLT SDKs:\n' >&2
  find /Library/Developer/CommandLineTools/SDKs \
    -maxdepth 1 -type d -name 'MacOSX*.sdk' -print 2>/dev/null >&2 || true

  rm -rf "$probe_dir"
  exit 1
}

select_macos_host_sdk

# Prefer Homebrew's Java 17 when present.
if command -v brew >/dev/null 2>&1 && brew --prefix openjdk@17 >/dev/null 2>&1; then
  export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
fi

[[ -x "${JAVA_HOME:-}/bin/java" ]] ||
  die "Java 17 not found. Install it with: brew install openjdk@17"

JAVA_MAJOR="$("$JAVA_HOME/bin/java" -version 2>&1 |
  awk -F[\".] '/version/ { if ($2 == "1") print $3; else print $2; exit }')"

[[ "$JAVA_MAJOR" == "17" ]] ||
  die "Rockbox Y1 expects Java 17; current JAVA_HOME reports Java $JAVA_MAJOR."

[[ -d "$ANDROID_SDK_PATH" ]] ||
  die "Android SDK not found at $ANDROID_SDK_PATH. Re-run with --setup."
[[ -d "$ANDROID_NDK_PATH" ]] ||
  die "Android NDK r10e not found at $ANDROID_NDK_PATH. Re-run with --setup."

# Find sdkmanager.
SDKMANAGER=""
for candidate in \
  "$ANDROID_SDK_PATH/tools/bin/sdkmanager" \
  "$ANDROID_SDK_PATH/cmdline-tools/latest/bin/sdkmanager"; do
  if [[ -x "$candidate" ]]; then
    SDKMANAGER="$candidate"
    break
  fi
done

if [[ -z "$SDKMANAGER" ]] && command -v sdkmanager >/dev/null 2>&1; then
  SDKMANAGER="$(command -v sdkmanager)"
fi

[[ -n "$SDKMANAGER" ]] ||
  die "sdkmanager not found under $ANDROID_SDK_PATH. Re-run with --setup."

log "Ensuring Android build-tools 28.0.3 and platform android-17 are installed"
yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
"$SDKMANAGER" "build-tools;28.0.3" "platforms;android-17"

AAPT_28="$ANDROID_SDK_PATH/build-tools/28.0.3/aapt"
AAPT_19_DIR="$ANDROID_SDK_PATH/build-tools/19.1.0"
AAPT_19="$AAPT_19_DIR/aapt"

[[ -x "$AAPT_28" ]] ||
  die "Expected aapt was not found at $AAPT_28."

if [[ ! -d "$AAPT_19_DIR" ]]; then
  die "Android build-tools 19.1.0 are missing. Run this script once with --setup."
fi

if [[ -e "$AAPT_19" && ! -L "$AAPT_19" && ! -e "$AAPT_19.bak" ]]; then
  log "Backing up old build-tools 19.1.0/aapt"
  mv "$AAPT_19" "$AAPT_19.bak"
fi

if [[ -L "$AAPT_19" || ! -e "$AAPT_19" ]]; then
  rm -f "$AAPT_19"
  ln -s "$AAPT_28" "$AAPT_19"
fi

log "Checking source tree"
git -C "$REPO_ROOT" diff --check

mkdir -p "$BUILD_DIR"

log "Configuring Rockbox for Y1 target 201 at 320x240"
(
  cd "$BUILD_DIR"
  ../../tools/configure \
    --target=201 \
    --lcdwidth=320 \
    --lcdheight=240 \
    --type=n
)

if [[ "$CLEAN" == true ]]; then
  log "Cleaning previous build outputs"
  make -C "$BUILD_DIR" clean
fi

log "Building native Rockbox code"
rm -f "$REPO_ROOT/tools/rdf2binary"
make -C "$BUILD_DIR"

log "Building Android Java classes"
make -C "$BUILD_DIR" classes

log "Building .rockbox resource zip"
make -C "$BUILD_DIR" zip

log "Building unsigned APK"
make -C "$BUILD_DIR" unsigned-apk

UNSIGNED_APK="$BUILD_DIR/rockbox_unsigned.apk"
[[ -f "$UNSIGNED_APK" ]] ||
  die "Build finished without producing $UNSIGNED_APK."
[[ -f "$LIB_DIR/librockbox.so" ]] ||
  die "Build finished without producing $LIB_DIR/librockbox.so."
[[ -f "$LIB_DIR/libmisc.so" ]] ||
  die "Build finished without producing $LIB_DIR/libmisc.so."

APKSIGNER=""
for candidate in \
  "$ANDROID_SDK_PATH/build-tools/28.0.3/apksigner" \
  "$(command -v apksigner 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    APKSIGNER="$candidate"
    break
  fi
done

[[ -n "$APKSIGNER" ]] || die "apksigner not found."

KEY="$ANDROID_DIR/platform.pk8"
CERT="$ANDROID_DIR/platform.x509.pem"

[[ -f "$KEY" ]] || die "Signing key missing: $KEY"
[[ -f "$CERT" ]] || die "Signing certificate missing: $CERT"

log "Signing APK"
cp "$UNSIGNED_APK" "$OUTPUT_APK"
"$APKSIGNER" sign \
  --key "$KEY" \
  --cert "$CERT" \
  "$OUTPUT_APK"

log "Verifying signed APK"
"$APKSIGNER" verify --verbose "$OUTPUT_APK"

printf '\nBuilt successfully:\n  %s\n' "$OUTPUT_APK"

if [[ "$INSTALL" != true ]]; then
  printf '\nBuild-only mode selected; not installing on the Y1.\n'
  exit 0
fi

require_cmd adb

log "Checking ADB connection"
DEVICE_COUNT="$(
  adb devices |
    awk 'NR > 1 && $2 == "device" { count++ } END { print count+0 }'
)"

if [[ "$DEVICE_COUNT" -eq 0 ]]; then
  die "No authorized Y1 found via ADB. Connect it, enable debugging, then run: adb devices"
elif [[ "$DEVICE_COUNT" -gt 1 ]]; then
  die "More than one ADB device is connected. Disconnect the others before running this script."
fi

adb wait-for-device

log "Checking root access on the Y1"
if ! adb shell su -u root -c id 2>/dev/null | tr -d '\r' | grep -q 'uid=0'; then
  die "Root access through 'su -u root -c' is required to replace the Y1 system Rockbox files."
fi

if [[ "$BACKUP" == true ]]; then
  if adb shell '[ -d /sdcard/.rockbox ]' >/dev/null 2>&1; then
    BACKUP_DIR="$HOME/y1-backups/$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$BACKUP_DIR"

    log "Backing up /sdcard/.rockbox to $BACKUP_DIR/.rockbox"
    adb pull /sdcard/.rockbox "$BACKUP_DIR/.rockbox" >/dev/null
  else
    warn "/sdcard/.rockbox does not exist; skipping backup."
  fi
fi

log "Stopping Rockbox before replacing files"
adb shell am force-stop org.rockbox >/dev/null 2>&1 || true

REMOTE_STAGE="/sdcard/.rockbox/custom-install"

log "Staging APK and native libraries on the Y1"
adb shell "rm -rf '$REMOTE_STAGE' && mkdir -p '$REMOTE_STAGE/libs/armeabi'"
adb push "$OUTPUT_APK" "$REMOTE_STAGE/rockbox.apk" >/dev/null
adb push "$LIB_DIR/." "$REMOTE_STAGE/libs/armeabi/" >/dev/null

if [[ -d "$PROJECT_ROCKBOX_DIR" ]] &&
  find "$PROJECT_ROCKBOX_DIR" -mindepth 1 -print -quit | grep -q .; then
  log "Staging project .rockbox overrides from $PROJECT_ROCKBOX_DIR"
  adb shell "mkdir -p '$REMOTE_STAGE/rockbox-overlay'"
  adb push "$PROJECT_ROCKBOX_DIR/." "$REMOTE_STAGE/rockbox-overlay/" >/dev/null
else
  log "No project .rockbox overrides found; skipping overlay"
fi

INSTALL_HELPER="$(mktemp "${TMPDIR:-/tmp}/rockbox-y1-install.XXXXXX")"
cat >"$INSTALL_HELPER" <<'REMOTE_INSTALL'
#!/system/bin/sh
set -e

STAGE="/sdcard/.rockbox/custom-install"

# Match the Y1 updater's installation layout.
mount -o rw,remount /system

cp "$STAGE/rockbox.apk" /system/app/org.rockbox.apk
chmod 644 /system/app/org.rockbox.apk
chown root:root /system/app/org.rockbox.apk

cp "$STAGE/libs/armeabi/librockbox.so" /system/lib/librockbox.so
chmod 644 /system/lib/librockbox.so
chown root:root /system/lib/librockbox.so

rm -rf /data/data/org.rockbox/lib
mkdir -p /data/data/org.rockbox/lib
cp "$STAGE"/libs/armeabi/* /data/data/org.rockbox/lib/
chmod 777 /data/data/org.rockbox/lib/*

# If Rockbox was previously installed with `adb install -r`, Android may keep
# that /data/app copy in preference to the system APK. Remove only that update
# copy so the freshly pushed /system/app APK becomes authoritative on reboot.
rm -f /data/app/org.rockbox*.apk
rm -rf /data/app/org.rockbox /data/app/org.rockbox-* /data/app-lib/org.rockbox*

# libmisc.so is a zip containing the packaged .rockbox resources. Sync those
# as well so source changes to languages, themes, plugins, etc. are installed.
rm -rf "$STAGE/resources"
mkdir -p "$STAGE/resources"
cd "$STAGE/resources"
unzip -o "$STAGE/libs/armeabi/libmisc.so" >/dev/null
if [ -d .rockbox ]; then
    mkdir -p /sdcard/.rockbox
    cp -rf .rockbox/* /sdcard/.rockbox/
fi

# Apply project-owned overrides last so version-controlled configuration wins
# over files bundled in libmisc.so.
if [ -d "$STAGE/rockbox-overlay" ]; then
    mkdir -p /sdcard/.rockbox
    cp -rf "$STAGE/rockbox-overlay/." /sdcard/.rockbox/
fi

sync
REMOTE_INSTALL

adb push "$INSTALL_HELPER" "$REMOTE_STAGE/install.sh" >/dev/null
rm -f "$INSTALL_HELPER"

log "Installing custom Rockbox as the Y1 system app"
if ! adb shell su -u root -c "sh '$REMOTE_STAGE/install.sh'"; then
  die "Root installation failed. The staged files remain at $REMOTE_STAGE for inspection."
fi

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rockbox-y1-verify.XXXXXX")"

log "Verifying installed files with SHA-256"
verify_same_file \
  "$OUTPUT_APK" \
  "/system/app/org.rockbox.apk" \
  "system APK" \
  "$VERIFY_DIR"

verify_same_file \
  "$LIB_DIR/librockbox.so" \
  "/system/lib/librockbox.so" \
  "system librockbox.so" \
  "$VERIFY_DIR"

verify_same_file \
  "$LIB_DIR/librockbox.so" \
  "/data/data/org.rockbox/lib/librockbox.so" \
  "app librockbox.so" \
  "$VERIFY_DIR"

verify_same_file \
  "$LIB_DIR/libmisc.so" \
  "/data/data/org.rockbox/lib/libmisc.so" \
  "app libmisc.so" \
  "$VERIFY_DIR"

if [[ -d "$PROJECT_ROCKBOX_DIR" ]]; then
  while IFS= read -r -d '' local_override; do
    relative_path="${local_override#"$PROJECT_ROCKBOX_DIR"/}"

    verify_same_file \
      "$local_override" \
      "/sdcard/.rockbox/$relative_path" \
      "overlay $relative_path" \
      "$VERIFY_DIR"
  done < <(find "$PROJECT_ROCKBOX_DIR" -type f -print0)
fi

rm -rf "$VERIFY_DIR"

log "Cleaning staged install files"
adb shell "rm -rf '$REMOTE_STAGE'"

log "Rebooting Y1"
adb reboot

cat <<EOF

Done.

Built and installed:
  $OUTPUT_APK

The APK, native Rockbox core, companion libraries, packaged .rockbox
resources, and any project .rockbox overrides were pushed before reboot.

EOF
