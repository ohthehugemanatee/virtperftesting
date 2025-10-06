#!/usr/bin/env bash
set -euo pipefail
# Ensure node labels exist for family selection
# oc label node -l "node.kubernetes.io/instance-type=Standard_D96s_v5" sku.family=dsv5-large --overwrite
# oc label node -l "node.kubernetes.io/instance-type=Standard_D96s_v6" sku.family=dsv6-large --overwrite
echo "OOTB profile: no PAO/kubelet tuning changes applied."
