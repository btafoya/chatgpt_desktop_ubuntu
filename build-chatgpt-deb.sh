#!/usr/bin/env bash
set -euo pipefail

# Repackage a Windows ChatGPT installer/application into a local Debian package
# that launches under Wine. This script is designed for local machine use.

readonly PACKAGE_NAME="chatgpt-desktop-windows"
readonly APP_NAME="ChatGPT"
readonly MAINTAINER="${MAINTAINER:-JohnO Local Build}"
readonly DESCRIPTION="ChatGPT Windows desktop app wrapped for Debian/Ubuntu via Wine"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_PAYLOAD="${PROJECT_ROOT}/ChatGPT.exe"
OUT_DIR="${PROJECT_ROOT}/dist"
BUILD_DIR="${PROJECT_ROOT}/build"
ARCH="amd64"
VERSION=""
CLEAN="yes"

section() {
  printf "\n\033[1;36m== %s ==\033[0m\n" "$1"
}

die() {
  printf "\033[1;31merror:\033[0m %s\n" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --exe PATH         Path to the Windows ChatGPT installer, MSIX/MSIXBundle, or extracted exe
  --version VERSION  Override package version
  --out-dir DIR      Output directory for the built .deb
  --clean yes|no     Remove build directory after success (default: yes)
  -h, --help         Show this help

Default input path:
  ${PROJECT_ROOT}/ChatGPT.exe
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --exe)
        INPUT_PAYLOAD="${2:-}"
        shift 2
        ;;
      --version)
        VERSION="${2:-}"
        shift 2
        ;;
      --out-dir)
        OUT_DIR="${2:-}"
        shift 2
        ;;
      --clean)
        CLEAN="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

check_deps() {
  section "Dependency Check"
  local missing=()
  for cmd in file dpkg-deb python3 wrestool icotool; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ! command -v wine64 >/dev/null 2>&1 && ! command -v wine >/dev/null 2>&1; then
    missing+=("wine64")
  fi

  if ((${#missing[@]} > 0)); then
    printf "missing tools: %s\n" "${missing[*]}"
    printf "install with:\n"
    printf "  sudo apt-get install -y wine64 icoutils dpkg-dev python3\n"
    die "required build tools are missing"
  fi
}

validate_input() {
  section "Input Validation"
  [[ -f "$INPUT_PAYLOAD" ]] || die "input file not found: $INPUT_PAYLOAD"

  local detected
  detected="$(file -b "$INPUT_PAYLOAD")"
  printf "input: %s\n" "$INPUT_PAYLOAD"
  printf "type:  %s\n" "$detected"

  if grep -qiE 'HTML document|XML document|ASCII text|UTF-8 text' <<<"$detected"; then
    die "the file is not a Windows binary; it looks like a saved web page or redirect instead"
  fi

  if ! grep -qiE 'PE32|MS Windows|Mono/.Net|executable|Zip archive data' <<<"$detected"; then
    printf "warning: file type is unusual for a Windows payload\n" >&2
  fi
}

prepare_dirs() {
  section "Workspace Setup"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
}

detect_version() {
  section "Version Detection"
  if [[ -n "$VERSION" ]]; then
    printf "using overridden version: %s\n" "$VERSION"
    return
  fi

  case "${INPUT_PAYLOAD,,}" in
    *.msixbundle)
      VERSION="$(INPUT_PAYLOAD="$INPUT_PAYLOAD" python3 - <<'PY'
import re, zipfile
p = __import__('os').environ['INPUT_PAYLOAD']
with zipfile.ZipFile(p) as z:
    data = z.read('AppxMetadata/AppxBundleManifest.xml').decode('utf-8', 'replace')
m = re.search(r'<Identity\b[^>]*\bVersion="([0-9.]+)"', data)
print(m.group(1) if m else "")
PY
)"
      ;;
    *.msix|*.appx|*.appxbundle)
      VERSION="$(INPUT_PAYLOAD="$INPUT_PAYLOAD" python3 - <<'PY'
import re, zipfile
p = __import__('os').environ['INPUT_PAYLOAD']
with zipfile.ZipFile(p) as z:
    data = z.read('AppxManifest.xml').decode('utf-8', 'replace')
m = re.search(r'<Identity\b[^>]*\bVersion="([0-9.]+)"', data)
print(m.group(1) if m else "")
PY
)"
      ;;
    *)
      VERSION="$(strings -n 4 "$INPUT_PAYLOAD" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
      ;;
  esac
  [[ -n "$VERSION" ]] || VERSION="1.0.0"
  printf "detected package version: %s\n" "$VERSION"
}

extract_payload() {
  section "Payload Extraction"
  mkdir -p "$BUILD_DIR/extract"

  case "${INPUT_PAYLOAD,,}" in
    *.msixbundle|*.appxbundle)
      INPUT_PAYLOAD="$INPUT_PAYLOAD" BUILD_DIR="$BUILD_DIR/extract" python3 - <<'PY'
import zipfile, os
src = os.environ['INPUT_PAYLOAD']
out = os.environ['BUILD_DIR']
with zipfile.ZipFile(src) as z:
    target = None
    for name in z.namelist():
        lower = name.lower()
        if lower.endswith('_x64.msix') or lower.endswith('_x64.appx') or lower == 'chatgpt_x64.msix':
            target = name
            break
    if not target:
        raise SystemExit('no x64 msix/appx found inside bundle')
    msix_path = os.path.join(out, 'inner.msix')
    with open(msix_path, 'wb') as f:
        f.write(z.read(target))
    with zipfile.ZipFile(msix_path) as inner:
        inner.extractall(os.path.join(out, 'payload'))
