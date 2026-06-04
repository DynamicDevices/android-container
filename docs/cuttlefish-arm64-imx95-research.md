# Cuttlefish on ARM64 / NXP i.MX95 — Feasibility Research

> Research/write-up only. No code was built or changed. Date: 2026-06-01.
> Scope: Can Google's Cuttlefish (AOSP virtual Android device) target arm64,
> and can it realistically run *on* an NXP i.MX95 (Cortex-A55, Armv8.2-A, Linux)?

---

## TL;DR verdict

- **Can Cuttlefish target arm64? YES — fully supported.** There are first-class
  arm64 lunch targets (`aosp_cf_arm64_phone-*`, `aosp_cf_arm64_only_phone-*`,
  `aosp_cf_arm64_auto-*`) and the host tooling (`android-cuttlefish` Debian
  packages) explicitly supports arm64 Linux hosts. Cuttlefish officially "runs
  locally on Linux x86 and ARM64 machines."

- **Can it run *on an i.MX95* (A55) natively? MARGINAL → PROBABLY NOT PRACTICAL
  as a real product, but technically *possible to demo* if every prerequisite
  lines up.** The make-or-break factors:
  1. **KVM at EL2** — Cuttlefish's VMM (crosvm, or QEMU) needs `/dev/kvm`.
     crosvm has **no software CPU emulation** (no TCG), so the host *must* be
     arm64 with working KVM. The A55 **does** have the Armv8.2-A virtualization
     extensions (EL2 + VHE), and NXP's i.MX boot flow (TF-A BL31 → U-Boot →
     kernel) **can** leave the kernel at EL2 — but this is **configuration
     dependent** and is the single most likely showstopper. **Flag this
     loudly: verify `/dev/kvm` exists on your actual i.MX95 image before
     believing any of this is feasible.**
  2. **RAM/storage** — A guest needs ~4–8 GB RAM + several GB disk. An 8 GB+
     LPDDR5 i.MX95 EVK can *just* host a single small guest; a smaller FRDM/SoM
     config cannot.
  3. **Graphics** — Practical path on i.MX95 is **headless + software rendering
     (`guest_swiftshader`)** over WebRTC/VNC. GPU acceleration via gfxstream is
     unlikely to be wired up on this BSP.
  4. **Performance** — Even when it boots, a 6×A55 @ ~1.8 GHz hosting a full
     Android guest under KVM will be *slow*. This is a tech-demo, not a test
     farm.

- **Best practical recommendation:** **Do NOT try to run Cuttlefish's host/VMM
  on the i.MX95 itself for any real workload.** If you want arm64 Cuttlefish,
  build the arm64 images here and run them on a **beefy arm64 server**
  (Ampere/Graviton/Apple-silicon-VM). Keep the i.MX95 doing what it's good at
  (LmP/Yocto edge workloads). Treat "Cuttlefish natively on i.MX95" as a
  curiosity/experiment gated on first proving `/dev/kvm` is present.

---

## 1. ARM64 Cuttlefish build targets

Cuttlefish has had arm64 build targets for years. From the Cuttlefish
`AndroidProducts.mk` and current AOSP lunch menus, the relevant targets are:

| Target | Notes |
|---|---|
| `aosp_cf_arm64_phone-trunk_staging-userdebug` | Standard arm64 phone profile |
| `aosp_cf_arm64_only_phone-userdebug` | "only" = single-arch arm64 (no 32-bit), the variant AOSP docs point ARM users at |
| `aosp_cf_arm64_auto-trunk_staging-userdebug` | Automotive (AAOS) arm64 |

Key points:

- The product-name convention is documented by AOSP:
  `aosp` + (optional) `cf` (= "intended to run in the Cuttlefish emulator") +
  architecture/form-factor, e.g. `aosp_cf_arm64_phone`. The `cf` token is the
  explicit marker for a Cuttlefish image.
- AOSP's "Get started" page tells ARM users to grab the
  `aosp_cf_arm64_only_phone-img-xxxxxx.zip` device-image artifact (vs
  `aosp_cf_x86_64_phone-img-…` for x86).
- The newer build system requires a *release_config* segment
  (`-trunk_staging-`, `-aosp_current-`, or a build-ID like `-ap2a-`) between
  product and variant, e.g.
  `lunch aosp_cf_arm64_phone-trunk_staging-userdebug`.
- You can **cross-build** the arm64 images and `cvd-host_package.tar.gz` on an
  x86_64 build machine (`lunch aosp_cf_arm64_phone-userdebug && m dist`) and
  then copy the artifacts to an arm64 *host* to actually run them. Building and
  running are separate concerns — only **running** needs KVM.

