# Archived scripts (not for FRDM LmP debug loop)

Moved here so the default path is only `flash-imx95-uuu-only.sh`.

| Script | Why archived |
|--------|----------------|
| `flash-imx95-foundries.full.sh` | USB heuristics, serial capture on ttyACM0, ModemManager — interfered with uuu + ser2net |
| `flash-imx95-nxp-reference.sh` | NXP LF bench only, not Foundries CI |
| `build-cuttlefish-x86_64.sh` | Android host VM, unrelated to LmP bring-up |

**Bundle prep** still uses the full script:

```bash
./scripts/archive/flash-imx95-foundries.full.sh --prepare-only --emmc TARGET dynamic-devices
```

Or: `./scripts/flash-imx95-uuu-only.sh prep TARGET`
