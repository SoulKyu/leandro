# Queries prêtes à copier (extraites des dashboards, 2026-08-10)

`$cluster` = `prod-cluster-1`, `$app` = valeur de `spark_app`,
`$window`/`$__range` = fenêtre (ex. `6h`).

## Santé cluster — les alertes (premier réflexe)

Pas de tool `list_alerts` : l'API alertes de Thanos n'a pas de filtre et
renvoie toute l'infra (75k+ alertes, 84 MiB). La métrique `ALERTS` filtrée
fait le même travail en 7 KiB :

```promql
ALERTS{alertstate="firing", k8s_cluster="$cluster"}
```

Depuis quand chaque alerte est active (timestamp epoch) :

```promql
ALERTS_FOR_STATE{k8s_cluster="$cluster"}
```

## Spark-on-Kubernetes — Application Deep-Dive

### Runs (sparkapp / id / start / durée / #exec)

```promql
label_replace(max by(spark_app,sparkapp)(max_over_time(kube_pod_start_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"}[$__range]) * on(k8s_cluster,namespace,pod) group_left(spark_app,sparkapp) max by(k8s_cluster,namespace,pod,spark_app,sparkapp)(label_replace(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="driver"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"),"sparkapp","$1","label_spark_app_name","(.*)-[a-z0-9]{8}"))) * 1000, "id","$1","spark_app",".*-([a-z0-9]{8})$")
```

```promql
max by(spark_app)((timestamp(last_over_time(kube_pod_start_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"}[$__range])) - max_over_time(kube_pod_start_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"}[$__range])) * on(k8s_cluster,namespace,pod) group_left(spark_app) max by(k8s_cluster,namespace,pod,spark_app,sparkapp)(label_replace(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="driver"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"),"sparkapp","$1","label_spark_app_name","(.*)-[a-z0-9]{8}")))
```

```promql
count by(spark_app)(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="executor"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"))
```

```promql
(max by(spark_app)(max_over_time(kube_pod_start_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"}[$__range]) * on(k8s_cluster,namespace,pod) group_left(spark_app) max by(k8s_cluster,namespace,pod,spark_app,sparkapp)(label_replace(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="driver"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"),"sparkapp","$1","label_spark_app_name","(.*)-[a-z0-9]{8}"))) - 600) * 1000
```

```promql
(max by(spark_app)(timestamp(last_over_time(kube_pod_start_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"}[$__range])) * on(k8s_cluster,namespace,pod) group_left(spark_app) max by(k8s_cluster,namespace,pod,spark_app,sparkapp)(label_replace(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="driver"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"),"sparkapp","$1","label_spark_app_name","(.*)-[a-z0-9]{8}"))) + 600) * 1000
```

### CPU usage (cores)

```promql
sum(spark_app:container_cpu_usage:cores{spark_app="$app"})
```

### Mem usage

```promql
sum(spark_app:container_memory_working_set:bytes{spark_app="$app"})
```

### CPU — usage / request / limit (cores)

```promql
sum(spark_app:container_cpu_usage:cores{spark_app="$app"})
```

```promql
sum(spark_app:container_cpu_request:cores{spark_app="$app"})
```

```promql
sum(spark_app:container_cpu_limit:cores{spark_app="$app"})
```

### Mémoire — working set / request / limit

```promql
sum(spark_app:container_memory_working_set:bytes{spark_app="$app"})
```

```promql
sum(spark_app:container_memory_request:bytes{spark_app="$app"})
```

```promql
sum(spark_app:container_memory_limit:bytes{spark_app="$app"})
```

### CPU throttling (ratio par container)

```promql
max(spark_app:container_cpu_throttled:ratio{spark_app="$app"})
```

```promql
avg(spark_app:container_cpu_throttled:ratio{spark_app="$app"})
```

### CPU usage par executor (cores)

```promql
label_replace(spark_app:container_cpu_usage:cores{spark_app="$app",spark_role="executor"}, "exec","$1","pod",".*-(exec-[0-9]+)$")
```

### Mémoire par executor (working set)

```promql
label_replace(spark_app:container_memory_working_set:bytes{spark_app="$app",spark_role="executor"}, "exec","$1","pod",".*-(exec-[0-9]+)$")
```

## Spark-on-Kubernetes — Platform Health

### Start latency p99 (submit→running)

```promql
histogram_quantile(0.99, sum by(le)(rate(spark_application_start_latency_seconds_histogram_bucket{k8s_cluster="$cluster"}[30m])))
```

### Failures (5m)

```promql
sum(increase(spark_application_failure_count{k8s_cluster="$cluster"}[5m]))
```

```promql
sum(increase(spark_application_failed_submission_count{k8s_cluster="$cluster"}[5m]))
```

