#!/usr/bin/env bash
set -o pipefail

if command -v oc >/dev/null; then
    cli=oc
elif command -v kubectl >/dev/null; then
    cli=kubectl
else
    echo "Install oc or kubectl to run preflight." >&2
    exit 1
fi
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

# Only rendered report lines reach the log. Keep raw API objects in pipelines.
umask 077
report() {
    local title=$1 filter=$2 result
    shift 2
    printf '\n%s\n' "$title"
    if result=$("$cli" --request-timeout=30s "$@" | jq -er "$jq_helpers $filter"); then
        printf '%s\n' "$result"
    else
        echo "  Unavailable (see diagnostic above)"
        return 1
    fi
}

jq_helpers='
    def condition($type):
        ([.status.conditions[]? | select(.type == $type) | .status][0] // "Unknown");
    def rows: if length == 0 then "  None" else .[] | "  " + @tsv end;
    def quantity:
        tostring as $raw | ($raw | capture("^(?<n>[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?)(?<u>Ki|Mi|Gi|Ti|Pi|Ei|[numkMGTPE]?)$")) // error("Invalid resource quantity: " + $raw)
        | (.n | tonumber) * ({"":1,n:1e-9,u:1e-6,m:0.001,k:1000,M:1e6,G:1e9,T:1e12,P:1e15,E:1e18,
            Ki:1024,Mi:1048576,Gi:1073741824,Ti:1099511627776,Pi:1125899906842624,Ei:1152921504606846976}[.u]);
    def rounded: . * 1000 | round / 1000;
'

ocp_report() {
    report "OpenShift release" '
        "  Desired version: " + (.status.desired.version // "Unknown"),
        "  Channel: " + (.spec.channel // "Unset"),
        "  Progressing: " + condition("Progressing")' get clusterversions.config.openshift.io version -o json
    report "Infrastructure" '
        "  Infra ID: " + (.status.infrastructureName // "Unknown"),
        "  Platform: " + (.status.platformStatus.type // .status.platform // "Unknown"),
        "  Control-plane topology: " + (.status.controlPlaneTopology // "Unknown")' get infrastructures.config.openshift.io cluster -o json
    report "Base domain" '.spec.baseDomain // "Unknown"' get dnses.config.openshift.io cluster -o json
    report "Apps route domain" '.spec.domain // "Unknown"' get ingresses.config.openshift.io cluster -o json
    report "Cluster network" '
        "  Plugin: " + (.status.networkType // .spec.networkType // "Unknown"),
        "  Pod CIDRs: " + ([.spec.clusterNetwork[]?.cidr] | join(", ")),
        "  Service CIDRs: " + ([.spec.serviceNetwork[]?] | join(", "))' get networks.config.openshift.io cluster -o json
    report "ClusterOperators" '
        [.items[] | [.metadata.name, condition("Available"), condition("Progressing"), condition("Degraded")]] as $ops
        | "  NAME\tAVAILABLE\tPROGRESSING\tDEGRADED", ($ops | rows),
          "  Available=True: \([$ops[] | select(.[1]=="True")] | length)  Progressing=True: \([$ops[] | select(.[2]=="True")] | length)  Degraded=True: \([$ops[] | select(.[3]=="True")] | length)"' get clusteroperators.config.openshift.io -o json
    report "MachineConfigPools" '
        "  POOL\tMACHINES\tREADY\tUPDATED\tDEGRADED\tUPDATING\tPAUSED",
        ([.items[] | [.metadata.name, .status.machineCount, .status.readyMachineCount,
          .status.updatedMachineCount, .status.degradedMachineCount, condition("Updating"), (.spec.paused // false)]] | rows)' get machineconfigpools.machineconfiguration.openshift.io -o json
}

main() {
    echo "Sentinella Preflight"
    printf 'Context: '
    "$cli" config current-context || echo "Unknown"
    report "Kubernetes server version" '.serverVersion.gitVersion' version -o json || return 1

    local discovery resource count
    if discovery=$("$cli" --request-timeout=30s api-resources -o name); then
        if grep -Fxq 'clusterversions.config.openshift.io' <<< "$discovery"; then
            ocp_report
        fi
        if grep -Fxq 'clusterserviceversions.operators.coreos.com' <<< "$discovery"; then
            report "Installed OLM operators (CSV objects)" '
                "  CSV count: \(.items | length)", "  NAMESPACE\tCSV\tDISPLAY NAME\tVERSION\tPHASE",
                ([.items[] | [.metadata.namespace,.metadata.name,.spec.displayName,.spec.version,.status.phase]] | rows)' get clusterserviceversions.operators.coreos.com -A -o json
        fi
        while IFS= read -r resource; do
            [[ $resource == networks || $resource == networks.* ]] || continue
            report "Networks ($resource)" '.items | length' get "$resource" -A -o json
        done <<< "$discovery"
    else
        echo "API discovery unavailable. OpenShift, OLM and network inventory skipped."
    fi

    report "Nodes" '
        def roles: (.metadata.labels // {} | keys | map(select(startswith("node-role.kubernetes.io/")) | split("/")[1]));
        def control: roles | any(. == "master" or . == "control-plane");
        "  Nodes: \(.items | length)  Control-plane: \([.items[] | select(control)] | length)  Non-control-plane: \([.items[] | select(control | not)] | length)",
        "  NAME\tROLES\tREADY\tCORDONED\tZONE\tKUBELET\tARCH\tALLOC CPU\tALLOC MEMORY",
        ([.items[] | [.metadata.name,(roles | join(",")),condition("Ready"),(.spec.unschedulable // false),
          (.metadata.labels["topology.kubernetes.io/zone"] // "-"),.status.nodeInfo.kubeletVersion,
          .status.nodeInfo.architecture,.status.allocatable.cpu,.status.allocatable.memory]] | rows)' get nodes -o json

    report "Pods" '
        "  Pods: \(.items | length)",
        "Pod distribution (node, count)",
        (.items | group_by(.spec.nodeName) | map([.[0].spec.nodeName // "(unassigned)",length]) | rows),
        "Pending pods (scheduling reason, count)",
        ([.items[] | select(.status.phase=="Pending")
          | ([.status.conditions[]? | select(.type=="PodScheduled" and .status=="False") | .reason][0] // "Unknown")]
          | group_by(.) | map([.[0],length]) | rows),
        "Regular container totals by namespace (all pod phases)",
        "  NAMESPACE\tREQ CPU (cores)\tREQ MEM (MiB)\tLIMIT CPU (cores)\tLIMIT MEM (MiB)",
        (.items | group_by(.metadata.namespace) | map(
            .[0].metadata.namespace as $ns
            | reduce (.[].spec.containers[]?.resources) as $r ([0,0,0,0];
                .[0] += (($r.requests.cpu // 0) | quantity) |
                .[1] += (($r.requests.memory // 0) | quantity) / 1048576 |
                .[2] += (($r.limits.cpu // 0) | quantity) |
                .[3] += (($r.limits.memory // 0) | quantity) / 1048576)
            | [$ns] + map(rounded)) | rows)' get pods -A -o json

    report "Services" '"  Total: \(.items | length)  LoadBalancers: \([.items[] | select(.spec.type=="LoadBalancer")] | length)"' get services -A -o json
    for resource in deployments daemonsets jobs cronjobs crds; do
        if count=$("$cli" --request-timeout=30s get "$resource" -A --no-headers -o custom-columns=NAME:.metadata.name | awk 'NF {n++} END {print n+0}'); then
            printf '%s: %s\n' "$resource" "$count"
        else
            printf '%s: Unavailable\n' "$resource"
        fi
    done
    for resource in limitranges resourcequotas; do
        report "$resource by namespace" '.items | group_by(.metadata.namespace) | map([.[0].metadata.namespace,length]) | rows' get "$resource" -A -o json
    done
    report "Storage classes (name, provisioner, binding mode)" '
        [.items[] | [.metadata.name,.provisioner,(.volumeBindingMode // "Immediate")]] | rows' get storageclasses -o json
    report "PVCs by class (class, count, requested GiB, pending)" '
        .items | group_by(.spec.storageClassName // "") | map([
            (.[0].spec.storageClassName | if . == null or . == "" then "(none)" else . end), length,
            (map((.spec.resources.requests.storage // 0) | quantity) | add / 1073741824 | rounded),
            (map(select(.status.phase=="Pending")) | length)]) | rows' get pvc -A -o json
    report "VolumeSnapshotClasses (name, driver, deletion policy)" '
        [.items[] | [.metadata.name,.driver,.deletionPolicy]] | rows' get volumesnapshotclasses.snapshot.storage.k8s.io -o json
    printf '\nNode usage (CPU and memory, absolute and percent)\n'
    "$cli" --request-timeout=30s top nodes || echo "  Node metrics unavailable"
    report "Top pod consumers" '
        [.items[] | [.metadata.namespace + "/" + .metadata.name,
          ([.containers[].usage.cpu | quantity] | add // 0),
          ([.containers[].usage.memory | quantity] | add // 0)]] as $pods
        | "Top 5 CPU (millicores)", ($pods | sort_by(-.[1],.[0]) | .[:5] | map([.[0],(.[1]*1000 | rounded)]) | rows),
          "Top 5 memory (MiB)", ($pods | sort_by(-.[2],.[0]) | .[:5] | map([.[0],(.[2]/1048576 | rounded)]) | rows)' get --raw /apis/metrics.k8s.io/v1beta1/pods
    echo
    echo "Evaluation completed. Output saved to preflight_out.log"
}
main 2>&1 | tee preflight_out.log
