# i.MX95 LMP on FRDM-IMX95 — Partner Support Plan

**Owner:** Dynamic Devices  
**Status:** Draft — working document  
**Last updated:** 2026-05-18  

## Board confirmation (hardware procurement)

**Confirmed with Michael:** the board we are receiving is the **FRDM-IMX95** (~£118), **not** the full **i.MX95 19×19 LPDDR5 EVK** (~£1,000).

| Board | Approx. cost | DRAM | Package | Our plan |
|-------|--------------|------|---------|----------|
| **FRDM-IMX95** | ~£118 | **LPDDR4** (NXP BSP: **LPDDR4x**) | 15×15, ~1 GB | **In scope** — all LmP work targets this |
| **i.MX95 19×19 EVK** (e.g. IMX95LPD5EVK-19) | ~£1,000 | **LPDDR5** | 19×19, much more RAM | **Out of scope** unless we buy one later |

The **DRAM type is not interchangeable**: different DDR training firmware (OEI), `imx-boot` targets, and Yocto `MACHINE` names. Mixing LPDDR5 EVK images or blobs on FRDM (or vice versa) will not boot.

Do **not** use NXP docs, UUU bundles, DDR firmware, or `MACHINE` values for the **LPDDR5 / 19×19** EVK on FRDM. Parent machine remains **`imx95-15x15-lpddr4x-frdm`**; our machine **`imx95-frdm-evk`**.

## Purpose

Bring up **Foundries Linux microPlatform (LmP)** on the **NXP FRDM-IMX95 EVK** so we have a booting, updatable, production-style Linux platform on real hardware.

This plan covers **factory integration, NXP BSP alignment, build/flash/verify**, and **partner engagement with Foundries.io**. It does **not** cover Android, containers, Xen, or Trout — those are a **separate future project** once LmP is stable on this board.

## Goals and success criteria

### Primary goal

Build and run an **LmP Target** on FRDM-IMX95 that:

1. Boots from the chosen media (eMMC or SD — match factory image layout).
2. Reaches a login-capable system over **serial console** (115200 on USB debug).
3. Supports **Foundries OTA** (Aktualizr-lite) for the platform image.
4. Can run **Compose apps** (Docker/Podman) for application workloads — no Android required.

### Success criteria (Phase 1 complete)

| # | Criterion | Verification |
|---|-----------|--------------|
| 1 | Factory CI builds `MACHINE=imx95-frdm-evk` without manual hacks | Green CI run, artefact published |
| 2 | Board boots LmP after flash (UUU or SD) | Serial log: kernel → systemd → login/SSH |
| 3 | Network up (Ethernet and/or WiFi IW612) | `ping`, `ip link`, optional `wpa_supplicant` |
| 4 | Device registers to Foundries Factory | `fioctl` / device gateway visible |
| 5 | OTA update to a new Target succeeds | Version bump, reboot, same checks |
| 6 | Documentation: flash steps, boot switches, known limits | This doc + factory README updated |

### Explicitly out of scope (future — “Android in containers”)

- NXP Android BSP (`evk_95`), fastboot Android images, super partition layout  
- Xen Dom0/DomU, Android Trout, Cuttlefish/Redroid/Waydroid  
- Running full Android BSP inside Docker on LmP  

