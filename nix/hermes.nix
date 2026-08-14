{ pkgs, k8sMcp, promMcp, modelVariant, nodejsHermes, ... }:
let
  # Two variants, selected by `modelVariant` (flake.nix module arg):
  # - "remote" (default): head of PR #65982 (claude-agent-sdk runtime,
  #   subscription-accounted). Fetched via the PR ref on the main repo;
  #   re-pin deliberately after upstream rebases; drop the pull-ref dance
  #   once the PR merges.
  # - "local": latest upstream release tag, native Hermes runtime against the
  #   internal OpenAI-compatible endpoint (hermes/config-local.yaml). No patch, no
  #   claude-agent-sdk extra. On bump: diff upstream toolsets.py against the
  #   disabled_toolsets denylist in config-local.yaml, enforced closed by
  #   leandro-toolset-guard below (drift from the reviewed baseline fails the
  #   agent units at start).
  isLocal = modelVariant == "local";
  hermesRev =
    if isLocal
    then "3c27eb6234bf91b8ceee9e9071591b31e9b148cb" # tag v2026.8.3
    else "77456cee9bbeeab823212d5a91117e3927929482";
  hermesFetchRef = if isLocal then "refs/tags/v2026.8.3" else "pull/65982/head";
  hermesConfig = if isLocal then ../hermes/config-local.yaml else ../hermes/config.yaml;
  hermesRepo = "https://github.com/NousResearch/hermes-agent";
  stateDir = "/var/lib/leandro";

  # Fail-closed toolset invariant. The tool denylists (disabled_toolsets in
  # config-local.yaml, disallowed_tools in the SDK patch) are the only barrier
  # between an unattended agent reading attacker-influenceable pod logs and a
  # shell/egress tool — and they are DENYLISTS: a Hermes bump that adds a new
  # toolset ships it enabled. This guard turns "diff toolsets.py on every bump"
  # from a remembered step into an enforced one: it hashes the installed
  # toolsets.py against a git-committed, reviewed baseline and refuses to start
  # the agent units on any drift (or if the file or baseline is missing).
  # Ceiling: whole-file hash, so a benign edit inside toolsets.py also trips it
  # — intended conservatism (any change to the tool-defining file gets a look).
  # Refresh the baseline with scripts/refresh-toolsets-lock.sh after reviewing.
  toolsetGuard = pkgs.writeShellScriptBin "leandro-toolset-guard" ''
    set -euo pipefail
    src="${stateDir}/hermes-src"
    baseline="/etc/leandro/toolsets.sha256"
    ts=$(${pkgs.findutils}/bin/find "$src" -name toolsets.py -print -quit 2>/dev/null || true)
    if [ -z "$ts" ]; then
      echo "toolset-guard: toolsets.py not found under $src — refusing to start (fail closed)." >&2
      exit 1
    fi
    want=$(${pkgs.coreutils}/bin/tr -d '[:space:]' < "$baseline" 2>/dev/null || true)
    case "$want" in
      ""|REPLACE_ME*)
        echo "toolset-guard: baseline not set. Run scripts/refresh-toolsets-lock.sh on the VM, commit hermes/toolsets.sha256, redeploy." >&2
        exit 1 ;;
    esac
    got=$(${pkgs.coreutils}/bin/sha256sum "$ts" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
      echo "toolset-guard: $ts changed vs reviewed baseline ($got != $want)." >&2
      echo "Upstream toolset surface moved. Diff it, extend the denylist (disabled_toolsets / the SDK patch), then refresh hermes/toolsets.sha256 and redeploy." >&2
      exit 1
    fi
    echo "toolset-guard: toolsets.py matches reviewed baseline ($got)."
  '';

  # Operator helper (run on the VM after a Hermes bump): print the installed
  # toolsets.py hash to paste into hermes/toolsets.sha256 once the new toolset
  # surface has been reviewed and the denylist extended. GitOps: the baseline
  # is committed in the repo, not written to the VM.
  refreshToolsetsLock = pkgs.writeShellScriptBin "refresh-toolsets-lock" ''
    set -euo pipefail
    src="''${1:-${stateDir}/hermes-src}"
    ts=$(${pkgs.findutils}/bin/find "$src" -name toolsets.py -print -quit 2>/dev/null || true)
    [ -n "$ts" ] || { echo "toolsets.py not found under $src" >&2; exit 1; }
    sha=$(${pkgs.coreutils}/bin/sha256sum "$ts" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
    echo "toolsets.py: $ts"
    echo "sha256:      $sha"
    echo
    echo "Reviewed the diff and extended the denylist? Put this in hermes/toolsets.sha256:"
    echo "$sha"
  '';

  hermesWrapper = pkgs.writeShellScriptBin "hermes" ''
    set -euo pipefail
    export HERMES_HOME="${stateDir}/hermes-home"
    export UV_PYTHON="${pkgs.python311}/bin/python3.11"
    # Two loader worlds need the nix-ld lib farm (libstdc++, zlib…):
    # - NIX_LD_LIBRARY_PATH: manylinux ELFs run via nix-ld (bundled claude CLI)
    # - LD_LIBRARY_PATH: C-extension wheels (grpcio) dlopen'd by the Nix-built
    #   python, whose glibc loader ignores nix-ld entirely
    export NIX_LD_LIBRARY_PATH="/run/current-system/sw/share/nix-ld/lib''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH="/run/current-system/sw/share/nix-ld/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    # Egress lockdown (nix/egress.nix): all HTTP(S) goes through the local
    # allowlist proxy — nftables owner-match drops anything going direct.
    # grpc (pubsub) reads the lowercase form; node/claude CLI the upper.
    export HTTP_PROXY="http://127.0.0.1:8888" HTTPS_PROXY="http://127.0.0.1:8888"
    export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY"
    export NO_PROXY="127.0.0.1,localhost,10.100.0.1,192.168.122.1"
    export no_proxy="$NO_PROXY"
    if [ -f ${stateDir}/secrets.env ]; then
      set -a; . ${stateDir}/secrets.env; set +a
    fi
    # Per-service delivery override: secrets.env always wins over the caller's
    # environment (sourced above), so a service that must deliver somewhere
    # other than the operator DM cannot just export GOOGLE_CHAT_HOME_CHANNEL.
    # LEANDRO_ALERT_CHANNEL is deliberately NOT in secrets.env — set it in a
    # systemd unit (see watcher.nix) to redirect that unit's `hermes send`
    # home-channel deliveries. Needed because `hermes send` explicit space
    # targets are broken upstream for google_chat (_parse_target_ref has no
    # google_chat rule → resolved directory ids lose their chat_id and fall
    # back to the home channel silently).
    if [ -n "''${LEANDRO_ALERT_CHANNEL:-}" ]; then
      export GOOGLE_CHAT_HOME_CHANNEL="''${LEANDRO_ALERT_CHANNEL}"
    fi
    exec ${pkgs.uv}/bin/uv run --frozen --no-sync --directory ${stateDir}/hermes-src hermes "$@"
  '';
in
{
  # Hermes pulls manylinux wheels (pydantic-core etc.); nix-ld lets them run on NixOS
  programs.nix-ld.enable = true;
  # grpcio (google-cloud-pubsub) links libstdc++.so.6 — discovered when the
  # Google Chat adapter failed its import check (see README nix-ld note).
  programs.nix-ld.libraries = with pkgs; [ stdenv.cc.cc.lib zlib ];

  # Thanos sits behind oauth2-proxy; the bypass is a custom header whose value
  # lives in /var/lib/leandro/thanos-bypass-token (provisioned by hand next to
  # secrets.env, never in git). This client config carries no secret itself —
  # prometheus/common reads the header value from the file at request time —
  # so a world-readable /etc path is fine.
  environment.etc."leandro/thanos-http.yaml".text = ''
    # proxy_url, not env vars: prometheus/common builds its client from THIS
    # file and ignores HTTPS_PROXY (proxy_from_environment defaults false) —
    # under the egress lockdown a direct dial to thanos is dropped and every
    # query dies on "context deadline exceeded" (found live; MCP servers are
    # also spawned with a sanitized env, so env vars were doubly unreliable).
    proxy_url: http://127.0.0.1:8888
    http_headers:
      X-Oauth-Bypass-Token:
        files:
          - /var/lib/leandro/thanos-bypass-token
  '';

  # Git-committed toolset baseline (see toolsetGuard above). Symlinked
  # read-only from the store; refresh via scripts/refresh-toolsets-lock.sh.
  environment.etc."leandro/toolsets.sha256".source = ../hermes/toolsets.sha256;

  environment.systemPackages = with pkgs; [
    hermesWrapper
    toolsetGuard
    refreshToolsetsLock
    k8sMcp
    promMcp
    uv
    git
    nodejsHermes # unstable nodejs_22 — hermes web UI engines pin, see flake.nix
    ripgrep
    ffmpeg
    python311
    kubectl # cron-scripts/ (cluster-snapshot.sh etc.) shell out to kubectl
  ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 leandro users -"
    "d ${stateDir}/hermes-home 0700 leandro users -"
    # Skills: whole tree symlinked read-only into the store. This is a
    # security control, not just packaging — it lets the `skills` toolset stay
    # enabled (read via skills_list/skill_view) while skill_manage's writes
    # die on the read-only store (EROFS, fail closed). skill_view trusts the
    # symlink: skills_tool.py resolves BOTH the skills root and the skill file
    # before its relative_to() containment check, so both land in the store
    # (unlike cron/scheduler.py, which resolves only the script — that's why
    # cron scripts are copied, see below).
    "L+ ${stateDir}/hermes-home/skills - - - - ${../hermes/skills}"

    # L+ symlinks into the Nix store: SOUL.md/config.yaml are read-only.
    # Hermes's atomic_replace() resolves symlinks before writing, so any
    # runtime attempt to persist config there would target the read-only
    # store and fail — upstream swallows that error silently instead of
    # surfacing it. Config changes must go through git + redeploy, never
    # through Hermes's own runtime config-write path.
    "L+ ${stateDir}/hermes-home/SOUL.md - - - - ${../hermes/SOUL.md}"
    "L+ ${stateDir}/hermes-home/config.yaml - - - - ${hermesConfig}"

    # Cron scripts dir only — the copy itself happens in hermes-install (see
    # below). A real copy is required, not a symlink: cron/scheduler.py's
    # _run_job_script() resolves the script path with Path.resolve() and
    # rejects anything outside HERMES_HOME/scripts/ via relative_to() — an L+
    # symlink into the Nix store resolves to /nix/store/... and gets blocked.
    # And tmpfiles C+ is NOT an option: systemd copies only when the
    # destination does not exist yet (COPY_MERGE — verified against systemd
    # v257 tmpfiles.c and empirically), so a script update would never
    # reach the VM through tmpfiles.
    "d ${stateDir}/hermes-home/scripts 0750 leandro users -"
  ];

  systemd.services.hermes-install = {
    description = "Checkout and uv-sync Hermes at pinned revision";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ git uv python311 coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "leandro";
      Environment = [
        "HOME=${stateDir}"
        "UV_PYTHON=${pkgs.python311}/bin/python3.11"
      ];
    };
    script = ''
      set -euo pipefail
      cd ${stateDir}
      if [ ! -d hermes-src/.git ]; then
        git init hermes-src
        git -C hermes-src remote add origin ${hermesRepo}
      fi
      git -C hermes-src fetch --depth 1 origin ${hermesFetchRef}
      # -f: the tree is dirty whenever the previous variant applied the local
      # patch — a plain checkout to a *different* rev refuses to overwrite the
      # patched file (same-rev re-runs never hit this). reset --hard below
      # re-cleans on top.
      git -C hermes-src -c advice.detachedHead=false checkout -f ${hermesRev}
      git -C hermes-src reset --hard ${hermesRev}
      ${pkgs.lib.optionalString (!isLocal) ''
        # Local patch until upstreamed to PR #65982: forward config.yaml
        # mcp_servers into the SDK session (otherwise Leandro has no K8s tools).
        # The local variant runs a release tag whose native runtime reads
        # mcp_servers directly — no patch needed (and it wouldn't apply).
        git -C hermes-src apply ${../patches/hermes-forward-user-mcp-servers.patch}
        # Reset-notice privacy: gate the gateway-emitted model/provider block
        # behind reset_notice_session_info (config.yaml sets it false).
        # Remote-only: crafted against PR #65982's gateway/{config,run}.py
        # line context; the local release tag differs. Drop once #83344 lands
        # and the pin advances past it.
        git -C hermes-src apply ${../patches/hermes-reset-notice-privacy.patch}
      ''}
      # Google Chat thread targeting for `hermes send` (both variants, applies
      # cleanly to the PR head and the release tag): upstream's standalone send
      # path never parses the ":<thread>" part of a google_chat target and
      # omits messageReplyOption, so the API silently ignores thread.name.
      # Lets the watcher chain heads-up + report into one thread. Upstreamable
      # as a bugfix PR; drop once merged.
      git -C hermes-src apply ${../patches/hermes-gchat-thread-targeting.patch}
      cd hermes-src
      # Load-bearing extras — default `uv sync` omits them (and would
      # uninstall a lazy install on the next sync):
      # - remote: claude-agent-sdk, the provider runtime itself.
      # - local: mcp, the client SDK for config.yaml mcp_servers (upstream's
      #   documented path is a runtime lazy-install via `hermes setup`;
      #   without it the K8s server silently registers 0 tools and Leandro
      #   diagnoses blind — found empirically, `hermes mcp test kubernetes`).
      uv sync --frozen --extra ${if isLocal then "mcp" else "claude-agent-sdk"}
      # google_chat's pubsub/api-client deps (google-cloud-pubsub etc.) are
      # not in uv.lock at all; upstream's documented install path is this
      # oauth --install-deps command, not a lockfile extra.
      uv run --frozen --no-sync python -m plugins.platforms.google_chat.oauth --install-deps
      # Egress lockdown: httplib2 (googleapiclient transport in the google_chat
      # adapter) parses proxy env vars but silently connects DIRECT unless a
      # socks module is importable (`import socks` → `socks = None` fallback) —
      # under nftables default-deny that killed the Chat adapter (30s connect
      # timeout at gateway start, found live). requests/grpc need nothing.
      # After `uv sync` on purpose: sync prunes non-lockfile packages.
      # --python .venv: the unit's UV_PYTHON would otherwise aim uv pip at the
      # immutable Nix store interpreter (externally-managed error).
      uv pip install --python .venv pysocks
      # Cron scripts: install (not tmpfiles C+, which never overwrites an
      # existing file) so content updates deploy — the store path changes
      # with the content, the unit changes, systemd re-runs this script.
      install -m 0750 ${../hermes/cron-scripts/cluster-snapshot.sh} \
        ${stateDir}/hermes-home/scripts/cluster-snapshot.sh
    '';
  };

  systemd.services.hermes-gateway = {
    description = "Hermes gateway (Google Chat via Pub/Sub pull)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "hermes-install.service" ];
    wants = [ "network-online.target" ];
    requires = [ "hermes-install.service" ];
    unitConfig = {
      # Gateway is useful only with (a) secrets and (b) a provisioned Google
      # Chat service account. Without gchat-sa.json it would crash-loop on
      # placeholder values every RestartSec.
      ConditionPathExists = [ "${stateDir}/secrets.env" "${stateDir}/gchat-sa.json" ];
    };
    path = with pkgs; [ uv git python311 k8sMcp ];
    serviceConfig = {
      User = "leandro";
      Environment = [ "HOME=${stateDir}" ];
      # Fail closed if the upstream toolset surface drifted from the reviewed
      # baseline before the agent ever handles a message (see toolsetGuard).
      ExecStartPre = "${toolsetGuard}/bin/leandro-toolset-guard";
      ExecStart = "${hermesWrapper}/bin/hermes gateway";
      Restart = "always";
      RestartSec = 15;

      # Mirrors leandro-watcher's sandbox (nix/watcher.nix): the gateway runs
      # the same LLM-driven agent against attacker-influenceable Chat input,
      # so it gets the same blast-radius containment. /var/lib/leandro holds
      # secrets.env, the kubeconfig, and HERMES_HOME — the one path that
      # legitimately needs to be writable.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/leandro" ];
      ProtectHome = "read-only";
    };
  };
}
