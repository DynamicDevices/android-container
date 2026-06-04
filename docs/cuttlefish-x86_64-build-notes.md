# Cuttlefish x86_64 — build FROM SOURCE notes

Goal: build our own `aosp_cf_x86_64_phone` (Google Cuttlefish virtual Android
device) **from source** on this x86_64 Linux host and run it headless in a
container with `/dev/kvm` passed through.

> **Strategy: FROM SOURCE.** This document supersedes any earlier
> "use prebuilt images" recommendation. We are building cuttlefish images
> ourselves. Prebuilts from `ci.android.com` are mentioned only as a fallback
> sanity-check, not the plan.

---

## 1. Host readiness (verified 2026-06-01)

| Item | Result | Notes |
|---|---|---|
| Arch | `x86_64` | `uname -m` — native, no emulation needed |
| OS | Ubuntu, kernel 6.8.0-124 | |
| Docker | `29.5.2` | installed; user is in `docker` group |
| Podman | not installed | not needed (using docker) |
| `/dev/kvm` | present, `root:kvm`, mode `crw-rw----+` (ACL) | HW virt usable |
| CPU virt flags | 40 (`vmx`/`svm`) | nested/HW virt OK |
| CPU | 20 cores | good for `-j20` |
| RAM | 62 GiB (+2 GiB swap) | sufficient for AOSP `m` |
| Disk (`/`) | 3.6 TB total, **~1014 GB free** (71% used) | single `nvme0n1p2` mount |

**KVM access caveat:** user `ajlennon` is in `docker` but **not** in the `kvm`
group. We don't need to add them to `kvm` if we run launch_cvd inside a
privileged docker container that has `--device /dev/kvm`. For a bare-metal
host run, add the user to `kvm`/`render` and re-login.

**Disk note:** a cuttlefish `m` build output (`out/`) is ~80–150 GB. With
~1014 GB free this fits, **but** see §3 — the existing local tree already
occupies ~1.2 TB, so we build into a dedicated `OUT_DIR` and keep an eye on
free space.

---

## 2. Local Android source inventory

### The usable tree (Android 16, fully synced, has cuttlefish)

```
downloads/extracted-android-16.0.0_1.2.0/imx-android-16.0.0_1.2.0/android_build
```

- **NXP i.MX Android BSP release `imx-android-16.0.0_1.2.0` (Android 16).**
  This is an **AOSP-derived** tree: `repo init` against
  `https://github.com/nxp-imx/imx-manifest -b imx-android-16
  -m imx-android-16.0.0_1.2.0.xml`, fully `repo sync`'d.
- Size: **~1.2 TB** total (`.repo` ~1006 GB, `out/` ~59 GB).
- `out/` already contains a **partial NXP `evk_95` (i.MX95) build**
  (`build-evk_95.ninja`, `build_progress.pb`). Do **not** clobber it.
- **Crucially, it DOES contain the Cuttlefish device tree and x86_64 targets:**
  - `device/google/cuttlefish/`, `cuttlefish_prebuilts/`, `cuttlefish_vmm/`
  - `device/google/cuttlefish/AndroidProducts.mk` lists
    `aosp_cf_x86_64_phone` (and many other `aosp_cf_x86_64_*` combos).
- **Validated**: `lunch aosp_cf_x86_64_phone-bp2a-userdebug` resolves cleanly
  (`TARGET_PRODUCT=aosp_cf_x86_64_phone`, `TARGET_RELEASE=bp2a`,
  `TARGET_BUILD_VARIANT=userdebug`, exit 0).

### Other Android-ish artifacts (NOT relevant to cuttlefish)

- `downloads/imx-android-16.0.0_1.2.0.tar.gz` (419 MB) — the NXP **release
  overlay package** (vendor blobs + `imx_android_setup.sh`), already extracted
  into the dir above. This is *not* a source tree by itself; it overlays one.
- `downloads/target-2707/` — Foundries **LmP / Yocto** factory image
  (`lmp-factory-image-imx95-frdm-evk.wic.gz`, `imx-boot…`). Linux, not Android.
- `/home/ajlennon/data_drive/esl/imx-android-16.0.0_1.2.0/` — empty dir.

---

## 3. NXP-vs-AOSP — definitive answer

**We can reuse the local NXP tree for x86_64 Cuttlefish, and that is the chosen
path.**

Normally an NXP i.MX BSP is arm/i.MX-focused (lunch targets like
`mek_8q-*`, `evk_95-*`) and you would *not* expect cuttlefish x86_64.
**However**, NXP's `imx-android-16` manifest is layered on top of the standard
AOSP manifest, so it pulls in the upstream `device/google/cuttlefish` project
verbatim — which provides the full set of `aosp_cf_x86_64_*` products,
including `aosp_cf_x86_64_phone`. We verified this on-disk and confirmed
`lunch` resolves the target.

Why reuse instead of a fresh vanilla AOSP checkout:

- The tree is **already `repo sync`'d** (Android 16). A fresh vanilla checkout
  would re-download ~100+ GB and take a long time — pure duplication.
- `aosp_cf_x86_64_phone` is **stock AOSP** and does not depend on any
  `vendor/nxp` blobs, so the NXP customisations don't taint the cuttlefish
  product.

Caveats / mitigations:

- **Not officially tested by NXP** — cuttlefish on an NXP manifest is
  "incidentally present", not a supported NXP target. If we hit a weird build
  break tied to an NXP patch to a *common* project, the fallback is a fresh
  vanilla AOSP checkout (§6).
