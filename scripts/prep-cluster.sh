#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
TARGET_OCP_VERSION="${TARGET_OCP_VERSION:-4.18.25}"   # set desired OCP version
COMPUTE_MACHINESET="${COMPUTE_MACHINESET:-Standard_D96s_v5}" # or Standard_D96s_v6
COMPUTE_COUNT="${COMPUTE_COUNT:-6}"                    # number of workers

# Optional dedicated ODF pool
USE_ODF_POOL="${USE_ODF_POOL:-true}"    # true/false
ODF_MACHINESET="${ODF_MACHINESET:-Standard_D16s_v5}" # smaller/disk-heavy SKU
ODF_NODE_COUNT="${ODF_NODE_COUNT:-3}"

ODF_CHANNEL="${ODF_CHANNEL:-stable-4.18}"
CNV_CHANNEL="${CNV_CHANNEL:-stable}"
NS_ODF="openshift-storage"
NS_CNV="openshift-cnv"

ASK_ALL="${ASK_ALL:-false}"

confirm() {
  local prompt="$1"
  if [ "$ASK_ALL" = true ]; then
    echo "$prompt [y/n/a/q]: y"
    return 0
  fi

  while true; do
    read -rp "$prompt [y/n/a/q]: " ans
    case "$ans" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      [Aa]) ASK_ALL=true; return 0 ;;
      [Qq]) echo "Aborting."; exit 1 ;;
      *) echo "Please enter y (yes), n (no), a (all), or q (quit)." ;;
    esac
  done
}

sanitize_sku() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/_/-/g'
}

create_machineset_for_sku () {
  local sku="$1"
  local safe_sku=$(sanitize_sku "$sku")
  local replicas="$2"
  local ns="openshift-machine-api"
  local template_ms

  # Pick the first existing worker machineset as template
  template_ms=$(oc get machinesets -n $ns -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "$template_ms" ]]; then
    echo "ERROR: No existing MachineSet found. Please create one manually."
    exit 1
  fi

  # Dump template, change name and vmSize
  local newname="${template_ms%-*}-${safe_sku}"

  oc get machineset "$template_ms" -n $ns -o json \
    | jq --arg newname "$newname" --arg sku "$sku" --arg replicas $replicas'
        .metadata.name = $newname
        | .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $newname
        | .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $newname
        | .spec.template.spec.providerSpec.value.vmSize = $sku
        | .spec.replicas = $replicas 
      ' \
    | oc apply --quiet -n $ns -f -

  echo "$newname"
}

