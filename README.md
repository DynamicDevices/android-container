# NXP i.MX Android 16 — i.MX95 15×15 FRDM build workspace

Automation and notes for building **NXP i.MX Android 16 GA** (`android-16.0.0_1.2.0`) for **i.MX95 15×15 FRDM** hardware (machine `imx95-15x15-lpddr4x-frdm`; Foundries LmP often uses `imx95-frdm-evk`). The Android product is still **`evk_95`** — board variant is selected at flash time, not via a separate lunch combo.

For the **19×19 EVK** reference board, set `BOARD_VARIANT=19x19-evk` (NXP `image_95evk` prebuilts target that layout).

Primary script: `scripts/setup-nxp-android-imx95.sh`

**Foundries LmP on FRDM-IMX95 (Yocto / `meta-dynamicdevices-bsp`):** [docs/lmp-frdm-workflow.md](docs/lmp-frdm-workflow.md) — only `./scripts/flash-imx95-uuu-only.sh` and `./scripts/capture-frdm-serial.sh`. Heavy flash wrappers are in `scripts/archive/`.

**Foundries LmP (not Android):** flash factory target 2707 to onboard eMMC:

```bash
# SW1 Serial Download (0,1), USB J3 — production flash needs long timeout
# Default: NXP flash_all for USB phases + Foundries LmP WIC (see docs/imx95-foundries-emmc.md)
./scripts/flash-imx95-uuu-only.sh run 2735
```

