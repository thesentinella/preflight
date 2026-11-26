![preflight](https://repository-images.githubusercontent.com/827472651/d41c5a3c-7a6d-4d9d-9359-2771bac5150d "preflight")

# preflight
A set of preflight scripts to evaluate different environments

## Kubernetes and OpenShift

From a checkout, run `./kubernetes.sh` with Bash, jq 1.6 or newer, and an
authenticated `oc` or `kubectl` on PATH. The script prefers `oc` when both are
installed and uses that client's current context. It prints the report and
overwrites `preflight_out.log` in the working directory.

The report includes node readiness, roles, cordons, zones, kubelet versions,
architecture and allocatable resources. It also covers workload counts, pod
placement, pending scheduling reasons, namespace requests and limits, quotas,
storage provisioners, PVC demand and snapshot classes. Node utilization and the
top five CPU and memory consumers require the resource metrics API.

On clusters advertising the OpenShift ClusterVersion API, the report includes
the desired release and update state, platform and topology, DNS and ingress
domains, network plugin and CIDRs, ClusterOperator conditions and
MachineConfigPool rollout counts. CSV inventory is collected wherever the
classic OLM API is advertised.

The collector uses read-only requests. Cluster-wide list access is needed for
complete inventory. A failed server-version check stops the run. Later failures
appear alongside their API diagnostics and the remaining checks continue.
An empty snapshot class list means the API was readable and no classes were
returned. Namespace CPU and memory totals sum regular containers across all
returned pod phases, including completed pods. Init containers, pod overhead,
and pod-level resources are outside those totals.

Run `bash tests/report.sh` for the offline fixture checks.

### Sizing and migration planning

Use a checkout of this branch with Python 3.8+ and a client authenticated to
the source cluster. Planning runs separately from the text report. Use a fresh
output directory for each collection so optional exports from earlier runs
cannot be confused with the current snapshot.

```bash
./kubernetes.sh --planning --context source --output-dir ./source-inventory
```

| Output | How to use it |
| --- | --- |
| `sizing.csv` | Compare desired template demand to current scheduled, non-terminal pod requests by workload. Includes scaled-to-zero controllers, HPA bounds, surge settings, placement constraints and extended resources. CPU is cores and memory is MiB. |
| `migration.csv` | Trace template volumes through namespace-scoped claims to PVs, storage classes and drivers. Check access modes, node-local storage, shared claim consumers, service accounts, referenced Secret/ConfigMap names, selector-matched Services, Ingress/Routes and observed SCCs. |
| `pools.csv` | Inspect CPU, memory and pod slots per pool. Each resource gets its own worst single-worker-loss estimate. Only Ready, uncordoned nodes contribute capacity. All assigned non-terminal pods count toward demand, including DaemonSets on the lost node. A negative margin warrants investigation. |
| `target-storage.csv` | With `--target-context TARGET`, check the target for matching storage-class names and provisioners. Validate access modes, topology, snapshots and restore procedures separately. |
| `history.csv` | With `--prometheus-proxy PATH`, collect namespace CPU and memory p95, maxima and sample counts. The default is 30 days sampled every 15 minutes. Compare sample counts with the requested window before using a percentile. |

```bash
./kubernetes.sh --planning --context source --target-context destination \
  --pool-label workload --output-dir ./comparison
```

For a Prometheus service exposed through the Kubernetes API service proxy, add
`--prometheus-proxy /api/v1/namespaces/monitoring/services/http:prometheus:9090/proxy --days 14`.
Use the actual namespace, service, scheme and port from your installation.
The endpoint must permit instant PromQL queries and expose cAdvisor metrics.
Review the underlying metric series for duplicate scrape targets. A collection
with no matching time series produces a header-only history file.

**Interpretation**

- Desired demand uses controller templates. Admission defaults, injected
  sidecars and RuntimeClass overhead may change admitted pod requests. Scheduled
  demand uses the live pod specs. CronJobs carry a per-pod profile and schedule,
  with desired concurrency blank. Standalone Jobs use parallelism as their upper
  concurrency setting. CronJob-owned Jobs contribute their live pods to the CronJob.
- Pool capacity is a first-pass aggregate screen. A positive margin still
  requires a placement review for per-node fit, taints, affinity, volume
  topology, GPUs and disruption budgets. By default, nodes are grouped by the
  OpenShift MachineSet label, with separate fallback groups for control-plane
  and unlabelled worker nodes.
- Volume relationships come from workload templates. StatefulSet claim rows
  include existing ordinal claims, which may include retained PVCs. A template
  without a matching PVC still gets a row. Workloads without data volumes also
  get a row. Requested storage is provisioned demand. Measuring occupied bytes,
  change rate and restore throughput requires storage or application telemetry.
- Services are matched by selectors. External dependencies, custom application
  CRs and traffic through selectorless Services require separate discovery.
  Only reference names appear in the exports. No Secret objects are requested.
- A failed source list produces partial exports, names the unavailable
  inventories and exits with status 2. Blank fields can also indicate an
  inapplicable or unset setting. Source or optional endpoint failures which
  prevent generation leave the previous exports in place.

Run `python3 tests/planning.py` for the offline planning checks.
