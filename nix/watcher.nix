{ pkgs, ... }:
let
  stateDir = "/var/lib/leandro";
  # python311Packages.kubernetes is broken in nixpkgs
  # 25.05 (sphinx FTBFS building its docs). The watcher is 3.11+-compatible
  # and runs fine on pkgs.python3's newer interpreter, so the watcher's own
  # env moves off python311 — only the hermes wrapper (path below) stays
  # pinned to 311, since UV_PYTHON is hardcoded there (nix/hermes.nix).
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.kubernetes ps.requests ]);
in
{
  systemd.tmpfiles.rules = [
    "d ${stateDir}/incidents 0750 leandro users -"
  ];

  systemd.services.leandro-watcher = {
    description = "Leandro cluster watcher (read-only detection + diagnosis)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "hermes-install.service" ];
    wants = [ "network-online.target" ];
    requires = [ "hermes-install.service" ];
    unitConfig = {
      # Useless without cluster access; stays quiet until the read-only
      # kubeconfig is provisioned.
      ConditionPathExists = "${stateDir}/kubeconfig";
    };
    # hermes wrapper needs uv + git at run time; UV_PYTHON inside the wrapper
    # itself pins python311 (nix/hermes.nix), so that stays on PATH too.
    path = [ pkgs.uv pkgs.git pkgs.python311 ];
    serviceConfig = {
      User = "leandro";
      Environment = [
        "HOME=${stateDir}"
        "KUBECONFIG=${stateDir}/kubeconfig"
        "LEANDRO_HERMES_BIN=/run/current-system/sw/bin/hermes"
        # Diagnoses go to Google Chat via `hermes send -t google_chat`.
        # LEANDRO_ALERT_CHANNEL redirects THIS unit's deliveries to the team
        # space "Infra - DevOps" — the hermes wrapper (nix/hermes.nix)
        # applies it over GOOGLE_CHAT_HOME_CHANNEL after sourcing secrets.env.
        # Safe from EnvironmentFile precedence: the variable does not exist in
        # secrets.env. Gateway and cron deliveries keep the operator DM.
        "LEANDRO_CHAT_TARGET=google_chat"
        "LEANDRO_ALERT_CHANNEL=spaces/AAAAexampleID"
        # Display-only cluster label in heads-up messages — matches the
        # k8s_cluster label used by Thanos so alerts and metrics agree.
        "LEANDRO_CLUSTER_NAME=prod-cluster-1"
      ];
      EnvironmentFile = "-${stateDir}/secrets.env";
      # Fail closed if the installed Hermes toolset surface drifted from the
      # reviewed baseline (nix/hermes.nix leandro-toolset-guard) — the watcher
      # spawns `hermes -z` per incident, so it inherits the same tool posture.
      ExecStartPre = "/run/current-system/sw/bin/leandro-toolset-guard";
      ExecStart = "${pythonEnv}/bin/python ${../watcher/leandro_watcher.py}";
      Restart = "always";
      RestartSec = 30;

      # The watcher feeds attacker-influenceable text (pod logs, k8s event
      # messages) into an LLM and shells out to `hermes`. Blast radius stays
      # inside the state dir even if that subprocess is turned against us.
      # ProtectSystem=strict makes the whole filesystem read-only, so the one
      # writable path has to be declared: /var/lib/leandro holds the incident
      # reports, the dedup state, and HERMES_HOME.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/leandro" ];
      ProtectHome = "read-only";
    };
  };
}
