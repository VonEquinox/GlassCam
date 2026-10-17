"""Resolve the stateless factory preset's native sharpness parameters.

GlassCam applies tool-only XML files over Standard, as its native gradation
reference already does. A missing field in such a tool is not a request to
disable sharpening. Full ImageCorrection payloads are decoded independently.

Phocus 4.2.2 CImageCorrection::DecodePartFrom reads absent numeric USM keys as
zero and defaults an absent ApplyUSM to true. That differs from calling
SetDefaultSharpness (radius/dark=10, amount=0). These rules are verified with
original getters by audit_phocus_sharpness_settings.py, not inferred from None.
"""
from copy import deepcopy


def correction_payload(catalog, filename):
    original = catalog["source_files"][filename]["plist"]
    if "ImageSetting" in original:
        return deepcopy(original["ImageSetting"]["ImageCorrection"])
    baseline = catalog["source_files"]["Standard.xml"]["plist"]["ImageSetting"]["ImageCorrection"]
    return dict(deepcopy(baseline), **deepcopy(original))


def sharpness_settings(payload):
    def integer(key, low, high):
        value = payload.get(key, 0)
        if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
            raise ValueError(f"Invalid native sharpness field {key}: {value!r}")
        return value

    enabled = payload.get("ApplyUSM", True)
    if not isinstance(enabled, bool):
        raise ValueError("ApplyUSM must be Boolean")
    return {
        "enabled": enabled,
        "amount": integer("USMAmount", -32768, 32767),
        "radius": integer("USMRadius", -32768, 32767),
        "noise_limit": integer("USMNoiseLimit", 0, 255),
        "dark_limit": integer("USMDarkLimit", -32768, 32767),
    }


def preset_sharpness(presets, key):
    filename = presets.FACTORY_SETTING_FILES[presets.settings(key)["name"]]
    return sharpness_settings(correction_payload(presets.catalog(), filename))
