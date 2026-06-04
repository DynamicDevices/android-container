# Foundries `dynamic-devices` factory — imx95-frdm-evk integration

**Factory:** `dynamic-devices`  
**Machine:** `imx95-frdm-evk`  
**CI branch:** `main-imx95-frdm-devel`  
**Support ticket:** raised (waiting for Foundries to whitelist machine)

## When support approves (day-one CI trigger)

1. **`ci-scripts`** — merge snippet from `factory-config-imx95-frdm-devel.snippet.yml` into `factory-config.yml`, push `main`.
2. **`lmp-manifest`** — pin `meta-dynamicdevices-bsp` to commit containing `imx95-frdm-evk.conf` (merge `feature/imx95-frdm-evk-support` → `main` first).
3. **`meta-subscriber-overrides`** — create branch `main-imx95-frdm-devel`, push, run `./force-build.sh`.
4. Monitor: `fioctl targets list --factory dynamic-devices`

BSP layer branch: https://github.com/DynamicDevices/meta-dynamicdevices-bsp/tree/feature/imx95-frdm-evk-support

## lmp-manifest pointer (template)

In `dynamic-devices.xml`, set the BSP project revision, for example:

```xml
<project name="meta-dynamicdevices-bsp"
         path="layers/meta-dynamicdevices-bsp"
         remote="dynamicdevices"
         revision="<git-sha-after-merge>" />
```

Use the SHA from `meta-dynamicdevices-bsp` `main` after imx95 machine is merged.
