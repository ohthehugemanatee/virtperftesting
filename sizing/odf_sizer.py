
#!/usr/bin/env python3

import sys, math, yaml, json, argparse
from pathlib import Path

def load_cfg(path: Path):
    with open(path, "r") as f:
        return yaml.safe_load(f)

def mbps_to_iops(throughput_mb_s: float, block_kb: int = 4):
    # Approximate translation for small-block profile
    return (throughput_mb_s * 1024) / block_kb

def cap_with_headroom(val: float, headroom: float):
    return val * headroom

def plan(cfg):
    tgt_iops = cfg["workload_target"]["aggregate_iops"]
    tgt_tput = cfg["workload_target"]["aggregate_throughput_mb_s"]
    repl = cfg["ceph"]["replication"]
    nodes = cfg["cluster"]["odf_worker_nodes"]

    # Backend IO amplified by replication
    backend_iops = tgt_iops * repl
    backend_tput = tgt_tput * repl

    # Per-disk effective caps
    per_disk_iops = cap_with_headroom(cfg["disk"]["per_disk_iops_cap"], cfg["safety"]["iops_headroom"])
    per_disk_tput = cap_with_headroom(cfg["disk"]["per_disk_throughput_mb_s"], cfg["safety"]["tput_headroom"])

    # Per-VM (node) caps
    vm_iops_cap = cap_with_headroom(cfg["vm_caps"]["vm_disk_iops_cap"], cfg["safety"]["iops_headroom"])
    vm_tput_cap = cap_with_headroom(cfg["vm_caps"]["vm_disk_throughput_mb_s"], cfg["safety"]["tput_headroom"])
    vm_nic_cap  = cap_with_headroom(cfg["vm_caps"]["vm_nic_throughput_mb_s"], cfg["safety"]["tput_headroom"])

    # Determine required number of disks by IOPS and throughput separately
    disks_for_iops = math.ceil(backend_iops / per_disk_iops) if per_disk_iops > 0 else float("inf")
    disks_for_tput = math.ceil(backend_tput / per_disk_tput) if per_disk_tput > 0 else float("inf")
    disks_total = max(disks_for_iops, disks_for_tput)

    # Spread across nodes
    osds_per_node = math.ceil(disks_total / nodes)

    # Check per-node caps
    node_iops = min(osds_per_node * per_disk_iops, vm_iops_cap)
    node_tput = min(osds_per_node * per_disk_tput, vm_tput_cap, vm_nic_cap)

    # Cluster capacity achievable with this layout
    cluster_iops = node_iops * nodes
    cluster_tput = node_tput * nodes

    # Headroom against targets
    iops_ok = cluster_iops >= backend_iops
    tput_ok = cluster_tput >= backend_tput

    return {
        "inputs": cfg,
        "targets": {
            "client_iops": tgt_iops,
            "client_throughput_mb_s": tgt_tput,
            "backend_iops": backend_iops,
            "backend_throughput_mb_s": backend_tput,
        },
        "per_disk_effective_caps": {
            "iops": per_disk_iops,
            "throughput_mb_s": per_disk_tput,
        },
        "per_node_caps_effective": {
            "vm_disk_iops_cap": vm_iops_cap,
            "vm_disk_throughput_mb_s": vm_tput_cap,
            "vm_nic_throughput_mb_s": vm_nic_cap,
        },
        "layout": {
            "nodes": nodes,
            "osds_per_node": osds_per_node,
            "disks_total": osds_per_node * nodes,
            "one_osd_per_disk": bool(cfg["disk"].get("osds_per_disk",1) == 1),
        },
        "achievable_cluster_caps": {
            "iops": cluster_iops,
            "throughput_mb_s": cluster_tput,
        },
        "meets_targets": {
            "iops": iops_ok,
            "throughput": tput_ok,
        }
    }

def pretty_mb(n): 
    return f"{n:,.0f} MB/s"
def pretty_iops(n):
    return f"{n:,.0f} IOPS"

def explain(plan):
    p = []
    t = plan["targets"]
    caps = plan["per_disk_effective_caps"]
    nodecaps = plan["per_node_caps_effective"]
    lay = plan["layout"]
    ach = plan["achievable_cluster_caps"]
    p.append("=== ODF Sizing Plan ===")
    p.append(f"Targets (client): {pretty_iops(t['client_iops'])}, {pretty_mb(t['client_throughput_mb_s'])}")
    p.append(f"Backend (x{plan['inputs']['ceph']['replication']} replication): {pretty_iops(t['backend_iops'])}, {pretty_mb(t['backend_throughput_mb_s'])}")
    p.append("")
    p.append(f"Per-disk effective caps (with headroom): {pretty_iops(caps['iops'])}, {pretty_mb(caps['throughput_mb_s'])}")
    p.append(f"Per-node effective caps (with headroom): disk {pretty_iops(nodecaps['vm_disk_iops_cap'])} / {pretty_mb(nodecaps['vm_disk_throughput_mb_s'])}, NIC {pretty_mb(nodecaps['vm_nic_throughput_mb_s'])}")
    p.append("")
    p.append(f"Layout suggestion: {lay['nodes']} nodes, {lay['osds_per_node']} disks/OSDs per node => {lay['disks_total']} total disks (1 OSD per disk: {lay['one_osd_per_disk']})")
    p.append(f"Cluster achievable (bounded by per-node caps): {pretty_iops(ach['iops'])}, {pretty_mb(ach['throughput_mb_s'])}")
    p.append(f"Meets targets? IOPS: {plan['meets_targets']['iops']}, Throughput: {plan['meets_targets']['throughput']}")
    return "\n".join(p)

def main():
    ap = argparse.ArgumentParser(description="ODF (Ceph) sizing helper for Azure managed disks on ARO")
    ap.add_argument("--config", "-c", default="sizing/odf_sizer.config.yaml", help="Path to YAML config")
    ap.add_argument("--json", action="store_true", help="Output JSON")
    args = ap.parse_args()
    cfg = load_cfg(Path(args.config))
    pl = plan(cfg)
    if args.json:
        print(json.dumps(pl, indent=2))
    else:
        print(explain(pl))

if __name__ == "__main__":
    main()
