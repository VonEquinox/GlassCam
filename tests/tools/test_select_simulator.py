import importlib.util
from pathlib import Path
import pytest


module = importlib.util.spec_from_file_location(
    "select_simulator", Path(__file__).resolve().parents[2] / "scripts/select_simulator.py"
)
selection = importlib.util.module_from_spec(module)
module.loader.exec_module(selection)


def runtime(version, available=True):
    return {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
            "version": version, "isAvailable": available}


def device(udid, state="Shutdown", kind="iPhone-18-Pro", available=True):
    return {"udid": udid, "state": state, "isAvailable": available,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + kind}


def test_booted_simulator_precedes_newer_shutdown_runtime():
    current, newer = runtime("27.0"), runtime("27.1")
    devices = {current["identifier"]: [device("RUNNING", "Booted")],
               newer["identifier"]: [device("NEWER")]}

    selected = selection.select(devices, [current, newer])

    assert selected == "RUNNING"


@pytest.mark.parametrize("newer_version", ["27.1", "27.0.1"])
def test_without_booted_simulator_newest_runtime_is_selected(newer_version):
    current, newer = runtime("27.0"), runtime(newer_version)
    devices = {current["identifier"]: [device("CURRENT")], newer["identifier"]: [device("NEWER")]}

    selected = selection.select(devices, [current, newer])

    assert selected == "NEWER"


def test_inventory_order_does_not_change_selection():
    current = runtime("27.0")
    candidates = [device("B"), device("A"), device("C", kind="iPhone-18-Pro-Max")]

    selected = [selection.select({current["identifier"]: order}, [current])
                for order in [candidates, list(reversed(candidates))]]

    assert selected == ["A", "A"]


def test_explicit_id_selects_supported_shutdown_simulator():
    current = runtime("27.0")
    devices = {current["identifier"]: [device("RUNNING", "Booted"), device("SELECTED")]}

    selected = selection.select(devices, [current], "selected")

    assert selected == "SELECTED"


def test_unavailable_runtime_old_ios_ipad_and_unavailable_device_are_excluded():
    current, old, unavailable = runtime("27.0"), runtime("26.0"), runtime("27.1", available=False)
    devices = {current["identifier"]: [device("IPAD", kind="iPad-Pro"), device("UNAVAILABLE", available=False)],
               old["identifier"]: [device("OLD")], unavailable["identifier"]: [device("NO-RUNTIME")]}

    with pytest.raises(ValueError, match="No available iPhone simulator"):
        selection.select(devices, [current, old, unavailable])


def test_unknown_explicit_id_fails_instead_of_selecting_another_device():
    current = runtime("27.0")

    with pytest.raises(ValueError, match="SIMULATOR_ID=UNKNOWN"):
        selection.select({current["identifier"]: [device("AVAILABLE")]}, [current], "UNKNOWN")
