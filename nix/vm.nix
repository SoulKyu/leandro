{ pkgs, ... }:
{
  networking.hostName = "leandro";
  networking.useDHCP = true;

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  services.qemuGuest.enable = true;

  users.users.leandro = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Replace with your own public key before deploying.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPLACEHOLDERxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx you@example.com"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # Required so `nixos-rebuild --target-host leandro@<ip>` can copy unsigned
  # closures to the VM. Takes effect from the next generation onward — the
  # deployed image predates this, so the *first* in-place switch needs the
  # one-time bootstrap documented in README.md.
  nix.settings.trusted-users = [ "root" "@wheel" ];
  system.stateVersion = "25.05";
}