PY
      ;;
    *.msix|*.appx)
      INPUT_PAYLOAD="$INPUT_PAYLOAD" BUILD_DIR="$BUILD_DIR/extract" python3 - <<'PY'
import zipfile, os
src = os.environ['INPUT_PAYLOAD']
out = os.path.join(os.environ['BUILD_DIR'], 'payload')
with zipfile.ZipFile(src) as z:
    z.extractall(out)
PY
      ;;
    *)
      printf "non-MSIX payload; copying raw input\n"
      mkdir -p "$BUILD_DIR/extract/raw"
      cp -f "$INPUT_PAYLOAD" "$BUILD_DIR/extract/raw/"
      ;;
  esac
}

locate_exe() {
  section "Executable Discovery"
  local candidate=""

  candidate="$(find "$BUILD_DIR/extract" -type f \( -path '*/app/ChatGPT.exe' -o -iname 'ChatGPT.exe' -o -iname '*chatgpt*.exe' -o -iname '*.exe' \) | head -n 1 || true)"
  [[ -n "$candidate" ]] || die "could not find a Windows executable inside extracted payload"

  printf "selected executable: %s\n" "$candidate"
  cp -f "$candidate" "$BUILD_DIR/ChatGPT.exe"
}

extract_icon() {
  section "Icon Extraction"
  mkdir -p "$BUILD_DIR/icon"
  if wrestool -x -t 14 "$BUILD_DIR/ChatGPT.exe" -o "$BUILD_DIR/icon/chatgpt.ico" >/dev/null 2>&1; then
    if icotool -x "$BUILD_DIR/icon/chatgpt.ico" -o "$BUILD_DIR/icon" >/dev/null 2>&1; then
      local png
      png="$(find "$BUILD_DIR/icon" -type f -name '*.png' | sort | tail -n 1 || true)"
      if [[ -n "$png" ]]; then
        cp -f "$png" "$BUILD_DIR/chatgpt.png"
        printf "icon extracted: %s\n" "$png"
        return
      fi
    fi
  fi

  printf "warning: icon extraction failed; package will fall back to a generic icon\n" >&2
}

extract_msix_assets() {
  section "Asset Extraction"
  local asset=""
  asset="$(find "$BUILD_DIR/extract" -type f \( -iname 'StoreLogo.png' -o -iname 'Square44x44Logo.png' -o -iname 'AppList.png' -o -iname 'MedTile.png' \) | head -n 1 || true)"
  if [[ -n "$asset" && ! -f "$BUILD_DIR/chatgpt.png" ]]; then
    cp -f "$asset" "$BUILD_DIR/chatgpt.png"
    printf "copied package asset icon: %s\n" "$asset"
  fi
}

stage_deb_tree() {
  section "Debian Staging"
  local root="${BUILD_DIR}/pkgroot"
  local opt_dir="${root}/opt/${PACKAGE_NAME}"
  local bin_dir="${root}/usr/bin"
  local app_dir="${root}/usr/share/applications"
  local icon_dir="${root}/usr/share/icons/hicolor/256x256/apps"
  local debian_dir="${root}/DEBIAN"

  mkdir -p "$opt_dir" "$bin_dir" "$app_dir" "$icon_dir" "$debian_dir"

  cp -f "$BUILD_DIR/ChatGPT.exe" "${opt_dir}/ChatGPT.exe"

  cat > "${bin_dir}/chatgpt-desktop-windows" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WINEPREFIX="${HOME}/.local/share/chatgpt-desktop-windows/prefix"
APPDIR="/opt/chatgpt-desktop-windows"
EXE="${APPDIR}/ChatGPT.exe"

mkdir -p "${WINEPREFIX}"

if command -v wine64 >/dev/null 2>&1; then
  exec wine64 "${EXE}" "$@"
fi

exec wine "${EXE}" "$@"
EOF
  chmod 0755 "${bin_dir}/chatgpt-desktop-windows"

  cat > "${app_dir}/chatgpt-desktop-windows.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${APP_NAME} (Windows)
Comment=ChatGPT Windows desktop app via Wine
Exec=/usr/bin/chatgpt-desktop-windows
Icon=chatgpt-desktop-windows
Terminal=false
Categories=Network;Office;Utility;
StartupNotify=true
EOF

  if [[ -f "$BUILD_DIR/chatgpt.png" ]]; then
    cp -f "$BUILD_DIR/chatgpt.png" "${icon_dir}/chatgpt-desktop-windows.png"
  fi

  cat > "${debian_dir}/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: misc
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Depends: wine64
Description: ${DESCRIPTION}
 Local Debian wrapper around the Windows ChatGPT desktop app.
EOF
}

build_deb() {
  section "Build Debian Package"
  local output="${OUT_DIR}/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
  dpkg-deb --build "$BUILD_DIR/pkgroot" "$output" >/dev/null
  printf "built package: %s\n" "$output"
}

print_next_steps() {
  section "Next Steps"
  cat <<EOF
1. Install the package:
   sudo apt-get install ${OUT_DIR}/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb

2. Launch it:
   chatgpt-desktop-windows

3. If Wine prompts for first-run setup, let it complete once.

Current note:
  The file currently at ${INPUT_PAYLOAD} must be a real Windows payload.
  If it is actually an HTML download page, replace it and rerun this script.
EOF
}

cleanup() {
  if [[ "$CLEAN" == "yes" ]]; then
    rm -rf "$BUILD_DIR"
  fi
}

main() {
  parse_args "$@"
  check_deps
  validate_input
  prepare_dirs
  detect_version
  extract_payload
  locate_exe
  extract_icon
  extract_msix_assets
  stage_deb_tree
  build_deb
  print_next_steps
  cleanup
}

main "$@"
