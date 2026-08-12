#!/usr/bin/env bash
# Build the qcow2 image and (re)create the libvirt domain "leandro".
# Destroys the existing domain and its disk: state to keep must live
# outside the VM (secrets are re-provisioned per the README runbook).
set -euo pipefail

# Determinate Nix installs outside default shell PATHs
PATH="/nix/var/nix/profiles/default/bin:$PATH"

cd "$(dirname "$0")/.."

IMG_STORE="${IMG_STORE:-/var/lib/libvirt/images}"
VIRSH="${VIRSH:-sudo virsh}"

read -r -p "This destroys the existing 'leandro' VM and disk. Continue? [y/N] " ans
[ "$ans" = "y" ] || exit 1

nix build .#qcow2

$VIRSH destroy leandro 2>/dev/null || true
$VIRSH undefine leandro --nvram 2>/dev/null || true

sudo install -m 644 -o root -g root result/nixos.qcow2 "$IMG_STORE/leandro.qcow2"
sudo qemu-img resize "$IMG_STORE/leandro.qcow2" 40G

sudo virt-install \
  --name leandro \
  --memory 4096 \
  --vcpus 2 \
  --disk "$IMG_STORE/leandro.qcow2,bus=virtio" \
  --import \
  --osinfo nixos-25.05 \
  --network network=default \
  --graphics none \
  --noautoconsole

echo "VM leandro started. Find its IP with:"
echo "  $VIRSH domifaddr leandro"
