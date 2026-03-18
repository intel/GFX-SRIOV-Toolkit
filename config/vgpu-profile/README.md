# SR-IOV Resource Profile Summary

This document summarizes the SR-IOV resource allocation profile for Intel Battlemage (BMG) GPUs in IDV (Individual Desktop Virtualization) mode.

## Profile File

- **bmg-idv-profile.xml** - IDV workload optimized (fewer, high-performance VFs)

---

## Physical Function (PF) Resources

| Resource | ECC Off | ECC On | Description |
|----------|---------|--------|-------------|
| LMEM | 4 GiB | 4 GiB | Local memory reserved for host |
| GGTT | 768 MiB | 768 MiB | Global GTT space |
| Contexts | 8192 | 8192 | Execution contexts |
| Doorbells | 16 | 16 | Doorbell registers |

---

## Virtual Function (VF) Resource Profiles

| Profile | VFs | LMEM (ECC Off) | LMEM (ECC On) | GGTT | Contexts | Doorbells |
|---------|-----|----------------|---------------|------|----------|-----------|
| Bmg_24 | 1 | 20 GiB | 17 GiB | 640 MiB | 8192 | 240 |
| Bmg_12 | 2 | 10 GiB | 8.5 GiB | 640 MiB | 8192 | 120 |
| Bmg_8 | 3 | 6.66 GiB | 5.66 GiB | 640 MiB | 8192 | 80 |
| Bmg_6 | 4 | 5 GiB | 4.25 GiB | 640 MiB | 8192 | 60 |

**Use case**: High-performance workloads requiring substantial GPU resources per VM (CAD, 3D rendering, gaming).

---

## Scheduler Profiles

### Available profile

- **Edge_DefaultIDV_GPUTimeSlicing** (default)

### Scheduler Parameters (PF)

- Execution Quantum: 25 ms
- Preemption Timeout: 500 ms

### VF Scheduler Parameters

| VF Count | Exec Quantum (ms) | Preempt Timeout (ms) |
|----------|-------------------|----------------------|
| 1 | 25 | 500 |
| 2 | 25 | 500 |
| 3 | 25 | 500 |
| 4 | 25 | 500 |

---

## Step 2 Explained: Enable and Configure GPU VFs

In the top-level workflow, Step 2 is executed with `scripts/provision-sriov.sh`. This step does more than enabling VF instances.

### What Step 2 configures

1. **VF count (virtual GPU instances)**
   - Controlled by `-n` / `--num-vfs`
   - Supported counts: `1, 2, 3, 4`
   - Higher VF count increases density but reduces per-VF share of resources

2. **vGPU profile selection (resource policy template)**
   - Profile data is defined in `bmg-idv-profile.xml`
   - VF count maps to profile tiers (`Bmg_24`, `Bmg_12`, `Bmg_8`, `Bmg_6`)
   - Selected profile defines PF reserve and VF allocations

3. **GPU scheduler timing policy**
   - Scheduler can be selected with `-s` / `--scheduler` (or default from XML)
   - Timing controls include execution quantum and preemption timeout

4. **GPU resource partitioning**
   - Applies per-PF and per-VF settings for GGTT, contexts, doorbells, and scheduler values

5. **GPU memory (LMEM) partitioning**
   - PF receives reserved LMEM
   - Remaining LMEM is split across VFs by selected profile
   - ECC mode (`-e on|off`) changes effective LMEM availability

### Typical Step 2 commands

```bash
# Default IDV configuration
sudo ./scripts/provision-sriov.sh -n 4

# Explicit scheduler override
sudo ./scripts/provision-sriov.sh -n 3 -s Edge_DefaultIDV_GPUTimeSlicing
```

### Validate applied values

```bash
sudo ./scripts/read-sriov-resources.sh
```

---

## Usage

```bash
# Enable IDV profile (default config file)
sudo ./scripts/provision-sriov.sh -n 4

# Enable with explicit config file
sudo ./scripts/provision-sriov.sh -n 4 -c config/vgpu-profile/bmg-idv-profile.xml

# Disable SR-IOV
sudo ./scripts/provision-sriov.sh --disable
```

---

## Notes

- **ECC Mode**: When ECC is enabled, available LMEM is reduced due to parity overhead.
- **Contexts**: Higher context count enables more concurrent GPU operations.
- **Doorbells**: Used for VF-to-PF communication and scaled by VF count.
