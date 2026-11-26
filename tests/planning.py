"""Run the planning entry point against simulated source and target API responses."""
import csv
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "kubernetes.sh"


def obj(name, spec, **extra):
    return {"metadata": {"name": name, "namespace": "lab"}, "spec": spec, **extra}


MOCK = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
r = a[a.index("get")+1] if "get" in a else ""
if r == "pods" and os.getenv("DENY"):
    sys.exit(1)
if "api-resources" in a:
    print("routes.route.openshift.io")
elif r == "--raw":
    print(json.dumps({"status":"success","data":{"result":[{"metric":{"namespace":"lab"},"value":[0,"9"]}]}}))
else:
    with open("fixtures.json") as f:
        print(json.dumps({"items":json.load(f).get(r,[])}))
"""


class Planning(unittest.TestCase):
    def test_exports(self):
        spec = {"containers": [{"name": "db", "resources": {"requests": {"cpu": "1", "memory": "1Gi"}},
                                "envFrom": [{"secretRef": {"name": "password"}}]}],
                "initContainers": [{"restartPolicy": "Always", "resources": {"requests": {"cpu": "100m"}}},
                                   {"resources": {"requests": {"cpu": "2"}}}], "overhead": {"cpu": "50m"}}
        sts = obj("db", {"replicas": 1, "template": {"metadata": {"labels": {"app": "db"}}, "spec": spec},
                         "volumeClaimTemplates": [{"metadata": {"name": "data"}, "spec": {"accessModes": ["ReadWriteOnce"]}}]})
        pod = obj("db-0", dict(spec, nodeName="worker"), status={"phase": "Running"})
        pod["metadata"]["ownerReferences"] = [{"controller": True, "kind": "StatefulSet", "name": "db"}]
        finished = obj("finished", dict(spec, nodeName="worker"), status={"phase": "Succeeded"})
        fixture = {
            "statefulsets.apps": [sts], "pods": [pod, finished],
            "deployments.apps": [obj("off", {"replicas": 0, "template": {"spec": {"containers": []}}})],
            "pvc": [obj("data-db-0", {"storageClassName": "fast", "volumeName": "vol", "accessModes": ["ReadWriteOnce"]})],
            "pv": [{"metadata": {"name": "vol"}, "spec": {"csi": {"driver": "example.io"}}}],
            "nodes": [{"metadata":{"name":"worker"}, "spec":{}, "status":{"allocatable":{"cpu":"4","memory":"8Gi","pods":"50"},
                       "conditions":[{"type":"Ready","status":"True"}]}}],
            "storageclasses.storage.k8s.io": [{"metadata":{"name":"fast"},"provisioner":"example.io"}],
            "services": [obj("db-svc", {"selector":{"app":"db"}})],
            "routes.route.openshift.io": [obj("db-route", {"to":{"name":"db-svc"}})],
        }
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            cli = directory / "oc"
            cli.write_text(MOCK)
            cli.chmod(0o700)
            (directory / "fixtures.json").write_text(json.dumps(fixture))
            env = dict(os.environ, PATH=folder + os.pathsep + os.environ["PATH"])
            command = [str(SCRIPT), "--planning", "--target-context", "target", "--prometheus-proxy",
                       "/api/v1/namespaces/monitoring/services/prom:9090/proxy"]
            def rows(name):
                with (directory / (name + ".csv")).open() as f:
                    return list(csv.DictReader(f))
            subprocess.run(command, cwd=directory, env=env, check=True)
            sizes = {r["workload"]: r for r in rows("sizing")}
            self.assertEqual(float(sizes["db"]["scheduled_cpu_cores"]), 2.15)
            self.assertEqual(float(sizes["db"]["desired_memory_MiB"]), 1024)
            self.assertEqual(sizes["finished"]["scheduled_active_pods"], "0")
            self.assertEqual(sizes["off"]["desired_cpu_cores"], "0")
            db = next(r for r in rows("migration") if r["workload"] == "db")
            self.assertEqual((db["pvc"], db["pv"], db["csi_driver"]), ("data-db-0", "vol", "example.io"))
            self.assertEqual((db["secret_refs"], db["ingress_routes"]), ("password", "Route/db-route"))
            self.assertEqual(rows("target-storage")[0]["comparison"], "name and driver match")
            self.assertEqual(rows("history")[0]["cpu_cores_p95"], "9")
            self.assertEqual(float(rows("pools")[0]["n_minus_one_margin"]), -2.15)
            result = subprocess.run(command, cwd=directory, env=dict(env, DENY="1"))
            self.assertEqual(result.returncode, 2)
            self.assertEqual(rows("sizing")[0]["scheduled_cpu_cores"], "")
            self.assertIn("Pod", rows("sizing")[0]["unavailable_inventories"])


if __name__ == "__main__":
    unittest.main()
