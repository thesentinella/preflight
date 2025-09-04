#!/bin/bash

# Color setup for terminal
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# Spinner (only in terminal)
show_spinner() {
    if [ ! -t 1 ]; then return; fi
    local pid=$1 delay=0.1 spinstr='|/-\'
    while ps -p $pid &>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "      \b\b\b\b\b\b"
}

# Requirements check
for cmd in kubectl jq awk; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${RED}$cmd is required but not installed.${NC}"
        [[ -f /etc/redhat-release ]] && echo -e "${YELLOW}Try: sudo dnf install $cmd${NC}"
        [[ -f /etc/debian_version ]] && echo -e "${YELLOW}Try: sudo apt install $cmd${NC}"
        exit 1
    fi
done

# Prefer oc if present (works as kubectl superset on OCP)
OCCMD="kubectl"
if command -v oc &>/dev/null; then OCCMD="oc"; fi

# Detect if this is an OpenShift cluster (config.openshift.io group exists)
is_openshift() {
    $OCCMD api-resources --api-group=config.openshift.io &>/dev/null
}

# --- Helpers (Kubernetes) ---
get_resource_count() { kubectl get "$1" --all-namespaces --no-headers 2>/dev/null | wc -l; }
get_k8s_version() { kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion'; }
get_storage_classes() { kubectl get storageclass -o custom-columns=":metadata.name" --no-headers; }
get_volume_snapshot_support() { kubectl get volumesnapshotclass &>/dev/null && echo "Supported" || echo "Not Supported"; }
metrics_available() { kubectl top nodes &>/dev/null; return $?; }

# --- Helpers (OpenShift) ---
get_ocp_version() {
    $OCCMD get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null
}
get_cluster_name() {
    # infrastructureName is the canonical "cluster name"/infra ID used by OCP/Clouds
    $OCCMD get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null
}
get_base_domain() {
    # May be empty in some installs; printed only if present
    $OCCMD get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null
}
get_apps_domain() {
    # Default apps route domain (e.g., apps.<basedomain>)
    $OCCMD get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}' 2>/dev/null
}
print_cluster_operators() {
    # Summary counts + per-operator availability/progress/degraded
    local json out
    json="$($OCCMD get co -o json 2>/dev/null)" || return 0
    if [ -z "$json" ]; then return 0; fi
    echo -e "\nClusterOperators state:"
    echo "$json" | jq -r '
      .items[]
      | .metadata.name as $n
      | (.status.conditions[]? | select(.type=="Available")   | .status) as $a
      | (.status.conditions[]? | select(.type=="Progressing") | .status) as $p
      | (.status.conditions[]? | select(.type=="Degraded")    | .status) as $d
      | "\($n): Available=\($a) Progressing=\($p) Degraded=\($d)"
    ' | sed "s/^/  /"

    echo -e "\nClusterOperators summary:"
    echo "$json" | jq -r '
      [ .items[]
        | {
            a: (.status.conditions[]? | select(.type=="Available")   | .status),
            p: (.status.conditions[]? | select(.type=="Progressing") | .status),
            d: (.status.conditions[]? | select(.type=="Degraded")    | .status)
          }
      ]
      | {
          available_true:   ([.[] | select(.a=="True")]      | length),
          progressing_true: ([.[] | select(.p=="True")]      | length),
          degraded_true:    ([.[] | select(.d=="True")]      | length)
        }
      | "  Available=True: \(.available_true)\n  Progressing=True: \(.progressing_true)\n  Degraded=True: \(.degraded_true)"
    '
}

print_installed_olm_operators() {
    # OLM-installed operator CSVs
    if ! $OCCMD api-resources | grep -q '^clusterserviceversions'; then
        echo -e "\nInstalled OLM Operators: ${YELLOW}Not Available (OLM not detected)${NC}"
        return
    fi
    echo -e "\nInstalled OLM Operators (ClusterServiceVersions):"
    $OCCMD get csv -A -o json 2>/dev/null \
      | jq -r '
          .items[]
          | "\(.metadata.namespace)/\(.metadata.name)\t\(.spec.displayName // .metadata.name)\t\(.spec.version // "n/a")\t\(.status.phase // "n/a")"
        ' \
      | awk -F'\t' 'BEGIN{printf "  %-40s %-45s %-15s %-10s\n", "Namespace/Name", "DisplayName", "Version", "Phase"}
                    {printf "  %-40s %-45s %-15s %-10s\n", $1, $2, $3, $4}'
}

