#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: install-omarchy-link-development.sh --root ROOT --work WORK"
}

fail() {
  echo "install-omarchy-link-development: $*" >&2
  exit 1
}

root=""
work=""
while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --work)
      work=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ $root == /* && -d $root ]] || fail "--root must be an absolute staged root"
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing unsafe root: $root"
    ;;
esac
[[ $work == /* && -d $work ]] || fail "--work must be an absolute directory"
command -v cargo >/dev/null || fail "cargo is required"

script_dir=$(cd "$(dirname "$0")" && pwd)
component_dir=$(cd "$script_dir/../omarchy-link" && pwd)
target_dir="$work/omarchy-link-target"

CARGO_TARGET_DIR="$target_dir" cargo build \
  --frozen \
  --release \
  --manifest-path "$component_dir/Cargo.toml"

binary="$target_dir/release/omarchy-link"
[[ -f $binary && -x $binary && ! -L $binary ]] || fail "the compiled broker is missing or unsafe"
install -d -m 0755 "$root/usr/local/bin"
install -m 0755 "$binary" "$root/usr/local/bin/omarchy-link"

echo "Installed the Owner-local Omarchy Link broker (host transport unavailable)"
