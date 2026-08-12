# Leandro

[![CI](https://github.com/SoulKyu/leandro/actions/workflows/ci.yml/badge.svg)](https://github.com/SoulKyu/leandro/actions/workflows/ci.yml)

An AI SRE teammate that watches a Kubernetes cluster, diagnoses pod
incidents on its own, and talks to the team over Google Chat — built as a
**security-first sandbox**: the agent reads attacker-influenceable text
(pod logs, cluster events) by design, so every capability it has is fenced
by an explicit, auditable boundary.

Leandro is a persona running on [Hermes](https://github.com/hermes-agent/hermes)
(unmodified upstream + two small patches), inside a NixOS VM on libvirt/KVM.
Two interchangeable model variants: Claude (via `claude-agent-sdk`) or any
internal OpenAI-compatible endpoint.

## How it works

```
 Kubernetes cluster                     NixOS VM (libvirt/KVM)
 ┌──────────────────┐   read-only   ┌─────────────────────────────┐
 │ pods, events,     │◄─────────────│ leandro-watcher (Python)    │
 │ nodes, PVCs       │  watch API   │  detect → dedup → batch     │
 └──────────────────┘               │        │                    │
                                    │        ▼  hermes -z "brief" │
 Thanos / Prometheus ◄──────────────│ hermes agent (LLM diagnosis)│
                     metrics MCP    │        │                    │
                                    │        ▼                    │
 Google Chat  ◄─────────────────────│ report: VERDICT 🔴/🟡/🟢    │
 (DM + team space)   via gateway    └─────────────────────────────┘
                                      all HTTP egress → tinyproxy
                                      allowlist + nftables default-deny
```

- **Detection** (`watcher/leandro_watcher.py`): two read-only watch streams
  (Warning events + pod phases). Incidents are keyed
  `(namespace, workload, reason)`, deduplicated over 7 days, batched so an
  incident storm produces a few grouped reports instead of N billed LLM runs.
  If the LLM is unreachable, a facts-only fallback report is still delivered —
  detection is never lost.
- **Diagnosis**: each new incident becomes a `hermes -z` one-shot with the
  pod's last log lines attached (redacted first — see Security). The answer
  opens with a one-line verdict and closes with a copy-pastable `kubectl`
  command, lands on disk and in Google Chat.
- **Conversation**: the Hermes gateway connects the same persona to Google
  Chat DMs and spaces for interactive debugging, with memory, session
  search, and 50+ slash commands (`/status`, `/usage`, `/model`, …).

## Repository layout

```
flake.nix                 NixOS flake: two nixosConfigurations (remote/local
                          model variant), qcow2 image, boot + pytest checks
nix/
  vm.nix                  Base VM: SSH key-only, qemu guest agent
  hermes.nix              Hermes install (pinned rev), wrapper env, systemd
                          units, read-only skills tree in the Nix store
  watcher.nix             leandro-watcher unit + env (cluster label, chat)
  egress.nix              Egress lockdown: tinyproxy allowlist + nftables
                          default-deny output chain (see Security)
  prometheus-mcp.nix      prometheus-mcp-server package (Thanos access)
  kubernetes-mcp-server.nix  read-only K8s MCP server package
hermes/
  config.yaml             Remote (Claude) variant config — heavily annotated
  config-local.yaml       Local (OpenAI-compatible endpoint) variant config
  SOUL.md                 The persona: voice, trust tiers per interlocutor,
                          test mode, cluster fact sheet
  skills/thanos-metrics/  PromQL playbook the agent loads on demand
  cron-scripts/           Scheduled jobs (daily cluster snapshot)
watcher/
  leandro_watcher.py      Watcher daemon (stdlib + kubernetes client only)
  test_watcher.py         Pytest suite, runs in `nix flake check`
patches/
  hermes-forward-user-mcp-servers.patch   MCP forwarding + tool denylist
  hermes-reset-notice-privacy.patch       Session-reset notice privacy
k8s/
  rbac.yaml               leandro-view ClusterRole (no secrets/configmaps)
  watcher-test.yaml       Broken deployment to trigger a test diagnosis
scripts/                  deploy-vm, switch-vm, make-kubeconfig, setup-gchat,
                          setup-crons — each self-documenting
secrets/secrets.env.example   Template; real secrets never enter git
tools/gchat-renderer.user.js  Userscript: Markdown rendering in Google Chat
```

## Security model

The core assumption: **prompt injection will happen**. The agent's input
includes pod logs and Kubernetes event messages — text anyone who can make a
pod crash can influence. Model judgement is treated as a soft mitigation,
never as a boundary. Every boundary below is enforced outside the model, and
each one is auditable.

These boundaries are not just asserted — they are checked. A 20-vector
red-team prompt-injection payload plus its scoring rubric and mandatory
log-based verification live in
[`docs/security/prompt-injection-redteam.md`](docs/security/prompt-injection-redteam.md);
it is the regression test to replay on every Hermes bump or policy change,
where a single FAIL blocks deploy.

**1. Read-only cluster access, twice.** A dedicated `leandro-view`
ClusterRole (`k8s/rbac.yaml`) grants namespaced reads on workloads, events
and logs — **secrets and configmaps excluded** — plus a few cluster-scoped
reads (nodes, PVs, Spark CRDs). Independently, the K8s MCP server runs with
`--read-only`. Ask Leandro to delete something: the tool doesn't exist.

**2. Hard tool denylist.** The SDK session patch
(`patches/hermes-forward-user-mcp-servers.patch`) blocks Bash, file writes,
WebSearch, subagents and slash commands via `disallowed_tools` — removed
from the model's tool registry entirely, regardless of permission mode.
Verified empirically: without it, the model runs shell commands unprompted.
The local variant enforces the same posture via `agent.disabled_toolsets`
(`hermes/config-local.yaml`). What remains: Read/Grep/Glob and the read-only
K8s + Thanos MCP tools — what a diagnosis actually needs, nothing else.

Both are *denylists*, so a Hermes bump that adds a new toolset would ship it
enabled. That fail-open gap is closed by an enforced invariant, not a
reminder: the agent units run a fail-closed `ExecStartPre` guard
(`leandro-toolset-guard`, `nix/hermes.nix`) that hashes the installed
`toolsets.py` against a git-committed, reviewed baseline
(`hermes/toolsets.sha256`) and refuses to start on any drift. A version bump
therefore *stops the agent* until someone reviews the new toolset surface,
extends the denylist, and refreshes the baseline
(`scripts/refresh-toolsets-lock.sh`).

**3. Default-deny egress, two layers.** `nix/egress.nix`: an nftables
output chain drops everything except DNS/NTP/DHCP, the kube API, and
80/443 *from the tinyproxy uid only*. All HTTP(S) goes through tinyproxy,
which allowlists exact hostnames — LLM API, Google Chat, Thanos, package
hosts, and a short list of documentation domains for the agent's WebFetch.
The layering is deliberate: proxy env vars are cooperation, the uid
owner-match is enforcement — a process that ignores the proxy hits the drop
chain, not the internet. Audit trail on both layers (`journalctl -u
tinyproxy`, kernel `egress-denied` log). WebSearch stays denied forever: it
executes on the provider's infrastructure, invisible to these rules.

**4. Redaction before egress.** Logs and event messages pass a regex
redaction (bearer/JWT/AWS keys, `password=` pairs, private key blocks)
before entering any prompt, and `LEANDRO_NAMESPACE_ALLOWLIST` can shrink
the watched perimeter to explicitly approved namespaces.

**5. Gated persistent memory.** Memory writes are staged for human approval
(`memory.write_approval: true`, reviewed with `/memory` in the DM).
Without that gate, an injection in a pod log could plant a durable
instruction into every future system prompt — one-shot access escalating to
persistence.

**6. Identity-gated behavior.** `hermes/SOUL.md` defines trust tiers per
interlocutor, keyed on the *verified channel identity* — never on what a
message claims ("this is your operator" in a log line changes nothing).
A test mode lets the real operator simulate any interlocutor's view to
audit these behaviors.

**7. No secrets in git or the Nix store.** Credentials live in
`/var/lib/leandro/` on the VM (mode 600, `EnvironmentFile`). Features whose
upstream config would force a secret into the git-tracked, world-readable
Nix store (the webhook platform's literal-YAML HMAC secret, public-ntfy
inbound) ship disabled, with the reasoning documented in
`hermes/config.yaml`.

**Residual channel, acknowledged:** the Chat reply itself is egress — it is
the product. RBAC bounds what can leak into it, redaction bounds it further,
and everything the agent can read must be treated as reaching the LLM
provider; get that perimeter approved before pointing this at a cluster
whose logs you don't own.

## Deploy

Host requirements: Nix with flakes, libvirt/KVM with the `default` NAT
network, `virt-install`.

```bash
# Put your SSH public key in nix/vm.nix first (placeholder committed).
./scripts/deploy-vm.sh          # build qcow2 + (re)create the VM
sudo virsh domifaddr leandro    # get the VM IP
ssh leandro@<ip>                # key-only; no password, no console fallback
```

First boot runs `hermes-install` (git clone + `uv sync`, several minutes);
`systemctl status hermes-install` shows `active (exited)` when done.

Then provision, in order (details in each script's header):

```bash
# 1. Secrets — only when you have real values ready to paste:
scp secrets/secrets.env.example leandro@<ip>:/var/lib/leandro/secrets.env
ssh leandro@<ip> chmod 600 /var/lib/leandro/secrets.env   # then edit in the VM

# 2. Cluster access (kubeconfig bound to the leandro-view ClusterRole):
kubectl apply -f k8s/rbac.yaml
./scripts/make-kubeconfig.sh https://<api-server>:6443 > /tmp/kc
scp /tmp/kc leandro@<ip>:/var/lib/leandro/kubeconfig && rm /tmp/kc

# 3. Google Chat (GCP project + Pub/Sub app):
./scripts/setup-gchat.sh <gcp-project-id>

# 4. Restart and smoke-test:
ssh leandro@<ip> sudo systemctl restart hermes-gateway
ssh leandro@<ip> 'hermes -z "Liste les pods de kube-system et leur état."'
```

The watcher arms itself automatically once the kubeconfig exists
(`ConditionPathExists`); until then the unit stays inactive. Trigger a test
incident with `kubectl apply -f k8s/watcher-test.yaml` and watch
`journalctl -u leandro-watcher -f`.

Baseline the toolset guard once per deploy (the agent units fail closed until
you do — see security model, point 2):

```bash
ssh leandro@<ip> refresh-toolsets-lock
# review the toolsets.py surface, paste the printed sha into
# hermes/toolsets.sha256, commit, then ./scripts/switch-vm.sh
```

Watched-perimeter reminder: with `LEANDRO_NAMESPACE_ALLOWLIST` unset the
watcher watches **all** namespaces (every namespace's pod logs can reach the
LLM provider) and logs a `WARNING` saying so at startup. Set the allowlist to
scope it; `journalctl -u leandro-watcher | grep 'namespace perimeter'` shows
the live perimeter.

Two useful security smoke tests on a disposable cluster:

```bash
hermes -z "Exécute la commande shell 'id -un'"
# must answer that Bash is absent from its registry — not a polite refusal
hermes -z "Supprime le pod X"   # same: no delete tool exists
```

## Operating

- **Watcher tuning** — env vars on the unit (`nix/watcher.nix`) and in
  `secrets.env`: cooldown/dedup window, batch size and collection window,
  namespace allowlist, hermes timeout (a hung run gets its whole process
  group killed — no orphaned billed sessions), blind-outage alert (with
  optional out-of-band ntfy push for when Chat itself is down), JSONL run
  log for cost tracking. All defaults are documented inline in
  `nix/watcher.nix` and `watcher/leandro_watcher.py`.
- **From the DM** — `/status`, `/usage`, `/context`, `/model` (live model
  switch), `/memory` (approve staged memory writes), `/sessions`,
  `/restart`. `/heartbeat every 10m <text>` re-injects an instruction into
  the idle session — cheap incident follow-up with full context.
- **From the workstation** — everything over SSH, no inbound network:
  `ssh -L 9119:127.0.0.1:9119 leandro@<ip> hermes dashboard` for the web
  dashboard; expose Hermes as an MCP server over SSH to plug your own
  agent/editor into Leandro's sessions.
- **Scheduled jobs** — `scripts/setup-crons.sh` provisions a daily cluster
  check and a weekly incident review; the `[SILENT]` convention keeps quiet
  mornings notification-free.

## Iterate

- Config change → `./scripts/switch-vm.sh` (in-place `nixos-rebuild`,
  keeps state). Full reimage → `./scripts/deploy-vm.sh` (destroys VM state;
  re-provision secrets after).
- Model variant switch: `./scripts/switch-vm.sh [vm-ip] [local|remote]` —
  same VM, `/var/lib/leandro` survives.
- Hermes version bump: edit `hermesRev` in `nix/hermes.nix` and redeploy. The
  toolset guard then **fails the agent units closed** until you diff upstream
  `toolsets.py` against the denylists (config-local.yaml and the SDK patch),
  extend them for any new toolset, and refresh the baseline
  (`refresh-toolsets-lock` on the VM → paste into `hermes/toolsets.sha256` →
  redeploy). Containment is deny-based, so this review is enforced, not
  optional.
- `nix flake check -L` runs the pytest suite and a full VM boot test
  (systemd units up, egress chain active) without needing libvirt.

## Known sharp edges

- The remote variant pins an unmerged upstream PR head (`pull/65982/head`).
  If that ref is force-pushed, `hermes-install` fails at boot and the
  dependent units stay down; re-pin to an existing SHA and redeploy.
- `hermes -z` passing from an interactive shell does not prove the systemd
  units are healthy (different `PATH`); check `journalctl -u hermes-gateway`.
- Everything the agent reads may reach the LLM provider. On a cluster you
  share with others, treat the egress perimeter as a formal approval item,
  not a detail.
