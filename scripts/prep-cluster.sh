#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
TARGET_OCP_VERSION="${TARGET_OCP_VERSION:-4.18.25}"   # set desired OCP version
WORKER_MACHINESET="${WORKER_MACHINESET:-Standard_D96s_v5}" # or Standard_D96s_v6
WORKER_COUNT="${WORKER_COUNT:-6}"                    # number of workers

# Optional dedicated ODF pool
USE_ODF_POOL="${USE_ODF_POOL:-true}"    # true/false
ODF_MACHINESET="${ODF_MACHINESET:-Standard_D16s_v5}" # smaller/disk-heavy SKU
ODF_NODE_COUNT="${ODF_NODE_COUNT:-3}"

ODF_CHANNEL="${ODF_CHANNEL:-stable-4.18}"
CNV_CHANNEL="${CNV_CHANNEL:-stable}"
NS_ODF="openshift-storage"
NS_CNV="openshift-cnv"

# Ensure oc is logged in
oc whoami >/dev/null

echo "=== STEP 1: Upgrade cluster to target version $TARGET_OCP_VERSION ==="
oc adm upgrade --to="$TARGET_OCP_VERSION" || true

echo "=== STEP 2: Scale worker nodes to $WORKER_COUNT of $WORKER_MACHINESET ==="
# Ensure jq is available
command -v jq >/dev/null 2>&1 || { echo >&2 "ERROR: jq is required"; exit 1; }

MS=$(oc get machinesets -n openshift-machine-api -o json \
  | jq -r --arg sku "$WORKER_MACHINESET" '
      .items[]
      | select(.spec.template.spec.providerSpec.value.vmSize == $sku)
      | .metadata.name')

if [[ -z "$MS" ]]; then
  echo "ERROR: No MachineSet found for SKU $WORKER_MACHINESET"
  exit 1
fi

oc scale machineset "$MS" -n openshift-machine-api --replicas="$WORKER_COUNT"
oc wait node --for=condition=Ready --timeout=30m \
  -l "node.kubernetes.io/instance-type=$WORKER_MACHINESET"

if [[ "$USE_ODF_POOL" == "true" ]]; then
  echo "=== STEP 2b: Ensure ODF node pool ($ODF_MACHINESET, $ODF_NODE_COUNT nodes) ==="
  ODF_MS=$(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep "$ODF_MACHINESET" || true)
  if [[ -z "$ODF_MS" ]]; then
    echo "WARNING: No MachineSet found for $ODF_MACHINESET. You may need to create one manually."
  else
    oc scale machineset "$ODF_MS" -n openshift-machine-api --replicas="$ODF_NODE_COUNT"
    oc wait node --for=condition=Ready --timeout=30m -l "node.kubernetes.io/instance-type=$ODF_MACHINESET"
    # Label and taint nodes for ODF
    for n in $(oc get nodes -l node.kubernetes.io/instance-type=$ODF_MACHINESET -o name); do
      oc label $n odf=true --overwrite
      oc adm taint nodes $n dedicated=odf:NoSchedule --overwrite || true
    done
  fi
fi

echo "=== STEP 3: Install ODF Operator and StorageSystem ==="
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
  kind: storagecluster
  name: ocs-storagecluster
  namespace: $NS_ODF
EOF

echo "Waiting for Ceph cluster to be healthy..."
oc wait --for=condition=Available --timeout=30m storagecluster/ocs-storagecluster -n $NS_ODF || true

echo "=== STEP 4: Install OpenShift Virtualization (CNV) ==="
oc apply -f - <<EOF
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

echo "Waiting for HCO to be ready..."
oc rollout status deployment/virt-operator -n $NS_CNV --timeout=15m || true

oc apply -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: $NS_CNV
spec: {}
EOF

oc wait hyperconverged/kubevirt-hyperconverged -n $NS_CNV --for=condition=Available --timeout=20m || true

echo "=== STEP 5: Ensure wrapper storageclasses exist (odf-rbd, odf-cephfs) ==="
oc apply -f cluster/storageclasses/odf-rbd.yaml || true
oc apply -f cluster/storageclasses/odf-cephfs.yaml || true

echo "=== PREP COMPLETE ==="
echo "You can now run perf tests, e.g.:"
echo "  make PROFILE=ootb FAMILY=v5 run"

