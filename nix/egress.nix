{ config, lib, pkgs, ... }:
# Egress lockdown, phase 1.
# Two deliberate layers: tinyproxy's domain allowlist is the policy, the
# nftables owner-match is the enforcement — a process ignoring proxy env vars
# hits the default-deny output chain, not the internet.
let
  cfg = config.leandro.egress;
  proxyUrl = "http://127.0.0.1:8888";

  # One anchored extended-regex per line: `^github\.com$` — unanchored,
  # `evil-github.com` would match `github.com`.
  filterFile = pkgs.writeText "tinyproxy-allowlist"
    (lib.concatMapStrings (d: "^${lib.escapeRegex d}$\n") cfg.allowedDomains);

  # 10.100.0.1 = kube API (direct L3 rule below), 192.168.122.1 = libvirt
  # host bridge (DNS, disposable-cluster APIs in tests).
  noProxy = "127.0.0.1,localhost,10.100.0.1,192.168.122.1";
  proxyEnv = {
    HTTP_PROXY = proxyUrl;
    HTTPS_PROXY = proxyUrl;
    http_proxy = proxyUrl; # grpc (pubsub) reads the lowercase form
    https_proxy = proxyUrl;
    NO_PROXY = noProxy;
    no_proxy = noProxy;
  };
in
{
  options.leandro.egress = {
    enforce = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        true = default-deny: drop any outbound packet not allowlisted below
        (log stays on). false = log-only: same rules, policy accept — used to
        audit the wiring before flipping the drop.
      '';
    };
    allowedDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Exact hostnames tinyproxy lets through. Phase 2 = append doc domains here.";
      default = [
        # LLM providers
        "api.anthropic.com" # remote variant — every diagnosis
        "console.anthropic.com" # claude CLI OAuth token refresh
        "llm.internal.example.com" # local variant LLM endpoint
        # Metrics
        "thanos.internal.example.com"
        # Google Chat gateway (pull + send + auth)
        "pubsub.googleapis.com"
        "chat.googleapis.com"
        "oauth2.googleapis.com"
        "www.googleapis.com"
        # hermes-install: clone/fetch + uv sync
        "github.com"
        "codeload.github.com"
        "objects.githubusercontent.com"
        "raw.githubusercontent.com"
        "pypi.org"
        "files.pythonhosted.org"
        # Blind outbound alert when the LLM provider is down (LEANDRO_NTFY_URL)
        "ntfy.sh"
        # Phase 2 — upstream documentation, fetched FROM the VM so this proxy
        # constrains it. Exact hosts: tinyproxy matching is anchored,
        # subdomains must be spelled out.
        "kubernetes.io"
        "spark.apache.org"
        "yunikorn.apache.org"
        "celeborn.apache.org"
        "kyverno.io"
        "cilium.io"
        "docs.cilium.io" # Cilium docs live on the subdomain
        "etcd.io"
      ];
    };
  };

  config = {
    services.tinyproxy = {
      enable = true;
      settings = {
        Listen = "127.0.0.1";
        Port = 8888;
        Allow = "127.0.0.1";
        Filter = filterFile;
        FilterType = "ere";
        FilterDefaultDeny = true;
        ConnectPort = 443; # CONNECT is for TLS only; plain :80 goes as proxied GET
        LogLevel = "Connect"; # journal = the audit trail (foreground mode logs to stdout)
      };
    };

    # Swaps the NixOS firewall to the nftables backend; the firewall keeps
    # owning the input chain (SSH stays open via services.openssh), this
    # table only adds an output chain.
    networking.nftables.enable = true;
    # The build-sandbox `nft --check` has no tinyproxy user in its passwd —
    # substitute one it does have, keeping the syntax check (upstream's
    # documented escape hatch for exactly this).
    networking.nftables.preCheckRuleset = "sed 's/skuid tinyproxy/skuid nobody/g' -i ruleset.conf";
    networking.nftables.tables.leandro-egress = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy ${if cfg.enforce then "drop" else "accept"};
          oifname "lo" accept
          ct state established,related accept
          udp dport 67 accept comment "DHCP renew (useDHCP) — lose this, lose the lease"
          icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit } accept
          ip daddr 192.168.122.1 udp dport 53 accept
          ip daddr 192.168.122.1 tcp dport 53 accept
          udp dport 123 accept comment "NTP (systemd-timesyncd)"
          ip daddr 10.100.0.1 tcp dport 6443 accept comment "kube API — also in NO_PROXY"
          meta skuid tinyproxy tcp dport { 80, 443 } accept
          limit rate 5/second burst 20 packets log prefix "egress-denied: "
        }
      '';
      # No drop verdict on the log rule: the chain policy is the verdict, so
      # `enforce` flips exactly one word and log-only mode needs no second rule.
    };

    # Units that talk to the network without going through the hermes wrapper
    # (git/uv in install's script, python watcher). The wrapper itself exports
    # the same vars (nix/hermes.nix) for gateway/one-shot/interactive paths.
    # after+wants tinyproxy: with proxy env set, 127.0.0.1:8888 down = no
    # network at all — hermes-install fails hard on git fetch (seen live).
    systemd.services.hermes-install = {
      environment = proxyEnv;
      after = [ "tinyproxy.service" ];
      wants = [ "tinyproxy.service" ];
    };
    systemd.services.hermes-gateway = {
      environment = proxyEnv;
      after = [ "tinyproxy.service" ];
      wants = [ "tinyproxy.service" ];
    };
    systemd.services.leandro-watcher = {
      environment = proxyEnv;
      after = [ "tinyproxy.service" ];
      wants = [ "tinyproxy.service" ];
    };

    environment.systemPackages = [ pkgs.curl ]; # egress verification
  };
}
