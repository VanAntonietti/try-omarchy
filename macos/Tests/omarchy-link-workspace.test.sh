#!/bin/bash

set -euo pipefail

native_dir=$(cd "$(dirname "$0")/.." && pwd -P)
source "$native_dir/qemu-persistent-storage.sh"
export QEMU_PERSISTENT_STORAGE_HELPER="$native_dir/.build/debug/omarchy-vm-helper"

fail() {
  printf 'omarchy-link-workspace.test: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "expected [$2], got [$1]"
}

test_root=$(mktemp -d '/private/tmp/omarchy-link-workspace.XXXXXX')
cleanup() {
  qemu_persistent_storage_release_lock || true
  /bin/rm -rf "$test_root"
}
trap cleanup EXIT
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/state"
export OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=0
source_disk="$test_root/source.ext4"
dd if=/dev/zero of="$source_disk" bs=4096 count=1 >/dev/null 2>&1
source_sha=$(/usr/bin/shasum -a 256 "$source_disk" | awk '{ print $1 }')
bundle_identity=$(printf 'factory' | /usr/bin/shasum -a 256 | awk '{ print $1 }')

select_workspace() {
  qemu_persistent_storage_select "${1:-persistent}" \
    "$bundle_identity" "$source_disk" "$source_sha" 4096 ''
}

