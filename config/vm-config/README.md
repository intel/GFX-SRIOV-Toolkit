# VM Config Notes

This folder contains VM XML definitions used by `scripts/launch-vm.sh` and `scripts/launch-vm-libvirt.sh`.

## VM definition files

| File | Target Platform | Display Mode | Description |
| --- | --- | --- | --- |
| `bmg-idv-config.xml` | Intel Battlemage discrete GPU | IDV | VM definitions optimized for Battlemage dGPU IDV workflows. |
| `igpu-idv-config.xml` | Intel Core integrated GPU platforms | IDV | VM definitions for iGPU IDV workflows across supported Intel Core products. See release notes for the exact supported product list. |
| `igpu-spice-config.xml` | Intel Core integrated GPU platforms | SPICE | VM definitions for iGPU SPICE workflows when remote display/streaming access is preferred over local IDV rendering. |

IDV is intended for local accelerated display workflows, while SPICE is intended for remote display workflows.

## Required fields (per `<vm>`)

Each VM entry should include:

- `name`
- `memory_size`
- `cpu_cores`
- `cpu_threads`
- `mac_address`
- `disk_path`
- `vm_pid`

## Optional fields

- `os_type`: `windows` or `ubuntu` (controls OVMF/disk launch behavior)
- `ssh_port`: host-side SSH forward port used by `--network localhost`
- `monitor_port`: enables QEMU monitor telnet (`-monitor telnet:...`)
- `cpu_assignment`: optional CPU pinning range/list (for example `0-3` or `0-3,8-11`)
- `usb_mouse_hostbus` and `usb_mouse_hostport`: optional USB mouse passthrough mapping
- `description`: free text used as metadata/fallback hint

## Network modes

- `dynamic`: tap networking
- `localhost`: user networking with `hostfwd=tcp::ssh_port-:22` (requires numeric `ssh_port`)

## Display configuration schema

Display values are resolved in this order:

1. `vm/display_configuration/<tag>`
2. `vm/<tag>` (legacy compatibility)
3. `display_configurations/mode[@name='idv']/<tag>` (global defaults)

Supported display tags:

- `display_mode`: `idv` (default), `spice`, or `spice-gtk`
- `fullscreen`
- `show_fps`
- `max_outputs`
- `blob`
- `render_sync`
- `hw_cursor`
- `input`
- `spice_port`: SPICE port used by `-spice port=...` (falls back to `5900 + vm_id`)

Boolean tags accept common forms (`on/off`, `true/false`, `yes/no`, `1/0`).

Display mode behavior:

- `idv`: `-display gtk,input=...,gl=on,full-screen=...,show-fps=...,hw-cursor=...`
- `spice`: `-display egl-headless` + `-spice addr=<primary_ip>,port=<spice_port>,disable-ticketing=on`
- `spice-gtk`: `-display none` + `-spice addr=<primary_ip>,port=<spice_port>,disable-ticketing=on,gl=on,streaming-video=filter,preferred-codec=gstreamer:h264,agent-mouse=on`

## Connector mapping

Per-VM connector mapping supports one or more connectors:

```xml
<display_configuration>
    <display_connectors>
        <connector index="0">DP-1</connector>
        <connector index="1">DP-2</connector>
    </display_connectors>
</display_configuration>
```

Each connector emits into QEMU `-display` as:

- `connectors.<index>=<name>`

Global connector defaults can also be set under:

- `display_configurations/mode[@name='<mode>']/connectors/connector`

Legacy compatibility is still supported for a single connector via `display_connector`.

## Example

```xml
<vm id="1">
    <name>win1</name>
    <os_type>windows</os_type>
    <memory_size>8192</memory_size>
    <cpu_cores>4</cpu_cores>
    <cpu_threads>2</cpu_threads>
    <mac_address>EE:DD:BB:DD:AA:11</mac_address>
    <disk_path>/path/win11_1.img</disk_path>
    <ssh_port>1101</ssh_port>
    <monitor_port>1111</monitor_port>
    <display_configuration>
        <display_connectors>
            <connector index="0">DP-1</connector>
            <connector index="1">DP-2</connector>
        </display_connectors>
    </display_configuration>
    <vm_pid>vm_pid1</vm_pid>
</vm>
```
