#!/usr/bin/env bash
# In-place update of the running "leandro" VM: builds the new system closure
# and activates it over SSH. State under /var/lib/leandro (secrets, hermes
# memory) is untouched — unlike deploy-vm.sh, which reimages from scratch.
set -euo pipefail

PATH="/nix/var/nix/profiles/default/bin:$PATH"

cd "$(dirname "$0")/.."

# Args, any order: an IP, and/or a model variant (local|remote).
# remote (default) = claude-agent-sdk on the Anthropic PR pin;
# local = upstream release on an internal OpenAI-compatible endpoint (see nix/hermes.nix).
VARIANT="remote"
IP=""
for arg in "$@"; do
  case "$arg" in
    local|remote) VARIANT="$arg" ;;
    *) IP="$arg" ;;
  esac
done
TARGET="leandro"
[ "$VARIANT" = "local" ] && TARGET="leandro-local"

if [ -z "$IP" ]; then
  IP=$(sudo virsh domifaddr leandro | awk '/ipv4/ {sub(/\/.*/, "", $4); print $4}')
fi
[ -n "$IP" ] || { echo "usage: switch-vm.sh [vm-ip] [local|remote] (auto-detect failed)"; exit 1; }

echo "Switching leandro VM at $IP to variant '$VARIANT' (flake target .#$TARGET) ..."
# --use-remote-sudo is deprecated in nixos-rebuild-ng but REQUIRED here: the
# ng wrapper re-execs into the flake's legacy 25.05 nixos-rebuild script,
# which does not know --sudo/--elevate. Do not "modernize" this flag.
nix run ".#nixosConfigurations.${TARGET}.config.system.build.nixos-rebuild" -- switch \
  --flake ".#${TARGET}" \
  --target-host "leandro@${IP}" \
  --use-remote-sudo

echo "Done. Sanity:"
ssh "leandro@${IP}" "systemctl is-active hermes-install || true; hermes --help >/dev/null 2>&1 && echo 'hermes: OK'"
