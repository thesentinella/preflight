#!/bin/bash

# Define colors (only apply if running in terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# Spinner (only if running in terminal)
show_spinner() {
    if [ ! -t 1 ]; then return; fi
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid &> /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "      \b\b\b\b\b\b"
}

# Check requirements
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl is not installed. Please install it to use this script.${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}jq is not installed. Please install it to use this script.${NC}"
    if [ -f /etc/redhat-release ]; then
        echo -e "${YELLOW}Install with: sudo dnf install jq${NC}"
    elif [ -f /etc/debian_version ]; then
        echo -e "${YELLOW}Install with: sudo apt-get install jq${NC}"
    fi
    exit 1
fi

# Helper functions
get_resource_count() {
    kubectl get "$1" --all-namespaces --no-headers 2>/dev/null | wc -l
}

get_k8s_version() {
    kubectl version --output=json | jq -r '.serverVersion.gitVersion'
}

get_storage_classes() {
    kubectl get storageclass --no-headers -o custom-columns=":metadata.name"
}

has_volume_snapshot_support() {
    if kubectl get volumesnapshotclass --no-headers &> /dev/null; then
        echo "Supported"
    else
        echo "Not Supported"
    fi
}

# Redirect all output to file and terminal
exec > >(tee -i preflight_out.log)
exec 2>&1

# Header
echo -e "${BLUE}=============================="
echo -e "     Sentinella Preflight"
echo -e "==============================${NC}"

# Kubernetes version
echo -n "Kubernetes Version: "
version=$(get_k8s_version)
echo -e "${GREEN}${version}${NC}"

echo -e "${YELLOW}Evaluating OpenShift Deployment...${NC}"

# Gather data
nodes=$(kubectl get nodes --no-headers | wc -l)
masters=$(kubectl get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l)
workers=$(kubectl get nodes --no-headers 2>/dev/null | grep -v master | wc -l)
pods=$(get_resource_count pods)
deployments=$(get_resource_count deployments)
services=$(get_resource_count services)

# Optional: check if 'networks' resource exists
if kubectl api-resources | grep -qw networks; then
    networks=$(get_resource_count networks)
else
    networks="Not Available"
fi

# Storage classes and volume snapshot support
storage_classes=$(get_storage_classes)
snapshot_support=$(has_volume_snapshot_support)

# Output results
echo -e "Quantity of Nodes: ${GREEN}${nodes}${NC}"
echo -e "Quantity of Master Nodes: ${GREEN}${masters}${NC}"
echo -e "Quantity of Worker Nodes: ${GREEN}${workers}${NC}"
echo -e "Quantity of Pods: ${GREEN}${pods}${NC}"
echo -e "Quantity of Deployments: ${GREEN}${deployments}${NC}"
echo -e "Quantity of Services: ${GREEN}${services}${NC}"
echo -e "Quantity of Networks: ${GREEN}${networks}${NC}"

echo "Storage Classes:"
while read -r sc; do
    echo -e "  ${GREEN}${sc}${NC}"
done <<< "$storage_classes"

echo -e "VolumeSnapshotClass Support: ${GREEN}${snapshot_support}${NC}"

echo -e "${YELLOW}Evaluation Completed.${NC}"
echo -e "${YELLOW}Output saved to preflight_out.log${NC}"

