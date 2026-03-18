# VM Config Notes

This folder contains VM XML definitions used by `scripts/launch-vm.sh`.

## VM definition files

- `bmg-idv-config.xml`: IDV VM examples

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
- `cpu_id`: optional CPU pinning/selection field consumed by launch flow
- `description`: free text used as metadata/fallback hint

## Network modes

- `dynamic`: tap networking
- `localhost`: user networking with `hostfwd=tcp::ssh_port-:22`

## Display configuration schema

Display values are resolved in this order:

1. `vm/display_configuration/<tag>`
2. `vm/<tag>` (legacy compatibility)
3. `display_configurations/mode[@name='idv']/<tag>` (global defaults)

Supported display tags:

- `fullscreen`
- `show_fps`
- `max_outputs`
- `blob`
- `render_sync`
- `hw_cursor`
- `input`

Boolean tags accept common forms (`on/off`, `true/false`, `yes/no`, `1/0`).

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
