# Running Google Cuttlefish (AOSP virtual Android device) in a container

**Research / findings document — engineer-facing**
**Date:** 2026-06-01
**Scope:** How to build Cuttlefish from AOSP (or use prebuilt artifacts) and run it inside Docker/Podman, hardware prerequisites (nested KVM), the new Host Orchestrator REST API, and CI integration.
**Audience:** Embedded Linux / Yocto engineers comfortable with containers and KVM.

> This is a desk-research write-up based on official AOSP docs, the `google/android-cuttlefish` and `google/cloud-android-orchestration` repos, and community write-ups. Where details are version-dependent or I couldn't fully verify, that is flagged inline. No code was built or changed.

---

## TL;DR — direct answers to the two questions

**1. Can Cuttlefish run in a container (Docker/Podman)?**
**Yes.** Google ships and officially supports a Cuttlefish container image (`cuttlefish-orchestration`) for both x86_64 and ARM64, and the `android-cuttlefish` repo has first-class `docker` *and* `podman` build/run tooling. Other OCI runtimes should work too. **The one hard requirement is that the host kernel exposes working KVM** (`/dev/kvm`), because Cuttlefish boots a real Android guest inside a VMM (crosvm by default, QEMU optional). The container does **not** virtualize the CPU itself — it passes `/dev/kvm` (and a few other devices) through to the host kernel. So "containerized Cuttlefish" = a normal VM workload wrapped in a container, *not* a fully isolated sandbox.

**2. Do you need heavy Android build customisation, or can you "drop a vanilla image in"?**
You **cannot** drop an arbitrary phone OEM image or a Google Pixel factory image into Cuttlefish. Cuttlefish runs **Cuttlefish-targeted AOSP images** — the `aosp_cf_*` build targets (e.g. `aosp_cf_x86_64_phone`). The good news: **these are plain/vanilla AOSP builds for the Cuttlefish virtual board, and Google publishes them prebuilt on `ci.android.com`.** So for "just give me a working Android instance," you download a prebuilt `aosp_cf_x86_64_phone-img-*.zip` + the matching `cvd-host_package.tar.gz` and run it — **zero build customisation required**. You only need to do an AOSP source build if you want *your own* framework/kernel/HAL changes in the image. Either way the device target is `aosp_cf_*`; that target choice is a build-system selection, not a big "porting" effort. Cuttlefish is described by Google as the *canonical* device for representing tip-of-tree AOSP, and it's the virtual target Google officially supports.

**Bottom line for an embedded shop:** It's very runnable in a container on a bare-metal or KVM-enabled Linux host. Start with prebuilt `aosp_cf_x86_64_phone` artifacts to prove the pipeline, then swap in your own AOSP build of the same target when you need your customisations. The main thing that bites people is **nested virtualization not being available on the host/cloud runner**.

---

## 1. What Cuttlefish is (1-minute background)

