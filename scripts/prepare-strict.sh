#!/usr/bin/env bash
set -euo pipefail

if oc api-resources | grep -q performance.openshift.io; then
  oc apply -f cluster/tuning/performanceprofile-strict.yaml
  oc wait mcp/worker --for='condition=Updated=True' --timeout=45m
else
  oc apply -f cluster/tuning/kubeletconfig-strict.yaml
  oc wait mcp/worker --for='condition=Updated=True' --timeout=45m
fi

# Label strict-capable workers (you can refine this selector if you split pools)
for n in $(oc get nodes -l 'node-role.kubernetes.io/worker' -o name); do
  oc label $n performance.openshift.io/profile=strict --overwrite
done