### Request latency p50/p99 (read vs write)

```promql
histogram_quantile(0.99, sum by(le)(rate(apiserver_request_duration_seconds_bucket{k8s_cluster="$cluster",verb=~"GET|LIST"}[5m])))
```

```promql
histogram_quantile(0.99, sum by(le)(rate(apiserver_request_duration_seconds_bucket{k8s_cluster="$cluster",verb=~"POST|PUT|PATCH|DELETE"}[5m])))
```

```promql
histogram_quantile(0.5, sum by(le)(rate(apiserver_request_duration_seconds_bucket{k8s_cluster="$cluster",verb=~"GET|LIST"}[5m])))
```

### 5xx error ratio

```promql
sum(rate(apiserver_request_total{k8s_cluster="$cluster",code=~"5.."}[5m]))/clamp_min(sum(rate(apiserver_request_total{k8s_cluster="$cluster"}[5m])),0.001)
```

### WAL fsync p99

```promql
histogram_quantile(0.99, sum by(le)(rate(etcd_disk_wal_fsync_duration_seconds_bucket{job="etcd-prod"}[5m])))
```

### Reconcile errors/s

```promql
sum(rate(controller_runtime_reconcile_errors_total{k8s_cluster="$cluster"}[5m]))
```

### Backlog & gang en formation (root.spark)

```promql
sum(yunikorn_queue_resource{k8s_cluster="$cluster",queue="root.spark",resource="pods",state="pending"}) or vector(0)
```

```promql
sum(yunikorn_root_spark_queue_app{k8s_cluster="$cluster",state="accepted"}) or vector(0)
```

```promql
sum(yunikorn_root_spark_queue_app{k8s_cluster="$cluster",state="new"}) or vector(0)
```

### Nodes under pressure

```promql
count(kube_node_status_condition{k8s_cluster="$cluster",condition=~"MemoryPressure|DiskPressure|PIDPressure",status="true"} == 1) or vector(0)
```

### Image pull p99 / p90  (détecteur cold-pull & throttle registre)

```promql
histogram_quantile(0.99, sum by(le)(rate(kubelet_image_pull_duration_seconds_bucket{k8s_cluster="$cluster"}[1h])))
```

```promql
histogram_quantile(0.90, sum by(le)(rate(kubelet_image_pull_duration_seconds_bucket{k8s_cluster="$cluster"}[1h])))
```

### Pulls lents > 5s (1h)

```promql
sum(increase(kubelet_image_pull_duration_seconds_bucket{k8s_cluster="$cluster",le="+Inf"}[1h])) - sum(increase(kubelet_image_pull_duration_seconds_bucket{k8s_cluster="$cluster",le="5.0"}[1h]))
```

### flash01 — usage % par node (top 10)

```promql
topk(10, 100 * (1 - node_filesystem_avail_bytes{mountpoint="/var/mnt/flash01",k8s_cluster="$cluster"} / node_filesystem_size_bytes{mountpoint="/var/mnt/flash01",k8s_cluster="$cluster"}))
```

## Spark on Kubernetes — Resource Right-Sizing

### CPU throttling par rôle — $app

```promql
avg by(label_spark_role)((rate(container_cpu_cfs_throttled_periods_total{k8s_cluster="$cluster",namespace="spark",container=~"spark-kubernetes-.*"}[5m]) / clamp_min(rate(container_cpu_cfs_periods_total{k8s_cluster="$cluster",namespace="spark",container=~"spark-kubernetes-.*"}[5m]),0.001)) * on(pod,namespace) group_left(label_spark_app_name,label_spark_role) max by(pod,namespace,label_spark_app_name,label_spark_role)(max_over_time(kube_pod_labels{k8s_cluster="$cluster",namespace="spark",label_spark_app_name=~"$app-[a-z0-9]{8}",label_spark_role!=""}[$window]))) or vector(0)
```

### Déséquilibre de partitionnement — $app

```promql
max by(label_spark_app_name)(max_over_time(container_memory_working_set_bytes{k8s_cluster="$cluster",namespace="spark",container="spark-kubernetes-executor"}[$window]) * on(pod,namespace) group_left(label_spark_app_name) max by(pod,namespace,label_spark_app_name)(max_over_time(kube_pod_labels{k8s_cluster="$cluster",namespace="spark",label_spark_app_name=~"$app-[a-z0-9]{8}",label_spark_role="executor"}[$window])))
```

```promql
min by(label_spark_app_name)(max_over_time(container_memory_working_set_bytes{k8s_cluster="$cluster",namespace="spark",container="spark-kubernetes-executor"}[$window]) * on(pod,namespace) group_left(label_spark_app_name) max by(pod,namespace,label_spark_app_name)(max_over_time(kube_pod_labels{k8s_cluster="$cluster",namespace="spark",label_spark_app_name=~"$app-[a-z0-9]{8}",label_spark_role="executor"}[$window])))
```