- Cuttlefish is a **configurable virtual Android device** that runs locally on Linux x86_64 / ARM64 and on cloud instances. Unlike the Android *Emulator* (tuned for app devs), Cuttlefish aims for **full fidelity with the Android framework** — pure AOSP or your custom tree — so it behaves like a real device at the OS level. It's the canonical representation of tip-of-tree AOSP. (https://source.android.com/docs/devices/cuttlefish)
- It is **virtio-compliant** (GPU, input, net, Wi-Fi via `mac80211_hwsim`, block, etc.) and boots inside a VMM: **crosvm** by default, with **QEMU** as an option (`-vm_manager qemu_cli`). It registers over **adb** like a normal device and offers a browser UI via **WebRTC** on port 8443.
- Two repos matter:
  - **`google/android-cuttlefish`** — host-side support: Debian packages, the `cvd`/`launch_cvd` tooling, **and the container (docker/podman) images + the Host Orchestrator**. (https://github.com/google/android-cuttlefish)
  - **`google/cloud-android-orchestration`** — the **Cloud Orchestrator** web service + `cvdr` client for managing many hosts/instances (CI / multi-tenant). (https://github.com/google/cloud-android-orchestration)
- The Android device implementation itself lives in AOSP at `device/google/cuttlefish`.

---

## 2. Hardware prerequisites — nested KVM (the part that bites you)

Cuttlefish **requires hardware virtualization (KVM)** on the host. In a VM/cloud, that means the VM must expose **nested virtualization**. This is the single most common blocker.

### How to verify on the host

```bash
# 1) CPU has virt extensions (Intel VT-x = vmx, AMD-V = svm). Nonzero = good.
grep -c -w 'vmx\|svm' /proc/cpuinfo          # x86_64

# 2) The KVM device node exists and is usable (works on ARM64 too)
ls -l /dev/kvm
find /dev -name kvm

# 3) Ubuntu helper (from the cpu-checker package)
sudo apt-get install -y cpu-checker
kvm-ok                                        # "KVM acceleration can be used"

# 4) Is nested virt enabled in the kvm module? (when you ARE inside a VM/hypervisor)
cat /sys/module/kvm_intel/parameters/nested   # Y/1 = nested on (Intel)
cat /sys/module/kvm_amd/parameters/nested     # Y/1 = nested on (AMD)
```

`grep -c -w "vmx\|svm" /proc/cpuinfo` returning nonzero, plus a present and group-accessible `/dev/kvm`, is the canonical check from the official Get Started page. (https://source.android.com/docs/devices/cuttlefish/get-started)

The Cuttlefish host packages add your user to the `kvm`, `cvdnetwork` and `render` groups and install kernel modules / udev rules on reboot — that's what makes `/dev/kvm` and the bridged networking usable without root.

### The AWS / cloud caveat (important)

- Historically you could only run KVM on **bare-metal** EC2 instances; ordinary virtualized EC2 instances did **not** expose nested virt, which is exactly why Cuttlefish "didn't work on AWS". 
- **This changed in Feb 2026:** AWS announced **nested virtualization on *virtual* EC2 instances** for the **C8i / M8i / R8i** families (KVM or Hyper-V inside the guest). So modern AWS can run Cuttlefish on those instance types without going full bare-metal; older/other instance types still can't. (https://aws.amazon.com/about-aws/whats-new/2026/02/amazon-ec2-nested-virtualization-on-virtual/)
- **GitHub-hosted runners:** standard `ubuntu-latest` runners do **not** reliably provide nested virt — it "sometimes" appears depending on which physical node you land on, and Google/GitHub explicitly say **don't rely on it**. Use GitHub **larger runners** (which support nested virt), a self-hosted runner on KVM-capable hardware, or a third-party KVM-enabled CI (e.g. actuated). Note nested virt is **x86 (Intel/AMD) only** on most providers — no aarch64 nested-virt runners as of writing. (See §8.)
- **GCE:** Cuttlefish natively supports Google Compute Engine; enable the nested-virt licence on the instance. Bare-metal anywhere is always fine.

> **Rule of thumb:** bare metal or a properly configured KVM host = fine. A generic cloud VM = check for `/dev/kvm` and the `nested` module param *before* you spend time on images. If `kvm-ok` fails, no amount of container flags will help — Cuttlefish will fall back to painfully slow or non-functional software emulation.

---

## 3. Option A — Use prebuilt images + host package (fastest path)

This is the recommended way to *prove out the pipeline*. No AOSP source tree, no multi-hour build.

1. **Get the artifacts from Android CI** at https://ci.android.com/
   - Pick a branch, e.g. `aosp-main` (or `aosp-android-latest-release`, or a GSI branch like `aosp-android13-gsi`).
   - Navigate to a Cuttlefish target — e.g. `aosp_cf_x86_64_phone` (or `aosp_cf_x86_64_only_phone`) → `userdebug` → latest green build.
   - From **Artifacts**, download two things **from the same build**:
     - the device images: **`aosp_cf_x86_64_phone-img-<build>.zip`** (ARM64: `aosp_cf_arm64_only_phone-img-<build>.zip`)
     - the host tools: **`cvd-host_package.tar.gz`** (always match the build ID to the image).

   You can also script the download directly, e.g.:
   ```bash
   # Example pattern (substitute a real, known-good build ID / target):
   curl -LSsO "https://ci.android.com/builds/submitted/<BUILD_ID>/aosp_cf_x86_64_phone-userdebug/latest/aosp_cf_x86_64_phone-img-<BUILD_ID>.zip"
   curl -LSs  "https://ci.android.com/builds/submitted/<BUILD_ID>/aosp_cf_x86_64_phone-userdebug/latest/cvd-host_package.tar.gz" | tar -xzf -
   ```

2. **Extract into one directory** (host package first, then the image zip):
   ```bash
   mkdir cf && cd cf
   tar -xvf /path/to/cvd-host_package.tar.gz
   unzip /path/to/aosp_cf_x86_64_phone-img-<build>.zip
   ```
   You'll get `bin/`, plus `super.img`, `boot.img`, `vendor_boot.img`, `vbmeta*.img`, `userdata.img`, etc.

3. **Launch** (bare host with cuttlefish-base installed):
   ```bash
   HOME=$PWD ./bin/launch_cvd --daemon
   ./bin/adb devices                 # device shows up like a real one
   # Browser UI:
   #   https://localhost:8443   (WebRTC, on by default)
   HOME=$PWD ./bin/stop_cvd          # stop it
   ```

The official "Get started" walkthrough is exactly this download-extract-`launch_cvd` flow. (https://source.android.com/docs/devices/cuttlefish/get-started)

> **Image/host-package version coupling:** the host package and images must come from the **same build** (and broadly the same branch). Mismatches are a common cause of boot failures.

---

## 4. Option B — Build Cuttlefish from AOSP (your own customisations)

Do this when you need *your* framework/HAL/kernel changes in the guest. The target is still `aosp_cf_*` — that's the only thing you're "customising" at the build-config level; everything else is normal AOSP development.

```bash
mkdir aosp && cd aosp
repo init -u https://android.googlesource.com/platform/manifest -b aosp-main   # or a release branch
repo sync -j"$(nproc)"

source build/envsetup.sh
lunch aosp_cf_x86_64_phone-userdebug        # x86_64 host target
#   ARM64: lunch aosp_cf_arm64_only_phone-userdebug
#   newer naming may be e.g. aosp_cf_x86_64_phone-trunk_staging-userdebug

m                  # full build; or:
m dist             # also stages distributable artifacts under out/dist/
```

**Artifacts produced:**
- `out/dist/cvd-host_package.tar.gz` — the host tools (`launch_cvd`, `cvd`, `adb`, etc.).
- `out/dist/aosp_cf_x86_64_phone-img-*.zip` (or the ARM64 equivalent) — the device images.

These are the *same two artifacts* as Option A — so the run steps in §3 (and the container steps in §5) are identical; you just point at your own build instead of CI.

**Build target naming:** `aosp_cf_<arch>_<formfactor>` — common ones: `aosp_cf_x86_64_phone`, `aosp_cf_x86_64_only_phone`, `aosp_cf_arm64_only_phone`, plus auto/tv variants. Use `lunch` with no args to see the interactive list. Build variant: `eng` (fastest, dev), `userdebug` (root + debuggable, the usual choice for Cuttlefish), `user` (production-locked).

**Resource requirements (rough, AOSP full build):**

| Resource | Guidance |
|---|---|
| Disk | **~150 GB minimum**; a full tree + out dir is commonly **250 GB+**. Use a fast **SSD/NVMe** — disk speed dominates. A Cuttlefish-only userspace checkout can be smaller (~90 GB) but the full platform build is large. |
| RAM | **16 GB minimum**, 32–64 GB+ strongly recommended. |
| CPU | More cores = better; build scales with `-j`. |
| Time | First clean build ≈ **30 min on a big build server** to **2–3 h on a laptop**. `repo sync` of the tree can take hours / overnight. Use **ccache** for rebuilds. |

(Requirements per AOSP build docs and community write-ups: https://source.android.com/docs/setup/build/building , https://nathanchance.dev/posts/building-using-cuttlefish/)

> **Yocto-engineer note:** the build resource profile is comparable to a big Yocto/LmP build — plan disk and RAM accordingly, and keep the AOSP tree on fast local storage, not NFS.

---

## 5. Running Cuttlefish in Docker

There are **two distinct container approaches**. Pick based on whether you want the official orchestrated path or a quick manual run.

### 5.1 Official image (`cuttlefish-orchestration`)

Google publishes a container image with `cuttlefish-base`, `cuttlefish-user`, and `cuttlefish-orchestration` preinstalled, for x86_64 and ARM64:

```bash
docker pull us-docker.pkg.dev/android-cuttlefish-artifacts/cuttlefish-orchestration/cuttlefish-orchestration:stable
```

Or build it yourself from the repo (you must build the host Debian packages first — see `tools/buildutils/cw/README.md`):

```bash
git clone https://github.com/google/android-cuttlefish
cd android-cuttlefish
container/image/image-builder.sh -m dev -c docker     # -c podman for Podman
docker image list      # expect a 'cuttlefish-orchestration' image (~700 MB)
```

This image is designed to be driven by the **Host Orchestrator** (REST API, §7) — typically launched and managed by the **Cloud Orchestrator** + `cvdr` (§6). That's the path the official "Run Cuttlefish on an on-premise server" doc steers you toward.
(https://github.com/google/android-cuttlefish/blob/main/container/README.md , https://source.android.com/docs/devices/cuttlefish/on-premises)

### 5.2 Manual / direct `docker run` (community pattern)

If you just want to run `launch_cvd` inside a container by hand (useful to understand the moving parts), the key is **device passthrough** and enough privilege for crosvm + bridged networking. A representative invocation:

```bash
docker run -it --rm \
  --privileged \                       # simplest; or use fine-grained caps + devices
  --network host \                     # easiest path for adb/WebRTC port exposure
  --device /dev/kvm \                  # REQUIRED — hardware virtualization
  --device /dev/vhost-vsock \          # guest<->host vsock (cvd control channel)
  --device /dev/vhost-net \            # virtio-net acceleration
  --device /dev/net/tun \              # TAP devices for the cvd bridge network
  <cuttlefish-image>

# then inside the container:
cd /cf
HOME=$PWD ./bin/launch_cvd --daemon
```

**Why each device/flag:**

| Flag / device | Why it's needed |
|---|---|
| `--device /dev/kvm` | Cuttlefish boots a real VM via crosvm/QEMU. Without KVM there's no (usable) virtualization. **Non-negotiable.** |
| `--device /dev/vhost-vsock` (+ `/dev/vsock`) | Cuttlefish uses **vsock** for the host↔guest control plane between `cvd` and the running instance. |
| `--device /dev/vhost-net` | Accelerated virtio networking for the guest. |
| `--device /dev/net/tun` | `cuttlefish-base` sets up a bridge (`cvd-...`/`cvd-wbr` style) and TAP interfaces for guest networking; needs `/dev/net/tun`. |
| `--privileged` **or** `--cap-add NET_ADMIN` (+ others) | Network/bridge setup and crosvm need elevated privileges. `--privileged` is the blunt instrument; fine-grained setups add `NET_ADMIN`, `SYS_ADMIN`, etc. and pass only the devices above. |
| `--network host` | Simplest way to reach adb (`6520+`) and WebRTC (`8443`, `15550–15599 TCP/UDP`) from the host without per-port `-p` mapping. |

Note: some community images also pass `/dev/log` through to keep crosvm happy — that's image-specific, not universal. (Examples: https://github.com/thatoddmailbox/cuttlefish-docker , https://junsun.net/wordpress/2025/12/android-cuttlefish-container-for-local-development/)

**Kubernetes / non-privileged note:** you don't strictly need `--privileged` if you can expose the device nodes via a device plugin. The relevant nodes are `/dev/kvm`, `/dev/vhost-vsock`, `/dev/vhost-net`, `/dev/vsock`. (https://medium.com/@lemonchoismarceau/running-cuttlefish-in-a-non-privileged-pod-b236c8701610)

> **Key point:** the container shares the **host kernel's KVM**. There is no nested-virt *inside* the container layer — the container is just packaging/isolation around a normal KVM workload. So container ≠ extra virtualization cost, but container also ≠ a way to get KVM where the host doesn't have it.

---

## 6. Running Cuttlefish in Podman

Podman is **explicitly supported** by the same tooling — the `image-builder.sh` script takes `-c podman`:

```bash
cd android-cuttlefish
sudo container/image/image-builder.sh -m dev -c podman   # note: sudo in the README example
sudo podman image list    # localhost/cuttlefish-orchestration ... ~1.1 GB
```

(https://github.com/google/android-cuttlefish/blob/main/container/README.md)

**Differences / gotchas vs Docker:**
- The README runs the Podman build under **`sudo`** (rootful Podman). For Cuttlefish, **rootful Podman is the path of least resistance** — bridge/TAP creation and device access are simpler than rootless.
- **Rootless Podman** is harder: `/dev/kvm` access needs your user in the `kvm` group and the device passed through; `/dev/net/tun` + bridge setup typically wants `NET_ADMIN`/root, so the bridged `cvd` networking is the sticky part rootless. If you go rootless, expect to wrestle with networking and device permissions.
- Device passthrough syntax mirrors Docker: `--device /dev/kvm --device /dev/vhost-vsock --device /dev/vhost-net --device /dev/net/tun`, plus `--privileged` or the equivalent capabilities.
- Otherwise the resulting image and the `cvd`/Host Orchestrator workflow are the same as Docker. Google states it should work with other OCI runtimes too.

---

## 7. The Host Orchestrator REST API (the "new HTTP API")

This is the piece highlighted at the May 2026 meetup. There are **two orchestrators** — don't confuse them:

| | **Host Orchestrator** | **Cloud Orchestrator** |
|---|---|---|
| Runs where | *Inside each Cuttlefish host/container* | A front-end web service managing many hosts |
| Role | Create/list/delete **CVD instances** on that one host; manage uploaded build artifacts; stream logs | Create/list/delete **hosts** (VMs/containers), then proxy to each host's Host Orchestrator |
| Client | `curl` / REST, or driven by Cloud Orchestrator | **`cvdr`** CLI |
| Lives in | `google/android-cuttlefish` (`frontend/src/host_orchestrator`) | `google/cloud-android-orchestration` |

### What the Host Orchestrator gives you

A **REST API to manage CVD instances over HTTP** instead of SSHing in and running `launch_cvd` by hand. This is what makes Cuttlefish multi-tenant and CI-friendly: a service can create an instance, upload locally-built artifacts, boot it, fetch logs, and tear it down — all over HTTP. Representative endpoints (observed in Google's own tooling; treat exact paths/ports as version-dependent):

```bash
# Host Orchestrator typically listens on 2080 (HTTP) / 2443 (HTTPS) inside the host/container.

# 1) Create a user-artifacts dir (for locally-built images you upload)
curl -s -k -X POST https://localhost:2080/userartifacts          # -> { "name": "<dir>" }
#    then upload artifacts to it via multipart/form-data (chunked)

# 2) Create / start a CVD (fetch from CI, or use uploaded user artifacts)
curl -s -k -X POST https://localhost:2080/cvds \
  -H 'Content-Type: application/json' \
  -d '{ "cvd": { "build_source": { "user_build_source": { "artifacts_dir": "<dir>" } } },
        "additional_instances_num": 0 }'

# (also: GET /cvds to list, DELETE to remove, /operations for async op status, log endpoints)
```

(Endpoint shapes seen in `device/google/cuttlefish/tools/launch_cvd_arm64_server_docker.sh` and the orchestration repos: https://android.googlesource.com/device/google/cuttlefish/ , https://github.com/google/cloud-android-orchestration)

### Driving it the easy way — `cvdr` + Cloud Orchestrator

For most users, you don't hit the Host Orchestrator REST API directly; you run `cvdr` against the Cloud Orchestrator, which spins up a Docker host running the `cuttlefish-orchestration` image and talks to its Host Orchestrator for you:

```bash
cvdr \
  --branch=aosp-main \
  --build_target=aosp_cf_x86_64_phone-trunk_staging-userdebug \
  create
# -> Creating Host... Fetching artifacts... Starting and waiting for boot complete... OK
#    Status: Running, ADB: 127.0.0.1:<port>, Logs: http://localhost:8080/v1/zones/local/hosts/<id>/cvds/1/logs/
```

Cloud Orchestrator's own API is under `http://<host>:8080/v1/zones/.../hosts/...`. Config lives in `~/.config/cvdr/cvdr.toml`. (https://github.com/google/cloud-android-orchestration/blob/main/docs/cvdr.md , https://github.com/google/cloud-android-orchestration/blob/main/docs/cloud_orchestrator.md)

> **Don't confuse with the "Environment control" REST API.** There's a *separate* REST/CLI surface (`cvd env`, default port **1443**) for changing a running device's *environment* — Wi-Fi signal, GPS location, etc. That's runtime device control, not instance lifecycle. (https://source.android.com/docs/devices/cuttlefish/control-environment)

> **Uncertainty flag:** exact Host Orchestrator port numbers, route names and request schemas are evolving (active development through 2026 — see the migration of Cloud Android's launcher out of AOSP into GitHub). Verify against the version of `android-cuttlefish` you deploy rather than treating the above as a stable contract.

---

## 8. CI integration notes & gotchas

**The whole game in CI is: do you have KVM on the runner?**

- **GitHub-hosted standard runners (`ubuntu-latest`): unreliable.** Nested virt appears only on *some* underlying nodes; Google and GitHub both say not to depend on it. KVM/libvirt jobs fail when `/dev/kvm` isn't present. (https://github.com/actions/runner-images/issues/8882 , https://actuated.com/blog/kvm-in-github-actions)
- **GitHub larger runners:** support nested virtualization (x86 only). This is the supported way to run KVM workloads on GitHub-hosted infra. macOS larger runners do **not** get it.
- **Self-hosted runners** on bare-metal or KVM-capable VMs: works; you control the kernel and `/dev/kvm`. Beware running runners *inside* unprivileged pods (k8s) — you then need device plugins to expose `/dev/kvm`, `/dev/vhost-vsock`, etc.
- **Cloud:** as of Feb 2026, AWS C8i/M8i/R8i support nested virt on virtual instances; before that you needed `*.metal`. GCE supports nested virt with the right licence. Azure/others: check per-SKU.
- **aarch64 CI:** essentially no hosted nested-virt aarch64 runners yet — build x86_64 Cuttlefish, or use a real ARM server / bare metal for ARM64 guests.

**Practical CI recipes that work:**
- Community **GitHub Actions** examples boot Cuttlefish on runners by: install the `cuttlefish-base`/`cuttlefish-user` packages, fix KVM/`cvdnetwork` group perms, download `aosp_cf_x86_64_phone` images + `cvd-host_package` from `ci.android.com` (with caching), `launch_cvd` with CI-tuned flags, run tests / take a screenshot, `stop_cvd`. (e.g. https://github.com/jonathanpeppers/cuttlefish)
- For **fleet / many-instance CI**, use the **Cloud Orchestrator + `cvdr`** path with the `cuttlefish-orchestration` Docker image as the host — this is exactly the "enable your own CI" story the Cuttlefish team has been pushing (Linaro Connect 2025 / AOSP meetup talks). On-prem sizing example from Google: ~40 instances at 4 vCPU + 8 GB each ≈ 160 cores / 320 GB RAM. (https://source.android.com/docs/devices/cuttlefish/on-premises)

**Common gotchas checklist:**
- `/dev/kvm` missing or wrong perms → not in `kvm` group, or no nested virt. Verify first (§2).
- Host package / image **build-ID mismatch** → boot hangs.
- Forgot `HOME=$PWD` → runtime files scatter / collide.
- Container without `/dev/vhost-vsock` or `/dev/net/tun` → boot/network failures even with `/dev/kvm`.
- Firewall blocks WebRTC ports `8443` + `15550–15599` (TCP/UDP) when viewing remotely.
- Rootless Podman networking for the `cvd` bridge — prefer rootful unless you have a reason not to.

---

## 9. Links / references

**Official AOSP docs**
- Cuttlefish overview — https://source.android.com/docs/devices/cuttlefish
- Get started (verify KVM, download artifacts, `launch_cvd`) — https://source.android.com/docs/devices/cuttlefish/get-started
- Run Cuttlefish on an on-premise server (Docker image + Cloud Orchestrator + `cvdr`) — https://source.android.com/docs/devices/cuttlefish/on-premises
- WebRTC streaming (ports, browser UI) — https://source.android.com/docs/devices/cuttlefish/webrtc
- Environment control REST API / `cvd env` (port 1443) — https://source.android.com/docs/devices/cuttlefish/control-environment
- Build Android (lunch/targets/variants) — https://source.android.com/docs/setup/build/building
- Android CI artifacts — https://ci.android.com/

**Repos**
- `google/android-cuttlefish` (Debian pkgs, container tooling, Host Orchestrator) — https://github.com/google/android-cuttlefish
- Container README (docker/podman build + pull) — https://github.com/google/android-cuttlefish/blob/main/container/README.md
- `google/cloud-android-orchestration` (Cloud Orchestrator + `cvdr`) — https://github.com/google/cloud-android-orchestration
  - `cvdr` usage — https://github.com/google/cloud-android-orchestration/blob/main/docs/cvdr.md
  - Cloud Orchestrator — https://github.com/google/cloud-android-orchestration/blob/main/docs/cloud_orchestrator.md
  - On-prem single-server setup — https://github.com/google/cloud-android-orchestration/blob/main/scripts/on-premises/single-server/README.md
- AOSP device tree: `device/google/cuttlefish` — https://android.googlesource.com/device/google/cuttlefish/

**The May 2026 AOSP/AAOS meetup (anchor for this research)**
- Meetup archive (slides/video links): **"The May 2026 Meetup → Talk 1: Cuttlefish Development & Deployment", Sergio Rodriguez (Google)** — https://aospandaaos.github.io/meetup.html  *(this is what `https://lnkd.in/edRX-Drv` resolves to)*
- Event page (27 May 2026) — https://www.meetup.com/the-aosp-and-aaos-meetup/events/312460222/
- Related background by Ram Muthiah (Cuttlefish, Kernels & Bootloaders, Linaro Connect 2025) — https://www.kitefor.events/download/289
  - *Note:* the meetup page lists the talk under Sergio Rodriguez; Ram Muthiah is the long-time Cuttlefish lead and co-author of the surrounding "enable your own CI / orchestration / Docker container strategy" material. At time of writing I could not confirm a directly clickable slides/video file link on the archive page for the May 2026 talk — check the archive page again, as links are usually added after the event.

**Community write-ups (useful, unofficial)**
- Nathan Chancellor — Building and using Cuttlefish — https://nathanchance.dev/posts/building-using-cuttlefish/
- Jun Sun — cuttlefish-host-container (local dev container) — https://junsun.net/wordpress/2025/12/android-cuttlefish-container-for-local-development/
- thatoddmailbox/cuttlefish-docker (minimal privileged docker run example) — https://github.com/thatoddmailbox/cuttlefish-docker
- jonathanpeppers/cuttlefish (Cuttlefish on GitHub Actions) — https://github.com/jonathanpeppers/cuttlefish
- Running Cuttlefish in a non-privileged k8s pod — https://medium.com/@lemonchoismarceau/running-cuttlefish-in-a-non-privileged-pod-b236c8701610
- AWS nested virt on virtual instances (Feb 2026) — https://aws.amazon.com/about-aws/whats-new/2026/02/amazon-ec2-nested-virtualization-on-virtual/

---

## 10. Suggested path for *this* team

1. **Smoke-test on bare metal / a KVM-capable box:** `kvm-ok`, then Option A (prebuilt `aosp_cf_x86_64_phone` + `cvd-host_package`) → `launch_cvd` → confirm `adb devices` and `https://localhost:8443`.
2. **Containerize it:** pull `cuttlefish-orchestration:stable` (or `image-builder.sh -c docker`), run with `--device /dev/kvm --device /dev/vhost-vsock --device /dev/vhost-net --device /dev/net/tun` (+ `--privileged`/`NET_ADMIN`, `--network host`).
3. **Only if you need custom framework/kernel/HAL:** stand up an AOSP tree, `lunch aosp_cf_x86_64_phone-userdebug`, `m dist`, and feed your own artifacts in (same run steps).
4. **For CI/fleet:** Cloud Orchestrator + `cvdr` driving the Docker image, on a self-hosted/larger/bare-metal runner with guaranteed `/dev/kvm`.

**The decisive prerequisite throughout is nested KVM on the host — validate it before anything else.**
