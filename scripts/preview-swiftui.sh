#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/scripts/simdeck-swiftui-preview.mjs"
BUILD_ROOT="${SIMDECK_PREVIEW_BUILD_ROOT:-$ROOT_DIR/.simdeck-preview/build}"
DERIVED_DATA="${SIMDECK_PREVIEW_DERIVED_DATA:-$ROOT_DIR/.simdeck-preview/DerivedData}"

args=()
has_file=0
has_project=0
has_scheme=0
has_configuration=0
has_derived_data=0
has_build_root=0
has_min_ios=0
has_skip_xcode_build=0
has_skip_codesign=0
force_xcode_build=0

while (($# > 0)); do
  case "$1" in
    --file)
      has_file=1
      args+=("$1" "$2")
      shift 2
      ;;
    --project)
      has_project=1
      args+=("$1" "$2")
      shift 2
      ;;
    --workspace)
      has_project=1
      args+=("$1" "$2")
      shift 2
      ;;
    --scheme)
      has_scheme=1
      args+=("$1" "$2")
      shift 2
      ;;
    --configuration)
      has_configuration=1
      args+=("$1" "$2")
      shift 2
      ;;
    --derived-data-path)
      has_derived_data=1
      args+=("$1" "$2")
      shift 2
      ;;
    --build-root)
      has_build_root=1
      args+=("$1" "$2")
      shift 2
      ;;
    --min-ios)
      has_min_ios=1
      args+=("$1" "$2")
      shift 2
      ;;
    --skip-xcode-build)
      has_skip_xcode_build=1
      args+=("$1")
      shift
      ;;
    --skip-codesign)
      has_skip_codesign=1
      args+=("$1")
      shift
      ;;
    --force-xcode-build)
      force_xcode_build=1
      shift
      ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    --*)
      args+=("$1")
      if (($# > 1)) && [[ "$2" != --* ]]; then
        args+=("$2")
        shift 2
      else
        shift
      fi
      ;;
    *)
      if [[ "$1" == *.swift && $has_file -eq 0 ]]; then
        has_file=1
        if [[ "$1" = /* ]]; then
          args+=("--file" "$1")
        else
          args+=("--file" "$ROOT_DIR/$1")
        fi
      else
        args+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ $has_file -eq 0 ]]; then
  args+=("--file" "$ROOT_DIR/Macrodex/Views/BrandLogo.swift")
fi
if [[ $has_project -eq 0 ]]; then
  args+=("--project" "$ROOT_DIR/Macrodex.xcodeproj")
fi
if [[ $has_scheme -eq 0 ]]; then
  args+=("--scheme" "Macrodex")
fi
if [[ $has_configuration -eq 0 ]]; then
  args+=("--configuration" "Debug")
fi
if [[ $has_derived_data -eq 0 ]]; then
  args+=("--derived-data-path" "$DERIVED_DATA")
fi
if [[ $has_build_root -eq 0 ]]; then
  args+=("--build-root" "$BUILD_ROOT")
fi
if [[ $has_min_ios -eq 0 ]]; then
  args+=("--min-ios" "18.0")
fi
if [[ $has_skip_codesign -eq 0 ]]; then
  args+=("--skip-codesign")
fi
debug_dylib="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Macrodex.app/Macrodex.debug.dylib"
if [[ $force_xcode_build -eq 0 && $has_skip_xcode_build -eq 0 && -f "$debug_dylib" ]]; then
  args+=("--skip-xcode-build")
fi

exec node "$RUNNER" "${args[@]}"
