<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# IP over USB, and the fileshare

Plug the board's USB-C port into a computer and it becomes a USB device: a
network adapter, and a read-only drive with the VS Code installers and the
learning content on it.

```
your computer                          UNO Q
─────────────                          ─────
its own address  ◄── USB-C cable ──►   <hostname>.local
(it runs DHCP)       the board asks    http://<hostname>.local:8080/
                                       "UNO-Q" drive, read-only
```

Set it up once with:

```bash
sudo bash ~/two-computers-one-board/share/fetch-vscode.sh    # ~1.8 GB, needs internet
sudo bash ~/two-computers-one-board/share/build-image.sh     # FAT32 image
sudo bash ~/two-computers-one-board/provision/95-usb-gadget.sh
```

Then plug it in. Nothing to configure on the computer.

The web page on port 8080 in the picture is a separate extra, and serves the
same image. Add it at any point after the image is built, with
`sudo bash ~/two-computers-one-board/provision/75-learning-web.sh` (a plain
`./bootstrap.sh` includes it). Without it you still have the network link
and the drive.

---

## The one thing that surprises people

**The USB-C port cannot be a host and a device at the same time.**

There is exactly one USB data controller on this board — `4e00000.usb`, a dwc3
with `dr_mode = "otg"`. While the board is a device, it is not a host: a hub,
dock, network dongle, keyboard or USB stick plugged into it is *gone* until you
disconnect from the computer.

That is a hardware fact, not a configuration choice. If you develop with a USB
Ethernet dongle, you are choosing between the dongle and the gadget.

## Addressing

**The board is always the DHCP client on this link, and the fixed thing you
type is a name.**