**Conclusion:** arm64 is a fully supported Cuttlefish build target. No problem
here.

---

## 2. Host requirements for arm64 Cuttlefish (the KVM / EL2 reality)

### 2.1 Cuttlefish runs the guest in a real VM — it needs KVM

Cuttlefish boots the guest Android inside a virtual machine driven by a VMM
(historically **crosvm**, with QEMU as an alternative backend). The host
requirements from `source.android.com` and the `google/android-cuttlefish`
README are explicit:

- "Cuttlefish is a virtual device and is dependent on virtualization being
  available on the host machine."
- On x86: `grep -c -w "vmx\|svm" /proc/cpuinfo` must be non-zero.
- **On arm64: "the most direct way is to check for the existence of
  `/dev/kvm`"** (`find /dev -name kvm`).
- Install `cuttlefish-base` (+ `cuttlefish-user`) Debian packages — these build
  for arm64 (`cuttlefish-*_*_arm64.deb`) — then
  `usermod -aG kvm,cvdnetwork,render $USER` and reboot.

So the gating host requirement on Arm is literally **"is `/dev/kvm`
present and usable?"**

### 2.2 crosvm has NO software emulation — you cannot fake an arm64 guest on x86

This is the crux of the "can't cheaply emulate" question:

- crosvm's own docs: *"This only runs VMs through the Linux's KVM interface… No
  actual hardware is emulated."* It has a `kvm`/`kvm_sys` layer and **no TCG /
  dynamic binary translator**.
- KVM (on any arch) is hardware-assisted: it executes guest instructions
  **directly on the host CPU**. By definition **the guest architecture must
  match the host CPU architecture**. KVM cannot run an arm64 guest on an x86
  CPU.
- The only way to run an arm64 guest on an x86 host is **QEMU TCG** (full
  software emulation), which is **5–50× slower** than native and is *not* the
  supported/blessed Cuttlefish path. Booting a full Android userspace under TCG
  is painfully slow and routinely flaky — fine for a one-off poke, useless for
  real testing.

**Therefore: running arm64 Cuttlefish at any usable speed requires an arm64
host with working KVM.** There is no shortcut.

### 2.3 Arm KVM requires EL2 — the kernel must be *entered* at EL2

On Arm, KVM is a type-2 (hosted) hypervisor that needs the **EL2 (hypervisor)
exception level**:

- Arm KVM/arm64 needs EL2 for: two-stage (stage-2) memory translation, virtual
  interrupts (vGIC), virtual timers, and the HVC trap.
- The kernel can only become a KVM host **if the bootloader/firmware hands it
  control while at EL2**. If firmware drops the CPU to **EL1** before launching
  Linux, **KVM is silently disabled** and `/dev/kvm` never appears (you'll see
  "CPU: All CPU(s) started at EL1" instead of "…at EL2" in dmesg).
- Modern cores (Armv8.1+) add **VHE** (Virtualization Host Extensions) so the
  host kernel can run efficiently *in* EL2; without VHE the split (nVHE) model
  runs a small EL2 stub with the kernel at EL1-under-EL2.

This "entered at EL1 vs EL2" detail is the recurring gotcha on NXP/embedded Arm
boards and is the centre of gravity for the i.MX95 question below.

---

## 3. i.MX95 assessment (be skeptical)

### 3.1 Does the A55 / i.MX95 have the virtualization extensions (EL2/VHE)?

**Yes.**

- The Cortex-A55 implements **Armv8.2-A** (64-bit). The NXP datasheet confirms
  i.MX95 = "6× Arm Cortex-A55, up to 1.8 GHz… Arm v8.2 fully 64-bit capable."
- Armv8.2-A DynamIQ cores (A55/A75/A76) **support VHE** (per Arm's
  "Armv8-A virtualization" guide: *"The DynamIQ processors (Cortex-A55,
  Cortex-A75 and Cortex-A76) support Virtualization Host Extensions (VHEs)"*).
- Independent confirmation that the SoC is virtualization-capable: vendors ship
  **Xen on i.MX95** (iWave), which *requires* EL2. NXP markets i.MX95 for
  "Linux + Android + RTOS coexistence."
- i.MX95 uses a **GICv3-class** interrupt controller (Arm GIC-600), which is
  what KVM's vGIC wants for a clean arm64 virtualization setup.

So at the **silicon level there is no blocker** — the A55 cores have EL2 + VHE
and the SoC has the right GIC.

