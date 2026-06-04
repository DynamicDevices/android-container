# Push checklist — dynamic-devices factory (after Foundries whitelist)

Branches prepared locally under `/data_drive/dd/foundries-build/`:

| Repo | Branch | Push to |
|------|--------|---------|
| `meta-dynamicdevices-bsp` | `feature/imx95-frdm-evk-support` | GitHub (then merge → update manifest to `main` SHA) |
| `lmp-manifest` | `main-imx95-frdm-devel` | `source.foundries.io/.../dynamic-devices/lmp-manifest` |
| `ci-scripts` | `prepare-imx95-frdm-devel` | `source.foundries.io/.../dynamic-devices/ci-scripts` → merge `master` when approved |
| `meta-subscriber-overrides` | `main-imx95-frdm-devel` | `source.foundries.io/.../dynamic-devices/meta-subscriber-overrides` |

## 1. Push BSP branch (GitHub)

```bash
cd meta-dynamicdevices-bsp
git push -u origin feature/imx95-frdm-evk-support
```

## 2. Push factory repos

```bash
cd /data_drive/dd/foundries-build/lmp-manifest
git push -u origin main-imx95-frdm-devel

cd ../meta-subscriber-overrides
git push -u origin main-imx95-frdm-devel

cd ../ci-scripts
git push -u origin prepare-imx95-frdm-devel
# After Foundries OK: merge to master via UI or PR on factory
```

## 3. First CI build (only after whitelist)

```bash
cd /data_drive/dd/foundries-build/meta-subscriber-overrides
git checkout main-imx95-frdm-devel
./force-build.sh
```

## 4. Manifest entry point

Factory must build with manifest **`dynamic-devices.xml`** (same as `main-imx93-jaguar-eink`).  
BSP pin:

```xml
<project name="meta-dynamicdevices-bsp"
         revision="feature/imx95-frdm-evk-support"
         ... />
```

## 5. Do not push before whitelist

- `ci-scripts` → `master` with `imx95-frdm-evk` machine will be **declined** until support enables it.
- `./force-build.sh` before whitelist wastes queue time.
