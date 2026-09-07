#!/bin/bash
# Disposable-Linux verification for the Owner-local broker (issue #8).
#
# Builds the locked, vendored broker with `cargo build --frozen --release`,
# installs the factory `omarchy-link.service` user unit unchanged, and checks
# in a throwaway Lima VM that:
#   1. the service starts for the uid-1000 Owner and owns a 0600 socket in a
#      0700 runtime directory;
#   2. a second account's status and Mutation Proposal requests fail before
#      reaching the broker (client refusal plus kernel EACCES on the socket);
#   3. a second account cannot run the production daemon;
#   4. the service stops cleanly (runtime directory removed) and status works
#      again after a restart.
#
# No personal Apple data, host transport, or real Mac Service is involved.
#
# Environment:
#   OMARCHY_LINK_VERIFY_VM    VM name (default: omarchy-link-verify)
#   OMARCHY_LINK_VERIFY_KEEP  set to 1 to keep the VM for inspection

set -euo pipefail

vm=${OMARCHY_LINK_VERIFY_VM:-omarchy-link-verify}
keep=${OMARCHY_LINK_VERIFY_KEEP:-0}

script_dir=$(cd "$(dirname "$0")" && pwd)
component_dir=$(cd "$script_dir/.." && pwd)
guest_dir=$(cd "$component_dir/.." && pwd)
unit="$guest_dir/native-overlay/usr/lib/systemd/user/omarchy-link.service"

fail() {
  echo "verify-owner-broker-lima: $*" >&2
  exit 1
}

step() {
  echo
  echo "== $*"
}

command -v limactl >/dev/null || fail "limactl is required"
[[ -f $unit ]] || fail "missing factory unit: $unit"
[[ -d $component_dir/vendor ]] || fail "missing vendored dependencies"