Reference only: [NXP Android User's Guide](https://nxp.com/docs/en/user-guide/ANDROID_USERS_GUIDE.pdf).

---

## Hardware reference

| Item | Detail |
|------|--------|
| Board | [FRDM-IMX95](https://www.nxp.com/design/design-center/development-boards-and-designs/FRDM-IMX95) |
| SoC | NXP i.MX95 (6× Cortex-A55, M33, M7, NPU) |
| Form factor / DRAM | 15×15, **LPDDR4 / LPDDR4x** (~1 GB — plan memory budget accordingly) |
| NXP Yocto parent machine | `imx95-15x15-lpddr4x-frdm` |
| Dynamic Devices machine | **`imx95-frdm-evk`** (`meta-dynamicdevices-bsp`) |
| Base DTB (NXP) | `imx95-15x15-frdm.dtb` |
| Getting started | [GS-FRDM-IMX95](https://www.nxp.com/document/guide/getting-started-with-frdm-imx95:GS-FRDM-IMX95) |

### NXP machine names (Yocto — for reference)

| NXP `MACHINE` | Use when |
|---------------|----------|
| **`imx95-15x15-lpddr4x-frdm`** | **FRDM-IMX95 (our parent)** |
| `imx95-15x15-lpddr4x-evk` | 15×15 LPDDR4x EVK (not FRDM) |
| `imx95-19x19-lpddr5-evk` | **Full EVK (~£1k)** — not our board; NXP Android/Xen demos |
| `imx95-19x19-verdin` | Toradex Verdin SoM |
| `imx95evk` | Consolidated multi-DTB image (usually avoid for FRDM-first) |

---

## Repositories and branches

| Repo | Role | Branch / note |
|------|------|----------------|
| [meta-dynamicdevices-bsp](https://github.com/DynamicDevices/meta-dynamicdevices-bsp) | Machine `imx95-frdm-evk`, DT, kernel bbappends | **`feature/imx95-frdm-evk-support`** (initial machine commit) |
| [meta-dynamicdevices](https://github.com/DynamicDevices/meta-dynamicdevices) | Recipes, features, app integration | TBD — imx95 overrides as needed |
| [meta-dynamicdevices-distro](https://github.com/DynamicDevices/meta-dynamicdevices-distro) | Distro fragments | TBD |
| Foundries **factory manifest** | Pins LmP version, BSP, `machines:` | New machine entry + CI |
| Foundries **meta-subscriber-overrides** | Factory-specific config | Scarthgap compat, kernel cmdline, etc. |

---

## Partner support — Foundries.io

**Factory:** `dynamic-devices`  
**Machine requested:** `imx95-frdm-evk`  
**Support ticket:** **Raised** — waiting for Foundries to whitelist the machine for CI.

LmP **v95+** pulls NXP BSP updates that include i.MX95 SoC support in **meta-freescale/meta-imx**, but **`imx95-frdm-evk` is not on the public [supported boards](https://docs.foundries.io/latest/reference-manual/linux/linux-supported.html) list** (highest listed NXP i.MX is i.MX93). CI will decline `machines:` changes until support approves.

**Ready to apply when approved:** `android-container/factory-integration/factory-config-imx95-frdm-devel.snippet.yml`  
**Parallel work (while waiting):** `android-container/factory-integration/WHILE_WAITING_FOR_FOUNTRIES.md`

### Questions for Foundries support

Use [support.foundries.io](https://support.foundries.io/) (or your account team). Suggested ticket:

1. **CI whitelist:** Can our factory build `MACHINE=imx95-frdm-evk` (parent `imx95-15x15-lpddr4x-frdm`)? What is the correct machine string for FRDM if different?
2. **LmP version:** Minimum LmP release for i.MX95 (v95.2 NXP BSP `LF6.6.52_2.2.1` changelog mentions `imx95-19x19-verdin` — is FRDM supported at BSP level only, or in CI?)
3. **meta-imx / EULA:** Confirm factory manifest should use same NXP layer revision as LmP v95.2+ and any imx95-specific `local.conf` fragments.
4. **Boot firmware:** Required `lmp-boot-firmware` / imx-boot / OEI / DDR firmware packages for FRDM — any LmP-specific gaps vs NXP Linux demo image?
5. **Secure boot / ELE:** Default for imx95 in LmP; do we need AHAB/ELE provisioning for first bring-up (recommend **disabled** until boot works)?
6. **Reference factory:** Any internal or partner factory already building imx95 we can diff against (e.g. Toradex `meta-partner` branch)?

### Deliverables we need from Foundries

- [ ] Written confirmation of **allowed `machines:`** value for FRDM-IMX95  
- [ ] Sample **`factory-config.yml`** snippet for imx95  
- [ ] Any **kernel/u-boot-scr** quirks (LmP v95 notes: `fdtfile` vendor prefix removed — align boot scripts)  
- [ ] Flashing doc pointer if they add imx95 to user-guide (or approval to document internally)

---

## Partner support — NXP

For BSP correctness (parallel to Foundries):

1. Confirm **recommended Linux BSP tag** aligned with LmP (e.g. `LF6.6.52_2.2.1` or newer).  
2. Confirm **UUU bundle** for FRDM: `imx-boot-imx95-15x15-lpddr4x-frdm-sd.bin`, `imx-image-full-imx95evk.wic` (per GS-FRDM-IMX95 — validate filenames for current release).  
3. **Boot switch** / SDP / SD vs eMMC default for development.  
4. Whether **Jailhouse/Xen** machine features in `imx95-evk.inc` affect image size or CI (LmP v95 **removed Jailhouse** — ensure we do not depend on it).

---

## Technical work plan

### Phase 0 — Prerequisites (1–2 days)

- [ ] FRDM board on bench: power, USB debug, Ethernet, optional SD  
- [ ] Host: `uuu`, serial terminal, `fioctl` / factory access  
- [ ] Flash **NXP pre-built Linux** once to validate hardware (GS-FRDM-IMX95 §2) — baseline before LmP  
- [ ] Record boot mode switch settings and working UUU command line  

### Phase 1 — BSP machine in meta-dynamicdevices-bsp

**Branch:** `feature/imx95-frdm-evk-support` (started)

- [x] Add `conf/machine/imx95-frdm-evk.conf` inheriting `imx95-15x15-lpddr4x-frdm`  
- [ ] Merge branch to `main` after review  
- [ ] Add **kernel bbappend** (`linux-lmp-fslc-imx` or factory kernel recipe) if FRDM needs patches  
- [ ] Add **boot files** recipe / `lmp-boot-firmware` layout for FRDM if factory requires custom blob layout  
- [ ] Add **WIC** or confirm factory default WIC works for SD/eMMC  
- [ ] Optional: `recipes-bsp/u-boot/` bbappend only if `u-boot-fio` / `imx-boot` needs FRDM-specific env  

**Machine tuning checklist**

- [ ] `SERIAL_CONSOLES` — confirm `ttyLP0` vs `ttyUSBConsole` on real LmP image  
- [ ] `OSTREE_KERNEL_ARGS` — console, rootwait, `rootfstype`  
- [ ] WiFi: `nxpiw612-sdio`, firmware package, `moal` module params (copy from `imx93-jaguar-eink` if applicable)  
- [ ] Remove or defer heavy features until boot stable (GPU, NPU demos, extra `MACHINE_EXTRA_RDEPENDS`)  

### Phase 2 — Foundries factory integration (`dynamic-devices`)

- [x] Raise Foundries support ticket for **`imx95-frdm-evk`** on **`dynamic-devices`** factory  
- [ ] Merge `meta-dynamicdevices-bsp` **`feature/imx95-frdm-evk-support`** → `main`; note SHA for manifest  
- [ ] Prepare **`ci-scripts`** / **`lmp-manifest`** / **`main-imx95-frdm-devel`** branches locally (see `factory-integration/`)  
- [ ] Bump factory manifest to **LmP v95.2+** (Scarthgap; `LAYERSERIES_COMPAT_meta-subscriber-overrides = "scarthgap"`)  
- [ ] Pin **meta-dynamicdevices-bsp** to imx95 machine commit in `lmp-manifest`  
- [ ] Merge `factory-config-imx95-frdm-devel.snippet.yml` into `factory-config.yml` (**after** whitelist)  
- [ ] `./force-build.sh` on **`meta-subscriber-overrides`** branch `main-imx95-frdm-devel`  
- [ ] `local.conf` / subscriber overrides: distro `lmp` or `lmp-base` for bring-up (`lmp-base` easier for kernel/DTB iteration)  
- [ ] Trigger CI build; fix **recipe conflicts** (common on first imx9 port: `imx-vpu-hantro`, `optee`, firmware EULA)  
- [ ] Download artefact; document **Target version** and **BUILD_ID**  

### Phase 3 — Flash and boot on hardware

- [ ] Flash via **UUU** (factory programmed image or `.wic` to SD)  
- [ ] Capture full serial log from power-on  
- [ ] Fix **boot chain**: SPL → U-Boot → TF-A → OEI/DDR → kernel DTB name (`fdtfile`)  
- [ ] Rootfs mount: partition layout vs `wic`  
- [ ] Login: default users, SSH keys via `lmp-device-register`  
- [ ] **Device registration** to factory  

### Phase 4 — Runtime validation

- [ ] Ethernet link and DHCP  
- [ ] WiFi scan/associate (IW612)  
- [ ] `docker` or `podman` runs hello-world container  
- [ ] **OTA**: push new Target, `aktualizr-lite` install, reboot  
- [ ] Stress: reboot loop × 20, document any intermittent failures  

### Phase 5 — Hardening and handoff

- [ ] Pin **known-good** manifest SHA in this doc  
- [ ] Minimal **operator guide**: flash, boot switches, serial, factory registration  
- [ ] Open issues list (display, CAN, PCIe, etc.) — only after core boot + OTA  
- [ ] Plan **custom carrier / Jaguar** board as separate machine (new DTB), not blocking FRDM EVK  

---

## Risk register

| Risk | Impact | Mitigation |
|------|--------|------------|
| Foundries CI rejects `imx95-frdm-evk` | Blocks factory builds | Early support ticket; interim local `lmp-base` build |
| **~1 GB RAM** on FRDM | OOM, slow builds on target | Lean image; defer heavy services; watch Compose memory |
| NXP BSP vs LmP kernel **version skew** | Boot or driver failures | Match LmP v95.2+ NXP BSP tag; avoid mixing hand-picked meta-imx |
| Wrong DTB / `fdtfile` | Silent hang after U-Boot | Use `imx95-15x15-frdm.dtb`; compare with NXP demo boot env |
| Secure boot / ELE enabled too early | Brick-like failures | Disable AHAB/ELE until unsecured boot path works |
| `imx95evk` consolidated machine used by mistake | Wrong bootloader for FRDM | Always use **`imx95-15x15-lpddr4x-frdm`** parent |
| Confusion with **£1k 19×19 EVK** | Wrong image flashed, wasted debug time | Procurement: FRDM only; check silkscreen / box label |
| **LPDDR5 vs LPDDR4** mix-up | No boot / corrupt DDR init | FRDM → only `lpddr4x_*` firmware & `imx95-15x15-lpddr4x-frdm`; never `lpddr5` / `19x19` |
| EULA / `fsl-eula-unpack` | CI failures | Confirm factory accepts NXP EULA flags |

---

## Build commands (local development reference)

After factory manifest and layers are configured (paths are examples):

```bash
# In factory build container / lmp build
export MACHINE=imx95-frdm-evk
export DISTRO=lmp-base   # optional for easier bring-up

bitbake lmp-base-console-image
# or factory default image target, e.g. lmp-factory-image
```

Flash (validate against current NXP release filenames):

```bash
sudo ./uuu -b sd_all imx-boot-imx95-15x15-lpddr4x-frdm-sd.bin-flash_all <factory-image>.wic
```

Boot switch: per [GS-FRDM-IMX95](https://www.nxp.com/document/guide/getting-started-with-frdm-imx95:GS-FRDM-IMX95) for SD vs eMMC vs SDP.

---

## Android / containers (future project — do not track here)

When LmP on FRDM is **done** (Phase 4+), a separate plan should cover:

- NXP Android BSP (`evk_95`) vs virtualized Trout  
- Whether “container” means Compose app, Xen guest, or other  
- RAM/storage requirements (likely need 19×19 EVK or custom carrier for concurrent Android + Linux)

**No work items in this document apply to Android until LmP success criteria are met.**

---

## Document history

| Date | Change |
|------|--------|
| 2026-05-18 | Initial plan — FRDM-IMX95 LmP focus; Android deferred |
| 2026-05-18 | Board confirmation: receiving FRDM (~£118), not full 19×19 EVK (~£1k) — Michael |
| 2026-05-18 | DRAM: full EVK = **LPDDR5**; FRDM = **LPDDR4** (NXP: LPDDR4x) — must not mix BSP blobs |
| 2026-05-18 | Foundries support ticket raised; `factory-integration/` CI snippet + waiting checklist |

---

## Action summary (next 2 weeks)

1. **Open Foundries support ticket** — CI machine whitelist for `imx95-frdm-evk`.  
2. **Merge** `feature/imx95-frdm-evk-support` → `main` in `meta-dynamicdevices-bsp`.  
3. **Factory manifest PR** — LmP v95.2+, add machine, trigger first CI build.  
4. **Hardware** — boot NXP Linux demo, then flash first LmP Target.  
5. **Iterate** boot chain and kernel cmdline until login + registration.  
