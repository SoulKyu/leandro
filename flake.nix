{
  description = "Leandro - Kubernetes debugger agent VM (NixOS + Hermes)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    # kubernetes-mcp-server v0.0.66 pins `go 1.26.3` in go.mod;
    # nixos-25.05 tops out at go_1_25. Pulled in solely to override buildGoModule's
    # `go` for that one package (see nix/kubernetes-mcp-server.nix).
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-generators }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
      # Built once here, where both nixpkgs are in scope; only the resulting
      # derivation crosses into the module system (see k8sMcpModule below), not
      # the full pkgsUnstable set.
      k8sMcp = pkgs.callPackage ./nix/kubernetes-mcp-server.nix { inherit pkgsUnstable; };
      promMcp = pkgs.callPackage ./nix/prometheus-mcp.nix { inherit pkgsUnstable; };
      # `hermes dashboard` builds its web UI with npm; upstream's engines pin
      # (node >=22.22.0, npm <11.10.0 || >=11.17.0) outgrew nixos-25.05's
      # nodejs_22 (22.20.0) — take it from unstable (22.23.2 / npm 10.9.8).
      nodejsHermes = pkgsUnstable.nodejs_22;
      # Injects the MCP servers as module args (not nixpkgs.overlays:
      # testers.runNixOSTest marks nixpkgs.pkgs/overlays read-only, so an
      # overlay module conflicts there).
      k8sMcpModule = {
        _module.args.k8sMcp = k8sMcp;
        _module.args.promMcp = promMcp;
        _module.args.nodejsHermes = nodejsHermes;
      };
      # modelVariant is threaded as a module arg like k8sMcp; the module-system
      # ignores nix/hermes.nix's function-arg default, so every consumer (incl.
      # the boot test below) must pass it explicitly.
      modulesFor = modelVariant: [
        ./nix/vm.nix ./nix/hermes.nix ./nix/watcher.nix ./nix/egress.nix k8sMcpModule
        { _module.args.modelVariant = modelVariant; }
      ];
      # One system per model variant (see nix/hermes.nix): "remote" =
      # claude-agent-sdk on the Anthropic PR pin, "local" = upstream release
      # tag on an internal OpenAI-compatible endpoint. Same VM, switched in place via
      # scripts/switch-vm.sh [local|remote] — state under /var/lib/leandro
      # survives the swap.
      mkLeandro = modelVariant: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = modulesFor modelVariant ++ [
          # Same disk/bootloader layout as the shipped image, so in-place
          # `nixos-rebuild switch --target-host` stays compatible with a VM
          # first booted from the qcow2. A raw import of formats/qcow.nix
          # fails to evaluate (it sets formatAttr/fileExtension without
          # declaring them); nixos-generators' pre-bundled module supplies
          # those options and is cheaper than evaluating every format.
          nixos-generators.nixosModules.qcow
        ];
      };
    in
    {
      nixosConfigurations.leandro = mkLeandro "remote";
      nixosConfigurations.leandro-local = mkLeandro "local";

      packages.${system}.qcow2 =
        self.nixosConfigurations.leandro.config.system.build.qcow;

      # Both checks live under one checks.${system}
      # binding — Nix can't merge two separate bindings that each index
      # with the same dynamic attribute (`${system}`).
      checks.${system} = {
        # python311Packages.kubernetes is broken in
        # nixpkgs 25.05 (sphinx FTBFS) — pkgs.python3 instead, matching
        # nix/watcher.nix's pythonEnv.
        watcher-tests = pkgs.runCommand "watcher-tests" {
          nativeBuildInputs = [
            (pkgs.python3.withPackages (ps: [ ps.pytest ps.kubernetes ps.requests ]))
          ];
        } ''
          cp ${./watcher}/leandro_watcher.py ${./watcher}/test_watcher.py .
          pytest test_watcher.py -v
          touch $out
        '';

        leandro-boots = pkgs.testers.runNixOSTest {
          name = "leandro-boots";
          nodes.machine = { imports = modulesFor "remote"; };
          testScript = ''
            machine.wait_for_unit("multi-user.target")
            machine.succeed("id leandro")
            machine.wait_for_unit("sshd.service")
            machine.succeed("uv --version")
            machine.succeed("command -v hermes")
            machine.succeed("systemctl cat hermes-install.service")
            # `systemctl cat` only shows the unit file, whose ExecStart= points
            # at a store path script — the flag lives in that script's body, so
            # resolve ExecStart's path= and grep the script it names instead.
            machine.succeed(
                "systemctl show -p ExecStart --value hermes-install.service"
                " | grep -oP 'path=\\K[^ ;]+' | xargs cat | grep -q -- '--extra claude-agent-sdk'"
            )
            machine.succeed("systemctl show -p Environment hermes-gateway.service | grep -q PATH")
            machine.succeed("test -d /var/lib/leandro/hermes-home")
            machine.succeed("kubernetes-mcp-server --version")
            machine.succeed("prometheus-mcp-server --help")
            machine.succeed("grep -q X-Oauth-Bypass-Token /etc/leandro/thanos-http.yaml")
            machine.succeed("test -L /var/lib/leandro/hermes-home/SOUL.md")
            machine.succeed("test -L /var/lib/leandro/hermes-home/skills")
            machine.succeed("test -f /var/lib/leandro/hermes-home/skills/thanos-metrics/SKILL.md")
            machine.succeed("grep -q read-only /var/lib/leandro/hermes-home/config.yaml")
            machine.succeed("systemctl cat hermes-gateway.service")
            machine.fail("systemctl is-active --quiet hermes-gateway.service")
            # Distinguish "inactive because ConditionPathExists is unmet" (intended)
            # from "inactive because it crash-looped and gave up" (regression) —
            # both make is-active fail, so assert the condition result directly.
            machine.succeed(
                'test "$(systemctl show -p ConditionResult --value hermes-gateway.service)" = no'
            )
            machine.succeed("systemctl cat leandro-watcher.service")
            machine.succeed(
                'test "$(systemctl show -p ConditionResult --value leandro-watcher.service)" = no'
            )
            # Egress lockdown (nix/egress.nix). The test VM has no network, but
            # tinyproxy filters the hostname BEFORE resolving/connecting, so the
            # 403 on a non-allowlisted domain is hermetic.
            machine.wait_for_unit("tinyproxy.service")
            machine.succeed("nft list ruleset | grep -q egress-denied")
            machine.succeed(
                "test \"$(curl -s -o /dev/null -w '%{http_code}' -x http://127.0.0.1:8888 http://example.com/)\" = 403"
            )
            machine.succeed("systemctl show -p Environment hermes-gateway.service | grep -q HTTPS_PROXY")
            machine.succeed("systemctl show -p Environment hermes-install.service | grep -q HTTPS_PROXY")
          '';
        };
      };
    };
}