ensure_scaled_machineset_for_sku() {
  local sku="$1"
  local replicas="$2"
  local ns="openshift-machine-api"
  local ms
  
  # Ensure jq is available
  command -v jq >/dev/null 2>&1 || { echo >&2 "ERROR: jq is required"; exit 1; }

  # look for an existing machineset
  ms=$(oc get machinesets -n openshift-machine-api -o json \
    | jq -r --arg sku "$sku" '
        .items[0]
        | select(.spec.template.spec.providerSpec.value.vmSize == $sku)
        | .metadata.name')

  if [[ -z "$ms" ]]; then
    echo "Could not find an existing machineset with SKU $sku"
    if confirm "Automatically create machineset for $replicas VMs with SKU $sku ?"; then
      ms=$(create_machineset_for_sku "$sku" "$replicas")
    else
      echo "Cannot find candidate machineset and cannot create one. Exiting."
      exit 1
    fi
  else
    echo "Found machineset $ms"
  fi
  
  if confirm "Automatically ensure machineset $ms has $replicas replicas?"; then
    oc scale machineset "$ms" -n openshift-machine-api --replicas="$replicas"
  fi

  echo "Waiting for compute machineset $ms to reach $replicas ready replicas..."
  if ! oc wait --for=jsonpath='{.status.readyReplicas}'="$replicas" \
       machineset "$ms" -n openshift-machine-api --timeout=15m; then
    echo "ERROR: Compute machineset $ms did not reach $replicas ready replicas."
    echo "Check cluster quota and node creation events: oc describe machineset/$ms -n openshift-machine-api"
    exit 1
  fi
}

# Ensure oc is logged in
oc whoami >/dev/null

echo "=== STEP 1: Upgrade cluster to target version $TARGET_OCP_VERSION ==="
if confirm "Automatically upgrade cluster to target version $TARGET_OCP_VERSION ?"; then
  oc adm upgrade --to="$TARGET_OCP_VERSION" || true
  echo "You may additionally need to run 'az aro update -n perftest1 -g arovert --upgradeable-to <version>'. Check your cloud console for details."
fi

echo "=== STEP 2: Scale worker nodes to $COMPUTE_COUNT of $COMPUTE_MACHINESET ==="

ensure_scaled_machineset_for_sku "$COMPUTE_MACHINESET" "$COMPUTE_COUNT"

if [[ "$USE_ODF_POOL" == "true" ]]; then
  echo "=== STEP 2b: Ensure ODF node pool ($ODF_MACHINESET, $ODF_NODE_COUNT nodes) ==="
  ensure_scaled_machineset_for_sku "$ODF_MACHINESET" "$ODF_NODE_COUNT"
    # Label and taint nodes for ODF
  for n in $(oc get nodes -l node.kubernetes.io/instance-type=$ODF_MACHINESET -o name); do
    oc label $n odf=true --overwrite
    oc adm taint nodes $n dedicated=odf:NoSchedule --overwrite || true
  done
fi

echo "=== STEP 3: Install ODF Operator and StorageSystem ==="
if confirm "Automatically install ODF Operator and StorageSystem?"; then
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: odf-operatorgroup
  namespace: $NS_ODF
spec:
  targetNamespaces:
  - $NS_ODF
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-subscription
  namespace: $NS_ODF
spec:
  channel: $ODF_CHANNEL
  installPlanApproval: Automatic
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  echo "Waiting for ODF operator pods..."
  oc rollout status deployment/odf-operator-controller-manager -n $NS_ODF --timeout=15m || true

  # Create StorageSystem → StorageCluster
  oc apply -f - <<EOF
apiVersion: odf.openshift.io/v1alpha1
kind: StorageSystem
metadata:
  name: ocs-storagecluster-storagesystem
  namespace: $NS_ODF
spec:
  kind: storagecluster.ocs.openshift.io/v1
  name: ocs-storagecluster
  namespace: $NS_ODF
EOF

  echo "Waiting for Ceph cluster to be healthy..."
  oc wait --for=condition=Available --timeout=30m storagecluster/ocs-storagecluster -n $NS_ODF || true
fi

echo "=== STEP 4: Install OpenShift Virtualization (CNV) ==="
if confirm "Automatically install OpenShift Virtualization operator?"; then
  oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS_CNV
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cnv-operatorgroup
  namespace: $NS_CNV
spec:
  targetNamespaces:
  - $NS_CNV
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: $NS_CNV
spec:
  channel: $CNV_CHANNEL
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  csv=$(oc get subscription kubevirt-hyperconverged -n $NS_CNV -o jsonpath='{.status.installedCSV}')
  echo "Waiting for CSV $csv in $NS_CNV..."
  until [[ "$(oc get csv "$csv" -n $NS_CNV -o jsonpath='{.status.phase}' 2>/dev/null)" == "Succeeded" ]]; do
    echo "  still waiting..."
    sleep 20
  done
  echo "CSV $csv is Succeeded."

  oc apply -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: $NS_CNV
spec: {}
EOF

  oc wait hyperconverged/kubevirt-hyperconverged -n $NS_CNV --for=condition=Available --timeout=20m || true
fi


echo "=== STEP 5: Ensure wrapper storageclasses exist (odf-rbd, odf-cephfs) ==="
oc apply -f cluster/storageclasses/odf-rbd.yaml || true
oc apply -f cluster/storageclasses/odf-cephfs.yaml || true

echo "=== STEP 6: Install benchmark-operator ==="
TMPDIR=$(mktemp -d --suffix=benchmark-operator)
cd $TMPDIR
git clone https://github.com/cloud-bulldozer/benchmark-operator.git 
cd benchmark-operator
make deploy
rm -rf $TMPDIR


echo "=== PREP COMPLETE ==="
echo "You can now run perf tests, e.g.:"
echo "  make PROFILE=ootb FAMILY=v5 run"

