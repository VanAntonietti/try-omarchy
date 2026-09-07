#!/bin/bash
# Launch contract for the optional Omarchy Link virtio channel: it exists only
# for a validated persistent Workspace, its bridge is supervised separately
# from QEMU, and every Link failure leaves the VM running.

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)

fail() {
  printf 'omarchy-link-channel.test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "expected output to contain [$2], got [$1]"
}

assert_not_contains() {
  [[ $1 != *"$2"* ]] || fail "expected output not to contain [$2], got [$1]"
}

test_root=$(mktemp -d '/private/tmp/omarchy-link-channel.XXXXXX')
case "$test_root" in
  /private/tmp/omarchy-link-channel.??????) ;;
  *) fail "unexpected test root: $test_root" ;;
esac
trap '/bin/rm -rf "$test_root"' EXIT HUP INT TERM

app="$test_root/Try Omarchy.app"
contents="$app/Contents"
resources="$contents/Resources"
shim_dir="$test_root/bin"
mkdir -p \
  "$contents/MacOS" \
  "$resources/guest" \
  "$resources/runtime/bin" \
  "$resources/scripts" \
  "$shim_dir"

/bin/cp "$macos_dir/run-qemu-gpu.sh" "$resources/scripts/run-qemu-gpu.sh"
/bin/cp "$macos_dir/qemu-port-forwarding.sh" "$resources/scripts/qemu-port-forwarding.sh"
chmod 755 "$resources/scripts/run-qemu-gpu.sh"
chmod 644 "$resources/scripts/qemu-port-forwarding.sh"

cat >"$contents/MacOS/omarchy-vm-helper" <<'SH'
#!/bin/bash
set -euo pipefail
case ${1:-} in
  --link-session-modes)
    printf 'link-session-modes %s\n' "$2" >>"$FAKE_LINK_LOG"
    [[ -n ${FAKE_LINK_MODES:-} ]] || exit 1
    printf '%s\n' "$FAKE_LINK_MODES"
    ;;
  --bridge-omarchy-link)
    printf 'bridge-omarchy-link %s %s %s %s %s\n' "$4" "$5" "$6" "$7" \
      "${FAKE_LINK_BRIDGE_BEHAVIOR:-wait}" >>"$FAKE_LINK_LOG"
    case ${FAKE_LINK_BRIDGE_BEHAVIOR:-wait} in
      disable) exit 2 ;;
      crash) exit 3 ;;
      *)
        while kill -0 "$2" 2>/dev/null; do
          sleep 0.02
        done
        ;;
    esac
    ;;
  --bridge-native-audio|--bridge-native-clipboard|--bridge-native-camera)
    while kill -0 "$2" 2>/dev/null; do
      sleep 0.02
    done
    ;;
esac
exit 0
SH
chmod 755 "$contents/MacOS/omarchy-vm-helper"

cat >"$resources/runtime/bin/Try Omarchy" <<'SH'
#!/bin/bash
# Identity markers validated by the production launcher:
# TryOmarchy.icns
# OMARCHY_SDL_AUDIO_CONTROL_DIRECTORY
# OMARCHY_SDL_INPUT_DEVICE_NAME
# OMARCHY_SDL_OUTPUT_DEVICE_NAME
# guest_owner_uid guest_owner_gid
case " $* " in
  *' -accel help '*) printf '%s\n' hvf ;;
  *' -machine help '*) printf '%s\n' 'virt                 ARM Virtual Machine' ;;
  *' -cpu help '*) printf '%s\n' '  host' ;;
  *' -display help '*) printf '%s\n' cocoa ;;
  *' -device help '*)
    for device in \
      hda-micro intel-hda virtconsole virtserialport virtio-balloon-pci \
      virtio-9p-pci virtio-blk-pci virtio-gpu-gl-pci virtio-keyboard-pci \
      virtio-net-pci virtio-rng-pci virtio-serial-pci virtio-tablet-pci; do
      printf 'name "%s"\n' "$device"
    done
    ;;
  *' -help '*)
    printf '%s\n' \
      '-add-fd fd=fd,set=set[,opaque=opaque]' \
      '-action reboot=reset|shutdown' \
      '-action shutdown=poweroff|pause' \
      'full-grab=on|off' \
      'immersive=on|off'
    ;;
  *' -machine virt -netdev help '*) printf '%s\n' user ;;
  *' -machine virt -audiodev help '*) printf '%s\n' sdl ;;
  *' -device virtio-gpu-gl-pci,help '*) printf '%s\n' 'romfile=<str>' ;;
  *)
    exec /usr/bin/python3 - "$@" <<'PY'
