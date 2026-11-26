"""Read-only Kubernetes sizing and migration inventory (Python 3 standard library)."""
import argparse
import csv
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from decimal import Decimal
from pathlib import Path
from urllib.parse import urlencode

RESOURCES = {
    "Deployment": "deployments.apps", "StatefulSet": "statefulsets.apps",
    "DaemonSet": "daemonsets.apps", "ReplicaSet": "replicasets.apps",
    "ReplicationController": "replicationcontrollers", "Job": "jobs.batch",
    "CronJob": "cronjobs.batch", "Pod": "pods",
    "HorizontalPodAutoscaler": "horizontalpodautoscalers.autoscaling",
    "Service": "services", "Ingress": "ingresses.networking.k8s.io",
    "PersistentVolumeClaim": "pvc", "PersistentVolume": "pv",
    "StorageClass": "storageclasses.storage.k8s.io", "Node": "nodes",
}
CLUSTER_SCOPED = {"PersistentVolume", "StorageClass", "Node"}
UNITS = {"": 1, "n": Decimal("1e-9"), "u": Decimal("1e-6"), "m": Decimal(".001")}
UNITS.update({k: 1000 ** i for i, k in enumerate("kMGTPE", 1)})
UNITS.update({k + "i": 1024 ** i for i, k in enumerate("KMGTPE", 1)})
SIZING = """namespace kind workload desired ready scheduled_active_pods template_cpu_cores
template_memory_MiB desired_cpu_cores desired_memory_MiB scheduled_cpu_cores scheduled_memory_MiB
missing_cpu_requests missing_memory_requests hpa_min hpa_max max_surge node_selector
required_affinity tolerations topology_spread extended_requests cron_schedule""".split()
MIGRATION = """namespace kind workload volume source pvc pv storage_class csi_driver access_modes
volume_mode requested_storage pvc_phase pv_node_affinity other_workloads storage_detail service_account secret_refs configmap_refs selected_services ingress_routes observed_scc""".split()


def quantity(value):
    match = re.fullmatch(r"([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][+-]?\d+)?)([a-zA-Z]*)", str(value))
    if not match or match[2] not in UNITS:
        raise ValueError(f"invalid Kubernetes quantity {value!r}")
    return Decimal(match[1]) * UNITS[match[2]]


def effective(spec, resource):
    def request(container):
        resources = container.get("resources", {})
        return quantity(resources.get("requests", {}).get(resource,
                        resources.get("limits", {}).get(resource, 0)))

    sidecars = peak = 0
    for container in spec.get("initContainers", []):
        value = request(container)
        peak = max(peak, sidecars + value)
        if container.get("restartPolicy") == "Always":
            sidecars += value
    running = sidecars + sum(request(c) for c in spec.get("containers", []))
    pod_request = spec.get("resources", {}).get("requests", {}).get(resource)
    base = quantity(pod_request) if pod_request is not None else max(running, peak)
    return base + quantity(spec.get("overhead", {}).get(resource, 0))


