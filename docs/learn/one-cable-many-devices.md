<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# One cable, many devices

Plug the board into a computer and it becomes a **network adapter** and a **USB
drive**, over the same cable that is powering it. You are very likely reading
this page through exactly that.

This is the part of the board that most surprises people, so it is worth
understanding rather than just using.

> [!NOTE]
> **You need** the USB extra for the commands on this page. It is not part of
> the course setup. Add it with `./bootstrap.sh --with-usb-gadget` (or
> `sudo bash ~/two-computers-one-board/provision/95-usb-gadget.sh`), and read
> what it costs first: the board's only USB port stops being a host while it is
> plugged into a computer. Without the extra there is no gadget to look at; the
> explanations still read fine. With it, the gadget is *defined* from boot, and
> it is *bound* (visible to a computer, with a network link) only while the
> USB-C port is plugged into one.

## Host and device

Every USB connection has two ends with different jobs.

The **host** is in charge. It supplies power, asks what is connected, assigns
addresses, and starts every transfer. Your laptop is a host. USB devices never
speak unless spoken to.

The **device** (or peripheral) answers. A mouse, a webcam, a memory stick.

Most chips can only be one or the other. This board's USB-C port can be
**either** — and that is why plugging it into a computer changes what the board
*is*, not just what it is connected to.

> **The trap.** The port cannot be both at once. While the board is a device to
> your laptop, it is not a host — a hub, a keyboard or a USB stick plugged into
> it is simply gone until you disconnect. There is one USB controller, and it has
> one job at a time. This is a hardware fact, not a setting.

Which role it takes is negotiated by the USB-C connector itself, from the
electrical signals on the cable. **You cannot switch it from software** — a real
disappointment if you have done this on a Raspberry Pi, where you can.

## Being a device on purpose: the gadget

Linux can pretend to be a USB device. The framework is called **USB gadget**, and
you configure it by *making directories*:

```bash
ls /sys/kernel/config/usb_gadget/unoq/
```

This is **configfs**: a filesystem where creating a directory creates an object
in the kernel. Making a directory called `functions/ncm.usb0` does not create a
folder — it creates a USB network function.

A gadget is assembled from:

- **Functions** — the individual things it can be: a network adapter (`ncm`), a
  disk (`mass_storage`), a serial port (`acm`).
- **Configurations** — sets of functions offered together. A host picks one.
- **A UDC** — the actual USB controller. Writing its name into the gadget's `UDC`
  file is the moment the board appears on the host. This is called **binding**.

```mermaid
flowchart TB
  subgraph G["the gadget, built in configfs"]
    F1["ncm.usb0<br/><small>network</small>"]
    F3["mass_storage.0<br/><small>the UNO-Q drive</small>"]
  end
  G -->|"write the controller's<br/>name to UDC = bind"| H(["your computer<br/>sees all of it<br/>on one cable"])
```

Ours offers a network adapter *and* a drive in one configuration, which is why a
single cable gives you both. The network function is `ncm` unless you ask for
the older `rndis` instead; only the one chosen is created.

**Try it:**

```bash
~/two-computers-one-board/usb/status.sh
```

That prints the whole picture: the role, the controller, the configuration and
its functions, the bridge, the address, and the recent log.

## Why you type a name, not an address

Two computers connected by a cable both need IP addresses, and something has to
hand them out. The obvious arrangement is for the board to do it — pick a range,
run a DHCP server, give the laptop an address.

It does not survive contact with the other two operating systems. Turn on
**internet sharing** on your computer — which is how the board reaches the
internet through it — and Windows and macOS stop negotiating. Windows pins its
end to `192.168.137.1` and runs *its own* DHCP server; macOS does the same at
`192.168.2.1`. Neither will ever accept an address from us.

If both ends insist on being the server, you get two computers on one wire with
addresses on different networks, unable to see each other — which looks exactly
like a dead cable, with nothing logged anywhere.

So the board gives in. It always asks, and takes whatever the computer offers.
That solves reachability and creates a smaller problem: the address is now
different on every host, and different again tomorrow.

The answer to *that* is to stop typing addresses. The board publishes its name
over **mDNS**, and Windows, macOS and Linux all resolve `.local` names with
nothing installed:

