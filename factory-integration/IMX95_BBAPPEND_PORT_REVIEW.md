# imx93 → imx95-frdm-evk bbappend port review

**Rule:** Port only after you approve each row. FRDM is **not** Jaguar eInk — many eInk/MCU recipes do not apply.

**Legend:** **Y** = port now · **N** = skip · **?** = your call (reply with row #)

---

## Boot / kernel / DT (critical for LmP boot)

| # | File | What imx93 does | Recommendation for imx95-frdm-evk | Your call |
|---|------|-----------------|-----------------------------------|-----------|
| 1 | `recipes-bsp/u-boot/u-boot-fio_%.bbappend` | Board-specific U-Boot env / boot args | **Y** — `custom-dtb.cfg` → `imx95-15x15-frdm.dtb` | **done** |
| 2 | `recipes-bsp/u-boot/u-boot-ostree-scr-fit.bbappend` | OSTree boot script / FIT | **Y** — pair with u-boot-fio | **done** |
| 3 | `recipes-bsp/imx-boot/imx-boot_%.bbappend` | `IMXBOOT_TARGETS` for mfgtool | **Y** — `flash_a55` for imx95 (not imx93 `flash_singleboot`) | **done** |
| 4 | `recipes-kernel/linux/linux-lmp-fslc-imx_%.bbappend` | Custom `imx93-jaguar-eink.dts` + many `.cfg` | **N** initially — use NXP `imx95-15x15-frdm.dtb` only; add custom DTS later | |
| 5 | `recipes-bsp/device-tree/lmp-device-tree.bbappend` | Extra DTS for lmp-device-tree | **N** until custom hardware DTS | |

---

## WiFi (FRDM has no IW612)

| # | File | What imx93 does | Recommendation | Your call |
|---|------|-----------------|----------------|-----------|
| 6 | `recipes-bsp/firmware-imx/firmware-nxp-wifi_1.%.bbappend` | IW612 SDIO firmware install | **N** — FRDM has no IW612; `nxpiw612-sdio` removed from machine | |
| 7 | `recipes-kernel/kernel-modules/kernel-module-nxp-wlan_%.bbappend` | WLAN patch + udev/NetworkManager rules | **?** — port if WiFi misbehaves; rules may differ on FRDM | |
| 8 | `recipes-kernel/firmware-imx/firmware-imx_%.bbappend` | Extra `iwlwifi` ucode for imx93 | **N** — eInk-specific Intel WiFi; FRDM uses NXP IW612 | |

---

## E-Ink / power MCU / product-specific (Jaguar only)

| # | File | What imx93 does | Recommendation | Your call |
|---|------|-----------------|----------------|-----------|
| 9 | `recipes-bsp/lmp-boot-firmware/lmp-boot-firmware.bbappend` | `zephyr.bin` MCXC companion | **N** — no MCXC on FRDM EVK | |
| 10 | `recipes-bsp/mcxc143-setup/mcxc143-setup_1.0.bb` | MCXC143 setup service | **N** | |
| 11 | `recipes-bsp/mcuboot/mcuboot_git.bb` | MCUboot tools for MCXC | **N** (or extend COMPATIBLE_MACHINE only if you need mcumgr on FRDM) | |
| 12 | `recipes-bsp/eink-power-management/eink-power-management_1.0.bb` | DSM / WiFi suspend for eInk | **N** | |
| 13 | `recipes-devtools/eink-power-cli/eink-power-cli_git.bb` | E-ink CLI | **N** | |
| 14 | `recipes-bsp/board-scripts/board-scripts_1.0.bb` | E-ink board scripts | **N** | |
| 15 | `recipes-core/packagegroups/packagegroup-mcuboot.bb` | MCXC in image | **N** | |

---

## ELE / secure provisioning (defer on FRDM bring-up)

| # | File | What imx93 does | Recommendation | Your call |
|---|------|-----------------|----------------|-----------|
| 16 | `recipes-support/nxp-ele-dev-tools_1.0.bb` | ELE dev tools | **N** first boot | |
| 17 | `recipes-support/lmp-ele-foundries_1.0.bb` | ELE + Foundries integration | **N** first boot | |
| 18 | `recipes-support/lmp-device-auto-register/lmp-device-auto-register.bbappend` | Per-machine registration script | **Y** — TAG `imx95-frdm-devel`, GROUP `frdm-devel` | **done** |

---

## Runtime tuning (eInk product — not FRDM EVK)

| # | File | What imx93 does | Recommendation | Your call |
|---|------|-----------------|----------------|-----------|
| 19 | `recipes-support/wifi-power-management/*.bb` | Aggressive WiFi PM | **N** initially | |
| 20 | `recipes-support/filesystem-optimizations/filesystem-optimizations.bb` | E-ink FS tuning | **N** | |
| 21 | `recipes-support/service-optimizations/service-optimizations.bb` | Systemd tuning for eInk | **N** | |
| 22 | `recipes-extended/iptables/iptables_1.%.bbappend` | Custom iptables rules | **N** unless FRDM needs same | |

---

## BSP / udev / misc

| # | File | What imx93 does | Recommendation | Your call |
|---|------|-----------------|----------------|-----------|
| 23 | `recipes-bsp/udev/udev-rules-imx_1.0.bb` | `20-jaguar.rules` | **N** — create FRDM-specific rules when hardware needs known | |
| 24 | `recipes-devtools/mcumgr/mcumgr_0.0.0-dev.bb` | COMPATIBLE_MACHINE includes imx93 | **?** — add `imx95-frdm-evk` only if you use mcumgr on FRDM | |
| 25 | `conf/machine/include/lmp-factory-custom.inc` | NetworkManager modem for imx93 | **N** unless FRDM has modem | |
| 26 | `conf/machine/include/mcuboot-pmu-vars.inc` | Zephyr PMU for MCXC | **N** | |
| 27 | `wic/imx93-jaguar-eink-large.wks` | Partition layout + LUKS | **?** — add `wic/imx95-frdm-evk.wks` **after** default WIC fails in CI | |

---

## Already in `imx95-frdm-evk.conf` (no bbappend)

- `TOOLCHAIN` for imx-vpu-hantro / nxp-afe  
- `MACHINE_FEATURES:remove` gpu/alsa and **nxpiw612-sdio** (no on-board IW612)  
- `MACHINE_EXTRA_RDEPENDS` — **not** copied from imx93 (no eink packages)

---

## Suggested approval batch for first CI (minimal)

If you want the shortest path, reply **“approve 1–3, 6, 18 when ready”** and we implement only those.