### 3.2 The real blocker: does the i.MX95 boot flow leave the kernel at EL2, and does the BSP enable KVM?

This is the **make-or-break** item, and it is **configuration/BSP dependent**,
not guaranteed.

i.MX95 boot chain (per U-Boot + NXP TF-A docs):

```
BootROM → (SPL) → BL31 (TF-A / nxp-imx/imx-atf, branch lf_v2.x) → BL33 (U-Boot) → Linux kernel
```

- TF-A **BL31** installs the EL3 secure monitor (PSCI etc.) and then returns to
  the non-secure world. On the i.MX8M / i.MX95 family this typically returns
  **BL33 (U-Boot) at EL2**, and U-Boot in turn normally boots the Linux kernel
  at EL2 (good for KVM). This is *unlike* some Layerscape/older flows that drop
  to EL1.
- **BUT** whether you actually land at EL2 with KVM working depends on:
  - The **TF-A build/SPD options** (e.g. if OP-TEE / `SPD_opteed` and the
    secure-world layout are configured such that the kernel is launched at EL1,
    KVM is dead).
  - **U-Boot** not forcing an EL1 hand-off (`armv8_switch_to_el1` /
    `bootm_boot_mode`-style settings). If U-Boot is configured to switch to EL1
    before `booti`, KVM will be unavailable.
  - The **kernel `.config`**: `CONFIG_KVM=y` (arm64 KVM) must be enabled. The
    LmP / NXP `imx` kernel and the arm64 `defconfig` do generally enable arm64
    KVM, but a given **product/Yocto config may not**, and `/dev/kvm` only
    appears when KVM both is compiled in *and* the CPU came up at EL2.

**Bottom line / uncertainty flag:** The i.MX95 *can* support KVM, and people run
Xen on it, so EL2 is reachable. But **there is no guarantee your specific
LmP/Yocto i.MX95 image boots the kernel at EL2 with `CONFIG_KVM` enabled.** This
must be **empirically verified on the actual board**, e.g.:

```bash
# On the i.MX95 target:
dmesg | grep -i "CPU.*EL"        # want "...started at EL2"
ls -l /dev/kvm                   # must exist
zcat /proc/config.gz | grep -i KVM   # CONFIG_KVM / CONFIG_VIRTUALIZATION
```

If `/dev/kvm` is absent or dmesg says "started at EL1", **Cuttlefish cannot run
on the device** until the firmware/kernel are reconfigured to boot at EL2 with
KVM — and that is firmware/BSP surgery (TF-A + U-Boot + kernel config), not a
trivial flag.

### 3.3 RAM and storage

Cuttlefish guest + host overhead is heavy:

- AOSP's on-premise guidance budgets **~8 GB RAM per Cuttlefish instance**
  (their reference farm: 128 cores / 512 GB for 40 instances). A single guest is
  commonly launched with `--memory_mb=4096` to `8192`.
- The host package + a single device image (`super.img`, `vendor.img`,
  `boot.img`, userdata, etc.) is **several GB of disk**; you want a real
  SSD/eMMC/NVMe with comfortable free space, not an SD card.
- i.MX95 EVKs (e.g. **IMX95LPD5EVK-19**) typically carry **8–16 GB LPDDR5**,
  which is *enough for one small guest* (e.g. `--memory_mb=4096`,
  `--cpus=2..4`), leaving little headroom for the host Linux + crosvm + browser
  stack. Smaller FRDM/SoM variants with ≤4 GB are **not** realistically
  sufficient.

So RAM is *plausible only on the larger EVK/SoM configs*, and even then it's
tight for a single instance.

### 3.4 Graphics

- Cuttlefish graphics modes: **gfxstream** (forward GL/Vulkan to host GPU),
  **drm_virgl** (virtio-gpu/virglrenderer), and **guest_swiftshader**
  (CPU software rendering). `--gpu_mode=auto` falls back to
  `guest_swiftshader` when it can't detect accelerated-rendering prerequisites
  (EGL `GL_KHR_surfaceless_context`, GLES, Vulkan host drivers).
