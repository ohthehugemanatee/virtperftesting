#!/usr/bin/env bash
set -euo pipefail

RESULTDIR="${1:-results}"
SELLERDIR="seller-pack"
mkdir -p "$SELLERDIR/charts"

python3 - <<'PY'
import json, glob, os, math
import pandas as pd
import matplotlib.pyplot as plt

# Pre-filled seller anchors
anchors = {
    "pgbench":       ("Departmental DB", "400 TPM",    "HR/CRM/ERP module"),
    "hammerdb":      ("Enterprise DB",   "1000 TPM",   "E-commerce order DB"),
    "redis-memtier": ("Cache",           "50k ops/s",  "API gateway / session store"),
    "nginx-wrk":     ("Web front-end",   "50k req/s",  "Static/dynamic web"),
    "smallfile":     ("File ops",        "10k ops/s",  "Logs / configs"),
}

rows = []
for fname in glob.glob("results/*.json"):
    with open(fname) as f:
        try:
            data = json.load(f)
        except Exception:
            continue
    bench = data.get("benchmark", "")
    if bench not in anchors:
        continue
    pod_val = float(data.get("pod_result", 0))
    vm_val  = float(data.get("vm_result", 0))
    cls, load, scenario = anchors[bench]
    overhead = ( (pod_val - vm_val) / pod_val * 100.0 ) if pod_val > 0 else float("nan")
    rows.append({
        "Benchmark": bench,
        "Workload": cls,
        "Moderate Load": load,
        "Scenario": scenario,
        "Pod Result": round(pod_val, 2),
        "VM Result": round(vm_val, 2),
        "Overhead %": round(overhead, 1) if not math.isnan(overhead) else "",
    })

df = pd.DataFrame(rows).sort_values(["Workload"])
os.makedirs("seller-pack", exist_ok=True)
df.to_csv("seller-pack/summary.csv", index=False)
with open("seller-pack/summary.md", "w") as f:
    f.write(df.to_markdown(index=False))

# Charts
for _, row in df.iterrows():
    fig, ax = plt.subplots()
    ax.bar(["Pod","VM"], [row["Pod Result"], row["VM Result"]])
    ax.set_title(f"{row['Workload']} – {row['Moderate Load']}")
    ax.set_ylabel("Throughput")
    fig.tight_layout()
    path = f"seller-pack/charts/{row['Workload'].replace(' ','_')}.png"
    plt.savefig(path, dpi=150)
    plt.close()
PY
