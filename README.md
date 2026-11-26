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