# PVC summary
summarize_pvcs() {
    echo -e "\nPVCs per StorageClass:"
    kubectl get pvc --all-namespaces -o json | jq -r '
        .items[] |
        select(.spec.storageClassName != null) |
        "\(.spec.storageClassName) \(.spec.resources.requests.storage)"
    ' | awk '{
        sc=$1; sz=$2;
        if (sz ~ /Gi$/) g=substr(sz,1,length(sz)-2);
        else if (sz ~ /Mi$/) g=sprintf("%.2f",substr(sz,1,length(sz)-2)/1024);
        else g=0;
        count[sc]++; size[sc]+=g;
    } END {
        for (sc in count)
            printf "  %s: %d PVCs, %.2f GiB\n", sc, count[sc], size[sc];
    }'
}

# Resource requests & limits
summarize_requests_limits() {
    echo -e "\nResource Requests & Limits (CPU & Memory) per Namespace:"
    kubectl get pods --all-namespaces -o json |
    jq -r '
        .items[] |
        select(.spec.containers != null) |
        .metadata.namespace as $ns |
        .spec.containers[]? |
        select(.resources != null) |
        [$ns, (.resources.requests.cpu // "0"), (.resources.requests.memory // "0"), (.resources.limits.cpu // "0"), (.resources.limits.memory // "0")] |
        @tsv
    ' | awk -F '\t' '
        {
            ns=$1;
            reqcpu=$2; reqmem=$3; limcpu=$4; limmem=$5;
            gsub(/[^0-9.]/,"",reqcpu); gsub(/[^0-9.]/,"",reqmem);
            gsub(/[^0-9.]/,"",limcpu); gsub(/[^0-9.]/,"",limmem);
            if ($3 ~ /Gi/) reqmem *= 1024;
            if ($5 ~ /Gi/) limmem *= 1024;
            rcpu[ns]+=reqcpu; rmem[ns]+=reqmem;
            lcpu[ns]+=limcpu; lmem[ns]+=limmem;
        } END {
            printf "%-20s %-10s %-10s %-10s %-10s\n", "Namespace", "ReqCPU", "ReqMemMi", "LimCPU", "LimMemMi";
            for (ns in rcpu)
                printf "%-20s %-10.2f %-10.2f %-10.2f %-10.2f\n", ns, rcpu[ns], rmem[ns], lcpu[ns], lmem[ns];
        }
    '
}

# Pending pods
summarize_pending_pods() {
    echo -e "\nPending Pods and Reasons:"
    kubectl get pods --all-namespaces --field-selector=status.phase=Pending -o json |
    jq -r '.items[] | [.metadata.namespace, .metadata.name, (.status.conditions[]? | select(.type=="PodScheduled") | .reason // "Unknown")] | @tsv' |
    awk -F '\t' '{count[$3]++} END {for (r in count) printf "  %s: %d\n", r, count[r]; if (NR==0) print "  None"}'
}

# Node usage vs allocatable
summarize_node_usage() {
    echo -e "\nNode Resource Usage vs Allocatable:"
    if metrics_available; then
        kubectl top nodes --no-headers | awk '{printf "  %-25s CPU: %s / %s  |  Memory: %s / %s\n", $1, $2, $3, $4, $5}'
    else
        echo "  Not Available – metrics server not installed"
    fi
}

# Pods per node
summarize_pods_per_node() {
    echo -e "\nPod Distribution per Node:"
    kubectl get pods -A -o json | jq -r '.items[].spec.nodeName' | sort | uniq -c | sort -nr | awk '{printf "  %s: %s pods\n", $2, $1}'
}

# Top CPU/memory pods
summarize_top_consumers() {
    echo -e "\nTop 5 Pods by CPU Usage:"
    if metrics_available; then
        kubectl top pods --all-namespaces --sort-by=cpu --no-headers | head -n 5 | awk '{printf "  %s/%s: %s\n", $1, $2, $3}'
    else
        echo "  Not Available – metrics server not installed"
    fi

    echo -e "\nTop 5 Pods by Memory Usage:"
    if metrics_available; then
        kubectl top pods --all-namespaces --sort-by=memory --no-headers | head -n 5 | awk '{printf "  %s/%s: %s\n", $1, $2, $4}'
    else
        echo "  Not Available – metrics server not installed"
    fi
}

# LimitRanges
summarize_limitranges() {
    echo -e "\nLimitRanges per Namespace:"
    kubectl get limitranges --all-namespaces --no-headers 2>/dev/null | awk '{count[$1]++} END {for (ns in count) printf "  %s: %d\n", ns, count[ns]; if (NR==0) print "  None"}'
}

# ResourceQuotas
summarize_resourcequotas() {
    echo -e "\nResourceQuotas per Namespace:"
    kubectl get resourcequotas --all-namespaces --no-headers 2>/dev/null | awk '{count[$1]++} END {for (ns in count) printf "  %s: %d\n", ns, count[ns]; if (NR==0) print "  None"}'
}

# Redirect output to log
exec > >(tee -i preflight_out.log)
exec 2>&1

# Header
echo -e "${BLUE}=============================="
echo -e "     Sentinella Preflight"
echo -e "==============================${NC}"

# Kubernetes version
echo -n "Kubernetes Version: "
echo -e "${GREEN}$(get_k8s_version)${NC}"

echo -e "${YELLOW}Evaluating OpenShift Deployment...${NC}"

# --- OpenShift details (if available) ---
if is_openshift; then
    ocp_ver="$(get_ocp_version)"
    infra_name="$(get_cluster_name)"
    base_domain="$(get_base_domain)"
    apps_domain="$(get_apps_domain)"

    echo -e "OpenShift Version:   ${GREEN}${ocp_ver:-Unknown}${NC}"
    echo -e "Cluster Name (infra):${GREEN}${infra_name:-Unknown}${NC}"
    if [ -n "$base_domain" ]; then
        echo -e "Base Domain:         ${GREEN}${base_domain}${NC}"
    fi
    if [ -n "$apps_domain" ]; then
        echo -e "Apps Route Domain:   ${GREEN}${apps_domain}${NC}"
    fi

    print_cluster_operators
    print_installed_olm_operators
else
    echo -e "${YELLOW}(config.openshift.io not detected — skipping OpenShift-specific details)${NC}"
fi

# Basic resource stats
echo -e "\nNode quantity:   ${GREEN}$(kubectl get nodes --no-headers | wc -l)${NC}"
echo -e "Master Nodes:        ${GREEN}$(kubectl get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l)${NC}"
echo -e "Worker Nodes:        ${GREEN}$(kubectl get nodes --no-headers 2>/dev/null | grep -v master | wc -l)${NC}"
echo -e "Pods:                ${GREEN}$(get_resource_count pods)${NC}"
echo -e "Deployments:         ${GREEN}$(get_resource_count deployments)${NC}"
echo -e "Services:            ${GREEN}$(get_resource_count services)${NC}"
echo -e "LoadBalancers:       ${GREEN}$(kubectl get svc -A -o=jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}: {.status.loadBalancer.ingress[0].ip}{"\n"}{end}' | wc -l)${NC}"
echo -e "Operators Installed: ${GREEN}$(kubectl get csv --all-namespaces --no-headers 2>/dev/null | wc -l)${NC}"
echo -e "DaemonSets:          ${GREEN}$(get_resource_count daemonsets)${NC}"

# Networks check
if kubectl api-resources | grep -qw networks; then
    networks=$(get_resource_count networks)
else
    networks="Not Available"
fi
echo -e "Networks:            ${GREEN}${networks}${NC}"

# Storage classes
echo -e "\nStorage Classes:"
get_storage_classes | while read -r sc; do
    echo -e "  ${GREEN}${sc}${NC}"
done

# Storage + CRDs
summarize_pvcs
echo -e "\nVolumeSnapshotClass Support: ${GREEN}$(get_volume_snapshot_support)${NC}"
echo -e "CRDs: ${GREEN}$(kubectl get crds --no-headers 2>/dev/null | wc -l)${NC}"
echo -e "Jobs: ${GREEN}$(get_resource_count jobs)${NC}"
echo -e "CronJobs: ${GREEN}$(get_resource_count cronjobs)${NC}"

# Extended insights
summarize_requests_limits
summarize_pending_pods
summarize_node_usage
summarize_pods_per_node
summarize_top_consumers
summarize_limitranges
summarize_resourcequotas

# Done
echo -e "\n${YELLOW}Evaluation Completed."
echo -e "Output saved to preflight_out.log${NC}"
