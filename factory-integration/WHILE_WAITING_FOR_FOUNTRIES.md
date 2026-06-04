# Work while waiting for Foundries machine whitelist

Foundries CI will **reject** `machines: imx95-frdm-evk` until support enables it on the **dynamic-devices** factory. Use this time to de-risk the first green build.

## Done / in progress

| Item | Status |
|------|--------|
| Support ticket for `imx95-frdm-evk` on `dynamic-devices` | **Raised** (you) |
| BSP machine `conf/machine/imx95-frdm-evk.conf` | **Branch** `feature/imx95-frdm-evk-support` |
| **`lmp-manifest`** `main-imx95-frdm-devel` | BSP pin → `feature/imx95-frdm-evk-support` (local, see `PUSH_CHECKLIST.md`) |
| **`ci-scripts`** `prepare-imx95-frdm-devel` | `ref_options` for `imx95-frdm-evk` (local, push after whitelist) |
| **`meta-subscriber-overrides`** `main-imx95-frdm-devel` | Placeholder `conf/machine/imx95-frdm-evk.conf` (local) |
| Bbappend port review | **`IMX95_BBAPPEND_PORT_REVIEW.md`** — approve per row before porting |
| Local KAS (step 3) | **`kas/imx95-frdm-evk-local.yml`** — use when ready |

## 1. Finish and merge BSP layer (no Foundries required)

```bash
cd meta-dynamicdevices-bsp
git checkout feature/imx95-frdm-evk-support
git push -u origin feature/imx95-frdm-evk-support
# Review, then merge to main via PR
```

After merge, note the **`main` commit SHA** for `lmp-manifest`.

## 2. Prepare factory repos locally (do not trigger CI yet)

On the machine that has `source.foundries.io` access (`/data_drive/dd/` or your factory checkout):

### ci-scripts

```bash
cd ci-scripts
git checkout -b prepare-imx95-frdm-devel
# Merge factory-config-imx95-frdm-devel.snippet.yml into factory-config.yml
git commit -am "Prepare main-imx95-frdm-devel CI config (imx95-frdm-evk)"
# Do NOT push until Foundries confirms whitelist — or push to a draft branch only
```

### lmp-manifest

```bash
cd lmp-manifest
git checkout -b imx95-bsp-pin
# Bump meta-dynamicdevices-bsp revision to merged SHA
# Confirm factory LmP tag is v95.2+ (Scarthgap, NXP LF6.6.52_2.2.1+)
git commit -am "Pin meta-dynamicdevices-bsp for imx95-frdm-evk"
```

### meta-subscriber-overrides

```bash
cd meta-subscriber-overrides
git checkout -b main-imx95-frdm-devel
# Verify: LAYERSERIES_COMPAT_meta-subscriber-overrides = "scarthgap"
git commit --allow-empty -m "Prepare branch for imx95-frdm-evk (no CI until whitelisted)"
git push -u origin main-imx95-frdm-devel
# Do NOT run ./force-build.sh until whitelist confirmed
```

## 3. Local LmP build (best pre-CI validation)

Validates **BitBake parses the machine** and catches recipe errors without Foundries.

From `meta-dynamicdevices` (KAS), when you have the LmP build container / kas setup:

```bash
export KAS_MACHINE=imx95-frdm-evk
export KAS_TARGET=lmp-base-console-image
# Use your existing kas entrypoint, e.g.:
# kas-container build kas/lmp-dynamicdevices.yml
```

Requirements:

- Factory manifest or kas includes **meta-imx** at LmP v95.2+ NXP BSP level  
- `meta-dynamicdevices-bsp` on path with `imx95-frdm-evk.conf`  
- `ACCEPT_FSL_EULA = "1"`  
- First build: expect **long** download + possible imx9 recipe fixes (copy from imx93 bbappends)

If full LmP kas is too heavy, minimum check:

```bash
# Inside bitbake environment with layers loaded:
bitbake-layers show-appends
bitbake -e imx95-frdm-evk | grep ^MACHINE=
```

## 4. Hardware baseline (when FRDM arrives)

Before first LmP flash, run **NXP pre-built Linux** once (validates LPDDR4x path):

- [GS-FRDM-IMX95](https://www.nxp.com/document/guide/getting-started-with-frdm-imx95:GS-FRDM-IMX95)  
- UUU: **`imx-boot-imx95-15x15-lpddr4x-frdm-*`** only — never `lpddr5` / `19x19`  
- Record boot switch positions and serial port (`ttyUSB*`)

## 5. Preempt CI failures (BSP layer)

Compare `imx93-jaguar-eink` and port bbappends to `imx95-frdm-evk` where needed:

| Area | imx93 reference | Action for imx95 |
|------|-----------------|------------------|
| `linux-lmp-fslc-imx_%.bbappend` | DT patches, defconfig | Add when custom DT needed |
| `u-boot-fio_%.bbappend` / `u-boot-ostree-scr-fit` | boot script | Check `fdtfile` = `imx95-15x15-frdm.dtb` |
| `lmp-device-tree` | custom DTS | Only if not using NXP base DTB |
| WiFi firmware | `firmware-nxp-wifi-nxpiw612-sdio` | Already in machine conf feature |
| OP-TEE / ELE | imx93 secure variants | **Defer** on first build |
| WIC | `wic/imx93-jaguar-eink-large.wks` | Add `wic/imx95-frdm-evk.wks` if default WIC fails |

## 6. Optional: build NXP upstream FRDM image

Confirms **meta-imx** and hardware before LmP:

```bash
# NXP Yocto environment — MACHINE=imx95-15x15-lpddr4x-frdm
# bitbake imx-image-full
```

Not LmP, but isolates “BSP/hardware OK” vs “LmP integration broken”.

## 7. After whitelist email arrives

1. Push prepared **`ci-scripts`** + **`lmp-manifest`** branches (or merge to `main`).  
2. **`meta-subscriber-overrides`**: `./force-build.sh` on `main-imx95-frdm-devel`.  
3. Monitor build; fix logs; flash FRDM.  

---

## What NOT to do while waiting

- Do not add `imx95-frdm-evk` to factory `machines:` and push — CI will decline and wastes queue time.  
- Do not run `./force-build.sh` on a branch that references the new machine in `factory-config.yml`.  
- Do not use **19×19 LPDDR5** EVK images or Android `evk_95` flash bundles on FRDM.
