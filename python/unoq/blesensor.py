# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""
The board as a Bluetooth sensor: the BME680's readings, to a phone.

    unoq-ble-sensor                        # read every 10 s, until Ctrl-C
    unoq-ble-sensor --name "Kitchen" --interval 30

Every interval it asks the MCU for `app env` (MCU.env(), the BME680 on the
header's I2C), and serves the answer over Bluetooth Low Energy as the GATT
Environmental Sensing Service, which phones and their apps already know how
to read. nRF Connect, for one, shows the three values in their units with no
setup at all:

    Environmental Sensing   0x181A
      Temperature           0x2A6E   sint16, 0.01 degC
      Humidity              0x2A6F   uint16, 0.01 %
      Pressure              0x2A6D   uint32, 0.1 Pa

Each characteristic can be read, and notifies a phone that subscribes
whenever its value changes. The fourth figure the part gives, the gas
sensor's resistance, has no characteristic in the service and is left out:
it is in `app env` and MCU.env() for anything on the board that wants it.

The other half of the split again, at a bigger scale: the MCU does the timing
and the bus, and Linux does a radio stack, a protocol and a phone.

HOW IT TALKS TO BLUETOOTH
-------------------------
Through BlueZ, the Linux Bluetooth daemon, over the system D-Bus: it exports a
few objects of its own (the service, its characteristics, an advertisement),
asks BlueZ to register them (GattManager1.RegisterApplication,
LEAdvertisingManager1.RegisterAdvertisement), and from then on answers the
calls BlueZ makes back into it when a phone reads or subscribes.

The D-Bus side is jeepney, which is pure Python with no dependencies of its
own, and so the [ble] extra in pyproject.toml rather than a system package:
dbus-python wants a GLib main loop for exporting objects, and both are C
extensions that the project's venv, built without system site packages,
cannot see. jeepney builds messages and parses them; the loop here is a plain
receive with a timeout, so the whole program is one thread.

No pairing, no bonding, no encryption: anything in range can read the values,
as with any shop-bought BLE thermometer. Nothing can be written.

The settings come from the environment, or the flags: UNOQ_BLE_SENSOR_NAME,
UNOQ_BLE_SENSOR_INTERVAL and UNOQ_BLE_SENSOR_ADAPTER. The unit reads them from
/etc/unoq/ble-sensor.env if that file exists.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from time import monotonic as _monotonic
from typing import Any, Protocol

from jeepney import (
    DBusAddress,
    HeaderFields,
    Message,
    MessageType,
    new_error,
    new_method_call,
    new_method_return,
    new_signal,
)
from jeepney.io.blocking import open_dbus_connection

from .mcu import MCU, PORT, EnvError, EnvReading, MCUError

DEFAULT_NAME = "UNO Q"
DEFAULT_INTERVAL = 10.0
DEFAULT_ADAPTER = "hci0"
# The advertisement is a legacy one, 31 bytes. BlueZ puts the flags (3) and the
# service's UUID (4) in it; the name takes 2 more than its length. Twenty
# leaves room for the TX power if BlueZ adds that too.
NAME_MAX_BYTES = 20
# How long a call to BlueZ may take. Registering is quick; this only stops a
# BlueZ that is not answering from hanging the start for ever.
CALL_TIMEOUT = 10.0

BLUEZ = "org.bluez"
OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
PROPERTIES = "org.freedesktop.DBus.Properties"
GATT_SERVICE = "org.bluez.GattService1"
GATT_CHARACTERISTIC = "org.bluez.GattCharacteristic1"
ADVERTISEMENT = "org.bluez.LEAdvertisement1"

# The objects this exports. BlueZ finds the service and its characteristics
# by asking the application's root for GetManagedObjects.
APP_PATH = "/org/unoq/blesensor"
SERVICE_PATH = APP_PATH + "/service0"
ADVERT_PATH = APP_PATH + "/advertisement0"


def uuid16(short: int) -> str:
    """A Bluetooth SIG 16-bit UUID in the 128-bit form BlueZ is given."""
    return f"{short:08x}-0000-1000-8000-00805f9b34fb"


ESS = 0x181A
TEMPERATURE = 0x2A6E
HUMIDITY = 0x2A6F
PRESSURE = 0x2A6D


# --- the encodings ----------------------------------------------------------
#
# The GATT Specification Supplement's formats for the three characteristics,
# little-endian like everything else in Bluetooth. Each takes the integers the
# firmware sends (EnvReading) and refuses a value the format cannot hold rather
# than wrapping it: a wrapped temperature is a plausible wrong number.


def _round_div(n: int, d: int) -> int:
    """n / d to the nearest integer, halves away from zero, in integers."""
    q, r = divmod(abs(n), d)
    q += 2 * r >= d
    return q if n >= 0 else -q


def encode_temperature(temp_mc: int) -> bytes:
    """Temperature (0x2A6E): sint16 in hundredths of a degree Celsius.

    The floor is absolute zero, -273.15; -32768 (0x8000) is the format's own
    "value is not known", so it is never sent as a reading.
    """
    hundredths = _round_div(temp_mc, 10)
    if not -27315 <= hundredths <= 32767:
        raise ValueError(f"{temp_mc} m°C does not fit Temperature (-273.15..327.67 °C)")
    return hundredths.to_bytes(2, "little", signed=True)


def encode_humidity(humidity_mpct: int) -> bytes:
    """Humidity (0x2A6F): uint16 in hundredths of a percent, 0..100 %."""
    hundredths = _round_div(humidity_mpct, 10)
    if not 0 <= hundredths <= 10000:
        raise ValueError(f"{humidity_mpct} m% does not fit Humidity (0..100 %)")
    return hundredths.to_bytes(2, "little")


def encode_pressure(pressure_pa: int) -> bytes:
    """Pressure (0x2A6D): uint32 in tenths of a pascal."""
    tenths = pressure_pa * 10
    if not 0 <= tenths <= 0xFFFFFFFF:
        raise ValueError(f"{pressure_pa} Pa does not fit Pressure (uint32 of 0.1 Pa)")
    return tenths.to_bytes(4, "little")


@dataclass(frozen=True)
class Characteristic:
    name: str
    short: int
    encode: Callable[[EnvReading], bytes]

    @property
    def path(self) -> str:
        return f"{SERVICE_PATH}/{self.name}"


CHARACTERISTICS = (
    Characteristic("temperature", TEMPERATURE, lambda r: encode_temperature(r.temp_mc)),
    Characteristic("humidity", HUMIDITY, lambda r: encode_humidity(r.humidity_mpct)),
    Characteristic("pressure", PRESSURE, lambda r: encode_pressure(r.pressure_pa)),
)


# --- the D-Bus side -----------------------------------------------------------


class BleError(RuntimeError):
    """BlueZ refused something this needs, or did not answer."""


# serve() needs this much of jeepney's blocking connection, and the tests give
# it a fake with the same three members.
class Bus(Protocol):
    outgoing_serial: Iterator[int]

    def send(self, message: Message, serial: int | None = None) -> None: ...

    def receive(self, *, timeout: float | None = None) -> Message: ...


Variant = tuple[str, Any]


@dataclass
class Server:
    """The objects this exports, and the latest reading they serve."""

    name: str
    reading: EnvReading | None = None
    # Why there is no reading, for a phone that asks. Never empty while
    # reading is None.
    missing: str = "no reading from the BME680 yet"
    notifying: set[str] = field(default_factory=set)
    # What each characteristic last notified, so an unchanged value is not
    # sent again.
    sent: dict[str, bytes] = field(default_factory=dict)

    def managed_objects(self) -> dict[str, dict[str, dict[str, Variant]]]:
        objects: dict[str, dict[str, dict[str, Variant]]] = {
            SERVICE_PATH: {GATT_SERVICE: {"UUID": ("s", uuid16(ESS)), "Primary": ("b", True)}}
        }
        for c in CHARACTERISTICS:
            objects[c.path] = {
                GATT_CHARACTERISTIC: {
                    "UUID": ("s", uuid16(c.short)),
                    "Service": ("o", SERVICE_PATH),
                    "Flags": ("as", ["read", "notify"]),
                }
            }
        return objects

    def advertisement(self) -> dict[str, Variant]:
        return {
            "Type": ("s", "peripheral"),
            "ServiceUUIDs": ("as", [f"{ESS:04x}"]),
            "LocalName": ("s", self.name),
        }

    def properties(self, path: str, interface: str) -> dict[str, Variant] | None:
        """The properties of one of these objects, or None if it has no such interface."""
        if path == ADVERT_PATH and interface == ADVERTISEMENT:
            return self.advertisement()
        return self.managed_objects().get(path, {}).get(interface)

    def value(self, c: Characteristic) -> bytes | None:
        return None if self.reading is None else c.encode(self.reading)

    def handle(self, bus: Bus, msg: Message) -> None:
        """Answer one message BlueZ sent. Anything but a method call is ignored."""
        if msg.header.message_type is not MessageType.method_call:
            return
        fields = msg.header.fields
        path = fields.get(HeaderFields.path)
        interface = fields.get(HeaderFields.interface)
        member = fields.get(HeaderFields.member)
        by_path = {c.path: c for c in CHARACTERISTICS}

        if (path, interface, member) == (APP_PATH, OBJECT_MANAGER, "GetManagedObjects"):
            bus.send(new_method_return(msg, "a{oa{sa{sv}}}", (self.managed_objects(),)))
        elif interface == PROPERTIES and member in ("GetAll", "Get"):
            self._properties(bus, msg, path, member)
        elif interface == GATT_CHARACTERISTIC and path in by_path:
            self._characteristic(bus, msg, by_path[path], member)
        elif (path, interface, member) == (ADVERT_PATH, ADVERTISEMENT, "Release"):
            # BlueZ is done with the advertisement: the adapter went away.
            print("BlueZ released the advertisement", flush=True)
            bus.send(new_method_return(msg))
        else:
            bus.send(
                new_error(
                    msg,
                    "org.freedesktop.DBus.Error.UnknownMethod",
                    "s",
                    (f"no {interface}.{member} on {path}",),
                )
            )

    def _properties(self, bus: Bus, msg: Message, path: str, member: str) -> None:
        interface = msg.body[0]
        props = self.properties(path, interface)
        if props is None:
            bus.send(
                new_error(
                    msg,
                    "org.freedesktop.DBus.Error.UnknownInterface",
                    "s",
                    (f"no {interface} on {path}",),
                )
            )
        elif member == "GetAll":
            bus.send(new_method_return(msg, "a{sv}", (props,)))
        elif msg.body[1] in props:
            bus.send(new_method_return(msg, "v", (props[msg.body[1]],)))
        else:
            bus.send(
                new_error(
                    msg,
                    "org.freedesktop.DBus.Error.UnknownProperty",
                    "s",
                    (f"no {msg.body[1]} in {interface}",),
                )
            )

    def _characteristic(self, bus: Bus, msg: Message, c: Characteristic, member: str) -> None:
        if member == "ReadValue":
            value = self.value(c)
            offset = msg.body[0].get("offset", ("q", 0))[1] if msg.body else 0
            if value is None:
                bus.send(new_error(msg, "org.bluez.Error.Failed", "s", (self.missing,)))
            elif offset > len(value):
                bus.send(new_error(msg, "org.bluez.Error.InvalidOffset", "s", (str(offset),)))
            else:
                bus.send(new_method_return(msg, "ay", (value[offset:],)))
        elif member == "StartNotify":
            self.notifying.add(c.path)
            self.sent.pop(c.path, None)
            bus.send(new_method_return(msg))
            # The value now, so a phone that subscribes sees one at once
            # rather than waiting for the next change.
            self.notify(bus)
        elif member == "StopNotify":
            self.notifying.discard(c.path)
            bus.send(new_method_return(msg))
        else:
            bus.send(
                new_error(
                    msg,
                    "org.bluez.Error.NotSupported",
                    "s",
                    (f"{member} is not supported: the values are read-only",),
                )
            )

    def notify(self, bus: Bus) -> None:
        """Send each subscribed characteristic's value, if it changed."""
        for c in CHARACTERISTICS:
            value = self.value(c)
            if c.path not in self.notifying or value is None or self.sent.get(c.path) == value:
                continue
            emitter = DBusAddress(c.path, interface=PROPERTIES)
            bus.send(
                new_signal(
                    emitter,
                    "PropertiesChanged",
                    "sa{sv}as",
                    (GATT_CHARACTERISTIC, {"Value": ("ay", value)}, []),
                )
            )
            self.sent[c.path] = value

    def update(self, bus: Bus, read: Callable[[], EnvReading]) -> None:
        """Take a reading, say in the journal when it starts or stops coming, and notify.

        No sensor, or a failed read, is not the end: the service stays up and
        a phone that reads is told why there is nothing. Any other MCUError -
        a firmware without `app env`, an MCU that does not answer - is raised.
        """
        try:
            got = read()
            # Encoded once here, so a reading no characteristic can carry is
            # caught as one, not on a phone's read.
            for c in CHARACTERISTICS:
                c.encode(got)
        except (EnvError, ValueError) as err:
            if str(err) != self.missing:
                print(f"no reading: {err}", flush=True)
            self.reading, self.missing = None, str(err)
        else:
            if self.reading is None:
                print(f"reading: {describe(got)}", flush=True)
            self.reading, self.missing = got, ""
        self.notify(bus)


def describe(r: EnvReading) -> str:
    return (
        f"{r.temp_c:.2f} °C, {r.humidity_pct:.2f} %RH, {r.pressure_hpa:.2f} hPa, gas {r.gas_ohm} Ω"
    )


def call(
    bus: Bus,
    server: Server,
    path: str,
    interface: str,
    method: str,
    signature: str,
    body: tuple[Any, ...],
) -> tuple[Any, ...]:
    """Call BlueZ and wait for the answer, answering BlueZ meanwhile.

    BlueZ does not reply to RegisterApplication until it has read the
    application with GetManagedObjects, so a wait that only listened for the
    reply would never get one. Everything else that arrives is handled.
    """
    msg = new_method_call(DBusAddress(path, BLUEZ, interface), method, signature, body)
    serial = next(bus.outgoing_serial)
    bus.send(msg, serial=serial)
    while True:
        try:
            reply = bus.receive(timeout=CALL_TIMEOUT)
        except TimeoutError:
            raise BleError(f"{interface}.{method}: BlueZ did not answer") from None
        if reply.header.fields.get(HeaderFields.reply_serial) != serial:
            server.handle(bus, reply)
        elif reply.header.message_type is MessageType.error:
            name = reply.header.fields.get(HeaderFields.error_name)
            said = f": {reply.body[0]}" if reply.body else ""
            raise BleError(f"{interface}.{method}: {name}{said}")
        else:
            return tuple(reply.body)


def serve(
    bus: Bus,
    read: Callable[[], EnvReading],
    name: str = DEFAULT_NAME,
    interval: float = DEFAULT_INTERVAL,
    adapter: str = DEFAULT_ADAPTER,
    count: int | None = None,
    clock: Callable[[], float] = _monotonic,
) -> Server:
    """Power the adapter, register the service and the advertisement, and serve.

    Reads `count` times, or for ever if count is None, `interval` seconds
    apart, answering BlueZ in between.
    """
    server = Server(name)
    adapter_path = f"/org/bluez/{adapter}"
    call(
        bus,
        server,
        adapter_path,
        PROPERTIES,
        "Set",
        "ssv",
        ("org.bluez.Adapter1", "Powered", ("b", True)),
    )
    for interface, method, path in (
        ("org.bluez.GattManager1", "RegisterApplication", APP_PATH),
        ("org.bluez.LEAdvertisingManager1", "RegisterAdvertisement", ADVERT_PATH),
    ):
        call(bus, server, adapter_path, interface, method, "oa{sv}", (path, {}))
    print(f"advertising as {name!r} on {adapter}: Environmental Sensing (0x181A)", flush=True)

    reads = 0
    while True:
        server.update(bus, read)
        reads += 1
        if count is not None and reads >= count:
            return server
        deadline = clock() + interval
        while (left := deadline - clock()) > 0:
            try:
                msg = bus.receive(timeout=left)
            except TimeoutError:
                break
            server.handle(bus, msg)


# --- the command ----------------------------------------------------------------


def _env_interval() -> float:
    raw = os.environ.get("UNOQ_BLE_SENSOR_INTERVAL", "")
    if not raw:
        return DEFAULT_INTERVAL
    try:
        return float(raw)
    except ValueError:
        raise SystemExit(
            f"unoq-ble-sensor: UNOQ_BLE_SENSOR_INTERVAL={raw!r} is not a number of seconds"
        ) from None


def connect() -> Bus:
    """The system bus, where BlueZ is."""
    bus: Bus = open_dbus_connection(bus="SYSTEM")
    return bus


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="unoq-ble-sensor",
        description="Serve the BME680's readings over Bluetooth LE (Environmental Sensing).",
    )
    parser.add_argument(
        "--name",
        default=os.environ.get("UNOQ_BLE_SENSOR_NAME") or DEFAULT_NAME,
        help=f"the name a phone sees, up to {NAME_MAX_BYTES} bytes (UNOQ_BLE_SENSOR_NAME)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=_env_interval(),
        help="seconds between readings (UNOQ_BLE_SENSOR_INTERVAL)",
    )
    parser.add_argument(
        "--adapter",
        default=os.environ.get("UNOQ_BLE_SENSOR_ADAPTER") or DEFAULT_ADAPTER,
        help="the Bluetooth adapter (UNOQ_BLE_SENSOR_ADAPTER)",
    )
    parser.add_argument("--count", type=int, default=None, help="stop after N readings")
    parser.add_argument("--port", default=PORT, help="serial port to the MCU")
    args = parser.parse_args(argv)
    if not args.interval > 0:
        parser.error("--interval has to be more than 0")
    if not 0 < len(args.name.encode()) <= NAME_MAX_BYTES:
        parser.error(f"--name has to be 1 to {NAME_MAX_BYTES} bytes, to fit the advertisement")
    if not args.adapter.isidentifier():
        parser.error(f"--adapter {args.adapter!r} is not an adapter name like hci0")

    try:
        with MCU(port=args.port) as mcu:
            bus = connect()
            serve(bus, mcu.env, args.name, args.interval, args.adapter, args.count)
    except KeyboardInterrupt:
        # Ctrl-C, and SIGINT from systemd. Closing the connection is what
        # takes the service and the advertisement down: BlueZ drops what a
        # client registered when the client goes.
        return 0
    except (MCUError, BleError, OSError) as err:
        # An MCUError here is not "no sensor" - that keeps serving - but a
        # firmware without `app env`, which says how to update it, or an MCU
        # that stopped answering. OSError is no system bus, or the port.
        print(f"unoq-ble-sensor: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