### Marge avant OOM kill — pic mémoire rapporté à la limit

```promql
(quantile by(appkey)(0.95, label_join(label_replace(max by(pod,namespace,container)(max_over_time(container_memory_working_set_bytes{k8s_cluster="$cluster",namespace="spark",container=~"spark-kubernetes-.*"}[$window])) * on(pod,namespace) group_left(label_spark_app_name,label_spark_role) max by(pod,namespace,label_spark_app_name,label_spark_role)(max_over_time(kube_pod_labels{k8s_cluster="$cluster",namespace="spark",label_spark_role!=""}[$window])), "app","$1","label_spark_app_name","(.*)-[a-z0-9]{8}$"), "appkey", " / ", "app", "label_spark_role"))) / clamp_min((avg by(appkey)(label_join(label_replace(max by(pod,namespace,container)(max_over_time(kube_pod_container_resource_limits{k8s_cluster="$cluster",namespace="spark",container=~"spark-kubernetes-.*",resource="memory"}[$window])) * on(pod,namespace) group_left(label_spark_app_name,label_spark_role) max by(pod,namespace,label_spark_app_name,label_spark_role)(max_over_time(kube_pod_labels{k8s_cluster="$cluster",namespace="spark",label_spark_role!=""}[$window])), "app","$1","label_spark_app_name","(.*)-[a-z0-9]{8}$"), "appkey", " / ", "app", "label_spark_role"))), 1)
```

## Spark-on-Kubernetes — Platform & Native Metrics

### Cluster shuffle (native, bytes/s)

```promql
sum(spark_native:executor_shuffle_read:rate{k8s_cluster="$cluster"})
```

```promql
sum(spark_native:executor_shuffle_write:rate{k8s_cluster="$cluster"})
```

### Runs (sparkapp / id / start / duration / #exec / heap / shuffle)

```promql
label_replace(max by(spark_app,sparkapp)(max_over_time(kube_pod_start_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"}[$__range]) * on(k8s_cluster,namespace,pod) group_left(spark_app,sparkapp) max by(k8s_cluster,namespace,pod,spark_app,sparkapp)(label_replace(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="driver"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"),"sparkapp","$1","label_spark_app_name","(.*)-[a-z0-9]{8}"))) * 1000, "id","$1","spark_app",".*-([a-z0-9]{8})$")
```

```promql
max by(spark_app)((kube_pod_completion_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"} - kube_pod_start_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"}) * on(k8s_cluster,namespace,pod) group_left(spark_app) max by(k8s_cluster,namespace,pod,spark_app,sparkapp)(label_replace(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="driver"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"),"sparkapp","$1","label_spark_app_name","(.*)-[a-z0-9]{8}")))
```

```promql
count by(spark_app)(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="executor"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"))
```

```promql
max by(spark_app)(max_over_time(spark_native:executor_jvm_heap:bytes{k8s_cluster="$cluster"}[$__range]))
```

```promql
max by(spark_app)(max_over_time(spark_native:executor_shuffle_write:rate{k8s_cluster="$cluster"}[$__range]))
```

```promql
(max by(spark_app)(max_over_time(kube_pod_start_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"}[$__range]) * on(k8s_cluster,namespace,pod) group_left(spark_app) max by(k8s_cluster,namespace,pod,spark_app,sparkapp)(label_replace(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="driver"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"),"sparkapp","$1","label_spark_app_name","(.*)-[a-z0-9]{8}"))) - 600) * 1000
```

```promql
(max by(spark_app)(kube_pod_completion_time{namespace="spark",k8s_cluster="$cluster",pod=~".+-driver"} * on(k8s_cluster,namespace,pod) group_left(spark_app) max by(k8s_cluster,namespace,pod,spark_app,sparkapp)(label_replace(label_replace(max_over_time(kube_pod_labels{namespace="spark",k8s_cluster="$cluster",label_spark_role="driver"}[$__range]),"spark_app","$1","label_spark_app_name","(.*)"),"sparkapp","$1","label_spark_app_name","(.*)-[a-z0-9]{8}"))) + 600) * 1000
```

### JVM heap vs process RSS vs container limit (aggregated)

```promql
sum(spark_native:executor_jvm_heap:bytes{spark_app="$app"})
```

```promql
sum(spark_native:executor_rss:bytes{spark_app="$app"})
```

```promql
sum(spark_app:container_memory_limit:bytes{spark_app="$app"})
```

```promql
sum(spark_app:container_memory_working_set:bytes{spark_app="$app"})
```

### GC time per executor (ratio)

```promql
spark_native:executor_gc_time:rate{spark_app="$app"}
```

