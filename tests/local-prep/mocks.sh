#!/usr/bin/env bash
OC_LOG="${OC_LOG:-/tmp/oc.log}"

oc() {

  local arg1="${1:-}"
  local arg2="${2:-}"
  case "$arg1 $arg2" in
    "whoami")
      echo "system:admin"
      echo "oc $*" >> "$OC_LOG"
      ;;
    "get machinesets")
      if [[ "$*" =~ jsonpath ]]; then
        echo "perftest1-worker-az1"
      else
        # Fake two machinesets: one D96s_v5, one D16s_v5
        cat <<EOF
{
  "items": [
    {
      "metadata": { "name": "perftest1-worker-az1" },
      "spec": {
        "template": { "spec": { "providerSpec": { "value": { "vmSize": "Standard_D96s_v5" } } } }
      }
    },
    {
      "metadata": { "name": "perftest1-odf-az1" },
      "spec": {
        "template": { "spec": { "providerSpec": { "value": { "vmSize": "Standard_D16s_v5" } } } }
      }
    }
  ]
}
EOF
      fi
      ;;
    "get nodes")
      echo "node/perftest1-worker-az1" 
      echo "node/perftest1-worker-az2"
      ;;
    *)
      echo "oc $*" >> "$OC_LOG"
      ;;
  esac
}

jq() {
  input=$(cat)
  if echo "$input" | grep -q 'Standard_D96s_v5'; then
    echo "perftest1-worker-az1"
  elif echo "$input" | grep -q 'Standard_D16s_v5'; then
    echo "perftest1-odf-az1"
  else
    echo ""
  fi
}