**The common case: the computer shares its connection.** The cable is in a
laptop with Internet Connection Sharing switched on in Windows, or Internet
Sharing in macOS. The laptop runs a DHCP server on the shared adapter, the
board asks it for an address, and the board reaches the internet through the
laptop. Nothing is set on the board to make this happen, and it is what most
people plugging a development board into a laptop are running. [Why the board
cannot choose its own address](#why-the-board-cannot-choose-its-own-address)
is the reasoning.

**The other case: the computer shares nothing.** Nobody answers the board's
DHCP request, so it gives itself an IPv4 link-local address, the computer does
the same, and the two talk with no configuration at either end. This is what it
is for: a host that is not sharing, where the board has to be reachable
regardless. It reaches that one computer and nothing beyond it. See [When
nothing is serving DHCP](#when-nothing-is-serving-dhcp).

Between the two sits a host that routes but hands out no address, where the
board takes one on the host's subnet itself — [The host that NATs but will not
lease](#the-host-that-nats-but-will-not-lease).

There is no mode to set for any of this. The board always asks first and falls
back by itself, and it moves between the cases as the host changes. Which one
it is in right now is a question for `status.sh`, further down this section.

| | |
|---|---|
| Board | whatever the computer leases it, on `br-usb` |
| If the host routes but serves no DHCP | an address on *its* subnet, self-assigned |
| If nothing at all is there | IPv4 link-local, `169.254.x.y` (RFC 3927) |
| Reachable as | `<hostname>.local`, over mDNS |
| Runs DHCP | the computer, never us |

```bash
~/two-computers-one-board/usb/status.sh
```

```
  dhcp                   udhcpc is asking the host for an address
  leased address         192.168.137.210/24
  gateway                192.168.137.1
  reachable as           <hostname>.local
```

The `network` section of that output says which case this is:

| Line | Means |
|---|---|
| `leased address` and `gateway` filled in | the computer is sharing, and leased the board an address |
| `host profile`, then `self-assigned - ...` | the host routes but serves no DHCP; the board took an address on its subnet |
| `link-local  active - no DHCP server on the other end` | the computer is sharing nothing |

The `dhcp` line only says the client is running — it reads the same in all
three, because the board never stops asking. `leased address` shows `<none>`
when there is no lease.

### Why the board cannot choose its own address

Turn on Internet Connection Sharing in Windows and it stops negotiating: it
pins the shared adapter to **`192.168.137.1/24`** and runs its own DHCP server
there. It will never take a lease from us. macOS Internet Sharing does the same
thing at `192.168.2.1`.

So any board that insisted on its own numbering would be on a different `/24`
from the host on the same wire, with no route between them. Both ends look
configured, the cable looks dead, and nothing logs an error — there is nothing
wrong with either end in isolation.

A board that wants internet over the cable therefore has to accept the host's
numbering, which means the numeric address is not ours to fix. Nothing here is
hardcoded to Microsoft's, though: the same code works for macOS, for a Linux
host running its own dnsmasq, and for whatever ICS gets changed to next.
`busybox udhcpc` is the client, because this image ships no other one and
busybox is already here.

### When nothing is serving DHCP

The cable is in a computer that is not sharing anything, ICS is off, or the
host is still booting. `udhcpc` reports `leasefail`, and the board falls back —
to the host's own numbering if it can prove there is a working host on the
other end, and to IPv4 link-local if it cannot.

**Link-local is the floor.** It is the same thing Windows, macOS and Linux each
do when their own DHCP finds nothing, so **both ends land on `169.254.0.0/16` by
themselves** and can talk with no configuration at either. `avahi-autoipd`
rather than picking an address ourselves because RFC 3927 is more than choosing
one — it ARP-probes before claiming, defends the claim, and re-picks on a
conflict, which matters precisely because the host is self-assigning from the
same range at the same moment on the same wire.

What link-local cannot do is get you *off* the wire: RFC 3927 forbids routing
off-link through a `169.254` next hop, so a board on link-local reaches the one
computer it is plugged into and nothing beyond it. That is the whole reason for
the fallback above it.

The moment a real lease arrives, `bound` takes whichever fallback is in place
back down. Never two at once — see below for why that is not merely tidiness.

### The host that NATs but will not lease

Windows ICS with its firewall profile dropping inbound DHCP is the case: the
gateway is up at `192.168.137.1`, it forwards and NATs to the internet in about
17 ms, and it answers no DHCP discover at all. Everything the board needs is on
the other end of the cable and reachable. The only missing thing is somebody to
hand over an address — so `usb-profile.sh` takes one.

```
  host profile           windows-ics (192.168.137.210/24 via 192.168.137.1)
                         self-assigned - the host is NAT-ing but not serving DHCP
```

It identifies the host **by asking the wire**, not by guessing from a config
file. Each profile names the address that kind of host puts on its own shared
adapter, and detection is an ARP request for it — ARP rather than ping because
Windows firewalls ICMP to the ICS adapter by default, so a ping-based check
would report "no host" for the most common host this will ever meet.

| Profile | Gateway | The board takes |
|---|---|---|
| `windows-ics` | `192.168.137.1` | `192.168.137.210/24` |
| `macos-sharing` | `192.168.2.1` | `192.168.2.210/24` |

`.210` rather than `.2`, because both shared adapters lease from the low end of
their range: a high address keeps the board clear of anything the host hands
out if its DHCP half comes back to life.

**Nothing is claimed without two proofs**, because an address claimed wrongly is
worse than no address at all:

1. **The address is free** — an RFC 5227 ARP probe (`arping -D`, sourced from
   `0.0.0.0`, so it is a question rather than a claim) before taking it. The
   board never collides with the host, or with a second board on the same
   machine.
2. **The route works** — an actual packet to the internet through `br-usb`
   after the route is in. A gateway that answers ARP and forwards nothing gets
   the address handed straight back, and the board falls through to link-local,
   which at least reaches the computer.

It will not guess. If no profile's gateway answers, this reports nothing and
link-local takes over; it does not sweep the subnet or invent numbering. A
Linux host with its own numbering is a line in a file:

```bash
# /etc/unoq/usb-profiles.conf - name, gateway, address, prefix length
my-linux-box  10.9.0.1  10.9.0.210  24
```

```bash
UNOQ_USB_PROFILE_FALLBACK=0   # link-local only, nothing cleverer
```

That line goes in `/etc/default/unoq-usb`, like every setting on this page.
Defaults and the full list are in
[What you can change](configuration.md#the-usb-link).

### DNS, when the host routes but does not resolve

A host that is not serving DHCP usually is not serving DNS either — the ICS
resolver is the other half of the same service that is not running, and a Linux
box NAT-ing with plain nftables never had one on that address to begin with.

Writing that gateway into `resolv.conf` anyway produces the least obvious
failure on this link: traffic routes, `ping 8.8.8.8` answers, and every name
lookup hangs until it times out. `apt` stops working while the network looks
perfect.

So the nameserver is **asked a question before it is written down** — a lookup
sent to that address specifically, bounded by `timeout` because a resolver that
is not there drops the query rather than refusing it. If it cannot answer, DNS
goes to public resolvers over the link that has just been proved to carry
traffic:

```
unoq-usb-dhcp: the host on br-usb answers no DNS - resolving through 1.1.1.1 8.8.8.8 instead
unoq-usb-dhcp: resolv.conf -> 1.1.1.1 8.8.8.8
```

This applies to a real lease's DNS servers as well, not just to the
self-assigned case — option 6 is a claim like any other. A nameserver that
answers is always preferred to the public ones, and the check runs again on
every lease event, so a resolver that starts working is picked up on the next
one.

```bash
UNOQ_USB_DNS_PUBLIC="1.1.1.1 8.8.8.8"   # or "" to keep every lookup on the link
UNOQ_USB_DNS_PROBE_NAME=example.com     # the name looked up to decide
UNOQ_USB_DNS_TIMEOUT=5                  # seconds per nameserver
```

(Defaults and where to set them:
[What you can change](configuration.md#the-usb-link).)

`resolv.conf` is only ever written when the USB link is the board's default
route — NetworkManager owns the file otherwise, and taking it while wifi is
carrying traffic would leave the board pointing at a gateway it loses the moment
the cable comes out.

### Why the name works now, and did not before

There must be **exactly one address** on `br-usb`, because avahi advertises
every address an interface has. The board used to carry two — a static
`10.55.0.1` alongside the lease — and a host querying over the cable got two A
records back:

```
Registering new address record for 10.55.0.1 on br-usb.IPv4
Registering new address record for 192.168.137.210 on br-usb.IPv4
```

It picked one, and half the time picked the one it had no route to. The name
was a coin flip, so the docs told you to use the numeric address instead. That
is the constraint the single-address design removes, and it is why
`usb-dhcp.sh` stops link-local *before* it puts a lease on, and why
`status.sh` warns if it ever finds more than one address here.

`10.55.0.1` was never really zero-configuration anyway: reaching it from a
Windows host meant an elevated `route add 10.55.0.0 mask 255.255.255.0
192.168.137.1`. Link-local needs nothing at the far end.

The address is still sticky, for anyone who prefers typing numbers: the last
lease is remembered in `/var/lib/unoq/usb-dhcp-last` and re-requested next
time, and ICS honors the request in practice.

Move the cable to a different computer and that request is the wrong one to
make - ICS shares from `192.168.137.0/24`, macOS Internet Sharing from
`192.168.2.0/24`, and neither hands out an address from the other's subnet. The
new host answers with a NAK, and `usb-dhcp.sh` takes that as its cue to forget
the remembered address: the running client re-discovers either way, but the
file is read once when `udhcpc` starts, so a refusal left on disk is one the
board repeats after every reboot. Nothing to do at your end; the first lease
from the new host becomes the sticky one.

---

## Do not switch the role from software

This catches people who have done USB gadgets on a Raspberry Pi, where you
write `dr_mode` or `echo device > .../role`. Here:

| | |
|---|---|
| `/sys/class/usb_role/4e00000.usb-role-switch/role` | exists on kernel 7.0.0 (root-writable, reads `device` on a cable); absent on earlier kernels |
| `/sys/class/typec/port0/data_role` | read-only |
| dwc3 `mode` attribute | not exposed |

On the kernels this page was first written against, the role switch registered
without its `role` attribute, because the driver did not set
`allow_userspace_control`. Kernel 7.0.0 has it, seen on 2026-11-01. Nothing in
this project writes it, and writing it has not been tried here. The **Type-C
controller** (`anx7625`) still picks host or device from the CC lines when a
cable is plugged in, and the design below depends on that, not on the file.
Writing `host` to it while the board is a device on the cable would drop that
link.

So the design here is event-driven, not boot-time:

```
boot, nothing plugged in
   → unoq-usb-gadget.service builds the definition, br-usb and DHCP, exits
     (RemainAfterExit=yes — it stays "active" having bound nothing)

plug into a computer
   → Type-C negotiates: computer = host, board = device
   → a UDC appears in /sys/class/udc
   → udev fires SYSTEMD_WANTS=unoq-usb-bind.service
   → that binds the gadget to the UDC
   → usb0 appears → udev fires the bind unit again
   → it joins br-usb; udhcpc asks the computer for an address
```

**Why two units.** The obvious design is one unit that udev restarts. It does
not work: the boot-time unit is `RemainAfterExit=yes`, and systemd will not
re-run `ExecStart` for a oneshot it still considers active — so a udev trigger
aimed at it is silently a no-op and the gadget never binds. `unoq-usb-bind.service`
exists solely to be re-runnable: `Type=oneshot`, no `RemainAfterExit`, back to
`inactive` the moment it finishes, ready for the next plug-in.

At boot with nothing plugged in, the prepare unit builds the definition and
exits. That is not a failure — there is simply nothing to bind to yet.

## What the computer sees

The gadget offers **one** configuration, holding both functions:

| Config | Functions | Used by |
|---|---|---|
| `c.1` | **NCM** + mass storage | Windows 10 ≥1903, Windows 11, macOS ≥Catalina, Linux |

**NCM first, not RNDIS** — the opposite of most USB-gadget recipes, which
predate Windows 10 version 1903 shipping a native NCM class driver
(`UsbNcm.sys`). NCM now needs no driver and no INF on Windows, macOS has had it
since Catalina, and Linux has always had it. RNDIS is deprecated at Microsoft's
end.

### Switching to RNDIS

For a host with no NCM driver. Two things have to happen: the setting has to be
somewhere the units read it at every boot, and the gadget that already exists
has to be thrown away so a new one is built.

```bash
echo 'UNOQ_GADGET_PRIMARY=rndis' | sudo tee -a /etc/default/unoq-usb
sudo ~/two-computers-one-board/usb/gadget-down.sh --purge      # required
sudo systemctl restart unoq-usb-gadget                         # builds it again, from the file
sudo systemctl start unoq-usb-bind                             # binds it, if a computer is plugged in
```

> [!WARNING]
> The purge unbinds the gadget and removes `br-usb`, so an SSH session over the
> cable ends at the second line. Run this over wifi, or do only the first line
> and reboot: the gadget definition does not survive a reboot, and the next
> boot builds it from the file.

**The setting belongs in the file, not on the command line.** A variable typed
in front of `gadget-up.sh` reaches that one run only. The definition lives in
configfs, which is rebuilt at every boot by `unoq-usb-gadget.service` from
`/etc/default/unoq-usb`, so a board switched on the command line is back on NCM
after its next reboot.

**The purge is not optional.** `gadget-up.sh` is idempotent and never rebuilds a
definition that already exists in configfs, so changing the setting on its own
changes nothing — the gadget you get is the one that was already there. The
script warns when the built gadget does not contain the function you asked for.

The result is the *same single configuration* with RNDIS in it. The choice is
made at build time rather than offered to the host to pick from. To go back,
delete the line from the file and repeat the other three. The setting is listed
in [What you can change](configuration.md#the-usb-link).

### Why not two configurations

It used to be two — NCM in `c.1`, RNDIS in `c.2` — on the reasoning that a host
enumerates configuration 1 and stops, so each OS could take the one it
supported. Both halves of that were wrong, and together they cost us the drive
on Windows entirely.

Windows generates the `USB\COMPOSITE` compatible id — the thing that makes it
load `usbccgp.sys`, which is what gives each function its own driver — only
when [all three of these hold][mscomposite]:

- `bDeviceClass` is 0, or class/subclass/protocol are `0xEF`/`0x02`/`0x01`
- the device has multiple interfaces
- **the device has a single configuration**

Two configurations failed the third. No composite id, no generic parent driver,
so exactly one driver bound to the whole device: networking worked and the mass
storage interface was **never enumerated at all** — not hidden, not
unmountable, absent. Windows' only escape is an INF naming the configuration
for `usbccgp` in the registry, which means shipping a signed driver package for
a device using the Linux Foundation's ids.

And the host never chose `c.1` anyway. The Microsoft OS descriptors carrying the
RNDIS compatible id were linked to whichever config held RNDIS, on the
assumption that Windows would not ask about a configuration it was not using.
Windows always asks: it follows `b_vendor_code` during enumeration, and the
`USB\MS_COMP_RNDIS` id it got back came in at the **top** of the board's
compatible id list. It went straight to the configuration filed as the fallback
nobody would pick.

So the OS descriptors are now published only when RNDIS is what was actually
built. On an NCM gadget they are worse than useless: they point Windows at a
driver for a function that is not there.

The device also now declares `bDeviceClass`/`SubClass`/`Protocol` as
`0xEF`/`0x02`/`0x01` — Interface Association Descriptor — rather than all
zeroes. A network function is two interfaces by itself, and with zeroes Windows
read interface 0 as the whole device, reporting this board as
`USB\Class_02&SubClass_02&Prot_FF`: the RNDIS control interface.

[mscomposite]: https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/enumeration-of-the-composite-parent-device

On the board, the chosen function registers a netdev, which is enslaved to a
bridge (`br-usb`) that carries the address.

### A serial login over the cable

The gadget can carry a third function: a serial port (CDC-ACM), with a login
on it. It is **off by default**.

With it on, the computer sees a serial port beside the network adapter and the
drive. Every host has a class driver for it, so nothing needs installing:
Windows binds `usbser.sys` and lists a COM port in Device Manager, Linux makes
`/dev/ttyACM0`, macOS `/dev/cu.usbmodem*`. Open it at any speed (the speed is
ignored on a USB serial port) and press Enter for a login prompt:

```bash
tio /dev/ttyACM0              # or: screen /dev/ttyACM0, or PuTTY on COMn
```

It needs no IP, no DHCP and no mDNS, so it is a way in when the network half
of the link is the thing that is broken. It is not a console: it starts with
userspace, needs the gadget built, and is gone in exactly the failures the
board's own UART (`/dev/ttyMSM0`) is still there for.

To turn it on, the setting goes in the file the units read, the step is run
again to set up the login, and the gadget is rebuilt:

```bash
echo 'UNOQ_GADGET_ACM=1' | sudo tee -a /etc/default/unoq-usb
sudo bash ~/two-computers-one-board/provision/95-usb-gadget.sh  # the login
sudo ~/two-computers-one-board/usb/gadget-down.sh --purge       # required
sudo systemctl restart unoq-usb-gadget                          # builds it again, from the file
sudo systemctl start unoq-usb-bind                              # binds it, if a computer is plugged in
```

Or set the line, run the step, and reboot: the gadget is rebuilt at every boot.
The purge drops a session on the cable, as in
[Switching to RNDIS](#switching-to-rndis), and the same two rules apply: the
setting belongs in the file (`sudo UNOQ_GADGET_ACM=1 usb/gadget-up.sh` reaches
one run, and `UNOQ_GADGET_ACM=1 sudo ...` reaches none, since `sudo` clears the
environment), and an existing gadget is never rebuilt in place. `gadget-up.sh`
warns when the setting asks for a port the built gadget does not have, and the
step warns when the line is not in the file.

What the step does is one link: `dev-ttyGS0.device` wants
`serial-getty@ttyGS0.service`. That getty is already `BindsTo=` the device, so
it starts whenever `/dev/ttyGS0` appears and stops when it goes. It is not
enabled into `getty.target`, the usual place, because then every boot would
wait up to 90 seconds for a device that a gadget built without the port never
makes. To undo it: remove the line from the file, then
`sudo systemctl remove-wants dev-ttyGS0.device serial-getty@ttyGS0.service`
(or `sudo rm /etc/systemd/system/dev-ttyGS0.device.wants/serial-getty@ttyGS0.service`
and `sudo systemctl daemon-reload`), and rebuild the gadget.

**The step warns if `arduino-router-serial.path` is still enabled.** Arduino's
factory image ships it with `PathExists=/dev/ttyGS0`: as soon as the port
exists, it starts a proxy that `Requires=` Arduino's router, which takes
`/dev/ttyHS1` from this project and `/dev/ttyGS0` from the login.
`provision/15-dev-tools.sh` disables it; on a board that has not run that step,
`sudo systemctl disable --now arduino-router-serial.path arduino-router-serial.service`.

**Why it is off by default.** It changes the descriptors of a composite device
that Windows has already mishandled once ([Why not two
configurations](#why-not-two-configurations)). The port goes into the same
single configuration, linked last, so the network and the drive keep their
interface numbers; that is the arrangement Windows' composite rules ask for. It
**has not yet been checked on Windows** with three functions in one
configuration, nor on a board and host at all. It stays off until a Windows host
has been seen binding NCM, the drive and the COM port together.

The same port can carry the MCU's shell instead of the login: see the next
section.

### The MCU's shell over the cable

With the serial port on, the same COM port can reach the STM32 instead of
Linux: the MCU's Zephyr shell, in PuTTY or `tio` on the host, with no SSH and
no network at all. A relay does it, `python/unoq/mcuserial.py`, which passes
every byte between `/dev/ttyGS0` and the MCU's UART `/dev/ttyHS1` untouched.
The step installs it as `unoq-mcu-serial.service` when `UNOQ_GADGET_ACM=1`,
and never enables or starts it: it runs only when someone asks.

`/dev/ttyHS1` has one owner at a time, and on a provisioned board that is the
CPU-bars demo. `/dev/ttyGS0` has one reader, and that is the login. So the
unit has `Conflicts=` on both, and starting it stops them:

```bash
sudo systemctl start unoq-mcu-serial    # stops unoq-cpu-bars and the login on ttyGS0
```

On the host, open the same COM port (or `/dev/ttyACM0`) as for the login and
press Enter. What answers is the Zephyr shell, running at the MCU's 115200
(the host's speed setting still does not matter), with its prompt:

```text
unoq:~$ app status
```

Everything in [the MCU's shell](mcu.md#interactive-shell) works from there,
`app` commands and all. It is raw: the shell does its own echo and line
editing, and the relay adds none.

To give the ports back:

```bash
sudo systemctl stop unoq-mcu-serial
sudo systemctl start unoq-cpu-bars
sudo systemctl start serial-getty@ttyGS0   # the login does not come back by itself
```

`Conflicts=` only stops the demo, so it has to be started again. The login
does too: the device wants it, which starts it when `/dev/ttyGS0` appears, and
the port has been there all along. A reboot or a rebuilt gadget brings both
back as well. Either `start` works without the `stop` first, because
`Conflicts=` works both ways and stops the relay.

The relay stops cleanly on `systemctl stop`, with both ports closed. Pulling the
cable hangs up `/dev/ttyGS0`, which ends the relay, and the unit starts it again
two seconds later to wait for the next host. Purging the gadget removes the
device, and `BindsTo=dev-ttyGS0.device` stops the relay with it. If the start
fails, the journal says why (`journalctl -u unoq-mcu-serial`). The usual cause
is something else holding `/dev/ttyHS1`, such as a `tio` left open on the
board, and the relay names it the way `unoq.mcu` does.

To remove it: `sudo rm /etc/systemd/system/unoq-mcu-serial.service` and
`sudo systemctl daemon-reload`.

---

## Running on the USB link alone

The radio is the largest thing on this board that can simply be switched off,
and on a board that is plugged into a computer anyway it is also the most
redundant. As a device the board is a power sink at USB default current with no
PD contract, so it is worth reclaiming.

```bash
~/two-computers-one-board/net/wifi.sh check      # would it be safe right now?
sudo ~/two-computers-one-board/net/wifi.sh off
sudo ~/two-computers-one-board/net/wifi.sh on
```

`check` and `off` run the same preflight, and `off` refuses if it fails:

```
  gadget bound, and 192.168.137.1 answers on br-usb
  the host is NAT-ing: the board keeps its internet over USB

  RECONNECT ON:  arduino@<hostname>.local   (or arduino@192.168.137.210)
```

This is not a wrapper around `nmcli radio wifi off` for the sake of it. You are
almost certainly typing that command over the wifi it is about to turn off, and
if the USB link is not actually carrying traffic — gadget did not bind, cable is
charge-only, host is not sharing — then the moment the radio drops there is no
path to the board at all. Not slow: absent.

The reachability check is ARP, not ping. **Windows blocks ICMP to its ICS
adapter by default**, so the gateway that is routing your traffic perfectly well
does not answer a ping, and refusing on that basis would refuse in the normal
case. A resolved neighbor proves frames cross the wire and get answered, which
is the property "will I still be able to reach this board" actually depends on.

**It looks in both address families, and the second one is not decoration.**
When nothing serves DHCP, the board autoconfigures a `169.254/16` address and
the host does the same, but neither side ARPs for the other until something
sends IPv4 traffic — whereas IPv6 link-local comes up unprompted and is what
carries the ssh session. Asking only IPv4 therefore failed in exactly the
no-DHCP case the neighbor fallback exists for: the v4 table held one `FAILED`
entry with no `lladdr`, the v6 table held the host `REACHABLE`, and `check`
reported *"no computer on br-usb"* to someone logged in over that very link. A
gateway still wins when there is one — an address the host routes with beats one
it merely answers on — then IPv4 neighbors, then IPv6. Multicast is never a
peer.

`off` also kicks the DHCP client into renewing, because NetworkManager owns
`/etc/resolv.conf` and rewrites it — without our nameservers — the moment the
radio goes down. `usb-dhcp.sh` puts them back on a lease event, and without the
kick that would not happen until the lease next renewed, which on an ICS lease
is days. The symptom is `ping 8.8.8.8` working and `apt` not.

### Two ways back, when the board is on USB only

Turning wifi off means the gadget is the only way in, so both failure modes have
an automatic path back to a board you can log into.

| What failed | What catches it | What it does |
|---|---|---|
| The bind is killing the board — brownout loop | `bind-guard.sh` | Refuses to bind after 3 unconfirmed boots, **and turns the radio back on** |
| The bind works and there is still no internet | `unoq-uplink-fallback.service` | Waits 240s after boot, then turns the radio back on |

The second one exists because the guard cannot see it: everything the guard
checks succeeded. The gadget bound, `br-usb` came up, the address is there — and
the board still has no way out, because the computer is asleep, or is not
sharing, or woke up with sharing switched off, or is a different computer.

It is a deadline after boot rather than a watchdog on a timer. A poll that ran
forever would flip the radio every time the host slept or the cable was jostled,
and would fight anyone who turned wifi off deliberately. Boot is when the
question is live and nobody is watching. Falling back then stays fallen back
until a person unmakes it, which is what you want from something you are relying
on.

```bash
UNOQ_UPLINK_FALLBACK=0       # in /etc/default/unoq-usb, to disable it
UNOQ_UPLINK_DEADLINE=240     # seconds to wait after boot
```

(Defaults and the rest of the guard settings:
[What you can change](configuration.md#the-guards).)

```bash
journalctl -b -u unoq-uplink-fallback -t unoq-uplink-fallback
```

Both are enabled unconditionally by `95-usb-gadget.sh`, including on a board
whose wifi is on — where the fallback looks, sees a radio already up and exits.
The moment either is needed is the moment nobody can enable it.

### The board's own route out

The board does not offer the computer a gateway, but it does take one *from*
it. When the host's lease arrives with a router in it, `usb-route.sh` points the
board's default route at that address, metric **700** — so a board with no other uplink
can reach the internet through the computer, provided the computer is NAT-ing
(Internet Connection Sharing, or `New-NetNat`, on Windows).

The metric is the whole safety story, and it is worth stating plainly because
getting it wrong is quiet:

| Link | Metric | |
|---|---|---|
| Ethernet (NetworkManager) | 100 | wins |
| USB gadget, **once proved** | **550** | beats wifi |
| **Wifi** (NetworkManager) | **600** | wins over an unproved cable |
| USB gadget, as installed | **700** | fallback only |

Higher metric = lower priority, so the route a lease installs is only ever used
when the board has nothing better. **This was 500 and therefore beat wifi**,
which is a bad failure to diagnose: SSH keeps working, because that is a
connected route on the LAN rather than the default, so the board looks reachable
and healthy while every outbound connection is being sent to a computer that
probably is not routing. `apt`, `git` and anything else wanting the internet
just stop.

**550 is that same side of the line, and what makes it safe is the proof.** It
is not what a lease installs. Every lease event, and every successful host
profile, runs `usb-route.sh prefer`, which sends a packet to the internet
*bound to `br-usb`* — ICMP first, then TCP, because some hosts firewall
outbound ping while NAT-ing TCP perfectly. Only if something answers is the
route promoted ahead of wifi, and the check is bound to the interface precisely
because "does this board have internet" would answer yes on the strength of the
wifi it is about to overtake.

It is not permanent either. The same check runs again on the next event, and a
host that has stopped forwarding is demoted back to 700 rather than keeping the
default route on the strength of having worked once. The residual case is worth
stating: a host that goes to sleep with the cable in leaves a promoted route
pointing at nothing until the next event —
`unoq-uplink-fallback.service` is the backstop for the version of that which
actually strands the board.

```bash
UNOQ_USB_PREFER_OVER_WIFI=0  # never promote; the cable stays a fallback
UNOQ_USB_DEFAULT_ROUTE=0     # never touch the default route at all
```

(Defaults and where to set them:
[What you can change](configuration.md#the-usb-link).)

Check which route actually won, with the cable plugged in:

```bash
ip route show default        # lowest metric is the one in use
```

### There is no DHCP server on this board

There used to be. `dnsmasq` ran on `br-usb` to lease the computer an address,
and it came with a standing worry worth recording: this board normally also
sits on a real network, and a DHCP server that answered on the wrong interface
is a rogue DHCP server on someone's home or office LAN. It was contained with
`--interface=br-usb --bind-dynamic`, which binds per-interface rather than to
`0.0.0.0`, and the socket listing was never the reassuring part — DHCP clients
broadcast from `0.0.0.0`, so `0.0.0.0:67` in `ss` output was expected and the
interface filter was the only thing making it safe.

Dropping server mode deletes that risk rather than containing it. If you are
looking at a board provisioned before the change and want to be sure:

```bash
sudo ss -ulnp | grep :67          # expect nothing
```

`usb-net-up.sh` also kills any instance it finds left over on `br-usb`, because
a stale one would be a second DHCP server on the same wire as the host's, with
the board taking whichever reply arrived first.

## The bind guard

Binding the gadget re-enumerates the USB port, and on a board powered by a
weak port that can drop the supply far enough to reset it. The board then
boots with the cable still in, binds again and resets again, with no moment at
which you could log in and stop it. The guard is what breaks that loop. Its
reasoning is in the header of
[`usb/bind-guard.sh`](../../usb/bind-guard.sh); this is how to live with it.

**What it counts.** Boots on which a bind was attempted and never confirmed.
`unoq-usb-bind.service` runs `bind-guard.sh check` before it binds, and the
first check of each boot adds one to a counter. Later checks in the same boot
are waved through, because udev starts the bind unit more than once per
plug-in. The counter is one line in a file, the boot's id and the count:

```
/var/lib/unoq/usb-bind-attempts
```

**What clears it.** `unoq-usb-confirm.service` waits for the network, sleeps
120 seconds, and then runs `bind-guard.sh confirm`, which deletes the file. A
board that stays up for those two minutes starts its next boot at zero. A board
that resets before then does not.

**When it trips.** Once the count has reached 3 (`UNOQ_USB_BIND_MAX_ATTEMPTS`),
the next boot's check refuses: the gadget is not bound, wifi is turned back on
if it was off (`UNOQ_GUARD_WIFI_RESCUE=0` stops that), and the journal says

```
unoq-bind-guard: REFUSING to bind: 3 consecutive boots never confirmed (max 3).
```

`unoq-usb-bind.service` is then a failed unit, so LED 2 is red. It turns red
one boot earlier than the refusal, as soon as the count reaches the limit.

Three ordinary reboots can do this too, if each one happens within two minutes
of the last boot with the cable plugged in. Nothing is wrong with the board in
that case; the guard cannot tell impatience from a brownout.

**Looking at it.** No root needed:

```bash
~/two-computers-one-board/usb/bind-guard.sh status
journalctl -b -u unoq-usb-bind -t unoq-bind-guard        # this boot
journalctl -b -1 -u unoq-usb-bind -t unoq-bind-guard     # the boot before
```

```
attempts: 1/3  (/var/lib/unoq/usb-bind-attempts)
  (already counted in the current boot)
```

`1/3` in the first two minutes of a healthy boot is normal. It drops to `0/3`
when the confirm unit runs.

**Clearing it by hand.** First deal with the cause if there is one: the message
suggests a powered hub or a PD supply rather than a 0.5 A port. Then:

```bash
sudo rm -f /var/lib/unoq/usb-bind-attempts
sudo systemctl start unoq-usb-bind.service
```

The first line resets the counter. The second binds the gadget now, and a
successful start also takes the unit out of the failed list, so LED 2 goes back
to green within a few seconds.

## The fileshare

`share/build-image.sh` builds a FAT32 image — the one filesystem Windows,
macOS and Linux all mount with no driver — and it is the **only** copy of the
content:

```
/home/arduino/unoq-share.img     the image (on the big partition)
  └─ mounted read-only at /srv/unoq-share
        ├─ index.html            the learning page
        └─ vscode/               installers + SHA256SUMS.txt
```

The same file is what `usb_f_mass_storage` exports and what `unoq-learn`
serves, so the drive and the web page cannot disagree about what is on the
board. It lives on `/home/arduino` because `/` has under 5 GB spare once
Zephyr is built.

**It is exported read-only, and mounted read-only.** The host and the board
would otherwise both be writing the same blocks with neither one's page cache
aware of the other, which destroys a FAT filesystem quickly.

To update the content, one command:

```bash
sudo bash ~/two-computers-one-board/share/build-image.sh
```

It takes the drive out of the gadget, renders the documentation, remounts the
image read-write, syncs the new content in, remounts it read-only, and hands
the drive back. With `--rw` it leaves the image writable and does not hand the
drive back, because the board and the computer would then both be writing it;
run it again without `--rw` when you are done.

An image whose partition table is there but whose filesystem is not, which is
what a run interrupted half way through formatting leaves, is formatted on the
next run.

**Do not unbind the gadget first.** The script swaps the drive's medium
underneath the mass-storage function, which is a media change, not a re-bind:
the network half of the gadget stays up, and so does an SSH session running
over the cable. `usb/gadget-down.sh` would end that session, because it unbinds
the gadget and deletes `br-usb`; and `systemctl restart unoq-usb-gadget`
afterwards would not bring it back, because that unit only builds the
definition and never binds.

To the computer this looks like the drive being ejected and put back, so it
reads the new contents rather than a cached copy of the old ones. A computer
with a file open on the drive at that moment loses it, as it would with a USB
stick pulled out.

`build-image.sh` stops `unoq-learn` while it remounts the image and starts it
again afterwards, because the web server serves from that mount and would
otherwise hold it. If something else is holding `/srv/unoq-share` — a shell
that has `cd`'d into it is the usual one — the script stops and names the
process, rather than forcing the unmount.

## adb is disabled, and SSH is switched on

`adbd` binds its *own* gadget to the first free UDC. With this installed there
would be two gadgets racing for one controller, so the last thing
`provision/95-usb-gadget.sh` does is hand the port over: `usb/handover.sh`
stops and disables `adbd`, rebuilds the gadget definition, and binds it if a
cable is already in.

`adb shell` is the only way into a factory-fresh board, so the step opens
another door before it closes that one. It enables `ssh`, generating host keys
if the board has none, and it refuses to touch `adbd` unless `sshd` is running.
After the hand-over, the way in is:

```bash
ssh arduino@<hostname>.local
```

That is password login, with the password you set with `sudo arduino-passwd`.
It is reachable from whatever the board is connected to: the cable, and wifi if
that is on.

### Running the step from `adb shell`

`adb shell` is a child of `adbd`, and systemd stops a unit by killing everything
in it. A script that stops `adbd` from inside `adb shell` stops itself. So when
the step sees it was started that way, it does not run the hand-over: it
schedules it with `systemd-run`, 20 seconds out, and says so. The run finishes
printing, the shell closes, and the board comes back on the same cable as a
network adapter and a drive.

```bash
journalctl -t unoq-usb-handover     # what the hand-over did, read over SSH afterwards
```

`UNOQ_HANDOVER_DELAY` changes the 20 seconds.

### Removing the gadget, and going back to adb over USB

Disabling `unoq-usb-gadget` alone is not enough: the udev rule would still
start the bind unit at the next plug-in. This removes everything
`provision/95-usb-gadget.sh` installed. It takes the USB network down at the
first line, so run it over wifi.

```bash
sudo systemctl disable --now unoq-usb-gadget unoq-usb-confirm unoq-uplink-fallback
sudo ~/two-computers-one-board/usb/gadget-down.sh --purge
sudo rm /etc/systemd/system/unoq-usb-gadget.service \
        /etc/systemd/system/unoq-usb-bind.service \
        /etc/systemd/system/unoq-usb-confirm.service \
        /etc/systemd/system/unoq-uplink-fallback.service \
        /etc/udev/rules.d/99-unoq-usb-gadget.rules \
        /etc/modules-load.d/unoq-usb-gadget.conf
sudo systemctl daemon-reload
sudo udevadm control --reload
sudo rm -f /var/lib/unoq/usb-bind-attempts
sudo systemctl enable --now adbd
```

SSH is left on. `sudo systemctl disable --now ssh` turns it off, once adb is
back and you have checked that it works.

Three things are left behind on purpose. `/etc/default/unoq-usb` holds your
settings, and `unoq-leds` reads its LED settings from the same file; delete it
if you want none of them. `/usr/local/lib/unoq/` holds root's copies of the
scripts, and `unoq-link` and `unoq-leds` still run from it: see
[What root runs](provisioning.md#what-root-runs). The `avahi-daemon` and `avahi-autoipd` packages are
harmless without the gadget; `sudo apt-get purge avahi-autoipd` removes the
second, and the first is what publishes `<hostname>.local` on every network,
so you probably want to keep it.

## Troubleshooting

Start here, because it prints everything below in one go:

```bash
~/two-computers-one-board/usb/status.sh
```

Role and power, the UDC, the configuration and its functions, the bridge
and its ports, whether the DHCP client is running and what it was leased, the
nameservers,
the wifi radio, the default routes in priority order, the bind guard's counter,
and the recent log. Read-only, no root.

It matters more than a convenience script normally would. When the board is
powered over the same cable that carries the gadget, every cable change is also
a power cut — you cannot watch a plug-in happen and no session survives one, so
whatever went wrong has always already finished by the time you can look. After
an unexplained reset the evidence is in the **previous** boot:

```bash
journalctl -b -1 -u unoq-usb-bind -t unoq-bind-guard
```

Problems that are not about the USB link are in the general
[troubleshooting page](troubleshooting.md).

**The journal says `REFUSING to bind`, or LED 2 is red.** The bind guard has
given up after three boots that never stayed up. See
[The bind guard](#the-bind-guard) for what that means and the two commands that
clear it.

**Nothing appears on the computer.** Check a UDC exists — if `/sys/class/udc`
is empty the Type-C negotiation did not make the board a device. Try the other
cable orientation, and make sure the cable is a data cable (charge-only USB-C
cables are common and look identical).

```bash
ls /sys/class/udc                 # empty = not a device right now
cat /sys/kernel/config/usb_gadget/unoq/UDC
journalctl -u unoq-usb-gadget -n 40
```

**The network is there but the drive is not, on Windows.** The classic symptom
of the gadget having more than one configuration — see [Why not two
configurations](#why-not-two-configurations). Check:

```bash
ls /sys/kernel/config/usb_gadget/unoq/configs/     # must be exactly c.1
cat /sys/kernel/config/usb_gadget/unoq/bDeviceClass # 0xEF (or 0x00)
~/two-computers-one-board/usb/status.sh            # warns on both
```

On the Windows side, the compatible id list is the proof. `USB\COMPOSITE`
present means the parent driver loaded and each function got its own driver;
absent means it did not, and only one function is visible:

```powershell
Get-PnpDevice -PresentOnly | Where-Object InstanceId -like '*VID_1D6B*' |
  ForEach-Object { Get-PnpDeviceProperty -InstanceId $_.InstanceId `
    -KeyName DEVPKEY_Device_CompatibleIds | Select-Object -ExpandProperty Data }
```

**The drive is there but the network is not.** The host has no driver for the
function the gadget was built with, or NetworkManager grabbed the gadget
interface. `ip -br addr show br-usb` should show one address — leased or
`169.254.x.y` — and `bridge link` should list a `usb*` port. If the host is an
old Windows with no NCM driver, rebuild the gadget with RNDIS: see
[Switching to RNDIS](#switching-to-rndis).

**The internet works but names do not resolve.** `ping 8.8.8.8` answers and
`apt` hangs. The board is routing through a host whose DNS resolver is not
running — the usual shape of a half-configured ICS adapter. This is handled
automatically now: `usb-dhcp.sh` tests the nameserver before writing it down and
switches to public resolvers when it cannot answer. What to check is whether
that happened.

```bash
cat /etc/resolv.conf                        # what is actually being used
journalctl -t unoq-usb-dhcp | grep -i dns   # and why
nslookup example.com 192.168.137.1          # ask the host's resolver yourself
```

A nameserver line pointing at the gateway, with the lookup above timing out,
means the check has not run since the resolver died — kick a renew with
`sudo kill -USR1 "$(cat /run/unoq-usb-udhcpc.pid)"`.

**`<hostname>.local` resolves to something unreachable.** There is more than
one address on `br-usb`; avahi advertises all of them. `usb/status.sh` warns
about this explicitly. It should not happen by design any more — the static
`10.55.0.1` that used to cause it is gone, and link-local is torn down when a
lease arrives.

**Powering the board from the computer.** As a device the board is a power
sink. A laptop USB-C port that only supplies 0.5 A will brown it out under
load — the four cores plus the MCU want considerably more. If the board
reboots when you run a build, power it properly.
