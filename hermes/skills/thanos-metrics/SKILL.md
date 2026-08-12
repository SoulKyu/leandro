---
name: thanos-metrics
description: "Playbook metrics Thanos pour prod-cluster-1 : recording rules Spark (spark_app:*, spark_native:*), SLIs spark-operator, drill-down plateforme en 11 couches, idiomes PromQL. À charger avant tout diagnostic metrics non trivial."
version: 1.0.0
metadata:
  hermes:
    tags: [thanos, prometheus, promql, spark, kubernetes, metrics]
---

# Thanos metrics — prod-cluster-1

Distillé des 14 dashboards Grafana du folder « spark-on-kubernetes »
(2026-08-10). Queries exactes prêtes à copier dans `references/queries.md`.

## Syntaxe EXACTE des tools (les erreurs d'arguments ici sont la 1ʳᵉ cause
## de faux « server unreachable »)

- **Timestamps** (`timestamp`, `start_time`, `end_time`) : epoch Unix,
  RFC3339, ou **durée relative à maintenant** (`"5m"`, `"1h30m"` = il y a
  5 min / 1 h 30). ⚠️ `"now"` N'EST PAS VALIDE — pour « maintenant »,
  **omets le champ** (c'est le défaut).
- `query` : `{query}` + `timestamp` optionnel. ⚠️ le champ s'appelle
  `timestamp`, PAS `time`.
- `range_query` : `{query, start_time}` + `end_time` (omis = now) + `step`
  optionnel (format Go : `"30s"`, `"5m"`).
- `series` : `{matches: ["kube_pod_info{namespace=\"spark\"}"]}` (requis,
  liste) + start/end optionnels. ⚠️ uniquement des sélecteurs simples —
  aucune expression PromQL (pas de `/`, `sum()`, comparaisons) : pour ça,
  utilise `query`.
- **Si un appel échoue en < 1 s avec une erreur de parsing/validation, ton
  ARGUMENT est faux — le serveur va bien.** Trois erreurs d'arguments
  d'affilée déclenchent un message « MCP server unreachable » : c'est un
  faux positif du circuit breaker, pas une panne. Corrige l'argument et
  continue, ne bascule pas sur un plan B.

## Conventions de labels

- `k8s_cluster="prod-cluster-1"` — obligatoire sur toute query K8s :
  ce Thanos est global multi-clusters.
- Pods Spark : `namespace="spark"`, containers `container=~"spark-kubernetes-.*"`,
  drivers `pod=~".+-driver"`, executors `pod=~".+-exec-.+"`.
- Séries éphémères : les jobs Spark naissent et meurent — une query
  instantanée vide ne prouve rien, élargis avec `range_query`/`max_over_time`.

## Recording rules (pré-jointes par app — TOUJOURS les préférer)

Labels portés : `spark_app`, `spark_role` (driver|executor), `pod`.

- `spark_app:container_cpu_usage:cores` / `_cpu_request:cores` /
  `_cpu_limit:cores` / `_cpu_throttled:ratio`
- `spark_app:container_memory_working_set:bytes` / `_memory_request:bytes` /
  `_memory_limit:bytes`
- `spark_native:executor_jvm_heap:bytes`, `_rss:bytes`, `_gc_time:rate`,
  `_active_tasks`, `_completed_tasks:rate`, `_failed_tasks:rate`,
  `_shuffle_read:rate`, `_shuffle_write:rate`, `_input_read:rate`

Pas besoin de jointure `kube_pod_labels` avec ces métriques.

## SLIs plateforme Spark (spark-operator)

- Compteurs : `spark_application_{running,submit,success,failure,failed_submission}_count`
  et `spark_executor_running_count` — en `increase(...[5m])` pour un taux.
- Latence de démarrage (submission → RUNNING) :
  `histogram_quantile(0.99, sum by(le)(rate(spark_application_start_latency_seconds_histogram_bucket{k8s_cluster="..."}[30m])))`
- Décomposition de l'attente scheduling :
  `kube_pod_status_scheduled_time - on(pod) kube_pod_created` sur les drivers.

## Drill-down plateforme — ordre des dashboards de l'équipe

1. **apiserver** — `apiserver_request_duration_seconds_bucket` p99 (verbes RW),
   ratio 5xx sur `apiserver_request_total`, `apiserver_current_inflight_requests`
2. **etcd** — ⚠️ `job="etcd-prod"`, PAS de label `k8s_cluster` —
   `etcd_disk_wal_fsync_duration_seconds_bucket` p99, `_backend_commit_`,
   `etcd_server_leader_changes_seen_total`
3. **cilium** — `cilium_agent_api_process_time_seconds_bucket`,
   `cilium_endpoint_state{endpoint_state!="ready"}`, `cilium_drop_count_total`
4. **coredns** — latence p99, SERVFAIL/s, cache hit ratio
5. **spark-operator** — `controller_runtime_reconcile_{time_seconds_bucket,errors_total}`,
   `workqueue_depth{namespace="spark-operator"}` (adds vs retries)
6. **yunikorn** — SPOF (1 replica) —
   `yunikorn_scheduler_scheduling_cycle_milliseconds_bucket` p99, backlog
   `yunikorn_queue_resource{queue="root.spark",resource="pods",state="pending"}`,
   gang en formation `yunikorn_root_spark_queue_app{state="accepted"}`
7. **celeborn** (shuffle) — nommage Dropwizard `metrics_*` :
   `metrics_OfferSlotsTime_99thPercentile`, `metrics_AvailableWorkerCount_Value`,
   `metrics_IsActiveMaster_Value`, disque `metrics_DeviceCeleborn{Total,Free}Bytes_Value`
8. **kubelet/nodes** — `kubelet_pod_start_duration_seconds_bucket`,
   `kubelet_pleg_relist_duration_seconds_bucket`,
   `kubelet_image_pull_duration_seconds_bucket` (pulls > 5 s : `le="5.0"` vs
   `le="+Inf"`), `kube_node_status_condition{condition=~".*Pressure"}`
9. **kyverno** (admission) — `kyverno_admission_review_duration_seconds_bucket` p99,
   `kyverno_breaker_drops_total`, `kyverno_policy_results_total{rule_result=~"fail|error"}`
10. **storage** — `purefa_volume_performance_latency_usec`, scratch flash01 :
    `node_filesystem_avail_bytes{mountpoint="/var/mnt/flash01"}` par node

## Idiomes qui valent de l'or

- **Marge avant OOM** : p95 de `max_over_time(container_memory_working_set_bytes[...])`
  rapporté à `kube_pod_container_resource_limits{resource="memory"}`
- **Throttling CPU** : `spark_app:container_cpu_throttled:ratio` (pré-calculé)
- **Skew de partitionnement** : `max by(app)` vs `min by(app)` du working set
  des executors — écart large = partitions déséquilibrées
- **Durée d'un run** : driver `kube_pod_completion_time - kube_pod_start_time`
- **Vecteurs vides** : terminer par `or vector(0)` dans les comparaisons

Queries complètes prêtes à copier : voir `references/queries.md`.
