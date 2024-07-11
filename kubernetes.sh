#!/bin/bash

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Define a function to show a waiting cursor
show_cursor() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null
then
    echo -e "${RED}kubectl could not be found. Please install kubectl to use this script.${NC}"
    exit
fi

# Check if jq is installed
if ! command -v jq &> /dev/null
then
    echo -e "${RED}jq could not be found. Please install jq to use this script.${NC}"
    if [ -f /etc/redhat-release ]; then
        echo -e "${YELLOW}You can install jq using: sudo dnf install jq${NC}"
    elif [ -f /etc/debian_version ]; then
        echo -e "${YELLOW}You can install jq using: sudo apt-get install jq${NC}"
    fi
    exit
fi

# Function to get the count of resources
get_resource_count() {
    local resource=$1
    kubectl get $resource --all-namespaces --no-headers | wc -l
}

# Function to list storage classes
list_storage_classes() {
    kubectl get storageclass --no-headers -o custom-columns=":metadata.name"
}

# Function to count master nodes
count_master_nodes() {
    kubectl get nodes --selector='node-role.kubernetes.io/master' --no-headers | wc -l
}

# Function to count worker nodes
count_worker_nodes() {
    kubectl get nodes --selector='!node-role.kubernetes.io/master' --no-headers | wc -l
}

# Function to check VolumeSnapshotClass support
check_volume_snapshot_class() {
    kubectl get volumesnapshotclass --no-headers &> /dev/null
    if [ $? -eq 0 ]; then
        echo "Supported"
    else
        echo "Not Supported"
    fi
}

# Function to get Kubernetes version
get_kubernetes_version() {
    kubectl version --output=json | jq -r '.serverVersion.gitVersion'
}

# Redirect output to a file
exec > >(tee -i preflight_out.log)
exec 2>&1

echo -e "${BLUE}======================="
echo -e " Sentinella  Preflight"
echo -e "=======================${NC}"

# Get Kubernetes version
echo -n "Kubernetes Version: "
(kubernetes_version=$(get_kubernetes_version) &
show_cursor $!
echo -e "${GREEN}${kubernetes_version}${NC}")

echo -e "${YELLOW}Evaluating OpenShift Deployment...${NC}"

# Quantity of nodes
echo -n "Quantity of Nodes: "
(kubectl get nodes --no-headers | wc -l) &
show_cursor $!
echo -e "${GREEN}$(kubectl get nodes --no-headers | wc -l)${NC}"

# Quantity of master nodes
echo -n "Quantity of Master Nodes: "
(count_master_nodes) &
show_cursor $!
echo -e "${GREEN}$(count_master_nodes)${NC}"

# Quantity of worker nodes
echo -n "Quantity of Worker Nodes: "
(count_worker_nodes) &
show_cursor $!
echo -e "${GREEN}$(count_worker_nodes)${NC}"

# Quantity of pods
echo -n "Quantity of Pods: "
(get_resource_count pods) &
show_cursor $!
echo -e "${GREEN}$(get_resource_count pods)${NC}"

# Quantity of deployments
echo -n "Quantity of Deployments: "
(get_resource_count deployments) &
show_cursor $!
echo -e "${GREEN}$(get_resource_count deployments)${NC}"

# Quantity of services
echo -n "Quantity of Services: "
(get_resource_count services) &
show_cursor $!
echo -e "${GREEN}$(get_resource_count services)${NC}"

# Quantity of networks
echo -n "Quantity of Networks: "
(get_resource_count networks) &
show_cursor $!
echo -e "${GREEN}$(get_resource_count networks)${NC}"

# List storage classes
echo "Storage Classes:"
list_storage_classes | while read -r storage_class; do
    echo -e "${GREEN}${storage_class}${NC}"
done

# Check for VolumeSnapshotClass support
echo -n "VolumeSnapshotClass Support: "
(check_volume_snapshot_class) &
show_cursor $!
echo -e "${GREEN}$(check_volume_snapshot_class)${NC}"

echo -e "${YELLOW}Evaluation Completed.${NC}"
echo -e "${YELLOW}The preflight_out.log has been generated.${NC}"
