# Power Center

**Only for the Lenovo ThinkPad T14 Gen 1 with AMD Ryzen 7 PRO 4750U CPU. It may not work on your device. Other models and CPUs are unsupported.**

This is a separate plugin from [Power + Eco](https://github.com/kkaattssuu/omarchy-power-eco), which remains available unchanged. Disable Power + Eco (`osean.power`) and the standalone `lutfi.eco` plugin before enabling this plugin; they must not run together.

```sh
omarchy plugin add https://github.com/kkaattssuu/omarchy-power-center --enable
```

Boost requires the separately installed privileged helper described below. Without it, boost is unavailable; installing the plugin does not install that helper.

Plugin ID: `osean.power-center` (kept stable for existing bar configuration).

- **Eco:** saves the current desktop settings, switches to power-saver,
  and applies the enabled visual/brightness adjustments. Click anywhere
  on its tile to toggle. Use **Eco settings** to configure it.
- **Saver / Balanced / Perf:** select the corresponding power profile.
- **+W:** on AC, selects Performance and requests 30 W sustained / 32 W
  burst package limits. Click again to restore the saved limits.
  These limits are shared by the CPU and integrated GPU.
- **AI Boost:** manually requests 40 W sustained / 42 W burst on AC. Higher
  limits increase heat and may be overridden by the firmware.
- Automatic Eco (when enabled) activates on unplug and restores desktop
  settings and ordinary Performance on reconnect. Boost is manual only.

Actions are serialized; while a change runs, the latest subsequent click
is queued. The background service checks boost validity every five seconds
and reacts to charger events even when the panel is closed.

The root-owned helper `/usr/local/bin/osean-cpu-boost` needs `ryzenadj`
and `ryzen_smu`. The sudoers rules permit only `status`, `on`, `ai`, and
`off`. After changing `bin/cpu-boost`, install that source as root-owned
mode 0755 at the helper path. Never grant sudo access to a user-writable
plugin script. Boost state is temporary in `/run` and expires on reboot.

Run regressions with `python3 -m unittest discover -s tests -v`.

## Removal

Turn off boost and Eco first, then run `omarchy plugin remove osean.power-center`. Any separately installed root-owned helper and sudoers rule must be removed separately. Shared Eco preferences remain in `~/.local/state/omarchy/lutfi.eco`.

## Requirements

Omarchy Quattro, Quickshell, Python 3, `hyprctl`, `brightnessctl`, `powerprofilesctl`, `notify-send`, and Omarchy battery, system-stats, and power-profile commands. Optional boost additionally requires `ryzenadj`, the `ryzen_smu` kernel module, and the separately installed root-owned helper. The boost limits are experimental and can increase heat.

## Credits

Power Center integration: Osean Sterling (@kkaattssuu), MIT ([LICENSE](LICENSE)). Original power widget: Omarchy, copyright David Heinemeier Hansson, MIT ([LICENSE.omarchy](LICENSE.omarchy)). Eco controller and service derive from [Lutfi Zain](https://github.com/lutfi-zain/omarchy-eco-mode), MIT ([LICENSE.eco](LICENSE.eco)).