cleanup() {
  if [[ $keep == 1 ]]; then
    echo "verify-owner-broker-lima: keeping VM $vm for inspection"
  else
    limactl delete --force "$vm" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Run a root shell script inside the VM, provided on stdin.
vmroot() {
  limactl shell "$vm" -- sudo bash -euo pipefail -s
}

step "Creating disposable VM $vm"
limactl delete --force "$vm" >/dev/null 2>&1 || true
limactl create --name="$vm" --tty=false template://default
limactl start "$vm"

step "Copying the locked, vendored sources and the factory unit"
tar -C "$guest_dir" -cf - --no-xattrs --exclude omarchy-link/target omarchy-link |
  limactl shell "$vm" -- sudo tar -C /opt -xf -
limactl shell "$vm" -- sudo tee /usr/lib/systemd/user/omarchy-link.service \
  >/dev/null <"$unit"

step "Provisioning toolchain, Owner (uid 1000), and a second account"
vmroot <<'PROVISION'
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >/dev/null
apt-get install -qy build-essential curl python3 >/dev/null

# The Owner is the uid-1000 account, as in a factory Workspace.
if id -u 1000 >/dev/null 2>&1; then
  owner=$(id -nu 1000)
else
  useradd -m -u 1000 owner
  owner=owner
fi
echo "$owner" >/run/verify-owner-name
id "$owner"
useradd -m mallory
id mallory

# The factory pins Rust 1.98.0; fall back to stable only if that release
# is unavailable from rustup, and record whichever toolchain built the broker.
export RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust
curl -fsSL https://sh.rustup.rs |
  sh -s -- -y --no-modify-path --default-toolchain 1.98.0 >/dev/null ||
  curl -fsSL https://sh.rustup.rs |
    sh -s -- -y --no-modify-path --default-toolchain stable >/dev/null
/opt/rust/bin/cargo --version
PROVISION

step "Building the broker with the exact locked, vendored dependency graph"
vmroot <<'BUILD'
export RUSTUP_HOME=/opt/rust CARGO_HOME=/opt/rust
# Run from the component directory so cargo discovers .cargo/config.toml,
# which redirects crates.io to the reviewed vendor/ directory.
cd /opt/omarchy-link
CARGO_TARGET_DIR=/opt/omarchy-link-target /opt/rust/bin/cargo build \
  --frozen --release
install -m 0755 /opt/omarchy-link-target/release/omarchy-link \
  /usr/local/bin/omarchy-link
# Enable exactly as configure-rootfs.sh does: a global user-unit want,
# gated to the Owner by the unit's ConditionUser=1000.
mkdir -p /etc/systemd/user/default.target.wants
ln -sfn /usr/lib/systemd/user/omarchy-link.service \
  /etc/systemd/user/default.target.wants/omarchy-link.service
BUILD

step "Starting user managers for both accounts"
vmroot <<'LINGER'
owner=$(cat /run/verify-owner-name)
loginctl enable-linger "$owner"
loginctl enable-linger mallory
for _ in $(seq 30); do
  [[ -S /run/user/1000/omarchy-link/socket ]] && break
  sleep 1
done
[[ -S /run/user/1000/omarchy-link/socket ]] ||
  { echo "the Owner broker socket never appeared" >&2; exit 1; }
LINGER

step "Check 1: the service is active for the Owner with safe modes"
vmroot <<'OWNER'
owner=$(cat /run/verify-owner-name)
state=$(systemctl --user --machine="$owner@" is-active omarchy-link.service)
echo "owner service: $state"
[[ $state == active ]]

directory_mode=$(stat -c '%a %U' /run/user/1000/omarchy-link)
socket_mode=$(stat -c '%a %U' /run/user/1000/omarchy-link/socket)
echo "runtime directory: $directory_mode"
echo "socket: $socket_mode"
[[ $directory_mode == "700 $owner" ]]
[[ $socket_mode == "600 $owner" ]]

# The unit's ConditionUser=1000 skips every other account's user manager.
mallory_state=$(systemctl --user --machine=mallory@ is-active omarchy-link.service) || true
echo "mallory service: $mallory_state"
[[ $mallory_state == inactive ]]
[[ ! -e /run/user/$(id -u mallory)/omarchy-link ]]

response=$(printf '%s' '{"method":"status"}' |
  runuser -u "$owner" -- env XDG_RUNTIME_DIR=/run/user/1000 \
    /usr/local/bin/omarchy-link call)
echo "owner status: $response"
grep -q '"hostAvailable":false' <<<"$response"
grep -q '"adapter":"unavailable"' <<<"$response"
OWNER

step "Check 2: a second account is denied before reaching the broker"
vmroot <<'MALLORY'
# The client refuses a runtime directory the caller does not own, so the
# request never leaves mallory's process.
set +e
printf '%s' '{"method":"status"}' |
  runuser -u mallory -- env XDG_RUNTIME_DIR=/run/user/1000 \
    /usr/local/bin/omarchy-link call >/run/verify-mallory-status
status_code=$?
printf '%s' '{"method":"calendar.create","title":"x","start":"2026-09-14T10:00:00Z","end":"2026-09-14T11:00:00Z","calendar":"c"}' |
  runuser -u mallory -- env XDG_RUNTIME_DIR=/run/user/1000 \
    /usr/local/bin/omarchy-link call >/run/verify-mallory-proposal
proposal_code=$?
set -e
echo "mallory status exit: $status_code ($(cat /run/verify-mallory-status))"
echo "mallory proposal exit: $proposal_code ($(cat /run/verify-mallory-proposal))"
[[ $status_code == 69 && $proposal_code == 69 ]]

# Independently of the client, the kernel denies traversal of the Owner's
# 0700 runtime directory, so even a raw connect cannot reach the socket.
runuser -u mallory -- python3 - <<'RAW'
import socket
s = socket.socket(socket.AF_UNIX)
try:
    s.connect("/run/user/1000/omarchy-link/socket")
except PermissionError as error:
    print(f"raw connect denied by the kernel: {error}")
else:
    raise SystemExit("raw connect unexpectedly reached the Owner socket")
RAW
MALLORY

step "Check 3: a second account cannot run the production daemon"
vmroot <<'DAEMON'
set +e
runuser -u mallory -- env XDG_RUNTIME_DIR="/run/user/$(id -u mallory)" \
  /usr/local/bin/omarchy-link daemon
daemon_code=$?
set -e
echo "mallory daemon exit: $daemon_code"
[[ $daemon_code == 69 ]]
DAEMON

step "Check 4: the Owner service stops cleanly and works after restart"
vmroot <<'RESTART'
owner=$(cat /run/verify-owner-name)
systemctl --user --machine="$owner@" stop omarchy-link.service
sleep 1
[[ ! -e /run/user/1000/omarchy-link ]] ||
  { echo "the runtime directory survived a stop" >&2; exit 1; }
echo "runtime directory removed on stop"

set +e
printf '%s' '{"method":"status"}' |
  runuser -u "$owner" -- env XDG_RUNTIME_DIR=/run/user/1000 \
    /usr/local/bin/omarchy-link call >/dev/null
stopped_code=$?
set -e
echo "owner call while stopped exit: $stopped_code"
[[ $stopped_code == 69 ]]

systemctl --user --machine="$owner@" start omarchy-link.service
for _ in $(seq 30); do
  [[ -S /run/user/1000/omarchy-link/socket ]] && break
  sleep 1
done
response=$(printf '%s' '{"method":"status"}' |
  runuser -u "$owner" -- env XDG_RUNTIME_DIR=/run/user/1000 \
    /usr/local/bin/omarchy-link call)
echo "owner status after restart: $response"
grep -q '"hostAvailable":false' <<<"$response"
RESTART

echo
echo "PASS: all Owner-broker checks succeeded in disposable VM $vm"
