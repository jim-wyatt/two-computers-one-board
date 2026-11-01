#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The whole USB gadget picture, in one command.
#
#   ~/two-computers-one-board/usb/status.sh
#
# WHY THIS EXISTS
# ---------------
# This board is normally powered over the same cable that carries the gadget,
# so every cable change is also a power cut. You cannot watch a plug-in happen
# and you cannot keep a session open across one: whatever went wrong has always
# already finished by the time you can look. The post-mortem is the only view
# there is, so it is worth having it be one command that always prints the same
# things in the same order, rather than eight remembered ones.
#
# Everything here is read-only. It changes nothing and needs no root.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
G="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"

hdr() { printf '\n== %s ==\n' "$*"; }
val() { printf '  %-22s %s\n' "$1" "${2:-<none>}"; }

hdr "role and power"
# The Type-C controller picks host vs device from the CC lines; software cannot
# override it. data_role is therefore the first thing to check, because in host
# mode there is no UDC and nothing else here can possibly work.
for f in data_role power_role power_operation_mode orientation; do
  [ -f "/sys/class/typec/port0/$f" ] &&
    val "$f" "$(cat "/sys/class/typec/port0/$f" 2>/dev/null)"
done
case "$(cat /sys/class/typec/port0/power_operation_mode 2>/dev/null)" in
  default)
    echo "  NOTE: 'default' means USB default current, no PD contract - not much"
    echo "        for four cores plus an MCU. Binding re-enumerates the port and"
    echo "        can brown the board out from here. Prefer a self-powered hub."
    ;;
esac

hdr "controller"
udc=""
for u in /sys/class/udc/*; do
  [ -e "$u" ] || continue
  udc="$udc $(basename "$u")"
done
udc="${udc# }"
val "UDC present" "${udc:-<none - board is not a device right now>}"
val "gadget bound to" "$(cat "$G/UDC" 2>/dev/null)"

hdr "gadget definition"
if [ -d "$G" ]; then
  nconfigs=0
  for c in "$G"/configs/*/; do
    [ -d "$c" ] || continue
    nconfigs=$((nconfigs + 1))
    fns=""
    for l in "$c"*; do
      [ -L "$l" ] && fns="$fns $(basename "$l")"
    done
    val "$(basename "$c")" "${fns# }"
  done
  val "drive backing file" "$(cat "$G/functions/mass_storage.0/lun.0/file" 2>/dev/null)"
  # There must be exactly one configuration. Windows only treats a device as
  # composite - and so only loads the parent driver that gives mass storage its
  # own driver - when the device has a SINGLE configuration. With two, the drive
  # is not hidden or unmountable, it is never enumerated, while the network goes
  # on working perfectly. That is a silent, one-sided failure nobody would think
  # to look for here, which is exactly why it is worth a line of output.
  if [ "$nconfigs" -gt 1 ]; then
    val "WARNING" "$nconfigs configurations - Windows will not show the drive"
  fi
  # Lowercased before matching: configfs echoes this back as 0xef whatever case
  # it was written in, so a literal 0xEF comparison warns on a correct gadget.
  devclass="$(tr 'A-F' 'a-f' <"$G/bDeviceClass" 2>/dev/null)"
  case "$devclass" in
    0xef | 0x00) ;;
    *) val "WARNING" "bDeviceClass $devclass is neither 0xEF nor 0x00 - not composite to Windows" ;;
  esac
else
  val "definition" "<not built - is unoq-usb-gadget.service running?>"
fi