```bash
ssh arduino@<hostname>.local      # the board's own name: run `hostname` on it
```

And if the computer is not sharing anything, so nothing answers the board's
DHCP request at all? Both ends independently fall back to a **link-local**
address — `169.254.something`, which every desktop OS self-assigns in exactly
this situation. They land on the same network by coincidence that is not a
coincidence, the name still resolves, and nothing had to be configured at
either end.

## The cable is also the power

Here is where this gets genuinely tricky, and it explains several defensive
things in this project.

As a device, the board is powered *by* the host. A laptop port with no power
negotiation supplies quite a modest amount — not much for four CPU cores plus a
microcontroller.

Two consequences:

**Every cable change is also a power cut.** You cannot watch the board being
plugged in, because it is rebooting as you do it. No session survives it. That
is why `status.sh` exists: whatever went wrong has always already finished by the
time you can look, so the post-mortem needs to be one command.

**Binding can brown out the board.** Binding re-enumerates the port, which can
draw enough current to drop the voltage and reset the board. Then it boots, the
cable is still there, it binds again, and it browns out again — a loop with no
window in which to log in and stop it.

This project handles that with a **bind guard**: it counts boots that never
proved themselves healthy, and after three it refuses to bind. The board gives
up the gadget and keeps the network, which is the right way round — the gadget is
the thing being experimented with, the network is how you get in to fix it. If
wifi has been turned off, the guard turns it back on.

That is the same pattern as firmware rollback from the previous page: **try the
new thing, fall back automatically if it does not confirm itself.**

**Try it — see the guard's state:**

```bash
~/two-computers-one-board/usb/bind-guard.sh status
journalctl -b -u unoq-usb-bind -t unoq-bind-guard
```

On a board that has never been plugged into a computer the first prints
`attempts: 0/3` and the second prints nothing, because nothing has tried to
bind. What to do when the guard has tripped is in
[usb.md](../reference/usb.md#the-bind-guard).

## The drive

The board also offers a read-only disk — the one this documentation is on.

It is a single file, `~/unoq-share.img`, containing a partition table and a FAT32
filesystem. The gadget exports that file as a disk; the board mounts the same
file read-only to serve it over HTTP. **One copy, two ways out**, so the drive
and the web page cannot disagree about what is on the board.

Two details that took experimentation to get right:

- **It has a partition table.** Formatting the image directly works fine on
  Linux and Windows will often refuse to assign it a drive letter. A real USB
  stick has an MBR; so does this.
- **It is exported read-only.** If the host could write while the board has the
  filesystem mounted, both would be caching the same blocks with neither aware of
  the other, and FAT does not survive that for long.

> [!TIP]
> **Go deeper.** [usb.md](../reference/usb.md) has all of it: why NCM rather than RNDIS on
> Windows 11, why the route metric is 700, why there are two systemd units, and
> the full troubleshooting list.

## Check yourself

1. You plug a USB keyboard into the board's port while it is connected to your
   laptop. What happens, and why?
2. Your laptop has internet sharing on and the board cannot be reached at all.
   What is the most likely cause?
3. Why does the bind guard give up the *gadget* rather than retrying it?

<details markdown="1">
<summary>Answers — try each one first</summary>

1. **Nothing — the keyboard is simply gone until you disconnect.** The port
   cannot be host and device at once: there is one USB controller, and it has
   one job at a time. While the board is a device to your laptop it is not a
   host, and you cannot switch it from software.
2. **Both ends insisting on being the DHCP server.** With sharing on, Windows
   pins its end to `192.168.137.1` and macOS to `192.168.2.1`, each running its
   own DHCP server, and neither will accept an address from the board. If the
   board hands out addresses too, the two ends sit on different networks and
   cannot see each other, which looks exactly like a dead cable. That is why
   the board always asks and takes whatever the computer offers.
3. **Because retrying is the failure.** Binding can brown out the board, which
   reboots with the cable still there and binds again — a loop with no window
   in which to log in and stop it. After three boots that never proved
   themselves healthy the guard refuses to bind and keeps the network: the
   gadget is the thing being experimented with, the network is how you get in
   to fix it.

</details>

Next: [four LEDs, and the surprisingly hard question of what an indicator should
actually say](four-lights.md).
