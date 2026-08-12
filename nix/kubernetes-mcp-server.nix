{ pkgs, pkgsUnstable }:
# Upstream go.mod pins `go 1.26.3`, newer than the
# go_1_25 ceiling in the pinned nixos-25.05 nixpkgs. pkgsUnstable (nixpkgs-unstable,
# threaded in from flake.nix) supplies go_1_26 — buildGoModule's own `go` is
# overridden here rather than bumping the whole flake's nixpkgs.
(pkgs.buildGoModule.override { go = pkgsUnstable.go_1_26; }) rec {
  pname = "kubernetes-mcp-server";
  version = "0.0.66";

  src = pkgs.fetchFromGitHub {
    owner = "containers";
    repo = "kubernetes-mcp-server";
    rev = "v${version}";
    hash = "sha256-vnJxSCfnpvOZJXQpKrCAW4QKt5R2PJDYQevA7O1uXZg="; # kubernetes-mcp-server v0.0.66 source
  };

  vendorHash = "sha256-gbqoT4X+wVOEktHm7jaAH9vHrUBrYgR8OjyFz1ljP6k="; # kubernetes-mcp-server v0.0.66 go modules

  subPackages = [ "cmd/kubernetes-mcp-server" ];
  doCheck = false; # upstream tests need a cluster
}
