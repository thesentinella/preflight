#!/usr/bin/env bash
# Exercise the normal CLI entry point without a cluster.
set -eu
script=$(cd "$(dirname "$0")/.." && pwd)/kubernetes.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
cat > oc <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> calls
[[ $1 == --request-timeout=* ]] && shift
case "$1 $2" in
    'config current-context') echo fixture ;;
    'version -o') [[ -z ${OFFLINE:-} ]] || exit 1; echo '{"serverVersion":{"gitVersion":"v1.test"}}' ;;
    'api-resources -o') [[ -z ${OCP:-} ]] || echo clusterversions.config.openshift.io ;;
    'get pods') echo '{"items":[{"metadata":{"namespace":"demo"},"spec":{"containers":[{"resources":{"requests":{"cpu":"1","memory":"1Gi"}}},{"resources":{"requests":{"cpu":"500m","memory":"512Mi"}}}]},"status":{"phase":"Pending"}}]}' ;;
    'get pvc') echo '{"items":[{"spec":{"resources":{"requests":{"storage":"1Ti"}}},"status":{"phase":"Pending"}}]}' ;;
    'get --raw') echo '{"items":[{"metadata":{"namespace":"n","name":"p"},"containers":[{"usage":{"cpu":"500000000n","memory":"1024Ki"}}]}]}' ;;
    'get jobs') echo Forbidden >&2; exit 1 ;;
    'get deployments'|'get daemonsets'|'get crds'|'get cronjobs'|'top nodes') ;;
    *) echo '{"items":[]}' ;;
esac
MOCK
chmod +x oc
export PATH="$tmp:$PATH"
"$script" > output
cmp output preflight_out.log
grep -Fq $'demo\t1.5\t1536\t0\t0' output
grep -Fq $'(none)\t1\t1024\t1' output
grep -Fq $'Unknown\t1' output
grep -Fq $'n/p\t500' output
grep -Fq $'n/p\t1' output
grep -Fxq 'jobs: Unavailable' output
[[ $(grep -c ' get pods ' calls) == 1 ]]
! grep -q clusterversions calls || exit 1
OCP=1 "$script" > output
grep -Fq 'MachineConfigPools' output
if grep -Fq 'Unavailable (see diagnostic' output; then cat output; exit 1; fi
if OFFLINE=1 "$script" > output; then exit 1; fi
echo "Report checks passed"
