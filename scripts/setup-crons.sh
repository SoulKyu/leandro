#!/usr/bin/env bash
# Provision Leandro's cron jobs. Run ONCE, directly on the VM (as the
# `leandro` user, or via `sudo -u leandro`), after nix/hermes.nix has been
# switched to at least once (cluster-snapshot.sh needs to already be copied
# into HERMES_HOME/scripts/ by its tmpfiles C+ rule):
#   scp scripts/setup-crons.sh leandro@<vm-ip>:/tmp/
#   ssh leandro@<vm-ip> bash /tmp/setup-crons.sh
# Only calls the `hermes` binary already on PATH — no repo checkout needed.
#
# Idempotent: each job has a fixed --name; re-running skips any job whose
# name already shows up in `hermes cron list --all`.
set -euo pipefail

existing="$(hermes cron list --all)"

create_if_missing() {
  local name="$1"
  shift
  if grep -q "Name:.*${name}$" <<<"${existing}"; then
    echo "skip (exists): ${name}"
    return 0
  fi
  echo "creating: ${name}"
  hermes cron create "$@" --name "${name}"
}

# Daily 08:00 — morning cluster briefing, always delivered.
create_if_missing "leandro-morning-briefing" \
  "0 8 * * *" \
  "Bilan matinal du cluster à partir du snapshot ci-dessus (nodes, pods, events Warning, PVC). Verdict en 1re ligne (RAS ou ce qui cloche), puis 2-3 lignes de détail seulement si une action est recommandée. Ce rapport doit TOUJOURS être livré : n'écris jamais SILENT ni NO_REPLY, sous aucune forme (le filtre de silence du gateway supprimerait le message)." \
  --script cluster-snapshot.sh \
  --deliver google_chat

# Daily 07:50 — silent watchdog: same snapshot, only speaks up if something
# is actually wrong. [SILENT] handling: gateway/response_filters.py's
# is_autonomous_silence_response() (used by cron/scheduler.py) suppresses
# delivery when the whole response is a bare marker, the marker sits alone
# on its own first/last line, or the response opens with "[SILENT]" —
# so an explicit "[SILENT]" first line is the safe, documented way to ask
# for silence here.
create_if_missing "leandro-silent-monitor" \
  "50 7 * * *" \
  "Examine le snapshot ci-dessus (nodes, pods, events Warning, PVC). Si rien d'anormal, réponds EXACTEMENT et uniquement par [SILENT] — rien d'autre. Si quelque chose nécessite attention, commence directement par le verdict (1-2 lignes), pas de [SILENT]." \
  --script cluster-snapshot.sh \
  --deliver google_chat

# Weekly Monday 09:00 — trend review, no script: pure session_search over
# the week's diagnoses (watcher incidents + chat sessions).
create_if_missing "leandro-weekly-review" \
  "0 9 * * 1" \
  "Revue de la semaine : utilise session_search pour lister les incidents de la semaine, dégage les récurrents et les tendances (pas juste une liste — qu'est-ce qui revient, qu'est-ce qui empire). Rapport concis." \
  --deliver google_chat

echo "Done. Check with: hermes cron list --all"
