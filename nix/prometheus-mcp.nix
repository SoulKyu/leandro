{ pkgs, pkgsUnstable }:
# Official Prometheus MCP server (ex-tjhop/prometheus-mcp-server, donated to
# the prometheus org — module path still github.com/tjhop/...). Queries the
# internal Thanos through its Prometheus-compatible HTTP API.
# Same go_1_26 override story as kubernetes-mcp-server.nix: upstream go.mod
# pins go 1.26, above the go_1_25 ceiling in nixos-25.05.
(pkgs.buildGoModule.override { go = pkgsUnstable.go_1_26; }) rec {
  pname = "prometheus-mcp-server";
  version = "0.18.0";

  src = pkgs.fetchFromGitHub {
    owner = "prometheus";
    repo = "prometheus-mcp";
    rev = "v${version}";
    # The binary go:embeds cmd/prometheus-mcp-server/external/docs, which is a
    # git submodule (pinned prometheus/docs snapshot) — without it the embed
    # directive fails the build with "no matching files".
    fetchSubmodules = true;
    hash = "sha256-67pkE28hbORN+etTkon4u9HzWTKL0K1q0GNp8X2Oaqo="; # prometheus-mcp v0.18.0 source
  };

  vendorHash = "sha256-QAny2SDYHaUHgiUn0KNesDmwfwh5NWpUB3FtwsB2g/I="; # prometheus-mcp v0.18.0 go modules

  subPackages = [ "cmd/prometheus-mcp-server" ];
  doCheck = false; # tests hit a live Prometheus via mock servers; skip like k8s-mcp
}
