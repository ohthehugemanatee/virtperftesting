#!/usr/bin/env bash
set -euo pipefail
oc get ns perf-tests >/dev/null 2>&1 || oc create ns perf-tests
oc label ns perf-tests openshift.io/cluster-monitoring=true --overwrite
oc adm policy add-scc-to-group privileged system:serviceaccounts:perf-tests || true

