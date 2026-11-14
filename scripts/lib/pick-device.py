#!/usr/bin/env python3
"""Print one paired physical iPhone/iPad as "<coredevice id>\t<udid>\t<name>".

    ./scripts/lib/pick-device.py                 # the only device, or ask which
    ./scripts/lib/pick-device.py <id|udid|name>  # that one, without asking

`devicectl` takes the CoreDevice id, `xctrace` takes the UDID, so both are
printed. A paired device over Wi-Fi reports tunnelState "disconnected" until a
command opens the tunnel, so any paired device is accepted; the menu says which
one is connected, on the network or offline, and lists them in that order.

With more than one device there is no answer to guess — someone is installing
onto a phone they are holding — so the person is asked. The question goes to
stderr and is read from /dev/tty, because the caller ran us inside $(...): its
stdout is data and its stdin may be anything. With no terminal to ask on (a
script, an agent) the list is printed and this exits non-zero rather than
installing onto whichever device came first.
"""

import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass

# `tunnelState`: a USB device is connected; one on Wi-Fi says disconnected until
# a command opens the tunnel, which installing does; unavailable is a paired
# device that is not there right now.
STATE = {"connected": "connected", "disconnected": "on network", "unavailable": "offline"}
RANK = {"connected": 0, "on network": 1, "offline": 2}


@dataclass(frozen=True)
class Device:
    identifier: str
    udid: str
    name: str
    state: str

    @property
    def line(self):
        return f"{self.identifier}\t{self.udid}\t{self.name}"


def die(message):
    sys.stderr.write(f"pick-device: {message}\n")
    raise SystemExit(1)


def paired_devices():
    """Every paired physical device devicectl knows, in devicectl's order."""
    handle, path = tempfile.mkstemp(prefix="lnreader-devices-", suffix=".json")
    os.close(handle)
    try:
        subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        try:
            with open(path) as listed:
                found = json.load(listed)["result"]["devices"]
        except (OSError, ValueError, KeyError):
            return []
    finally:
        os.unlink(path)

    devices = []
    for device in found:
        hardware = device.get("hardwareProperties", {})
        connection = device.get("connectionProperties", {})
        if hardware.get("reality") != "physical" or connection.get("pairingState") != "paired":
            continue
        identifier = device.get("identifier")
        if not identifier:
            continue
        devices.append(Device(
            identifier=identifier,
            udid=hardware.get("udid", ""),
            name=device.get("deviceProperties", {}).get("name", "device"),
            state=STATE.get(connection.get("tunnelState"), "offline"),
        ))
    return devices


def ask(devices):
    """The device the person picked, from the terminal."""
    for number, device in enumerate(devices, 1):
        print(f"  {number}) {device.name} ({device.state}) {device.udid}", file=sys.stderr)
    try:
        tty = open("/dev/tty")
    except OSError:
        tty = sys.stdin

    while True:
        print(f"pick-device: which device? [1-{len(devices)}] ",
              end="", file=sys.stderr, flush=True)
        answer = tty.readline()
        if not answer:
            sys.stderr.write("\n")
            die("nothing to ask on; name the device instead: "
                "./scripts/lib/pick-device.py <name>")
        answer = answer.strip()
        if answer.isdigit() and 1 <= int(answer) <= len(devices):
            return devices[int(answer) - 1]
        print(f"pick-device: 1 to {len(devices)}, or Ctrl-C.", file=sys.stderr)


def main(argv):
    wanted = argv[1].lower() if len(argv) > 1 else ""
    devices = [device for device in paired_devices()
               if not wanted or wanted in f"{device.identifier} {device.udid} {device.name}".lower()]
    devices.sort(key=lambda device: (RANK.get(device.state, 3), device.name.lower()))

    if not devices:
        if wanted:
            die(f"no paired device matches '{argv[1]}'.")
        return 0
    if len(devices) == 1:
        print(devices[0].line)
        return 0
    if wanted:
        listing = "".join(f"\n  {device.udid}\t{device.name}" for device in devices)
        die(f"'{argv[1]}' matches {len(devices)} devices; name one of them exactly:{listing}")
    print(ask(devices).line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
