
# ODF Sizing Helper (Azure Managed Disks)

Use `sizing/odf_sizer.py` to estimate how many **managed disks (OSDs)** you need per ODF worker to hit a target IOPS/throughput,
accounting for Ceph replication and per-VM caps. Edit `sizing/odf_sizer.config.yaml` with your numbers.

## Example

```bash
cd perf-suite
python3 sizing/odf_sizer.py
```

Outputs a proposed layout like `6 nodes × 6 disks each = 36 disks` and whether the plan meets targets.
Use Azure docs to fill **per-disk** and **per-VM** caps (e.g., Premium SSD v2 vs Ultra, D96s v5/v6). Add headroom to avoid throttling.

**Tip:** Ceph scales with parallelism. Prefer more smaller disks (OSDs) until you hit per-VM disk or NIC limits.