- **Release config**: this tree has no `trunk_staging` release config (NXP
  ships frozen ones: `ap2a/ap3a/ap4a/bp1a/bp2a`). Use **`bp2a`** (Baklava /
  Android 16) — i.e. `aosp_cf_x86_64_phone-bp2a-userdebug`, **not** the usual
  upstream `…-trunk_staging-userdebug`.
- **Don't clobber the NXP build**: build cuttlefish into a separate
  `OUT_DIR=out_cf` so the existing `out/` (i.MX95 partial build) is untouched.

---

## 4. From-source build workflow (CHOSEN PATH — reuse local tree)

All paths relative to the workspace root
`/home/ajlennon/data_drive/esl/android-container`.

```bash
cd downloads/extracted-android-16.0.0_1.2.0/imx-android-16.0.0_1.2.0/android_build

# Build into a dedicated out dir so the NXP i.MX95 build in ./out is untouched.
export OUT_DIR=out_cf

# Low priority so it doesn't starve interactive desktop work (repo rule).
source build/envsetup.sh
lunch aosp_cf_x86_64_phone-bp2a-userdebug

nice -n 15 ionice -c2 -n7 m -j20
```

Or use the helper script (does the above with logging):

```bash
./scripts/build-cuttlefish-x86_64.sh
```

### Expected artifacts (under `…/android_build/out_cf/`)

- Disk images: `out_cf/target/product/vsoc_x86_64/*.img`
  (`super.img`, `boot.img`, `vendor_boot.img`, `system.img`, etc.)
- Host package: `out_cf/host/linux-x86/cvd-host_package.tar.gz`
  (contains `launch_cvd`, `cvd`, `stop_cvd`, and host runtime) — this is what
  you unpack on the runtime host / inside the container.

### Resource / time expectations

- First full `m`: **~1.5–4 hours** on 20 cores / 62 GB RAM.
- `out_cf` will grow to **~80–150 GB**. Watch `df -h /` (only ~1 TB free, and
  the tree itself is ~1.2 TB).
- This is a **heavy** build — run it with `nice`/`ionice` (above) so it yields
  to interactive work, per the local-build-low-priority rule.

---

## 5. Run the built image (headless, in a container with /dev/kvm)

Cuttlefish needs host kernel modules + the `cvd` host tooling. Two options:

### 5a. Host packages (google/android-cuttlefish debs)

```bash
# (one-time) build & install the host debian packages
git clone https://github.com/google/android-cuttlefish
cd android-cuttlefish
tools/buildutils/build_packages.sh        # produces cuttlefish-base/.../*.deb
sudo dpkg -i ./cuttlefish-base_*.deb ./cuttlefish-user_*.deb
sudo apt-get install -f
sudo usermod -aG kvm,cvdnetwork,render "$USER"   # re-login afterwards
```

Then run with the freshly built images:

```bash
HOST=…/android_build/out_cf
mkdir -p ~/cf && cd ~/cf
tar xzf "$HOST/host/linux-x86/cvd-host_package.tar.gz"
cp "$HOST/target/product/vsoc_x86_64/"*.img .   # or point HOME at the build dir
HOME=$PWD ./bin/launch_cvd --daemon \
    --start_webrtc --report_anonymous_usage_stats=n
# headless: connect via `adb connect 0.0.0.0:6520` or WebRTC on :8443
HOME=$PWD ./bin/stop_cvd
```

### 5b. Docker container (android-cuttlefish docker image)

```bash
cd android-cuttlefish/docker
./image-builder.sh           # builds the cuttlefish docker image
# run privileged with KVM + the built host package + images mounted in
docker run --privileged \
    --device /dev/kvm \
    -v "$HOST":/cf:ro \
    -p 8443:8443 -p 6520:6520 \
    <cuttlefish-image> /bin/bash
# inside: unpack cvd-host_package.tar.gz, copy *.img, launch_cvd --daemon
```

Notes: launch_cvd needs `vhost_vsock`/`vhost_net` host modules (installed by
the cuttlefish-base deb). Privileged container + `--device /dev/kvm` is the
simplest path given the user isn't in the `kvm` group.

---

## 6. Fallback only — fresh vanilla AOSP checkout

Use this **only** if the NXP tree's customisations break the cuttlefish build.
Needs another ~100+ GB download and ~150–300 GB of build space.

```bash
mkdir -p ~/aosp-cf && cd ~/aosp-cf
repo init -u https://android.googlesource.com/platform/manifest -b android-latest-release
#   (or -b aosp-main for tip-of-tree)
repo sync -c -j"$(nproc)"
source build/envsetup.sh
lunch aosp_cf_x86_64_phone-trunk_staging-userdebug   # vanilla has trunk_staging
m
```

(Vanilla AOSP keeps the `trunk_staging` release config, so the lunch combo is
the upstream-documented one — unlike the NXP tree which needs `bp2a`.)

---

## 7. Current status / decision point

- [x] Host verified ready (docker, KVM, disk, CPU/RAM).
- [x] Local Android 16 tree found and confirmed to support
      `aosp_cf_x86_64_phone` (lunch validated).
- [x] Build plan + helper script written.
- [ ] **Run the multi-hour `m` build** — NOT started; waiting on go-ahead
      (heavy job, see resource cost in §4).
- [ ] Build/install cuttlefish host tooling (not yet installed: no
      `cuttlefish-base`/`cvd` on host).
- [ ] launch_cvd.