Default flash uses NXP LF `flash_all` at SDPS/SDPV until Foundries mfgtool reaches fastboot
([meta-dynamicdevices-bsp#12](https://github.com/DynamicDevices/meta-dynamicdevices-bsp/issues/12)).
Use `--foundries-boot` to test Foundries `imx-boot-mfgtool` only. SPL serial is **921600** on ttyACM0 during uuu.

NXP LF bench validation (archived): `scripts/archive/flash-imx95-nxp-reference.sh`.

Full detail: [docs/imx95-foundries-emmc.md](docs/imx95-foundries-emmc.md) (NXP vs LmP table, USB phases, troubleshooting). Passwordless sudo: `./scripts/install-flash-sudoers.sh`.

### GUI sudo password (agents / Cursor terminals)

Non-interactive terminals cannot show a TTY password or fingerprint prompt. Use a GUI askpass so **`sudo -A`** pops a dialog on the desktop instead of hanging.

**One-time check** (detects zenity / ksshaskpass / etc.):

```bash
./scripts/install-sudo-askpass.sh
```

**Enable** (pick one):

| Scope | Setup |
|-------|--------|
| This workspace | Open `imx95-frdm.code-workspace` — `terminal.integrated.env.linux` already sets `SUDO_ASKPASS` and `SSH_ASKPASS`. **Open a new integrated terminal** after changing settings. |
| All shells | Add to `~/.bashrc`: `export SUDO_ASKPASS="/path/to/android-container/scripts/sudo-askpass-gui.sh"` (and same for `SSH_ASKPASS` if needed). |

**Usage:** agents and scripts must call **`sudo -A command`**, not plain `sudo`.

```bash
sudo -A true          # test — expect a zenity password box
sudo -A systemctl restart ser2net
```

**Limits:**

- Requires a graphical session (`DISPLAY` or `WAYLAND_DISPLAY`). Pure SSH with no X forwarding will not show the dialog.
- **Fingerprint / polkit** auth is separate from `SUDO_ASKPASS`; askpass supplies the account password only. For repeated lab commands, prefer passwordless sudoers where appropriate.

**Optional passwordless ser2net** (lab serial proxy — no GUI prompt):

```bash
sudo cp config/sudoers.d/android-container-ser2net /etc/sudoers.d/android-container-ser2net
sudo chmod 0440 /etc/sudoers.d/android-container-ser2net
sudo visudo -cf /etc/sudoers.d/android-container-ser2net
```

## Prerequisites

| Requirement | NXP guidance |
|-------------|--------------|
| Host OS | Ubuntu 22.04 (matches NXP Docker image) |
| Disk | ~450 GB free (source tree + `out/`) |
| RAM | 64 GB recommended |
| Network | Stable access to NXP portal, GitHub, android.googlesource.com, armkeil.blob.core.windows.net |

Host packages (Ubuntu 22.04): baseline tools plus NXP Dockerfile apt deps. `./scripts/setup-nxp-android-imx95.sh check` verifies the Dockerfile set (including `libgnutls28-dev` via pkg-config or dpkg).

Baseline: `git`, `python3`, `openjdk-*`, `curl`, `tar`, `bzip2`, `make`, `gcc`, `repo` (script can install repo).

NXP Dockerfile apt packages (install missing items reported by `check`):

```bash
sudo apt install -y \
  uuid uuid-dev zlib1g-dev liblz-dev liblzo2-2 liblzo2-dev lzop \
  u-boot-tools mtd-utils android-sdk-libsparse-utils device-tree-compiler gdisk \
  m4 bison flex libssl-dev gcc-multilib libgnutls28-dev swig liblz4-tool \
  libdw-dev dwarves bc cpio lz4 rsync ninja-build clang build-essential \
  libncurses5 xxd unzip
```

Upstream reference: `${MY_ANDROID}/device/nxp/common/dockerbuild/Dockerfile`.

## One-time host setup (order)

Run from `android-container/`:

```bash
# 1. Verify host
./scripts/setup-nxp-android-imx95.sh check

# 2. Install repo tool (if missing)
./scripts/setup-nxp-android-imx95.sh install-repo

# 3. Download NXP source bundle (EULA — manual from nxp.com)
#    Place: downloads/imx-android-16.0.0_1.2.0.tar.gz

# 4. Extract bundle
./scripts/setup-nxp-android-imx95.sh from-tarball downloads/imx-android-16.0.0_1.2.0.tar.gz

# 5. Run NXP setup + sync (follow printed paths)
export MY_ANDROID=downloads/extracted-android-16.0.0_1.2.0/imx-android-16.0.0_1.2.0/android_build
cd downloads/extracted-android-16.0.0_1.2.0/imx-android-16.0.0_1.2.0
./imx_android_setup.sh
cd "${MY_ANDROID}" && repo sync -j$(nproc) -c

# 6. Install external host deps (NOT done by imx_android_setup.sh)
./scripts/setup-nxp-android-imx95.sh setup-host-deps

# 7. Load build environment into shell
eval "$(./scripts/setup-nxp-android-imx95.sh print-env)"
```

`setup-host-deps` is idempotent: skips toolchains already under `/opt`, re-runs kernel prebuilts only when needed.

Individual steps (if you prefer):

```bash
./scripts/setup-nxp-android-imx95.sh setup-gcc-toolchains      # Arm GNU 12.3 → /opt
./scripts/setup-nxp-android-imx95.sh setup-kernel-prebuilts    # needs synced tree; sudo
```

## Required environment variables

These must be set before `lunch` / `./imx-make.sh` (User's Guide §3.2; same as NXP Dockerfile):

| Variable | Default / purpose |
|----------|-------------------|
| `MY_ANDROID` | Path to `android_build/` tree |
| `KERNEL_PREBUILTS_PATH` | `/opt/android-kernel-prebuilts-6.12` — external kernel clang/rust/build-tools |
| `AARCH64_GCC_CROSS_COMPILE` | `/opt/arm-gnu-toolchain-12.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-` |
| `AARCH32_GCC_CROSS_COMPILE` | `/opt/arm-gnu-toolchain-12.3.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-` |
| `ARMGCC_DIR` | `/opt/arm-gnu-toolchain-12.3.rel1-x86_64-arm-none-eabi` |

Print exports anytime:

```bash
./scripts/setup-nxp-android-imx95.sh print-env
```

## Board variant (15×15 FRDM vs 19×19 EVK)

| Item | 15×15 FRDM (default) | 19×19 EVK reference |
|------|----------------------|---------------------|
| Hardware / Yocto | `imx95-15x15-lpddr4x-frdm` | 19×19 EVK |
| `BOARD_VARIANT` | `15x15-frdm` | `19x19-evk` |
| Lunch (same) | `evk_95-nxp_stable-userdebug` | same |
| `out/` product | `out/target/product/evk_95/` | same |
| DTB feature key | `imx95-15x15-frdm` → `imx95-15x15-frdm-os08a20-isp.dtb` | `imx95` → `imx95-19x19-evk-os08a20-isp-adv7535.dtb` |
| UUU `-u` (serial) | `15x15-frdm-uuu` | `evk-uuu` |
| UUU `-u` (A/B Trusty) | `trusty-15x15-frdm-dual` | `trusty-dual` |

NXP defines variants in `device/nxp/imx9/evk_95/BoardConfig.mk` and `UbootKernelBoardConfig.mk`. There is **no** separate lunch target for FRDM — one build produces images for all listed DTB/U-Boot variants.

`evk_95` packs DTBs into **vendor_boot** (`TARGET_INCLUDE_DTB_TO_VENDOR_BOOT=true`). Do **not** pass `-d` to `uuu_imx_android_flash.sh`; U-Boot picks the DTB via `fdt_name` (default `imx95-15x15-frdm` when flashed with `imx95_15x15_frdm_android_*` U-Boot).

```bash
export BOARD_VARIANT=15x15-frdm   # default in setup script
./scripts/setup-nxp-android-imx95.sh flash-help
```

## Build workflow

After tree sync and host deps:

```bash
eval "$(./scripts/setup-nxp-android-imx95.sh print-env)"
cd "${MY_ANDROID}"
source build/envsetup.sh
lunch evk_95-nxp_stable-userdebug
./imx-make.sh -j$(nproc)
```

Or use the helper (exports env, checks deps, logs to `logs/`):

```bash
./scripts/setup-nxp-android-imx95.sh build
```

Interactive / copy-paste session:

```bash
./scripts/setup-nxp-android-imx95.sh build-shell
```

Artifacts: `${MY_ANDROID}/out/target/product/evk_95/` (same path for FRDM and EVK)

### LmP / Yocto (kas)

Run local kas/bitbake builds at **lower CPU/IO priority** so desktop work stays responsive — use `../android-container/scripts/kas-build-lowprio.sh` (wraps `nice -n 15 ionice -c2 -n7 kas-container`). From `meta-dynamicdevices/`: `../android-container/scripts/kas-build-lowprio.sh build kas/imx95-frdm-evk-mfgtool.yml`.

### Flash (15×15 FRDM)

From `android-container/` after a full build:

```bash
export BOARD_VARIANT=15x15-frdm
./scripts/setup-nxp-android-imx95.sh flash-help
```

Typical UUU (images under `out/target/product/evk_95/`):

```bash
cd "${MY_ANDROID}/device/nxp/common/tools"
sudo ./uuu_imx_android_flash.sh -f imx95 \
  -u 15x15-frdm-uuu \
  -D "${MY_ANDROID}/out/target/product/evk_95" -t emmc -e
```

A/B + Trusty: use `-u trusty-15x15-frdm-dual` instead of the default `bootloader-imx95-trusty-dual.img` (19×19).

**Clean rebuild:** Not required to switch `BOARD_VARIANT` — the same `imx-make.sh` build already compiles all DTB/U-Boot variants. Reflash with the correct `-u` (and ensure U-Boot `fdt_name` if you changed it on device). Stop an in-flight build only if you intend to change the Android tree or lunch target, not merely to target FRDM.

## CI notes

Mirror local commands; do not introduce CI-only build logic.

**Cache (expensive, stable paths):**

| Path | Contents |
|------|----------|
| `/opt/android-kernel-prebuilts-6.12` | Kernel clang, rust, build-tools, clang-tools |
| `/opt/arm-gnu-toolchain-12.3.rel1-x86_64-aarch64-none-linux-gnu` | AARCH64 GCC 12.3 |
| `/opt/arm-gnu-toolchain-12.3.rel1-x86_64-arm-none-eabi` | AARCH32 GCC 12.3 |
| `${MY_ANDROID}/.repo` + synced tree | Full AOSP/NXP tree (large) |
| `${MY_ANDROID}/out/` | Incremental build (optional; invalidate on clean) |

**Reproducible CI job skeleton:**

```bash
./scripts/setup-nxp-android-imx95.sh check
./scripts/setup-nxp-android-imx95.sh setup-host-deps   # no-op if /opt caches hit
eval "$(./scripts/setup-nxp-android-imx95.sh print-env)"
./scripts/setup-nxp-android-imx95.sh build
```

**Docker alternative:** Build from `${MY_ANDROID}/device/nxp/common/dockerbuild/Dockerfile` (Ubuntu 22.04, same toolchain URLs and kernel prebuilts). Mount `MY_ANDROID`, export the same env vars, run `imx-make.sh` inside the container. See `./scripts/setup-nxp-android-imx95.sh docker-help`.

**NXP tarball:** Cannot be downloaded in CI without EULA acceptance — provide via secret artifact or pre-seeded runner volume.

## Script commands

```text
check                  Host disk/RAM/tools + deps verification
install-repo           Install repo to ~/bin
from-tarball <path>    Extract imx-android GA bundle
init / sync            repo init / sync (MY_ANDROID must be set)
setup-gcc-toolchains   Arm GNU 12.3 toolchains (sudo, idempotent)
setup-kernel-prebuilts Kernel prebuilts via NXP script (sudo)
setup-host-deps        Both toolchain installs + print env
print-env              Export lines for shell/CI
lunch / build          Lunch target + imx-make.sh
build-shell            Print interactive build commands
flash-help             UUU flags for BOARD_VARIANT (15x15-frdm default)
docker-help            NXP container build pointers
```