import os
from pathlib import Path
import socket
import sys
import time

arguments = sys.argv[1:]
Path(os.environ["FAKE_QEMU_LOG"]).write_text("\n".join(arguments) + "\n")

socket_paths = []
for argument in arguments:
    if argument.startswith("unix:"):
        socket_paths.append(argument[5:].split(",", 1)[0])
    elif argument.startswith("socket,"):
        for field in argument.split(","):
            if field.startswith("path="):
                socket_paths.append(field[5:])

servers = []
for path in socket_paths:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen(1)
    servers.append(server)

time.sleep(float(os.environ.get("FAKE_QEMU_LIFETIME", "0.20")))
for server in servers:
    server.close()
raise SystemExit(0)
PY
    ;;
esac
SH
chmod 755 "$resources/runtime/bin/Try Omarchy"

cat >"$resources/scripts/qemu-persistent-storage.sh" <<'SH'
#!/bin/bash
QEMU_PERSISTENT_STORAGE_INCOMPATIBLE_STATUS=78
QEMU_PERSISTENT_STORAGE_MISSING_STATUS=79
QEMU_PERSISTENT_STORAGE_QEMU_ADD_FD='fd=9,set=77,opaque=omarchy-persistent-lock'
QEMU_SELECTED_DISK=''
QEMU_SELECTED_STORAGE_MODE=''
QEMU_PERSISTENT_STORAGE_DIRECTORY=''
QEMU_PERSISTENT_STORAGE_IDENTITY=''
QEMU_SELECTED_KERNEL=''
QEMU_SELECTED_INITRAMFS=''
QEMU_SELECTED_KERNEL_COMMAND_LINE=''
QEMU_PERSISTENT_STORAGE_NEEDS_BOOT_RECOVERY=0
QEMU_LINK_WORKSPACE_IDENTITY=''
QEMU_LINK_WORKSPACE_KERNEL_ARGUMENT=''
_qps_owner() { /usr/bin/stat -f '%u' "$1"; }
_qps_permissions() { /usr/bin/stat -f '%Lp' "$1"; }
_qps_lstat_kind() { /usr/bin/stat -f '%HT' "$1"; }
_qps_size() { /usr/bin/stat -f '%z' "$1"; }
qemu_persistent_storage_release_lock() { :; }
qemu_persistent_storage_materialize_source() { return 1; }
qemu_persistent_storage_select_existing() { return "$QEMU_PERSISTENT_STORAGE_MISSING_STATUS"; }
qemu_persistent_storage_select() {
  if [[ $1 == ephemeral ]]; then
    mkdir -p "$6"
    QEMU_SELECTED_DISK="$6/rootfs.ext4"
    /bin/cp "$3" "$QEMU_SELECTED_DISK"
    chmod 600 "$QEMU_SELECTED_DISK"
    QEMU_SELECTED_STORAGE_MODE=ephemeral
    QEMU_SELECTED_KERNEL=$8
    QEMU_SELECTED_INITRAMFS=$9
    QEMU_SELECTED_KERNEL_COMMAND_LINE=${10}
    return 0
  fi
  mkdir -p "$FAKE_PERSISTENT_ROOT/boot"
  QEMU_SELECTED_DISK="$FAKE_PERSISTENT_ROOT/rootfs.ext4"
  printf 'factory\n' >"$QEMU_SELECTED_DISK"
  chmod 600 "$QEMU_SELECTED_DISK"
  /bin/cp "$8" "$FAKE_PERSISTENT_ROOT/boot/kernel"
  /bin/cp "$9" "$FAKE_PERSISTENT_ROOT/boot/initramfs"
  QEMU_SELECTED_STORAGE_MODE=persistent
  QEMU_PERSISTENT_STORAGE_DIRECTORY=$FAKE_PERSISTENT_ROOT
  QEMU_PERSISTENT_STORAGE_IDENTITY=saved-vm
  QEMU_SELECTED_KERNEL="$FAKE_PERSISTENT_ROOT/boot/kernel"
  QEMU_SELECTED_INITRAMFS="$FAKE_PERSISTENT_ROOT/boot/initramfs"
  QEMU_SELECTED_KERNEL_COMMAND_LINE=${10}
  if [[ -n ${FAKE_LINK_IDENTITY:-} ]]; then
    QEMU_LINK_WORKSPACE_IDENTITY=$FAKE_LINK_IDENTITY
    QEMU_LINK_WORKSPACE_KERNEL_ARGUMENT=" tryomarchy.workspace_id=$FAKE_LINK_IDENTITY"
  fi
}
SH
chmod 644 "$resources/scripts/qemu-persistent-storage.sh"

