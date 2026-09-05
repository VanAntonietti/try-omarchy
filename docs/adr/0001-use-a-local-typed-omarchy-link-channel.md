---
status: proposed
---

# Use a local typed channel for Omarchy Link

Try Omarchy already hosts its guest on the Mac whose services are being exposed, so Omarchy Link will use one versioned, multiplexed virtio-serial channel rather than Blip's remote-SSH topology. The host will advertise narrowly typed, allow-listed capabilities over bounded length-prefixed JSON; it will not expose arbitrary SQL, AppleScript, shell execution, files, or a host network listener.

## Considered options

SSH would reuse more of Blip's Mac bridge but would add keys, Remote Login, and a network-shaped trust boundary to a same-machine product. HTTP over QEMU networking would require authentication for a host listener. One port per service would isolate handlers but duplicate supervision and make future services consume more virtual devices.

## Consequences

The signed Try Omarchy helper owns host permissions and service adapters, while one guest broker owns the channel and multiplexes local clients. Protocol v1 must evolve additively because app updates can meet clients on persistent guest disks that the app does not rewrite; incompatibility disables Omarchy Link, never the VM.