# A new Workspace has a random, canonical UUID, independent of its factory
# identity. Later selection presents the same identity without writing the disk.
select_workspace
workspace_identity=${QEMU_LINK_WORKSPACE_IDENTITY:-}
[[ $workspace_identity =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || \
  fail 'new Workspace did not receive a random UUID identity'
assert_eq "${QEMU_LINK_WORKSPACE_KERNEL_ARGUMENT:-}" " tryomarchy.workspace_id=$workspace_identity"
# Persistent binding uses a volume UUID, not a mount-time device number that
# can change when this same APFS drive is unplugged and reconnected.
record=$(/usr/bin/xattr -p dev.tryomarchy.workspace-identity "$QEMU_PERSISTENT_STORAGE_DIRECTORY")
[[ $record =~ ^v1:$workspace_identity:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9]+:[0-9]+$ ]] || \
  fail 'Workspace binding has no persistent volume UUID'
qemu_persistent_storage_release_lock
qemu_persistent_storage_select_existing "$bundle_identity"
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" "$workspace_identity"
assert_eq "$QEMU_LINK_WORKSPACE_KERNEL_ARGUMENT" " tryomarchy.workspace_id=$workspace_identity"
cmp -s "$QEMU_SELECTED_DISK" "$source_disk" || fail 'identity provisioning changed guest disk contents'
qemu_persistent_storage_release_lock

# Reset reuses the factory and storage location, never the Workspace identity
# that will key Service Modes. Old choices therefore cannot follow the new VM.
select_workspace reset
reset_identity=$QEMU_LINK_WORKSPACE_IDENTITY
[[ $reset_identity != "$workspace_identity" && -n $reset_identity ]] || fail 'reset retained Workspace identity'
qemu_persistent_storage_release_lock
select_workspace
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" "$reset_identity"
qemu_persistent_storage_release_lock

# App updates and an in-volume folder rename preserve the same Workspace.
bundle_identity=$(printf 'updated factory' | /usr/bin/shasum -a 256 | awk '{ print $1 }')
mv "$OMARCHY_QEMU_GPU_STATE_ROOT" "$test_root/renamed-state"
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/renamed-state"
qemu_persistent_storage_select_existing "$bundle_identity"
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" "$reset_identity"
workspace_directory=$QEMU_PERSISTENT_STORAGE_DIRECTORY
qemu_persistent_storage_release_lock

# Missing host state (including a pre-Link disk) never triggers retrofit. Disk
# selection succeeds, but neither a consent key nor a guest boot token exists.
/usr/bin/xattr -d dev.tryomarchy.workspace-identity "$workspace_directory"
select_workspace
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
assert_eq "$QEMU_LINK_WORKSPACE_KERNEL_ARGUMENT" ''
cmp -s "$QEMU_SELECTED_DISK" "$source_disk" || fail 'legacy disk was modified'
qemu_persistent_storage_release_lock
qemu_persistent_storage_select_existing "$bundle_identity"
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
if /usr/bin/xattr -p dev.tryomarchy.workspace-identity "$workspace_directory" >/dev/null 2>&1; then
  fail 'existing Workspace was retrofitted with an identity'
fi
qemu_persistent_storage_release_lock

# Corrupt identity state also disables only Link, without repairing it.
for corrupt in 'not-an-identity' 'v2:future' ''; do
  /usr/bin/xattr -w dev.tryomarchy.workspace-identity "$corrupt" "$workspace_directory"
  select_workspace
  assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
  assert_eq "$QEMU_LINK_WORKSPACE_KERNEL_ARGUMENT" ''
  assert_eq "$(/usr/bin/xattr -p dev.tryomarchy.workspace-identity "$workspace_directory")" "$corrupt"
  qemu_persistent_storage_release_lock
done

# Reset is still an escape hatch for corrupt Link state.
select_workspace reset
valid_identity=$QEMU_LINK_WORKSPACE_IDENTITY
[[ -n $valid_identity && $valid_identity != "$reset_identity" ]] || fail 'reset did not replace corrupt identity'
workspace_directory=$QEMU_PERSISTENT_STORAGE_DIRECTORY
valid_record=$(/usr/bin/xattr -p dev.tryomarchy.workspace-identity "$workspace_directory")
qemu_persistent_storage_release_lock

# A second Workspace made from the same factory has independent state. Copying
# its otherwise valid identity record onto the first does not select its modes.
first_state_root=$OMARCHY_QEMU_GPU_STATE_ROOT
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/other-state"
select_workspace
other_identity=$QEMU_LINK_WORKSPACE_IDENTITY
[[ -n $other_identity && $other_identity != "$valid_identity" ]] || fail 'two Workspaces share identity'
other_record=$(/usr/bin/xattr -p dev.tryomarchy.workspace-identity "$QEMU_PERSISTENT_STORAGE_DIRECTORY")
qemu_persistent_storage_release_lock
export OMARCHY_QEMU_GPU_STATE_ROOT=$first_state_root
/usr/bin/xattr -w dev.tryomarchy.workspace-identity "$other_record" "$workspace_directory"
select_workspace
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
assert_eq "$QEMU_LINK_WORKSPACE_KERNEL_ARGUMENT" ''
qemu_persistent_storage_release_lock

# Even trailing bytes on an otherwise valid identity record are malformed.
/usr/bin/xattr -w dev.tryomarchy.workspace-identity "$valid_record"$'\n' "$workspace_directory"
select_workspace
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
qemu_persistent_storage_release_lock

# Substituting an equal-sized disk or cloning the entire host state cannot
# inherit access choices. The real filesystem boundary supplies distinct IDs.
/usr/bin/xattr -w dev.tryomarchy.workspace-identity "$valid_record" "$workspace_directory"
/bin/cp -c "$workspace_directory/rootfs.ext4" "$test_root/replacement.ext4"
chmod 600 "$test_root/replacement.ext4"
mv "$test_root/replacement.ext4" "$workspace_directory/rootfs.ext4"
select_workspace
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
qemu_persistent_storage_release_lock
select_workspace reset
qemu_persistent_storage_release_lock
/bin/cp -cR "$OMARCHY_QEMU_GPU_STATE_ROOT" "$test_root/copied-state"
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/copied-state"
select_workspace
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
qemu_persistent_storage_release_lock

# A crash before publication leaves only staging. A crash during reset leaves
# discarded state. Neither is eligible to become the next Workspace identity.
export OMARCHY_QEMU_GPU_STATE_ROOT=$first_state_root
for interrupted in initializing.ABCDEF discarded.interrupted; do
  select_workspace reset
  interrupted_identity=$QEMU_LINK_WORKSPACE_IDENTITY
  interrupted_directory=$QEMU_PERSISTENT_STORAGE_DIRECTORY
  qemu_persistent_storage_release_lock
  mv "$interrupted_directory" "${interrupted_directory%/*}/.current.$interrupted"
  select_workspace
  [[ -n $QEMU_LINK_WORKSPACE_IDENTITY && $QEMU_LINK_WORKSPACE_IDENTITY != "$interrupted_identity" ]] || \
    fail 'recovered an interrupted identity into another Workspace'
  [[ ! -e ${interrupted_directory%/*}/.current.$interrupted ]] || fail 'recognized interrupted transaction was not reclaimed'
  qemu_persistent_storage_release_lock
done

# Fail the filesystem durability boundary before publication and immediately
# after reset detaches the old Workspace. Neither failure may report success
# or let a later launch inherit the interrupted Workspace's identity.
export QPS_TEST_REAL_HELPER=$QEMU_PERSISTENT_STORAGE_HELPER
sync_probe="$test_root/sync-probe"
cat >"$sync_probe" <<'SH'
#!/bin/bash
if [[ $1 == --sync-storage ]]; then
  case "$QPS_TEST_SYNC_FAILURE:$2" in
    staging:*/.current.initializing.??????) exit 87 ;;
    reset:*/disks) [[ -d $2/current ]] || exit 88 ;;
  esac
fi
exec "$QPS_TEST_REAL_HELPER" "$@"
SH
chmod 700 "$sync_probe"
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/sync-failure-state"
export QEMU_PERSISTENT_STORAGE_HELPER=$sync_probe
export QPS_TEST_SYNC_FAILURE=staging
if select_workspace; then
  fail 'published a Workspace without a successful durability barrier'
fi
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
[[ ! -e $OMARCHY_QEMU_GPU_STATE_ROOT/disks/current ]] || fail 'published unsynchronized staging'
export QEMU_PERSISTENT_STORAGE_HELPER=$QPS_TEST_REAL_HELPER
select_workspace
before_failed_reset=$QEMU_LINK_WORKSPACE_IDENTITY
qemu_persistent_storage_release_lock
export QEMU_PERSISTENT_STORAGE_HELPER=$sync_probe
export QPS_TEST_SYNC_FAILURE=reset
if select_workspace reset; then
  fail 'reported a durable reset after its barrier failed'
fi
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
export QEMU_PERSISTENT_STORAGE_HELPER=$QPS_TEST_REAL_HELPER
select_workspace
[[ -n $QEMU_LINK_WORKSPACE_IDENTITY && $QEMU_LINK_WORKSPACE_IDENTITY != "$before_failed_reset" ]] || \
  fail 'failed reset retained old access choices on the new Workspace'
qemu_persistent_storage_release_lock
unset QPS_TEST_REAL_HELPER QPS_TEST_SYNC_FAILURE

# Ephemeral and missing selections cannot leak a preceding consent key/token.
mkdir -m 700 "$test_root/run"
qemu_persistent_storage_select ephemeral \
  "$bundle_identity" "$source_disk" "$source_sha" 4096 "$test_root/run"
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
assert_eq "$QEMU_LINK_WORKSPACE_KERNEL_ARGUMENT" ''
export OMARCHY_QEMU_GPU_STATE_ROOT="$test_root/missing-state"
if qemu_persistent_storage_select_existing "$bundle_identity"; then
  fail 'missing Workspace unexpectedly selected'
else
  assert_eq "$?" 79
fi
assert_eq "$QEMU_LINK_WORKSPACE_IDENTITY" ''
assert_eq "$QEMU_LINK_WORKSPACE_KERNEL_ARGUMENT" ''

# A boot kit cannot bake in an identity belonging to a different Workspace.
# Only the selected, host-validated identity may supply this launcher token.
kernel="$test_root/kernel"
dd if=/dev/zero of="$kernel" bs=1 count=64 >/dev/null 2>&1
printf 'ARMd' | dd of="$kernel" bs=1 seek=56 conv=notrunc >/dev/null 2>&1
printf '070701initramfs\n' >"$test_root/initramfs"
if qemu_persistent_storage_select persistent \
  "$bundle_identity" "$source_disk" "$source_sha" 4096 '' 4096 \
  "$kernel" "$test_root/initramfs" \
  "root=/dev/vda rw rootwait console=tty0 console=hvc0 tryomarchy.workspace_id=$workspace_identity"; then
  fail 'accepted a boot kit with a pre-baked Workspace identity'
fi
[[ ! -e $OMARCHY_QEMU_GPU_STATE_ROOT/disks/current ]] || fail 'invalid boot kit created a Workspace'

printf 'omarchy-link-workspace.test: PASS\n'