- On arm64 hosts that lack the prebuilt accelerated stack, users routinely end
  up on **`guest_swiftshader`** and view the device via **WebRTC
  (`--start_webrtc`, https://host:8443)** or VNC. There are well-documented
  arm64 pain points (missing `libEGL.so`, swiftshader-aarch64 prebuilts, browser
  quirks).
- The i.MX95 GPU is not part of the Cuttlefish host-GPU acceleration path, and
  gfxstream/virgl host enablement on this BSP is unlikely to be wired up.
  **Practical path on i.MX95 = headless + `guest_swiftshader` over WebRTC.**
  That further loads the (already modest) A55 CPUs.

---

## 4. Verdict, prerequisites, and showstoppers

### Verdict

- **arm64 as a Cuttlefish target: fully supported, no issue.**
- **Cuttlefish host/VMM running *on the i.MX95* itself: marginal — at best a
  slow single-instance tech demo, and only if KVM-at-EL2 is proven. For
  practical/product use: impractical.**

### Precise prerequisites to make on-device work *at all*

1. **`/dev/kvm` present and usable** on the i.MX95 Linux image — which requires:
   - Firmware (TF-A BL31 + U-Boot) that hands the kernel control **at EL2**
     (not EL1).
   - Kernel built with arm64 **`CONFIG_KVM=y`** (+ `CONFIG_VIRTUALIZATION=y`).
   - vGIC working (GICv3 — present on i.MX95).
2. **arm64 host packages**: build/install `cuttlefish-base` (+`cuttlefish-user`)
   `arm64` Debian packages on the device's distro (Debian/Ubuntu-style); LmP/
   Yocto would need these tools ported/packaged — non-trivial.
3. **Sufficient RAM/disk**: ≥8 GB LPDDR (so ~4 GB can go to one guest) and
   several GB of fast persistent storage.
4. **Matching guest images + host package** from the **same build ID**, arm64
   (`aosp_cf_arm64[_only]_phone`).
5. **Graphics expectation set to headless/software** (`guest_swiftshader`,
   WebRTC).

### Most likely showstoppers (in order)

1. **Kernel entered at EL1 / no `/dev/kvm`** on the shipped i.MX95 BSP image
   (firmware or kernel-config). *This is the #1 risk and must be checked first.*
2. **Host tooling**: `android-cuttlefish` packages assume a Debian/Ubuntu host;
   getting them onto an LmP/Yocto rootfs is extra integration work.
3. **RAM pressure** on anything below an 8 GB board.
4. **Performance**: 6×A55 @ ~1.8 GHz hosting a full Android guest (software
   rendering) is slow — acceptable for a demo, not for a CI/test fleet.

---

## 5. Recommended practical path

You already run **LmP/Yocto on i.MX95**. Distinguish two very different things:

**(a) Run Cuttlefish's host tooling / VMM *on* the i.MX95.**
- Only worth attempting as an **experiment**, and only **after** you confirm
  `/dev/kvm` exists and the kernel booted at EL2 on the actual board.
- Even then: single small guest, software graphics, slow. Not a product.
- Requires packaging the arm64 host tools onto your Yocto image and likely
  firmware/kernel-config work to guarantee EL2 + KVM.

**(b) Build arm64 AOSP Cuttlefish images here, run them on a real arm64 host.**
- **This is the recommended path.** Cross-build
  `aosp_cf_arm64[_only]_phone` images (+ `cvd-host_package.tar.gz`) on your x86
  build machine, then run them on a **proper arm64 server with KVM**:
  - Ampere Altra / AmpereOne, AWS Graviton (`c7g`/`m7g` etc.), or other
    Armv8.2+ Arm servers.
  - Apple-silicon Mac running an **arm64 Linux VM with nested KVM**
    (e.g. via the Virtualization framework / UTM) — works because the guest
    Linux gets EL2-equivalent KVM.
  - Note AOSP's own guidance: the **host CPU's Arm architecture should be ≥ the
    guest's** (their farm uses Armv8.2). A55 is Armv8.2-A, so most modern Arm
    servers (Neoverse N1/N2/V-series) comfortably satisfy this.
- You get fast, multi-instance, accelerated (or at least non-painful) Cuttlefish
  without fighting embedded firmware.

**Net recommendation:** Keep the i.MX95 for edge/LmP workloads. Use arm64
Cuttlefish on a dedicated arm64 server for Android image/app/framework testing.
Only pursue on-device Cuttlefish as a deliberate experiment gated on a
**confirmed `/dev/kvm` at EL2** on the i.MX95.

---

## 6. References

ARM64 Cuttlefish targets / build:
- Cuttlefish `AndroidProducts.mk` (arm64 targets, COMMON_LUNCH_CHOICES):
  https://android.googlesource.com/device/google/cuttlefish/+/refs/heads/android14-qpr2-s4-release/AndroidProducts.mk
- AOSP "Build Android" (lunch target naming, `cf` token):
  https://source.android.com/docs/setup/build/building
- AOSP "Cuttlefish: Get started" (arm64 `/dev/kvm` check; `aosp_cf_arm64_only_phone` image):
  https://source.android.com/docs/devices/cuttlefish/get-started
- AOSP "Cuttlefish virtual Android devices" ("runs locally on Linux x86 and ARM64"):
  https://source.android.com/docs/devices/cuttlefish

Host tooling / KVM requirement:
- `google/android-cuttlefish` (Go pkg doc: "targets locally hosted Linux x86/arm64"; install/groups):
  https://pkg.go.dev/github.com/google/android-cuttlefish
- Cuttlefish README (KVM availability, ARM `/dev/kvm`, host debian packages):
  https://android.googlesource.com/device/google/cuttlefish/
- crosvm README ("only runs VMs through Linux's KVM interface… No actual hardware is emulated"):
  https://chromium.googlesource.com/chromiumos/platform/crosvm/+/refs/heads/master/README.md
- Cuttlefish on-premise server (per-instance RAM budget; host Arm arch ≥ guest):
  https://source.android.com/docs/devices/cuttlefish/on-premises
- `launch_cvd` flags (`--memory_mb`, `--cpus`, minimal mode):
  https://android.googlesource.com/device/google/cuttlefish/+/4533f73f48978bfefb16e93a8359c8afdf79e521/host/commands/assemble_cvd/flags.cc

Arm virtualization / KVM / EL2 / VHE:
- Arm "Armv8-A virtualization" guide (DynamIQ A55/A75/A76 support VHE; EL2/E2H):
  https://developer.arm.com/documentation (Learn the Architecture: Armv8-A virtualization)
- AOSP AVF / pKVM architecture (KVM/arm64 VHE vs nVHE; bootloader enters kernel at EL2):
  https://source.android.com/docs/core/virtualization/architecture
- U-Boot / HYP-mode (kernel must be entered at the hypervisor level for KVM):
  https://blog.printk.io/2016/07/u-bootlinux-and-hyp-mode-on-armv7/
- KVM vs QEMU/TCG (KVM cannot cross-emulate; guest arch must match host CPU):
  https://hostingb2b.com/blog/comparison/qemu-vs-kvm-whats-the-difference/

i.MX95 specifics:
- NXP i.MX95 datasheet (6× Cortex-A55, Armv8.2, up to 1.8 GHz):
  https://www.nxp.com/docs/en/data-sheet/IMX95IEC.pdf
- NXP i.MX95 product page (Linux / Android / FreeRTOS; virtualization use cases):
  https://www.nxp.com/products/i.MX95
- iWave "Xen Hypervisor on i.MX95" (EL2 hypervisor mode supported on i.MX95):
  https://iwave-global.com/articles/enabling-secure-mixed-criticality-systems-with-xen-hypervisor-on-i-mx-95/
- U-Boot i.MX95 EVK board doc (TF-A `nxp-imx/imx-atf` lf_v2.10, BL31 → U-Boot boot chain):
  https://docs.u-boot.org/en/v2025.07/board/nxp/imx95_evk.html
- TF-A i.MX8 / i.MX8M platform docs (BootROM → BL31 → BL33(U-Boot) → kernel):
  https://github.com/ARM-software/arm-trusted-firmware/blob/master/docs/plat/imx8m.rst
- i.MX95 device tree (`imx95.dtsi`, A55 cluster, PSCI enable-method, GIC):
  https://android-kvm.googlesource.com/linux/+/8e4d28036c293241b312b1fceafb32b994f80fcc/arch/arm64/boot/dts/freescale/imx95.dtsi

Cuttlefish graphics:
- AOSP "Cuttlefish: GPU graphics acceleration" (gfxstream / virgl / SwiftShader):
  https://source.android.com/docs/devices/cuttlefish/gpu
- arm64 swiftshader/WebRTC pain points (real-world):
  https://stackoverflow.com/questions/75853644/cuttlefish-doesnt-display-device-screen-in-webrtc-on-aarch64

---

### Uncertainty notes (read before quoting this)
- The **single biggest uncertainty** is whether *your* i.MX95 LmP/Yocto image
  actually exposes `/dev/kvm` with the kernel at EL2. This was **not** verified
  on hardware in this research and must be checked on the board.
- Exact LmP/NXP kernel `CONFIG_KVM` defaults and TF-A/U-Boot EL hand-off depend
  on the specific BSP revision (e.g. `imx-atf` `lf_v2.10`, LmP kernel version)
  in use — confirm against your manifest, not assumptions.
- Board RAM figures are typical EVK values; confirm the exact DRAM size of your
  specific i.MX95 board/SoM.