hdr "network"
val "$BRIDGE" "$(ip -br addr show "$BRIDGE" 2>/dev/null | tr -s ' ' || echo '<not created>')"
ports=""
for i in /sys/class/net/*/master; do
  [ -e "$i" ] || continue
  [ "$(basename "$(readlink -f "$i")")" = "$BRIDGE" ] &&
    ports="$ports $(basename "$(dirname "$i")")"
done
val "bridge ports" "${ports# }"
# Liveness from /proc, not `kill -0`: this script is meant to run without root,
# and kill -0 against a root-owned daemon fails with EPERM for a normal user.
# shellcheck source=usb/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if is_udhcpc /run/unoq-usb-udhcpc.pid; then
  val "dhcp" "udhcpc is asking the host for an address"
  val "leased address" "$(awk '{print $1}' /run/unoq-usb-dhcp.state 2>/dev/null)"
  val "gateway" "$(awk '{print $2}' /run/unoq-usb-dhcp.state 2>/dev/null)"
else
  val "dhcp" "<udhcpc is not running>"
fi
# The host profile, when DHCP gave up but the computer on the other end was
# recognized anyway. Worth a line of its own because the address on the bridge
# then looks exactly like a leased one - same subnet, same gateway - and the
# difference matters when something goes wrong: this address was claimed by the
# board, not handed to it, so the host has no idea it exists.
if [ -r /run/unoq-usb-profile.state ]; then
  val "host profile" "$(awk '{print $1" ("$2" via "$3")"}' /run/unoq-usb-profile.state 2>/dev/null)"
  val "" "self-assigned - the host is NAT-ing but not serving DHCP"
fi
# Link-local is not a fault, it is the documented answer to "no DHCP server on
# the other end". It IS worth saying out loud, because it is also the state
# where the board is reachable from that one computer and from nowhere else.
AUTOIPD="${UNOQ_AUTOIPD:-/usr/sbin/avahi-autoipd}"
if [ -x "$AUTOIPD" ] && "$AUTOIPD" --check "$BRIDGE" 2>/dev/null; then
  val "link-local" "active - no DHCP server on the other end"
fi
# Which default route the USB link actually holds, and therefore whether it is
# carrying traffic or just sitting there. 550 means usb-route.sh proved the
# internet answers through the cable and promoted it ahead of wifi; 700 means it
# is the fallback of last resort it has always been.
usb_default="$(ip -4 route show default dev "$BRIDGE" 2>/dev/null | head -1)"
case "$usb_default" in
  *"metric ${UNOQ_USB_ROUTE_METRIC_PREFERRED:-550}"*)
    val "default route" "$usb_default"
    val "" "promoted ahead of wifi - the cable is carrying this board's traffic"
    ;;
  *metric*)
    val "default route" "$usb_default"
    val "" "fallback only - a real uplink still wins"
    ;;
esac
val "reachable as" "$(hostname).local"
# Exactly one address, and that is load-bearing rather than tidy: avahi
# advertises every address an interface has, so a second one makes
# <hostname>.local resolve to two A records with the host free to pick the one
# it cannot route to. That was the old static 10.55.0.1, and the reason the name
# could not be trusted.
naddr="$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | wc -l)"
if [ "$naddr" -gt 1 ]; then
  val "WARNING" "$naddr addresses on $BRIDGE - $(hostname).local will be a coin flip"
fi
val "nameservers" "$(sed -n 's/^nameserver //p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
val "wifi radio" "$(nmcli radio wifi 2>/dev/null)"

hdr "default routes (lowest metric wins)"
# The gadget route must LOSE to any real uplink. If the br-usb route is top of
# this list and the host is not NAT-ing, the board has no internet and the
# symptom will not look like USB.
ip route show default | sed 's/^/  /' || echo "  <none>"

hdr "bind guard"
"$HERE/bind-guard.sh" status 2>/dev/null | sed 's/^/  /' ||
  val "guard" "<bind-guard.sh not found>"

hdr "what root runs"
# The services do not run the scripts in the checkout. They run root-owned
# copies, which a provisioning step makes (install_runtime, provision/lib.sh),
# so that writing to a home directory is not the same as changing what root
# does at the next boot. The price is that there are two copies, and this is
# where they are compared - because the one you just edited and the one the
# board is running look identical from everywhere else, and a fix that "does
# nothing" is a miserable thing to debug over a cable that is also the power.
RUNTIME="${UNOQ_RUNTIME_DIR:-/usr/local/lib/unoq}"
SRC="$(cd "$HERE/.." && pwd)"
FROM="$(sed -n 's/^UNOQ_CHECKOUT=//p' "$RUNTIME/env" 2>/dev/null | tail -1)"
# Run as root's copy itself, there is no checkout beside this file: compare
# with the one the copies say they came from.
[ "$SRC" -ef "$RUNTIME" ] && SRC="$FROM"
if [ ! -d "$RUNTIME" ]; then
  val "root's copies" "<none at $RUNTIME>"
  echo "  NOTE: nothing has installed them. Either no step that needs them has run,"
  echo "        or this board was provisioned before they existed and its services"
  echo "        still run from the checkout. Re-run the steps, or bootstrap.sh."
elif [ -z "$SRC" ] || [ ! -d "$SRC/usb" ]; then
  val "root's copies" "$RUNTIME"
  val "copied from" "${FROM:-<not recorded>} (not there to compare with)"
else
  val "root's copies" "$RUNTIME"
  val "copied from" "${FROM:-<not recorded>}"
  # WHAT IS COMPARED, AND WHAT COUNTS AS A COPY
  #
  # The set is worked out from the checkout - the same five places
  # runtime_files (provision/lib.sh) names - and each of root's entries then
  # has to be a regular file of its own before its bytes are even looked at.
  #
  # It used to be worked out from root's directory, with `find -type f`, and
  # that is the wrong way round: a script that has been replaced by a symbolic
  # link is not a regular file, so find never listed it, nothing compared it,
  # and the check further down only asked whether the path existed - which a
  # link does. Link usb/usb-dhcp.sh back to the checkout and this section said
  # "same ... yes" about a board where root was once again executing a file in
  # somebody's home directory, the exact thing the copies exist to end. cmp
  # would not have helped either: it follows links, and a file equals itself.
  #
  # So: "same" now means every expected script is there, is a file and not a
  # link, is reached through no link on the way down, has the checkout's
  # bytes - and that nothing else is in the directory.
  differ=""
  notfile=""
  expected="mcu/link-up.sh status/leds.sh"
  for f in "$SRC"/usb/*.sh "$SRC"/net/*.sh "$SRC"/recovery/*.sh; do
    [ -e "$f" ] || continue
    expected="$expected $(basename "$(dirname "$f")")/$(basename "$f")"
  done

  # linked_above <relative path> - true if the directory holding root's copy of
  # it, or root's directory itself, is a symbolic link. usb -> ~/checkout/usb
  # makes every file under it look like a perfectly ordinary copy.
  linked_above() {
    local d
    [ -L "$RUNTIME" ] && return 0
    d="$(dirname "$1")"
    while [ "$d" != . ]; do
      [ -L "$RUNTIME/$d" ] && return 0
      d="$(dirname "$d")"
    done
    return 1
  }

  for rel in $expected; do
    if linked_above "$rel"; then
      notfile="$notfile $rel(reached-through-a-link)"
    elif [ -L "$RUNTIME/$rel" ]; then
      notfile="$notfile $rel(a-link)"
    elif [ ! -e "$RUNTIME/$rel" ]; then
      differ="$differ $rel"
    elif [ ! -f "$RUNTIME/$rel" ]; then
      notfile="$notfile $rel(not-a-file)"
    else
      cmp -s "$RUNTIME/$rel" "$SRC/$rel" || differ="$differ $rel"
    fi
  done
  # And the other direction: whatever root's directory holds that the checkout
  # no longer has. Everything that is not a directory, so a stray link counts.
  while IFS= read -r rel; do
    [ "$rel" = env ] && continue
    case " $expected " in *" $rel "*) continue ;; esac
    differ="$differ $rel"
  done < <(cd "$RUNTIME" && find . -mindepth 1 ! -type d 2>/dev/null | sed 's|^\./||' | sort)

  if [ -z "$differ" ] && [ -z "$notfile" ]; then
    val "same as $SRC" "yes"
  fi
  if [ -n "$notfile" ]; then
    val "NOT ROOT'S OWN FILES" "${notfile# }"
    echo "  NOTE: those are not copies. Root runs whatever each one leads to, which"
    echo "        may be a file anyone can edit - look before trusting this board:"
    echo "          ls -l $RUNTIME $RUNTIME/usb"
    echo "        A provisioning step replaces a linked script with a real copy,"
    echo "        and refuses a linked directory until it has been removed:"
    echo "          sudo bash $SRC/provision/50-status-leds.sh"
  fi
  if [ -n "$differ" ]; then
    val "DIFFERENT from $SRC" "${differ# }"
    echo "  NOTE: root is running the older copy of those. Editing the checkout does"
    echo "        not change what the services run; a provisioning step does, and any"
    echo "        of them refreshes every copy:"
    echo "          sudo bash $SRC/provision/50-status-leds.sh"
  fi
fi

hdr "recent gadget log"
# -b covers this boot; the interesting one after an unexplained reset is
# usually `journalctl -b -1`, which the footer points at.
journalctl -b -u unoq-usb-gadget -u unoq-usb-bind -u unoq-usb-confirm \
  -t unoq-bind-guard -t unoq-usb-route -t unoq-usb-dhcp -n 15 --no-pager -o short 2>/dev/null |
  sed 's/^/  /' || echo "  <no journal access>"

cat <<EOF

If the board reset and you are looking for why, the evidence is in the
PREVIOUS boot, not this one:

  journalctl -b -1 -u unoq-usb-bind -t unoq-bind-guard
  journalctl --list-boots
EOF