cat >"$shim_dir/codesign" <<'SH'
#!/bin/bash
for argument in "$@"; do
  if [[ $argument == -d ]]; then
    printf '%s\n' '<key>com.apple.security.hypervisor</key>' >&2
  fi
done
exit 0
SH
cat >"$shim_dir/file" <<'SH'
#!/bin/bash
printf '%s: Mach-O 64-bit executable arm64\n' "$1"
SH
cat >"$shim_dir/sysctl" <<'SH'
#!/bin/bash
if [[ $# == 2 && $1 == -n && ($2 == hw.logicalcpu || $2 == hw.ncpu) ]]; then
  printf '8\n'
  exit 0
fi
exec /usr/sbin/sysctl "$@"
SH
chmod 755 "$shim_dir"/*

guest="$resources/guest"
printf 'kernel\n' >"$guest/vmlinuz-linux"
printf 'initramfs\n' >"$guest/initramfs-linux.img"
printf 'factory\n' >"$guest/rootfs.ext4"
/usr/bin/plutil -create xml1 "$guest/launch.plist"
/usr/bin/plutil -insert bundleIdentity -string "$(printf 'a%.0s' {1..64})" "$guest/launch.plist"
/usr/bin/plutil -insert sourceDiskSHA256 -string "$(printf 'b%.0s' {1..64})" "$guest/launch.plist"
/usr/bin/plutil -insert sourceDiskBytes -integer 8 "$guest/launch.plist"
/usr/bin/plutil -insert compressedDiskBytes -integer 4 "$guest/launch.plist"
/usr/bin/plutil -insert workingDiskBytes -integer 16 "$guest/launch.plist"
/usr/bin/plutil -insert kernelCommandLine -string \
  'root=/dev/vda rw rootwait console=tty0 console=hvc0 loglevel=4 systemd.show_status=false rd.systemd.show_status=false mitigations=off nowatchdog' \
  "$guest/launch.plist"

launcher="$resources/scripts/run-qemu-gpu.sh"
workspace_identity='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
mode_snapshot='calendar=readWrite messages=read notes=off'

run_scenario() {
  local scenario=$1
  local expected_status=$2
  local launcher_argument=$3
  shift 3
  local scenario_dir="$test_root/$scenario"
  local actual_status=0
  mkdir -p "$scenario_dir"
  : >"$scenario_dir/link.log"
  if env \
    PATH="$shim_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    FAKE_PERSISTENT_ROOT="$scenario_dir/persistent" \
    FAKE_QEMU_LOG="$scenario_dir/qemu.log" \
    FAKE_LINK_LOG="$scenario_dir/link.log" \
    "$@" \
    "$launcher" ${launcher_argument:+"$launcher_argument"} \
    >"$scenario_dir/stdout" 2>"$scenario_dir/stderr"; then
    actual_status=0
  else
    actual_status=$?
  fi
  if [[ $actual_status != "$expected_status" ]]; then
    /bin/cat "$scenario_dir/stderr" >&2 || true
    fail "$scenario expected status $expected_status, got $actual_status"
  fi
}

# A validated persistent Workspace gets the private channel: one snapshot
# capture, the virtio-serial port, and one supervised bridge carrying the
# identity plus the frozen Service Modes. No TCP listener is introduced.
run_scenario enabled 0 '' \
  "FAKE_LINK_IDENTITY=$workspace_identity" \
  "FAKE_LINK_MODES=$mode_snapshot"
enabled_qemu=$(<"$test_root/enabled/qemu.log")
assert_contains "$enabled_qemu" 'id=omarchy-link-bridge'
assert_contains "$enabled_qemu" '/link.sock'
assert_contains "$enabled_qemu" \
  'virtserialport,bus=omarchy-serial.0,nr=5,chardev=omarchy-link-bridge,name=dev.tryomarchy.link'
assert_contains "$enabled_qemu" "tryomarchy.workspace_id=$workspace_identity"
assert_not_contains "$enabled_qemu" 'hostfwd'
enabled_link=$(<"$test_root/enabled/link.log")
assert_contains "$enabled_link" "link-session-modes $workspace_identity"
assert_contains "$enabled_link" \
  "bridge-omarchy-link $workspace_identity readWrite read off wait"
[[ $(grep -c '^bridge-omarchy-link ' "$test_root/enabled/link.log") == 1 ]] || \
  fail 'the healthy bridge was restarted'

# The dry run names the exact supervised bridge invocation.
run_scenario dry-run 0 '' \
  "FAKE_LINK_IDENTITY=$workspace_identity" \
  "FAKE_LINK_MODES=$mode_snapshot" \
  OMARCHY_QEMU_GPU_DRY_RUN=1
dry_run=$(<"$test_root/dry-run/stderr")
assert_contains "$dry_run" 'omarchy link bridge command:'
assert_contains "$dry_run" "$workspace_identity readWrite read off"

# Without a validated Workspace identity (a legacy or corrupt disk) nothing
# is captured, no channel device exists, and the VM still boots.
run_scenario no-identity 0 '' \
  "FAKE_LINK_MODES=$mode_snapshot"
assert_not_contains "$(<"$test_root/no-identity/qemu.log")" 'dev.tryomarchy.link'
[[ ! -s $test_root/no-identity/link.log ]] || fail 'Link ran without an identity'

# Ephemeral launches have no Workspace identity to bind; Link stays off.
run_scenario ephemeral 0 --ephemeral \
  "FAKE_LINK_IDENTITY=$workspace_identity" \
  "FAKE_LINK_MODES=$mode_snapshot"
assert_not_contains "$(<"$test_root/ephemeral/qemu.log")" 'dev.tryomarchy.link'
assert_not_contains "$(<"$test_root/ephemeral/qemu.log")" 'tryomarchy.workspace_id'
[[ ! -s $test_root/ephemeral/link.log ]] || fail 'Link ran for an ephemeral launch'

# A failed or malformed Service Mode snapshot only disables Link.
for broken in snapshot-failure snapshot-malformed; do
  modes=''
  [[ $broken == snapshot-malformed ]] && modes='calendar=everything messages=read notes=off'
  run_scenario "$broken" 0 '' \
    "FAKE_LINK_IDENTITY=$workspace_identity" \
    "FAKE_LINK_MODES=$modes"
  assert_contains "$(<"$test_root/$broken/stderr")" \
    'Omarchy Link is unavailable: the Service Mode snapshot could not be captured'
  assert_not_contains "$(<"$test_root/$broken/qemu.log")" 'dev.tryomarchy.link'
  assert_not_contains "$(<"$test_root/$broken/link.log")" 'bridge-omarchy-link'
done

# A protocol violation (bridge exit status 2) disables Link for the session
# without a restart, while QEMU continues and exits normally.
run_scenario protocol-violation 0 '' \
  "FAKE_LINK_IDENTITY=$workspace_identity" \
  "FAKE_LINK_MODES=$mode_snapshot" \
  FAKE_LINK_BRIDGE_BEHAVIOR=disable \
  FAKE_QEMU_LIFETIME=1.0
assert_contains "$(<"$test_root/protocol-violation/stderr")" \
  'Omarchy Link is disabled for the rest of this session'
[[ $(grep -c '^bridge-omarchy-link ' "$test_root/protocol-violation/link.log") == 1 ]] || \
  fail 'a protocol violation must not restart the Link bridge'

# A crashed bridge is restarted a bounded number of times.
run_scenario bridge-crash 0 '' \
  "FAKE_LINK_IDENTITY=$workspace_identity" \
  "FAKE_LINK_MODES=$mode_snapshot" \
  FAKE_LINK_BRIDGE_BEHAVIOR=crash \
  FAKE_QEMU_LIFETIME=2.5
assert_contains "$(<"$test_root/bridge-crash/stderr")" \
  'Omarchy Link bridge exited (status 3); restarting (1/5)'
(( $(grep -c '^bridge-omarchy-link ' "$test_root/bridge-crash/link.log") >= 2 )) || \
  fail 'a crashed Link bridge was not restarted'

echo 'omarchy-link-channel.test: ok'