def compact(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")) if value else ""


def key(obj):
    m = obj["metadata"]
    return m.get("namespace", ""), obj["kind"], m["name"]


def parent(obj):
    for owner in obj["metadata"].get("ownerReferences", []):
        if owner.get("controller"):
            return obj["metadata"].get("namespace", ""), owner["kind"], owner["name"]
    if obj["kind"] == "ReplicationController":
        dc = obj["metadata"].get("annotations", {}).get("openshift.io/deployment-config.name")
        if dc:
            return key(obj)[0], "DeploymentConfig", dc


def template(obj):
    spec = obj["spec"]
    if obj["kind"] == "Pod":
        return spec
    if obj["kind"] == "CronJob":
        spec = spec["jobTemplate"]["spec"]
    return spec.get("template", {}).get("spec", {})


def replicas(obj):
    kind, spec, status = obj["kind"], obj["spec"], obj.get("status", {})
    if kind == "DaemonSet":
        return status.get("desiredNumberScheduled"), status.get("numberReady", 0)
    if kind == "CronJob":
        return None, None
    if kind == "Job":
        terminal = any(c.get("type") in ("Complete", "Failed") and c.get("status") == "True"
                       for c in status.get("conditions", []))
        return (0 if terminal or spec.get("suspend") else spec.get("parallelism", 1)), status.get("ready", 0)
    if kind == "Pod":
        return int(status.get("phase") not in ("Failed", "Succeeded")), int(any(
            c.get("type") == "Ready" and c.get("status") == "True" for c in status.get("conditions", [])))
    return spec.get("replicas", 1), status.get("readyReplicas", 0)


def inventory(cli, context):
    command = [cli] + (["--context", context] if context else []) + ["--request-timeout=30s"]
    subprocess.run(command + ["get", "--raw", "/version"], stdout=subprocess.DEVNULL, check=True)
    resources = dict(RESOURCES)
    discovery = subprocess.run(command + ["api-resources", "-o", "name"], stdout=subprocess.PIPE, text=True)
    if "deploymentconfigs.apps.openshift.io" in discovery.stdout.splitlines():
        resources["DeploymentConfig"] = "deploymentconfigs.apps.openshift.io"
    if "routes.route.openshift.io" in discovery.stdout.splitlines():
        resources["Route"] = "routes.route.openshift.io"
    missing = [] if discovery.returncode == 0 else ["OpenShift API discovery"]
    objects = {}
    for kind, name in resources.items():
        args = [] if kind in CLUSTER_SCOPED else ["-A"]
        result = subprocess.run(command + ["get", name, *args, "-o", "json"], stdout=subprocess.PIPE)
        if result.returncode:
            missing.append(kind)
            continue
        for item in json.loads(result.stdout)["items"]:
            item["kind"] = kind
            objects[key(item)] = item
    return objects, missing


def volume_refs(obj, claims):
    for vol in template(obj).get("volumes", []):
        name = vol["name"]
        if "persistentVolumeClaim" in vol:
            yield name, "PVC", vol["persistentVolumeClaim"]["claimName"], {}
        elif "ephemeral" in vol:
            yield name, "generic ephemeral", "", vol["ephemeral"].get("volumeClaimTemplate", {}).get("spec", {})
        elif "hostPath" in vol or "emptyDir" in vol or "csi" in vol or "nfs" in vol:
            source = next(k for k in ("hostPath", "emptyDir", "csi", "nfs") if k in vol)
            yield name, source, "", vol[source]
        elif not any(k in vol for k in ("configMap", "secret", "projected", "downwardAPI")):
            yield name, "inline: " + ",".join(k for k in vol if k != "name"), "", {}
    for claim in obj["spec"].get("volumeClaimTemplates", []):
        name = claim["metadata"]["name"]
        prefix = name + "-" + obj["metadata"]["name"] + "-"
        matches = [p for p in claims if p.startswith(prefix) and re.fullmatch("[0-9]+", p[len(prefix):])]
        for pvc in sorted(matches) or [""]:
            yield name, "StatefulSet claim template", pvc, claim["spec"]


def dependencies(spec):
    secrets = {s["name"] for s in spec.get("imagePullSecrets", [])}
    configs = set()
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        for env in c.get("envFrom", []) + [e.get("valueFrom", {}) for e in c.get("env", [])]:
            for field, dest in (("secretRef", secrets), ("secretKeyRef", secrets),
                                ("configMapRef", configs), ("configMapKeyRef", configs)):
                if env.get(field, {}).get("name"):
                    dest.add(env[field]["name"])
    for vol in spec.get("volumes", []):
        for src in [vol] + vol.get("projected", {}).get("sources", []):
            secret = src.get("secret", {})
            name = secret.get("secretName") or secret.get("name")
            if name:
                secrets.add(name)
            if src.get("configMap", {}).get("name"):
                configs.add(src["configMap"]["name"])
    return [spec.get("serviceAccountName", "default"), ",".join(sorted(secrets)), ",".join(sorted(configs))]


def build(objects, missing):
    scheduled, hpas, claims = defaultdict(list), {}, defaultdict(list)
    workloads = {}
    scc, services, endpoints = defaultdict(set), defaultdict(list), defaultdict(set)
    for ident, obj in objects.items():
        ns, kind, name = ident
        if kind == "HorizontalPodAutoscaler":
            ref = obj["spec"]["scaleTargetRef"]
            hpas[ns, ref["kind"], ref["name"]] = obj["spec"]
        elif kind == "PersistentVolumeClaim":
            claims[ns].append(name)
        elif kind == "Service":
            if obj["spec"].get("selector"):
                services[ns].append((name, obj["spec"]["selector"]))
        elif kind == "Route":
            for backend in [obj["spec"].get("to", {})] + obj["spec"].get("alternateBackends", []):
                if backend.get("kind", "Service") == "Service":
                    endpoints[ns, backend.get("name")].add("Route/" + name)
        elif kind == "Ingress":
            backends = [obj["spec"].get("defaultBackend", {})]
            backends.extend(path.get("backend", {}) for rule in obj["spec"].get("rules", [])
                            for path in rule.get("http", {}).get("paths", []))
            for backend in backends:
                endpoints[ns, backend.get("service", {}).get("name")].add("Ingress/" + name)
        elif kind in CLUSTER_SCOPED:
            continue
        else:
            root, seen = obj, set()
            while parent(root) in objects and key(root) not in seen:
                seen.add(key(root))
                root = objects[parent(root)]
            root_id = key(root)
            workloads[root_id] = root
            annotation = obj["metadata"].get("annotations", {}).get("openshift.io/scc")
            if kind == "Pod" and annotation:
                scc[root_id].add(annotation)
            if kind == "Pod" and obj["spec"].get("nodeName") and obj.get("status", {}).get("phase") not in ("Failed", "Succeeded"):
                scheduled[root_id].append(obj["spec"])

    sizing, migration = [], []
    consumers = defaultdict(set)
    for ident, obj in sorted(workloads.items()):
        ns, kind, name = ident
        spec = template(obj)
        desired, ready = replicas(obj)
        pods = scheduled[ident]
        cpu, mem = effective(spec, "cpu"), effective(spec, "memory") / 1048576
        containers = spec.get("containers", []) + spec.get("initContainers", [])
        hpa = hpas.get(ident, {})
        strategy = obj["spec"].get("strategy", obj["spec"].get("updateStrategy", {}))
        affinity = {k: v["requiredDuringSchedulingIgnoredDuringExecution"] for k, v in spec.get("affinity", {}).items()
                    if "requiredDuringSchedulingIgnoredDuringExecution" in v}
        extended = {r for c in containers for field in ("requests", "limits")
                    for r in c.get("resources", {}).get(field, {}) if "/" in r or r.startswith("hugepages-")}
        sizing.append([*ident, desired, ready, None if "Pod" in missing else len(pods), cpu, mem,
                       None if desired is None else desired * cpu, None if desired is None else desired * mem,
                       None if "Pod" in missing else sum(effective(p, "cpu") for p in pods),
                       None if "Pod" in missing else sum(effective(p, "memory") for p in pods) / Decimal(1048576),
                       *(sum(r not in c.get("resources", {}).get("requests", {}) for c in containers) for r in ("cpu","memory")),
                       hpa.get("minReplicas", 1 if hpa else None), hpa.get("maxReplicas"),
                       strategy.get("rollingUpdate", {}).get("maxSurge"), compact(spec.get("nodeSelector")),
                       compact(affinity), compact(spec.get("tolerations")), compact(spec.get("topologySpreadConstraints")),
                       compact({r: str(effective(spec, r)) for r in sorted(extended)}), obj["spec"].get("schedule")])
        refs = list(volume_refs(obj, claims[ns])) or [("", "no data volume in template", "", {})]
        controller_spec = obj["spec"].get("jobTemplate", {}).get("spec", obj["spec"])
        meta = obj["metadata"] if kind == "Pod" else controller_spec.get("template", {}).get("metadata", {})
        labels = meta.get("labels", {})
        selected = sorted(s for s, selector in services[ns] if all(labels.get(k) == v for k, v in selector.items()))
        routes = sorted({ep for svc in selected for ep in endpoints[ns, svc]})
        deps = dependencies(spec) + [",".join(selected), ",".join(routes), ",".join(sorted(scc[ident]))]
        for volume, source, pvc, fallback in refs:
            claim = objects.get((ns, "PersistentVolumeClaim", pvc), {})
            cs = claim.get("spec", fallback)
            pv = cs.get("volumeName", "")
            ps = objects.get(("", "PersistentVolume", pv), {}).get("spec", {})
            sc = cs.get("storageClassName", ps.get("storageClassName", ""))
            driver = ps.get("csi", {}).get("driver") or objects.get(("", "StorageClass", sc), {}).get("provisioner")
            detail = ""
            if pvc:
                consumers[ns, pvc].add(kind + "/" + name)
                if not claim:
                    detail = "PVC inventory unavailable" if "PersistentVolumeClaim" in missing else "claim unresolved"
                elif pv and not ps:
                    detail = "PV inventory unavailable" if "PersistentVolume" in missing else "PV unresolved"
            if "local" in ps or "hostPath" in ps or source == "hostPath":
                detail = "node-local storage"
            elif source == "emptyDir":
                detail = "pod-lifetime data"
            if source == "csi":
                driver = fallback.get("driver")
            migration.append([*ident, volume, source, pvc, pv, sc, driver, ",".join(cs.get("accessModes", [])),
                              cs.get("volumeMode", "Filesystem" if claim or "accessModes" in cs else ""),
                              cs.get("resources", {}).get("requests", {}).get("storage"), claim.get("status", {}).get("phase"),
                              compact(ps.get("nodeAffinity")), "", detail, *deps])
    for row in migration:
        if row[5]:
            row[MIGRATION.index("other_workloads")] = ",".join(sorted(consumers[row[0], row[5]] - {row[1] + "/" + row[2]}))
    return sizing, migration


def pool_rows(objects, missing, label):
    """A capacity screen against current requests, with one eligible worker removed."""
    pools = defaultdict(list)
    pods = defaultdict(list)
    for (_, kind, name), obj in objects.items():
        if kind == "Pod" and obj["spec"].get("nodeName") and obj.get("status", {}).get("phase") not in ("Succeeded", "Failed"):
            pods[obj["spec"]["nodeName"]].append(obj)
        elif kind == "Node":
            labels = obj["metadata"].get("labels", {})
            control = any("node-role.kubernetes.io/" + r in labels for r in ("master", "control-plane"))
            pools[labels.get(label) or ("control-plane" if control else "unlabelled-workers")].append(obj)
    for pool, nodes in sorted(pools.items()):
        eligible = [n for n in nodes if not n["spec"].get("unschedulable") and any(
            c["type"] == "Ready" and c["status"] == "True" for c in n["status"].get("conditions", []))]
        for resource, unit in (("cpu", 1), ("memory", 1048576), ("pods", 1)):
            alloc = [quantity(n["status"]["allocatable"].get(resource, 0)) / unit for n in eligible]
            active = [p for n in nodes for p in pods[n["metadata"]["name"]]]
            reserved = sum(1 if resource == "pods" else effective(p["spec"], resource) / unit for p in active)
            ds = sum(1 if resource == "pods" else effective(p["spec"], resource) / unit for p in active
                     if (parent(p) or ("", "", ""))[1] == "DaemonSet")
            after_loss = sum(alloc) - max(alloc, default=0)
            yield [pool, resource if resource != "memory" else "memory_MiB", len(nodes), len(eligible),
                   sum(alloc), after_loss, None if "Pod" in missing else reserved,
                   None if "Pod" in missing else ds, None if "Pod" in missing else after_loss - reserved]


def historical(cli, context, proxy, days):
    command = [cli] + (["--context", context] if context else []) + ["--request-timeout=60s", "get", "--raw"]
    values = defaultdict(dict)
    series = {
        "cpu_cores": 'sum by(namespace)(rate(container_cpu_usage_seconds_total{container!="",container!="POD",namespace!=""}[5m]))',
        "memory_MiB": 'sum by(namespace)(container_memory_working_set_bytes{container!="",container!="POD",namespace!=""}) / 1048576',
    }
    fields = []
    for metric, expr in series.items():
        for stat, func in (("p95", "quantile_over_time"), ("max", "max_over_time"), ("samples", "count_over_time")):
            field = metric + "_" + stat
            fields.append(field)
            query = func + "(" + ("0.95," if stat == "p95" else "") + "(" + expr + f")[{days}d:15m])"
            uri = proxy.rstrip("/") + "/api/v1/query?" + urlencode({"query": query})
            result = json.loads(subprocess.check_output(command + [uri]))
            if result.get("status") != "success":
                raise ValueError("Prometheus query failed: " + result.get("error", "unknown error"))
            for entry in result["data"]["result"]:
                values[entry["metric"]["namespace"]][field] = entry["value"][1]
    return ["namespace", "window_days", "step_minutes", *fields], [
        [ns, days, 15, *(v.get(f) for f in fields)] for ns, v in sorted(values.items())]


def target_storage(cli, context, migration):
    output = subprocess.check_output([cli, "--context", context, "--request-timeout=30s",
                                      "get", RESOURCES["StorageClass"], "-o", "json"])
    classes = {c["metadata"]["name"]: c["provisioner"] for c in json.loads(output)["items"]}
    for row in migration:
        sc, driver = row[7:9]
        if sc:
            target = classes.get(sc)
            status = ("name missing" if not target else "source driver unknown" if not driver
                      else "driver differs" if driver != target else "name and driver match")
            yield row[:4] + [sc, driver, target, status]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("client", choices=("oc", "kubectl"))
    parser.add_argument("--context")
    parser.add_argument("--output-dir", type=Path, default=Path("."))
    parser.add_argument("--pool-label", default="machine.openshift.io/cluster-api-machineset")
    parser.add_argument("--target-context", help="compare storage classes against a second cluster")
    parser.add_argument("--prometheus-proxy", help="API-server service proxy path to Prometheus")
    parser.add_argument("--days", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.days <= 365:
        parser.error("--days must be between 1 and 365")
    if args.prometheus_proxy and not re.fullmatch(r"/api/v1/namespaces/[a-z0-9.-]+/services/[a-zA-Z0-9.:-]+/proxy/?", args.prometheus_proxy):
        parser.error("--prometheus-proxy must be a Kubernetes service proxy path")
    os.umask(0o077)
    objects, missing = inventory(args.client, args.context)
    rows = build(objects, missing)
    exports = {"sizing.csv": (SIZING, rows[0]), "migration.csv": (MIGRATION, rows[1]),
               "pools.csv": ("pool resource nodes eligible allocatable n_minus_one_allocatable scheduled_requests daemonset_requests n_minus_one_margin".split(),
                             list(pool_rows(objects, missing, args.pool_label)))}
    if args.target_context:
        exports["target-storage.csv"] = (MIGRATION[:4] + ["source_class", "source_driver", "target_driver", "comparison"],
                                         list(target_storage(args.client, args.target_context, rows[1])))
    if args.prometheus_proxy:
        exports["history.csv"] = historical(args.client, args.context, args.prometheus_proxy, args.days)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output_dir) as temp:
        for name, (header, data) in exports.items():
            with (Path(temp) / name).open("w", newline="", encoding="utf-8") as handle:
                writer = csv.writer(handle)
                writer.writerow(header + ["unavailable_inventories"])
                writer.writerows(row + [", ".join(missing)] for row in data)
        for name in exports:
            (Path(temp) / name).replace(args.output_dir / name)
    print(f"{args.output_dir}: {len(rows[0])} workload rows, {len(rows[1])} migration rows")
    if missing:
        print("Partial inventory: " + ", ".join(missing), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
