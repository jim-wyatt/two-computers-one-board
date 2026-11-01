# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""unoq-ble-sensor: the BME680's readings as the GATT Environmental Sensing Service.

There is no Bluetooth here and no D-Bus: BlueZ is a fake that hands the code
the messages bluetoothd would send, built with jeepney itself, and every
message the code sends is serialized, so a body that does not match its
signature fails here rather than on the bus. What is pinned: the bytes of each
characteristic, to the GATT Specification Supplement's formats; the calls
that register the service and the advertisement, answered while they wait;
the answers to a phone's reads and subscriptions; and that no sensor is a
service with nothing to say rather than a dead one.

What this cannot show: that BlueZ accepts the objects, that the adapter
advertises, or that a phone sees anything. That is the board's job, with the
part fitted.
"""

from __future__ import annotations

import itertools
from collections import deque
from collections.abc import Callable, Iterator
from typing import Any, ClassVar

import pytest
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
from jeepney.low_level import Parser

from unoq import blesensor
from unoq.blesensor import (
    ADVERT_PATH,
    APP_PATH,
    CHARACTERISTICS,
    SERVICE_PATH,
    BleError,
    Server,
    encode_humidity,
    encode_pressure,
    encode_temperature,
    uuid16,
)
from unoq.mcu import PORT, EnvError, EnvReading, MCUError

ROOM = EnvReading(21530, 45123, 101325, 52345)
TEMP, HUM, PRESS = (c.path for c in CHARACTERISTICS)
BLUEZ_NAME = ":1.7"


# --- the encodings ----------------------------------------------------------


def test_the_uuids_are_the_sigs_16_bit_ones_in_long_form() -> None:
    assert uuid16(0x181A) == "0000181a-0000-1000-8000-00805f9b34fb"
    assert [c.short for c in CHARACTERISTICS] == [0x2A6E, 0x2A6F, 0x2A6D]


@pytest.mark.parametrize(
    ("temp_mc", "raw"),
    [
        (21530, 2153),
        (0, 0),
        (-500, -50),
        (21534, 2153),
        (21535, 2154),  # halves away from zero
        (-21535, -2154),
        (-21534, -2153),
        (-273150, -27315),  # absolute zero is the floor
        (327670, 32767),
    ],
)
def test_temperature_is_a_little_endian_sint16_of_hundredths(temp_mc: int, raw: int) -> None:
    assert encode_temperature(temp_mc) == raw.to_bytes(2, "little", signed=True)


def test_temperature_bytes_for_a_room_spelled_out() -> None:
    # 21.53 degC is 2153 = 0x0869, low byte first.
    assert encode_temperature(21530) == b"\x69\x08"
    assert encode_temperature(-500) == b"\xce\xff"


@pytest.mark.parametrize("temp_mc", [-273160, 327675, -400000, 400000])
def test_a_temperature_the_format_cannot_hold_is_refused(temp_mc: int) -> None:
    # -32768 (0x8000) means "not known" to a reader, and wrapping would
    # send a plausible wrong number: neither may come out of a reading.
    with pytest.raises(ValueError, match="does not fit Temperature"):
        encode_temperature(temp_mc)


@pytest.mark.parametrize(
    ("mpct", "raw"), [(45123, 4512), (45125, 4513), (0, 0), (100000, 10000), (4, 0)]
)
def test_humidity_is_a_little_endian_uint16_of_hundredths(mpct: int, raw: int) -> None:
    assert encode_humidity(mpct) == raw.to_bytes(2, "little")


@pytest.mark.parametrize("mpct", [-5, 100005])
def test_a_humidity_outside_0_to_100_is_refused(mpct: int) -> None:
    with pytest.raises(ValueError, match="does not fit Humidity"):
        encode_humidity(mpct)


def test_pressure_is_a_little_endian_uint32_of_tenths_of_a_pascal() -> None:
    assert encode_pressure(101325) == (1013250).to_bytes(4, "little")
    assert encode_pressure(101325) == b"\x02\x76\x0f\x00"
    assert encode_pressure(0) == b"\x00\x00\x00\x00"
    assert encode_pressure(429496729) == (4294967290).to_bytes(4, "little")


@pytest.mark.parametrize("pa", [-1, 429496730])
def test_a_pressure_a_uint32_cannot_hold_is_refused(pa: int) -> None:
    with pytest.raises(ValueError, match="does not fit Pressure"):
        encode_pressure(pa)


# --- a BlueZ that is a list ---------------------------------------------------


def parse(data: bytes) -> Message:
    p = Parser()
    p.add_data(data)
    msg = p.get_next_message()
    assert msg is not None
    return msg


class FakeBus:
    """jeepney's blocking connection, as far as blesensor uses it.

    `script` is what receive() returns in turn: a Message, an exception to
    raise, or a function of the bus (for a reply, which needs the serial of
    the call it answers). Past the end, receive() times out. Every message
    sent is serialized and parsed back, as the bus would.
    """

    def __init__(self, script: list[Any] | None = None) -> None:
        self.outgoing_serial: Iterator[int] = itertools.count(100)
        self.script: deque[Any] = deque(script or [])
        self.sent: list[Message] = []
        self.calls: list[tuple[Message, int]] = []
        self.timeouts: list[float | None] = []

    def send(self, message: Message, serial: int | None = None) -> None:
        # jeepney's spelling, not ours.
        msg = parse(message.serialise(serial=serial or 1))  # codespell:ignore serialise
        self.sent.append(msg)
        if msg.header.message_type is MessageType.method_call:
            self.calls.append((msg, msg.header.serial))

    def receive(self, *, timeout: float | None = None) -> Message:
        self.timeouts.append(timeout)
        if not self.script:
            raise TimeoutError
        item = self.script.popleft()
        if isinstance(item, BaseException):
            raise item
        if callable(item):
            item = item(self)
        assert isinstance(item, Message)
        return item

    def replies(self) -> list[Message]:
        return [m for m in self.sent if m.header.message_type is not MessageType.method_call]


_serials = itertools.count(1)


def from_bluez(
    path: str, interface: str, member: str, sig: str = "", body: tuple[Any, ...] = ()
) -> Message:
    msg = new_method_call(DBusAddress(path, ":1.99", interface), member, sig or None, body)
    msg.header.serial = next(_serials)
    msg.header.fields[HeaderFields.sender] = BLUEZ_NAME
    return msg


def ok(*body: Any, sig: str | None = None) -> Callable[[FakeBus], Message]:
    """The reply to the last call the code made."""

    def reply(bus: FakeBus) -> Message:
        call, serial = bus.calls[-1]
        call.header.serial = serial
        return new_method_return(call, sig, body)

    return reply


def refused(name: str, *said: str) -> Callable[[FakeBus], Message]:
    def reply(bus: FakeBus) -> Message:
        call, serial = bus.calls[-1]
        call.header.serial = serial
        return new_error(call, name, "s" if said else None, said)

    return reply


def body(msg: Message) -> tuple[Any, ...]:
    return tuple(msg.body)


def error_name(msg: Message) -> str:
    assert msg.header.message_type is MessageType.error
    name: str = msg.header.fields[HeaderFields.error_name]
    return name


def handled(server: Server, msg: Message) -> list[Message]:
    bus = FakeBus()
    server.handle(bus, msg)
    return bus.sent


def read_value(path: str, offset: int | None = None) -> Message:
    options = {} if offset is None else {"offset": ("q", offset)}
    return from_bluez(path, blesensor.GATT_CHARACTERISTIC, "ReadValue", "a{sv}", (options,))


# --- the objects --------------------------------------------------------------


def test_the_application_is_one_primary_service_of_three_read_and_notify_values() -> None:
    (reply,) = handled(
        Server("UNO Q"), from_bluez(APP_PATH, blesensor.OBJECT_MANAGER, "GetManagedObjects")
    )
    assert reply.header.message_type is MessageType.method_return
    assert reply.header.fields[HeaderFields.destination] == BLUEZ_NAME
    (objects,) = body(reply)
    assert objects[SERVICE_PATH] == {
        "org.bluez.GattService1": {
            "UUID": ("s", "0000181a-0000-1000-8000-00805f9b34fb"),
            "Primary": ("b", True),
        }
    }
    for path, short in zip((TEMP, HUM, PRESS), ("2a6e", "2a6f", "2a6d"), strict=True):
        assert objects[path] == {
            "org.bluez.GattCharacteristic1": {
                "UUID": ("s", f"0000{short}-0000-1000-8000-00805f9b34fb"),
                "Service": ("o", SERVICE_PATH),
                "Flags": ("as", ["read", "notify"]),
            }
        }
    assert len(objects) == 4


def test_the_advertisement_names_the_board_and_the_service() -> None:
    msg = from_bluez(ADVERT_PATH, blesensor.PROPERTIES, "GetAll", "s", (blesensor.ADVERTISEMENT,))
    (reply,) = handled(Server("Kitchen"), msg)
    assert body(reply) == (
        {
            "Type": ("s", "peripheral"),
            "ServiceUUIDs": ("as", ["181a"]),
            "LocalName": ("s", "Kitchen"),
        },
    )


def test_get_all_answers_for_a_characteristic_too() -> None:
    msg = from_bluez(TEMP, blesensor.PROPERTIES, "GetAll", "s", (blesensor.GATT_CHARACTERISTIC,))
    (reply,) = handled(Server("x"), msg)
    assert body(reply)[0]["Flags"] == ("as", ["read", "notify"])


def test_get_answers_one_property_and_refuses_one_there_is_not() -> None:
    server = Server("Kitchen")
    msg = from_bluez(
        ADVERT_PATH, blesensor.PROPERTIES, "Get", "ss", (blesensor.ADVERTISEMENT, "LocalName")
    )
    (reply,) = handled(server, msg)
    assert body(reply) == (("s", "Kitchen"),)
    msg = from_bluez(
        ADVERT_PATH, blesensor.PROPERTIES, "Get", "ss", (blesensor.ADVERTISEMENT, "Color")
    )
    (reply,) = handled(server, msg)
    assert error_name(reply) == "org.freedesktop.DBus.Error.UnknownProperty"


@pytest.mark.parametrize(
    ("path", "interface"),
    [(ADVERT_PATH, blesensor.GATT_SERVICE), ("/nowhere", blesensor.ADVERTISEMENT)],
)
def test_properties_of_an_interface_an_object_does_not_have_are_refused(
    path: str, interface: str
) -> None:
    msg = from_bluez(path, blesensor.PROPERTIES, "GetAll", "s", (interface,))
    (reply,) = handled(Server("x"), msg)
    assert error_name(reply) == "org.freedesktop.DBus.Error.UnknownInterface"


@pytest.mark.parametrize(
    ("path", "interface", "member"),
    [
        (ADVERT_PATH, blesensor.OBJECT_MANAGER, "GetManagedObjects"),
        (APP_PATH, "org.example.Nothing", "Frob"),
        ("/elsewhere", blesensor.GATT_CHARACTERISTIC, "ReadValue"),
    ],
)
def test_anything_else_is_an_unknown_method(path: str, interface: str, member: str) -> None:
    (reply,) = handled(Server("x"), from_bluez(path, interface, member))
    assert error_name(reply) == "org.freedesktop.DBus.Error.UnknownMethod"


def test_a_message_that_is_not_a_call_is_left_alone() -> None:
    signal = new_signal(DBusAddress("/org/bluez", interface="org.x"), "Thing")
    assert handled(Server("x"), signal) == []


def test_release_is_acknowledged(capsys: pytest.CaptureFixture[str]) -> None:
    (reply,) = handled(Server("x"), from_bluez(ADVERT_PATH, blesensor.ADVERTISEMENT, "Release"))
    assert reply.header.message_type is MessageType.method_return
    assert "released" in capsys.readouterr().out


# --- what a phone sees ------------------------------------------------------------


def test_a_read_is_the_encoded_value() -> None:
    server = Server("x", reading=ROOM)
    for path, want in zip(
        (TEMP, HUM, PRESS),
        (encode_temperature(21530), encode_humidity(45123), encode_pressure(101325)),
        strict=True,
    ):
        (reply,) = handled(server, read_value(path))
        assert body(reply) == (want,)


def test_a_read_from_an_offset_is_the_rest_of_the_value() -> None:
    server = Server("x", reading=ROOM)
    (reply,) = handled(server, read_value(PRESS, offset=1))
    assert body(reply) == (encode_pressure(101325)[1:],)
    (reply,) = handled(server, read_value(PRESS, offset=4))
    assert body(reply) == (b"",)
    (reply,) = handled(server, read_value(PRESS, offset=5))
    assert error_name(reply) == "org.bluez.Error.InvalidOffset"


def test_a_read_with_no_options_at_all_starts_at_zero() -> None:
    msg = from_bluez(TEMP, blesensor.GATT_CHARACTERISTIC, "ReadValue")
    (reply,) = handled(Server("x", reading=ROOM), msg)
    assert body(reply) == (encode_temperature(21530),)


def test_a_read_with_no_reading_is_a_failure_that_says_why() -> None:
    server = Server("x", reading=None, missing="app env: env_err=-19: no BME680 answered")
    (reply,) = handled(server, read_value(TEMP))
    assert error_name(reply) == "org.bluez.Error.Failed"
    assert body(reply) == ("app env: env_err=-19: no BME680 answered",)


def test_a_write_is_refused() -> None:
    msg = from_bluez(
        TEMP, blesensor.GATT_CHARACTERISTIC, "WriteValue", "aya{sv}", (b"\x00\x00", {})
    )
    (reply,) = handled(Server("x", reading=ROOM), msg)
    assert error_name(reply) == "org.bluez.Error.NotSupported"


def notified(msgs: list[Message]) -> list[tuple[str, bytes]]:
    out = []
    for m in msgs:
        if m.header.message_type is MessageType.signal:
            assert m.header.fields[HeaderFields.member] == "PropertiesChanged"
            assert m.header.fields[HeaderFields.interface] == blesensor.PROPERTIES
            iface, changed, invalidated = m.body
            assert iface == blesensor.GATT_CHARACTERISTIC
            assert invalidated == []
            out.append((m.header.fields[HeaderFields.path], changed["Value"][1]))
    return out


def test_subscribing_sends_the_value_at_once_then_only_changes() -> None:
    server = Server("x", reading=ROOM)
    bus = FakeBus()
    server.handle(bus, from_bluez(TEMP, blesensor.GATT_CHARACTERISTIC, "StartNotify"))
    assert bus.sent[0].header.message_type is MessageType.method_return
    assert notified(bus.sent) == [(TEMP, encode_temperature(21530))]

    bus = FakeBus()
    server.update(bus, lambda: ROOM)
    assert notified(bus.sent) == []

    warmer = ROOM._replace(temp_mc=22000, pressure_pa=101000)
    server.update(bus, lambda: warmer)
    # Pressure changed too, and nobody asked for it.
    assert notified(bus.sent) == [(TEMP, encode_temperature(22000))]


def test_subscribing_again_sends_the_value_again() -> None:
    server = Server("x", reading=ROOM)
    start = from_bluez(HUM, blesensor.GATT_CHARACTERISTIC, "StartNotify")
    handled(server, start)
    assert notified(handled(server, start)) == [(HUM, encode_humidity(45123))]


def test_after_stop_notify_nothing_is_sent() -> None:
    server = Server("x", reading=ROOM)
    handled(server, from_bluez(TEMP, blesensor.GATT_CHARACTERISTIC, "StartNotify"))
    (reply,) = handled(server, from_bluez(TEMP, blesensor.GATT_CHARACTERISTIC, "StopNotify"))
    assert reply.header.message_type is MessageType.method_return
    bus = FakeBus()
    server.update(bus, lambda: ROOM._replace(temp_mc=0))
    assert bus.sent == []


def test_subscribing_with_no_reading_sends_nothing_until_there_is_one() -> None:
    server = Server("x")
    sent = handled(server, from_bluez(PRESS, blesensor.GATT_CHARACTERISTIC, "StartNotify"))
    assert notified(sent) == []
    bus = FakeBus()
    server.update(bus, lambda: ROOM)
    assert notified(bus.sent) == [(PRESS, encode_pressure(101325))]


# --- readings, and none -----------------------------------------------------------


def no_sensor() -> EnvReading:
    raise EnvError(-19)


def test_no_sensor_keeps_serving_and_says_so_once(capsys: pytest.CaptureFixture[str]) -> None:
    server = Server("x")
    bus = FakeBus()
    server.update(bus, no_sensor)
    server.update(bus, no_sensor)
    assert server.reading is None
    assert "no BME680 answered" in server.missing
    assert capsys.readouterr().out.count("no reading:") == 1


def test_a_reading_after_none_is_said_and_served(capsys: pytest.CaptureFixture[str]) -> None:
    server = Server("x")
    bus = FakeBus()
    server.update(bus, no_sensor)
    server.update(bus, lambda: ROOM)
    server.update(bus, lambda: ROOM)
    out = capsys.readouterr().out
    assert out.count("reading: 21.53 °C, 45.12 %RH, 1013.25 hPa, gas 52345 Ω") == 1
    assert server.reading == ROOM
    assert server.missing == ""
    # And losing it again is said again, though the words are the same.
    server.update(bus, no_sensor)
    assert capsys.readouterr().out.count("no reading:") == 1


def test_a_reading_no_characteristic_can_carry_is_no_reading() -> None:
    server = Server("x", reading=ROOM)
    server.update(FakeBus(), lambda: ROOM._replace(temp_mc=400000))
    assert server.reading is None
    assert "does not fit Temperature" in server.missing


def test_an_mcu_error_that_is_not_about_the_sensor_is_raised() -> None:
    def old_firmware() -> EnvReading:
        raise MCUError("this firmware has no `app env` command")

    with pytest.raises(MCUError, match="no `app env`"):
        Server("x").update(FakeBus(), old_firmware)


# --- calls to BlueZ -----------------------------------------------------------------


def test_a_call_waits_for_its_reply_and_answers_bluez_meanwhile() -> None:
    bus = FakeBus(
        [
            from_bluez(APP_PATH, blesensor.OBJECT_MANAGER, "GetManagedObjects"),
            ok("done", sig="s"),
        ]
    )
    got = blesensor.call(bus, Server("x"), "/org/bluez/hci0", "org.bluez.X", "Do", "s", ("a",))
    assert got == ("done",)
    call, serial = bus.calls[0]
    assert serial == 100
    assert call.header.fields[HeaderFields.destination] == "org.bluez"
    assert call.header.fields[HeaderFields.path] == "/org/bluez/hci0"
    # The GetManagedObjects that came first was answered.
    (answer,) = bus.replies()
    assert answer.header.message_type is MessageType.method_return
    assert bus.timeouts == [blesensor.CALL_TIMEOUT] * 2


def test_a_refused_call_is_a_ble_error_with_bluez_s_words() -> None:
    bus = FakeBus([refused("org.bluez.Error.AlreadyExists", "Already Exists")])
    with pytest.raises(BleError, match=r"X\.Do: org\.bluez\.Error\.AlreadyExists: Already Exists"):
        blesensor.call(bus, Server("x"), "/org/bluez/hci0", "org.bluez.X", "Do", "", ())


def test_a_refusal_without_words_is_still_named() -> None:
    bus = FakeBus([refused("org.bluez.Error.Failed")])
    with pytest.raises(BleError, match=r"X\.Do: org\.bluez\.Error\.Failed$"):
        blesensor.call(bus, Server("x"), "/org/bluez/hci0", "org.bluez.X", "Do", "", ())


def test_a_bluez_that_does_not_answer_is_a_ble_error() -> None:
    with pytest.raises(BleError, match="did not answer"):
        blesensor.call(FakeBus(), Server("x"), "/org/bluez/hci0", "org.bluez.X", "Do", "", ())


# --- serve ------------------------------------------------------------------------


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def registered() -> list[Any]:
    """What BlueZ says to the three calls serve() starts with."""
    return [
        ok(),
        from_bluez(APP_PATH, blesensor.OBJECT_MANAGER, "GetManagedObjects"),
        ok(),
        from_bluez(ADVERT_PATH, blesensor.PROPERTIES, "GetAll", "s", (blesensor.ADVERTISEMENT,)),
        ok(),
    ]


def test_serve_powers_the_adapter_and_registers_both(capsys: pytest.CaptureFixture[str]) -> None:
    bus = FakeBus(registered())
    server = blesensor.serve(bus, lambda: ROOM, name="Kitchen", adapter="hci1", count=1)
    calls = [
        (
            m.header.fields[HeaderFields.path],
            m.header.fields[HeaderFields.interface],
            m.header.fields[HeaderFields.member],
            body(m),
        )
        for m, _ in bus.calls
    ]
    assert calls == [
        (
            "/org/bluez/hci1",
            "org.freedesktop.DBus.Properties",
            "Set",
            ("org.bluez.Adapter1", "Powered", ("b", True)),
        ),
        ("/org/bluez/hci1", "org.bluez.GattManager1", "RegisterApplication", (APP_PATH, {})),
        (
            "/org/bluez/hci1",
            "org.bluez.LEAdvertisingManager1",
            "RegisterAdvertisement",
            (ADVERT_PATH, {}),
        ),
    ]
    assert server.reading == ROOM
    assert "advertising as 'Kitchen' on hci1" in capsys.readouterr().out


def test_serve_answers_between_readings_until_the_interval_is_up() -> None:
    clock = Clock()

    def tick(msg: Message) -> Callable[[FakeBus], Message]:
        def step(bus: FakeBus) -> Message:
            clock.now += 4
            return msg

        return step

    reads: list[float] = []

    def read() -> EnvReading:
        reads.append(clock.now)
        return ROOM

    bus = FakeBus(
        [
            *registered(),
            tick(read_value(TEMP)),
            tick(read_value(HUM)),
            tick(read_value(PRESS)),  # 12 s in: past the interval, so the read is next
            TimeoutError(),  # the second wait: nothing comes
        ]
    )
    blesensor.serve(bus, read, interval=10, count=3, clock=clock)
    assert reads == [0, 12, 12]
    values = [body(m) for m in bus.replies() if m.header.message_type is MessageType.method_return]
    assert (encode_pressure(101325),) in values
    # Each wait asks for what is left of the interval, no more.
    assert bus.timeouts[-4:] == [10, 6, 2, 10]


def test_serve_stops_at_a_refusal() -> None:
    bus = FakeBus([ok(), refused("org.bluez.Error.Failed", "Failed to register application")])
    with pytest.raises(BleError, match="RegisterApplication"):
        blesensor.serve(bus, lambda: ROOM, count=1)


# --- main ---------------------------------------------------------------------------


class FakeMCU:
    opened: ClassVar[list[str]] = []

    def __init__(self, port: str) -> None:
        FakeMCU.opened.append(port)

    def __enter__(self) -> FakeMCU:
        return self

    def __exit__(self, *exc: object) -> None:
        pass

    def env(self) -> EnvReading:
        return ROOM


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """main() with the MCU and the bus faked, and serve() recorded."""
    seen: dict[str, Any] = {}
    FakeMCU.opened = []
    monkeypatch.setattr(blesensor, "MCU", FakeMCU)
    bus = FakeBus()
    monkeypatch.setattr(blesensor, "connect", lambda: bus)

    def serve(
        b: Any, read: Any, name: str, interval: float, adapter: str, count: int | None
    ) -> Server:
        seen.update(bus=b, read=read(), name=name, interval=interval, adapter=adapter, count=count)
        if "raise" in seen:
            raise seen["raise"]
        return Server(name)

    monkeypatch.setattr(blesensor, "serve", serve)
    for var in ("UNOQ_BLE_SENSOR_NAME", "UNOQ_BLE_SENSOR_INTERVAL", "UNOQ_BLE_SENSOR_ADAPTER"):
        monkeypatch.delenv(var, raising=False)
    seen["bus_made"] = bus
    return seen


def test_main_serves_with_the_defaults(wired: dict[str, Any]) -> None:
    assert blesensor.main([]) == 0
    assert wired["bus"] is wired["bus_made"]
    assert wired["read"] == ROOM
    assert (wired["name"], wired["interval"], wired["adapter"], wired["count"]) == (
        "UNO Q",
        10.0,
        "hci0",
        None,
    )
    assert FakeMCU.opened == [PORT]


def test_main_takes_its_settings_from_the_environment(
    wired: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("UNOQ_BLE_SENSOR_NAME", "Kitchen")
    monkeypatch.setenv("UNOQ_BLE_SENSOR_INTERVAL", "30")
    monkeypatch.setenv("UNOQ_BLE_SENSOR_ADAPTER", "hci1")
    assert blesensor.main(["--count", "2", "--port", "/dev/null"]) == 0
    assert (wired["name"], wired["interval"], wired["adapter"], wired["count"]) == (
        "Kitchen",
        30.0,
        "hci1",
        2,
    )
    assert FakeMCU.opened == ["/dev/null"]


def test_a_flag_beats_the_environment(
    wired: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("UNOQ_BLE_SENSOR_NAME", "Kitchen")
    assert blesensor.main(["--name", "Hall"]) == 0
    assert wired["name"] == "Hall"


def test_an_interval_in_the_environment_that_is_not_a_number_stops_it(
    wired: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("UNOQ_BLE_SENSOR_INTERVAL", "soon")
    with pytest.raises(SystemExit, match="UNOQ_BLE_SENSOR_INTERVAL='soon'"):
        blesensor.main([])


@pytest.mark.parametrize(
    ("argv", "said"),
    [
        (["--interval", "0"], "--interval has to be more than 0"),
        (["--name", ""], "--name has to be 1 to 20 bytes"),
        (["--name", "x" * 21], "--name has to be 1 to 20 bytes"),
        (["--name", "é" * 11], "--name has to be 1 to 20 bytes"),  # 22 bytes
        (["--adapter", "../hci0"], "is not an adapter name"),
    ],
)
def test_main_refuses_settings_that_cannot_work(
    wired: dict[str, Any], capsys: pytest.CaptureFixture[str], argv: list[str], said: str
) -> None:
    with pytest.raises(SystemExit) as caught:
        blesensor.main(argv)
    assert caught.value.code == 2
    assert said in capsys.readouterr().err
    assert "name" not in wired


def test_ctrl_c_is_a_clean_stop(wired: dict[str, Any]) -> None:
    wired["raise"] = KeyboardInterrupt()
    assert blesensor.main([]) == 0


@pytest.mark.parametrize(
    "err",
    [
        BleError("org.bluez.GattManager1.RegisterApplication: org.bluez.Error.Failed"),
        MCUError("this firmware has no `app env` command"),
        FileNotFoundError(2, "No such file or directory", "/run/dbus/system_bus_socket"),
    ],
)
def test_a_failure_is_one_line_and_exit_1(
    wired: dict[str, Any], capsys: pytest.CaptureFixture[str], err: Exception
) -> None:
    wired["raise"] = err
    assert blesensor.main([]) == 1
    assert capsys.readouterr().err == f"unoq-ble-sensor: {err}\n"


def test_connect_opens_the_system_bus(monkeypatch: pytest.MonkeyPatch) -> None:
    asked: list[str] = []
    fake = FakeBus()

    def open_dbus_connection(bus: str) -> FakeBus:
        asked.append(bus)
        return fake

    monkeypatch.setattr(blesensor, "open_dbus_connection", open_dbus_connection)
    assert blesensor.connect() is fake
    assert asked == ["SYSTEM"]
