# FRDM-IMX95 Foundries LmP — eMMC programming and boot

Board: **FRDM-IMX95 15×15 LPDDR4x** (`imx95-frdm-evk` in Foundries; NXP machine `imx95-15x15-lpddr4x-frdm`)  
Factory: **dynamic-devices**, target **2707** (example)

Reference: [Getting Started with FRDM-IMX95 (GS-FRDM-IMX95)](https://www.nxp.com/document/guide/getting-started-with-frdm-imx95:GS-FRDM-IMX95)

## Hardware setup

| Item | Setting |
|------|---------|
| Board | FRDM-IMX95 15×15 LPDDR4x, **32 GB eMMC** on USDHC1 (mmc0) |
| USB programming | **J3** (not J1 debug) → host |
| Serial (SPL / early boot) | **ttyACM0 @ 921600** — full SPL output during uuu |
| Serial (Linux runtime) | ttyLP0 @ **115200** (Foundries LmP) |
| SW1 Serial Download (UUU) | BOOT_MODE1=**0**, BOOT_MODE0=**1** |
| SW1 eMMC boot (after flash) | BOOT_MODE1=**1**, BOOT_MODE0=**0** |
| SW1 SD boot | BOOT_MODE1=**1**, BOOT_MODE0=**1** |

Stop **ModemManager** before uuu (script does this automatically). Install passwordless sudo once: `./scripts/install-flash-sudoers.sh`.

## ⚠️ Known blocker: SDPV second stage fails on i.MX95 (2026-05-31)

Hardware testing (board at SW1=Serial Download, ModemManager neutralised via udev) shows the
SPL **second-stage SDPV download does not reach fastboot** on this i.MX95. After `SDPS: boot`
the board enumerates at `1fc9:0151` (SPL in SDP mode) and waits; every SDPV variant tried then
**resets the board back to `1fc9:015d`**, looping `015d → 0151 → 015d` without ever reaching
fastboot (`1fc9:0152`). All three second-stage forms fail:

| SDPV second stage tried | Result |
|-------------------------|--------|
| `SDPV: write -f imx-boot-mfgtool -skipspl` | `Unknown Image type on imx95 AHAB` |
| `SDPV: write -f imx-boot-mfgtool` (no -skipspl) | write 100%, `jump` → board resets to 015d (loop) |
| `SDPV: write -f u-boot-mfgtool.itb` (FIT) | write 100%, `jump` → board resets to 015d (loop) |

This matches NXP's own guidance (see `flash-imx95-nxp-reference.sh`): *“NO SDPV + u-boot-mfgtool.itb
— that imx8-style path fails on imx95 SPL.”* uuu's built-in `emmc_all` script (`uuu -bshow emmc_all`)
also uses a **single combined `_flash.bin`** for both `SDPS: boot` and `SDPV: write … -skipspl`,
not a separate SPL + ITB pair.

**Root cause:** the Foundries `lmp-mfgtool` artifacts (`imx-boot-mfgtool` SPL + `u-boot-mfgtool.itb`)
assume the imx8-style split SDPV flow, which i.MX95 SPL does not support. i.MX95 needs the NXP-style
**single full-container `flash_all` image at SDPS** that boots straight to fastboot (no SDPV).

**Resolution required (BSP):** produce an imx95 `flash_all`-equivalent combined mfgtool container
(SPL+ATF+U-Boot+fastboot in one AHAB image) and flash with `SDPS: boot -f <flash_all> -scanterm`
then `FB:` — no SDPV. Track in `meta-dynamicdevices-bsp` mfgtool-files recipe — see
[DynamicDevices/meta-dynamicdevices-bsp#12](https://github.com/DynamicDevices/meta-dynamicdevices-bsp/issues/12).
Until then, use the default flash path in `flash-imx95-foundries.sh` (`full_image-nxp-boot.uuu`:
NXP LF `flash_all` at SDPS/SDPV + Foundries LmP FB).

## Programming flow: NXP LF vs Foundries LmP

i.MX95 FRDM Foundries path (intended): **SDPS → SDPV → fastboot (FB)** — but see blocker above.

| Phase | USB ID | Image | Action |
|-------|--------|-------|--------|
| SDPS ROM | `1fc9:015d` | `imx-boot-mfgtool` | SPL loaded into DRAM via HID |
| SDPV / SPL | `1fc9:0151` | `u-boot-mfgtool.itb` | U-Boot FIT sent to SPL → fastboot |
| Fastboot | `1fc9:0152` | — | eMMC flash via fastboot protocol |

**SDPS image** (`imx-boot-mfgtool`): SPL-only AHAB container (`flash_a55` target, ~2.3 MB). Initialises DRAM, presents as USB gadget 0151.  
**SDPV image** (`u-boot-mfgtool.itb`): U-Boot FIT image (~1.4 MB). SPL loads it, starts full U-Boot in fastboot mode (0152).  
**Never** use `imx-boot-mfgtool` at SDPV — SPL cannot accept an AHAB container, causes reset loop back to 0151.  
**Never** use `-skipspl` — "Unknown Image type on imx95 AHAB".

| Item | NXP Linux LF (`LF_v6.18.2-1.0.0_images_IMX95`) | Foundries LmP (our path) |
|------|--------------------------------------------------|---------------------------|
| uuu script | `uuu.auto-imx95-15x15-lpddr4x-frdm` | Default **`full_image-nxp-boot.uuu`** (NXP flash_all + LmP FB); debug **`full_image.uuu`** with `--foundries-boot` |
| SDPS boot | `imx-boot-imx95-15x15-lpddr4x-frdm-sd.bin-flash_all` | **`imx-boot-mfgtool`** (lmp-mfgtool `flash_a55`) |
| SDPV image | skipped (NXP uses full AHAB at SDPS, no SDPV) | **`u-boot-mfgtool.itb`** (FIT, SPL loads U-Boot) |
| FB WIC | `imx-image-full-imx95evk.wic` (uncompressed) | `.wic.gz` in uuu by default; gunzip → `.wic` with `--wic-uncompressed` |
| FB bootloader | same `*-flash_all` as SDPS | **`imx-boot-imx95-frdm-evk`** (production) |
| FB mmc target | `${emmc_dev}` (= **0**, USDHC1 eMMC) | **`mmcdev 0`** explicit (was `${emmc_dev}`; default mmcdev=1 broke eMMC flash) |
| Invalid for SDPS | — | Android `u-boot-imx95-15x15-frdm-uuu.imx`, production `imx-boot-imx95-frdm-evk` |

### NXP reference flash (hardware validation)

Extract [LF_v6.18.2 images](https://www.nxp.com) to `~/Downloads/LF_v6.18.2-1.0.0_images_IMX95`, then:

```bash
# SW1 → Serial Download (0,1), USB J3, power on
./scripts/flash-imx95-nxp-reference.sh

# Production WIC (~multi-GB): allow 30 min
./scripts/flash-imx95-nxp-reference.sh --timeout 1800

# Or from bundle directory:
cd ~/Downloads/LF_v6.18.2-1.0.0_images_IMX95
sudo uuu uuu.auto-imx95-15x15-lpddr4x-frdm
```

Or via Foundries script wrapper: `./scripts/flash-imx95-foundries.sh --reference-nxp`

### Foundries LmP flash (single command)

Default path uses NXP LF `flash_all` for USB boot phases until Foundries mfgtool is fixed
([meta-dynamicdevices-bsp#12](https://github.com/DynamicDevices/meta-dynamicdevices-bsp/issues/12)).
Install NXP LF bundle to `~/Downloads/LF_v6.18.2-1.0.0_images_IMX95` (or set `NXP_LF_DIR`).

```bash
# SW1 → Serial Download (0,1), USB J3, power on
# Default: full_image-nxp-boot.uuu (NXP flash_all SDPS/SDPV + LmP WIC + prod bootloader)
./scripts/flash-imx95-foundries.sh --emmc 2707 dynamic-devices

# Production WIC flash (350 MB compressed → needs more time):
./scripts/flash-imx95-foundries.sh --emmc 2707 dynamic-devices --timeout 1800

# Debug Foundries-only mfgtool path (imx-boot-mfgtool at SDPS — currently blocked on hardware):
./scripts/flash-imx95-foundries.sh --foundries-boot --emmc 2707 dynamic-devices

# Power off, SW1 → eMMC boot (1,0), power on — login fio / fio
```

If Foundries artifacts lack `imx-boot-mfgtool`, build locally or pass `--sdps-boot` (see § Obtain imx-boot-mfgtool).

### Re-flash after wrong mmc target (recovery)

If the board boots to U-Boot but shows `No partition table` on mmc0, the LmP WIC likely landed on **mmc1** (empty SD slot) or eMMC **boot hwpart** instead of **mmc0 user area**. Re-flash:

```bash
# SW1 → Serial Download (0,1), USB J3, stop ModemManager if needed
./scripts/flash-imx95-foundries.sh --emmc 2707 dynamic-devices --timeout 1800
```

If the board is already at **fastboot** (`1fc9:0152`) from a prior attempt:

```bash
cd downloads/target-2707/flash-bundle
sudo uuu -pp 100 fb-only.uuu                    # compressed .wic.gz (default primary)
sudo uuu -pp 100 fb-only-wic-uncompressed.uuu     # gunzip .wic (NXP-style)
```

Power off, SW1 → eMMC boot **(1,0)**, power on.

## WIC compressed vs uncompressed (A/B verification)

Foundries ships **`lmp-factory-image-imx95-frdm-evk.wic.gz`**. NXP LF uses an **uncompressed `.wic`**.  
`flash-imx95-foundries.sh` defaults to **`.wic.gz` in uuu** (`--wic-compressed`) so you can test whether imx95 fastboot `flash -raw2sparse` accepts gzip bytes. Use **`--wic-uncompressed`** to gunzip in `flash-bundle` and reference `.wic` in primary scripts (NXP-style).

After **`--prepare-only`** or **`--regen-scripts`**, the bundle contains both companion sets:

| Script | WIC file |
|--------|----------|
| `fb-only.uuu` / `full_image-nxp-boot.uuu` | Primary (default: `.wic.gz`) |
| `fb-only-wic-compressed.uuu` | `.wic.gz` |
| `fb-only-wic-uncompressed.uuu` | `.wic` (requires gunzip; created during prepare) |

### Verify eMMC content in U-Boot (after flash)

Interrupt boot or use serial after re-flash. On **mmc0** user area:

```
mmc dev 0
mmc read 0x80400000 0 1
md.b 0x80400000 16
mmc part
```

| `md.b` at LBA0 | Meaning |
|----------------|---------|
| `1f 8b 08 …` | **gzip magic** — compressed `.wic.gz` was written raw (**BAD**) |
| other bytes; `md.b 0x80400200 16` shows `45 46 49 20 50 41 52 54` | **EFI PART** GPT header at 0x200 (**GOOD**, NXP-style uncompressed WIC) |

Also run **`mmc part`** — a good flash shows GPT partitions on **mmc 0**; gzip-at-LBA0 shows `** No partition table **`.

### Test commands (board at Serial Download or fastboot)

**A — compressed `.wic.gz` (default primary):**

```bash
./scripts/flash-imx95-foundries.sh --prepare-only --emmc 2707 dynamic-devices
cd downloads/target-2707/flash-bundle
# SW1 Serial Download (0,1), USB J3; or if already at 1fc9:0152:
sudo uuu -pp 100 fb-only-wic-compressed.uuu
# full SDPS path:
sudo uuu -pp 100 full_image-nxp-boot-wic-compressed.uuu
```

**B — uncompressed `.wic` (NXP-style):**

```bash
./scripts/flash-imx95-foundries.sh --prepare-only --wic-uncompressed --emmc 2707 dynamic-devices
cd downloads/target-2707/flash-bundle
sudo uuu -pp 100 fb-only.uuu
# or without changing primary scripts:
sudo uuu -pp 100 fb-only-wic-uncompressed.uuu
```

Compare **`md.b`** / **`mmc part`** after each test. Expect A to show gzip magic if fastboot does not gunzip; B should show GPT.

## Serial output during uuu

| Serial message | USB phase | Action |
|----------------|-----------|--------|
| `SDP: handle #N` requests | `1fc9:0151` | SPL waiting for SDPV — normal during full_image.uuu run |
| `Wrong container, no image found` | 0151/0152 | Wrong image at SDPV — must be `u-boot-mfgtool.itb` (FIT); not imx-boot-mfgtool (AHAB) |
| Fastboot / `Downloading` in uuu log | `1fc9:0152` | FB phase — fb-only OK if retrying without power-cycle |

Configure terminal: **921600 8N1** on **ttyACM0** for SPL. Do not open serial on ttyACM0 while uuu runs (causes **LIBUSB_ERROR_IO**).

## Generated full_image.uuu (Foundries)

`scripts/flash-imx95-foundries.sh --emmc` generates SDPS + SDPV + FB:

```
uuu_version 1.4.149

SDPS: boot -f imx-boot-mfgtool

SDPV: delay 1000
SDPV: write -f u-boot-mfgtool.itb
SDPV: jump

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv emmc_dev 0
FB: ucmd setenv mmcdev 0
FB: ucmd mmc dev 0
FB: ucmd mmc dev 0 1; mmc erase 0 0x2000; mmc dev 0 0
FB[-t 600000]: flash -raw2sparse all lmp-factory-image-imx95-frdm-evk.wic.gz
FB: flash bootloader imx-boot-imx95-frdm-evk
FB: ucmd if env exists emmc_ack; then ; else setenv emmc_ack 0; fi;
FB: ucmd mmc partconf 0 ${emmc_ack} 1 0
FB: done
```

**SDPS:** `imx-boot-mfgtool` (SPL-only AHAB, `flash_a55` target, ~2.3 MB). AHAB tag `0x87202302` at offset 0.  
**SDPV:** `u-boot-mfgtool.itb` (U-Boot FIT image, ~1.4 MB) — SPL loads this to start full U-Boot.  
**FB bootloader:** production `imx-boot-imx95-frdm-evk` only — never use for SDPS or SDPV.

## Does FRDM-IMX95 have eMMC?

**Yes.** 32 GB eMMC 5.1 on **USDHC1** (8-bit, non-removable). microSD is **USDHC2**. LmP `boot.cmd` uses **devnum 0** (eMMC). Default NXP boot mode is eMMC (SW1: 1,0).

### MMC numbering (critical for UUU fastboot)

| Layer | Onboard eMMC (USDHC1) | microSD (USDHC2) |
|-------|------------------------|------------------|
| Device tree alias | `mmc0 = &usdhc1` | `mmc1 = &usdhc2` |
| U-Boot `mmc list` | **FSL_SDHC: 0** (eMMC) | **FSL_SDHC: 1** (SD slot) |
| Linux block device | `/dev/mmcblk0` | `/dev/mmcblk1` |
| LmP `boot.cmd` | `devnum 0` | not used by default |
| NXP `emmc_dev` / fastboot target | **0** | SD path uses **1** |

NXP `uuu.auto-imx95-15x15-lpddr4x-frdm` uses `FB: ucmd setenv mmcdev ${emmc_dev}` with **`emmc_dev=0`** in U-Boot default env (`imx95_frdm.env`).

**Pitfall:** NXP `imx95_15x15_frdm_defconfig` sets **`CONFIG_SYS_MMC_ENV_DEV=1`** (U-Boot env stored on microSD). Default compiled env therefore has **`mmcdev=1`**. During Serial Download (USB) boot, `mmc_get_env_dev()` reads `mmcdev` and falls back to **1** if unset — so fastboot can flash **microSD (mmc1)** while production boot reads **eMMC (mmc0)**.

Foundries UUU scripts now **hardcode `mmcdev 0` / `emmc_dev 0`** for `--emmc` and restore **user hwpart** after boot-partition erase (`mmc dev 0 0`) before WIC sparse flash. Without hwpart restore, GPT/WIC can land on the small eMMC boot partition instead of user area → boot shows `** No partition table - mmc 0 **`.

Verify in fastboot (interrupt U-Boot, or use `fb-only.uuu` after reaching `1fc9:0152`):

```
mmc list
mmc dev 0
mmc part
```

Expect **mmc 0** = onboard eMMC with GPT after a good flash.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `** No partition table - mmc 0 **` / `Couldn't find partition mmc 0:1` after flash | WIC/GPT written to **mmc1** (SD) or eMMC **boot hwpart**, not eMMC user area | Re-flash with fixed scripts (`./scripts/flash-imx95-foundries.sh --emmc 2707 --timeout 1800`). Confirm `mmc list` in fastboot shows image on **mmc 0**. |
| SPL `Trying to boot from MMC1` then U-Boot fails on mmc0 | SPL **MMC1** = USDHC1/eMMC (1-based boot-device name); empty **mmc0 user area** means flash targeted wrong device | Same re-flash; see MMC table above |
| `MMC: no card present` on mmc1 | Normal if no microSD inserted; boot should use mmc0 | Insert SD only for `--sd` flash path |
| `LIBUSB_ERROR_IO` / `LIBUSB_ERROR_NO_DEVICE` / `Fail HID(W)` at SDPS | ModemManager grabbing/resetting the 1fc9 USB device, or minicom on ttyACM0 | **Permanent fix:** install `config/udev/99-nxp-mm-ignore.rules` (MM ignores 1fc9, no per-flash stop). Or stop MM each time: `sudo systemctl stop ModemManager`. Close serial terminals. |
| `Wrong container, no image found` (serial) | Wrong image type at SDPS or SDPV | SDPS: use `imx-boot-mfgtool` (flash_a55 SPL); SDPV: use `u-boot-mfgtool.itb` (FIT). Never use imx-boot-mfgtool at SDPV. |
| `Unknown Image type on imx95 AHAB` | `-skipspl` used with AHAB container at SDPV | Remove `-skipspl`; script now generates correct SDPV without it |
| `Success 0 Failure 0` at 0151 | `full_image.uuu` starts with SDPS, uuu waits for 015d that never comes | Power-cycle to 015d; or use **sdpv-resume-full.uuu** when stuck at 0151 |
| `Success 0 Failure 0` with 10s timeout | Timeout too short — SDPS transfer alone takes >10s at HID rates | Default now 300s; use `--timeout 1800` for full WIC |
| uuu exits at ~31% SDPS | Wrong SDPS image (Android flash_all) or ttyACM0 open | Script validates AHAB tag; close serial terminals |
| Stuck at `1fc9:0151` | SPL waiting for SDPV; previous flash interrupted | Power-cycle to 015d, re-run full_image.uuu; or run **sdpv-resume-full.uuu** directly |
| Phase mismatch after failed run | Board left in fastboot (0152) | Re-run (fb-only) or power-cycle to Serial Download (015d) |
| Test if Foundries `imx-boot-mfgtool` is the blocker | NXP `flash_all` reaches fastboot; Foundries SDPS image does not | Default: `./scripts/flash-imx95-foundries.sh --emmc 2707`; debug Foundries path: `--foundries-boot`; track fix in [meta-dynamicdevices-bsp#12](https://github.com/DynamicDevices/meta-dynamicdevices-bsp/issues/12) |
| FAT p1 has `tee.bin` + DTB only — no `boot.itb`; U-Boot loops on `distro_bootcmd` | meta-lmp has no mx95 sota wiring, so `WKS_FILE:sota` / `IMAGE_BOOT_FILES:sota = "boot.itb"` were unset; VFAT never got the OSTree boot script | Rebuild with BSP sota wiring mirrored from `mx93-generic-bsp` (see below). Expect p1 to contain `boot.itb`; kernel + DTB load from the OSTree deploy on p2. |
| U-Boot autoboot runs `bsp_bootcmd`, fails loading `boot.scr` / `Image` (FAT p1 has only `boot.itb`) | NXP `imx95_15x15_frdm_defconfig` sets `CONFIG_BOOTCOMMAND="bootflow scan -l; run bsp_bootcmd"`; LmP sota uses `boot.itb` (FIT script), not legacy Android layout | Rebuild **`u-boot-fio`** + **`imx-boot`** with `ostree-boot.cfg` + `lmp-spl-fit.cfg`. Interim manual boot below. |
| `Executing script at 83500000` then synchronous abort / reset loop | `ostree-boot.cfg` used `source 0x83500000` but imx95 had no SPL FIT (`CONFIG_SPL_LOAD_FIT`); nothing valid at that address | Same rebuild; autoboot is now `fatload mmc 0:1 ${loadaddr} boot.itb; bootm ${loadaddr}`. |
| `fdtfile=imx95-15x15-evk-adv7535-ap1302.dtb` in U-Boot env | NXP EVK defconfig default; wrong for FRDM | Rebuild **`u-boot-fio`** + **`imx-boot`** with `custom-dtb.cfg` (`CONFIG_DEFAULT_FDT_FILE=imx95-15x15-frdm.dtb`). `boot.cmd` also sets `fdtfile`. |

## Passwordless sudo

`scripts/flash-imx95-foundries.sh` runs `env -u TERMINFO sudo -n uuu -pp 100 …`. One-time:

```bash
./scripts/install-flash-sudoers.sh
# optional bundled uuu symlink:
./scripts/install-flash-sudoers.sh --link-bundled-uuu
```

This also installs NOPASSWD for `systemctl stop/start ModemManager` (both `/usr/bin/` and `/bin/` paths). If MM stop fails, stop it manually before flashing: `sudo systemctl stop ModemManager`.

Android UUU (`uuu_imx_android_flash.sh`) is separate and not covered by this sudoers file.

## Regenerating UUU scripts without Foundries auth

If artifacts are already cached but UUU scripts are stale:

```bash
# Regenerate primary + -wic-compressed / -wic-uncompressed companion scripts
./scripts/flash-imx95-foundries.sh --regen-scripts --emmc 2707

# Primary scripts reference .wic instead of .wic.gz
./scripts/flash-imx95-foundries.sh --regen-scripts --wic-uncompressed --emmc 2707
```

No fioctl authentication required — reads from `downloads/target-2707/flash-bundle/`.  
Gunzip to `.wic` runs automatically for companion `-wic-uncompressed` scripts (and for `--wic-uncompressed` primary).

## Obtain imx-boot-mfgtool

Target 2707 mfgtools may ship stub `full_image.uuu` and omit `imx-boot-mfgtool` until BSP mfgtool-files bbappend is merged.

**Local kas build:**

```bash
# From meta-dynamicdevices checkout
../android-container/scripts/kas-build-lowprio.sh build kas/imx95-frdm-evk-mfgtool.yml
cp build/tmp/deploy/images/imx95-frdm-evk/mfgtool-files/imx-boot-mfgtool \
   ../android-container/downloads/target-2707/imx-boot-mfgtool
./scripts/flash-imx95-foundries.sh --sdps-boot downloads/target-2707/imx-boot-mfgtool --emmc 2707
```

**Foundries artifact** (after mfg_tools rebuild): `imx95-frdm-evk-mfgtools/other/mfgtool-files/imx-boot-mfgtool`

## Is a new Foundries build required?

| Goal | New build? |
|------|------------|
| Flash 2707 to eMMC and boot | **No** — `./scripts/flash-imx95-foundries.sh --emmc 2707` |
| Larger root on 32 GB eMMC | **Yes** — custom `.wks` + `IMAGE_ROOTFS_EXTRA_SPACE` |
| GPT / split-boot / LUKS | **Yes** — custom WKS + factory CI params |
| Working `full_image.uuu` in mfgtool artifact | **Yes** — mfgtool template / CI |
| Signed boot + SIT | **Yes** — enable signing + imx8mm-style uuu |

## BSP / CI changes for production eMMC factory

Manifest pin (imx95 branch): `lmp-manifest/dynamic-devices.xml` → `meta-dynamicdevices-bsp` @ `feature/imx95-frdm-evk-support`

The Foundries (sota) boot flow is the same as `imx93-jaguar-eink`: `u-boot-ostree-scr-fit` compiles `boot.cmd` into a `boot.itb` FIT (boot script only) that lands on VFAT `/boot`; the kernel and DTB are loaded from the OSTree deployment on the rootfs. meta-lmp ships this wiring for `mx93-generic-bsp` but **not** for mx95, so the BSP mirrors it.

### 1. `imx95-frdm-evk.conf` (sota wiring, mirrors `mx93-generic-bsp`)

- `WKS_FILE:sota:imx95-frdm-evk = "emmc-imx-gpt-sota.wks"` (reuses meta-lmp's GPT eMMC layout: VFAT `/boot` + ext4 OSTree root; imx-boot lives in eMMC boot0/boot1 hwpart, not the WIC)
- `IMAGE_BOOT_FILES:sota:imx95-frdm-evk = "boot.itb"`
- `PREFERRED_PROVIDER_u-boot-default-script:sota:mx95-generic-bsp = "u-boot-ostree-scr-fit"`
- `KERNEL_IMAGETYPE:sota` / `KERNEL_CLASSES:sota` → `fitImage` / `kernel-lmp-fitimage`
- `SOTA_CLIENT_FEATURES:append = " ubootenv"`
- `UBOOT_DTB_NAME:imx95-frdm-evk = "imx95-15x15-frdm.dtb"`

### 2. U-Boot Kconfig fragments (`u-boot-fio/imx95-frdm-evk/`)

- `custom-dtb.cfg` — `CONFIG_DEFAULT_FDT_FILE=imx95-15x15-frdm.dtb`
- `fix-environment-config.cfg` — `CONFIG_SYS_MMC_ENV_DEV=0` (onboard eMMC, not microSD)
- `lmp-spl-fit.cfg` — SPL FIT boot (mirrors imx93 `lmp.cfg`; meta-lmp has no imx95 `lmp.cfg`)
- `ostree-boot.cfg` — `CONFIG_BOOTCOMMAND` fatloads `boot.itb` from VFAT p1 and `bootm ${loadaddr}` (replaces NXP `bsp_bootcmd`)
- `enable-foundries-imx-commands.cfg` — `CONFIG_CMD_FIOVB`, `CONFIG_CMD_SECONDARY_BOOT` (+ OPTEE/TEE deps) for Foundries `boot.cmd` (`fiovb`, `imx_is_closed`, `imx_secondary_boot`)
- `0005-fdt-pack-reg-unaligned-access.patch` — backport `put_unaligned_be64()` fix for `fdt_pack_reg()` (fixes synchronous abort at FIT FDT load during `bootm`, esr 0x96000046 @ `0x83000000`)

**Interim U-Boot manual boot** (current flash, before prod `imx-boot` rebuild): at the U-Boot prompt after stopping autoboot:

```
setenv devnum 0
setenv bootpart 1
setenv rootpart 2
setenv fdtfile imx95-15x15-frdm.dtb
setenv fdt_file imx95-15x15-frdm.dtb
setenv fdt_file_final imx95-15x15-frdm.dtb
mmc dev 0
fatload mmc 0:1 ${loadaddr} boot.itb
setenv verify 1
bootm ${loadaddr}
```

After a rebuild with `lmp-spl-fit.cfg`, SPL may also preload the embedded script to `0x83500000`; autoboot still uses `fatload`/`bootm` as the reliable path.

### 3. `boot.cmd` (`u-boot-ostree-scr-fit/imx95-frdm-evk/`)

Sets `fdtfile` / `fdt_file` / `fdt_file_final` to `imx95-15x15-frdm.dtb`; `devnum 0`, `bootpart 1`, `rootpart 2`.

### 4. `foundries-build/ci-scripts/factory-config.yml`

Under `refs/heads/main-imx95-frdm-devel`:

```yaml
params:
  WKS_FILE:sota: "imx95-frdm-evk.wks"
mfg_tools:
  - machine: imx95-frdm-evk
    params:
      WKS_FILE:sota: "imx95-frdm-evk.wks"
```

### 5. mfgtool / U-Boot (required for UUU SDPS)

BSP fix in `meta-dynamicdevices-bsp/recipes-support/mfgtool-files/`:

1. `mfgtool-files_%.bbappend` — deploy `imx-boot-mfgtool`, `u-boot-mfgtool.itb`, `fitImage-*-mfgtool`
2. `mfgtool-files/imx95-frdm-evk/full_image.uuu.in` — SDPS + SDPV (u-boot-mfgtool.itb) + FB eMMC
3. Rebuild `mfg_tools`; verify artifact `imx-boot-mfgtool` exists

`imx-boot_%.bbappend` sets `IMXBOOT_TARGETS:lmp-mfgtool:imx95-frdm-evk = "flash_a55"`.

## Related

- Foundries flash: `scripts/flash-imx95-foundries.sh`
- NXP reference flash: `scripts/flash-imx95-nxp-reference.sh`
- Android eMMC flash (separate): `README.md` § Flash (15×15 FRDM)
- NXP Getting Started: [GS-FRDM-IMX95](https://www.nxp.com/document/guide/getting-started-with-frdm-imx95:GS-FRDM-IMX95)
