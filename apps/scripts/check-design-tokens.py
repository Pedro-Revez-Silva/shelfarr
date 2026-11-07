#!/usr/bin/env python3
"""Fails if Android or iOS drift from apps/design/tokens.json, or text loses contrast."""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOKENS = json.loads((ROOT / "apps/design/tokens.json").read_text())
KOTLIN_TOKENS = (ROOT / "apps/android/app/src/main/java/org/shelfarr/app/ui/theme/Tokens.kt").read_text()
KOTLIN_READER = (ROOT / "apps/android/app/src/main/java/org/shelfarr/app/reader/ReaderSettings.kt").read_text()
SWIFT_THEME = (ROOT / "apps/ios/Shelfarr/Design/Theme.swift").read_text()
SWIFT_READER = (ROOT / "apps/ios/Shelfarr/Reader/ReaderSettings.swift").read_text()

MINIMUM_TEXT = 4.5
MINIMUM_LARGE = 3.0
problems = []


def luminance(colour):
    channels = [int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(first, second):
    lighter, darker = sorted((luminance(first), luminance(second)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


def require_contrast(label, foreground, background, minimum=MINIMUM_TEXT):
    ratio = contrast(foreground, background)
    if ratio < minimum:
        problems.append(f"{label}: contrast {ratio:.2f} is below {minimum}")


def kotlin_object(name):
    body = re.search(rf"object {name} \{{(.*?)\n\}}", KOTLIN_TOKENS, re.S).group(1)
    return {
        key: "#" + value.upper()
        for key, value in re.findall(r"val (\w+) = Color\(0xFF([0-9A-Fa-f]{6})\)", body)
    }


def compare(platform, expected, actual):
    for key, value in expected.items():
        if actual.get(key) != value.upper():
            problems.append(f"{platform} {key}: expected {value}, found {actual.get(key)}")


compare("Android light", TOKENS["color"]["light"], kotlin_object("LightTokens"))
compare("Android dark", TOKENS["color"]["dark"], kotlin_object("DarkTokens"))

swift_light, swift_dark = {}, {}
for key, light, dark in re.findall(r"static let (\w+) = dynamic\(0x([0-9A-F]{6}), 0x([0-9A-F]{6})\)", SWIFT_THEME):
    swift_light[key], swift_dark[key] = f"#{light}", f"#{dark}"
compare("iOS light", TOKENS["color"]["light"], swift_light)
compare("iOS dark", TOKENS["color"]["dark"], swift_dark)

swatches = [value.upper() for value in TOKENS["cover"]["swatches"]]
kotlin_swatches = re.search(r"CoverSwatches = listOf\((.*?)\n\)", KOTLIN_TOKENS, re.S).group(1)
if ["#" + v.upper() for v in re.findall(r"0xFF([0-9A-Fa-f]{6})", kotlin_swatches)] != swatches:
    problems.append("Android cover swatches differ from tokens.json")
swift_swatches = re.search(r"coverSwatches: \[Color\] = \[(.*?)\]", SWIFT_THEME, re.S).group(1)
if ["#" + v.upper() for v in re.findall(r"0x([0-9A-F]{6})", swift_swatches)] != swatches:
    problems.append("iOS cover swatches differ from tokens.json")

order = ("page", "text", "muted", "bar", "hairline", "accent")
for name, theme in TOKENS["reader"].items():
    expected = [theme[key].upper() for key in order]
    android = re.search(rf"{name.upper()}\(\"\w+\", (.*?), Theme\.", KOTLIN_READER)
    if android is None or ["#" + v.upper() for v in re.findall(r"0xFF([0-9A-Fa-f]{6})", android.group(1))] != expected:
        problems.append(f"Android reader theme {name} differs from tokens.json")
    ios = re.search(rf"case \.{name}: return \((.*?)\)", SWIFT_READER)
    if ios is None or ["#" + v.upper() for v in re.findall(r"0x([0-9A-F]{6})", ios.group(1))] != expected:
        problems.append(f"iOS reader theme {name} differs from tokens.json")

for mode, colours in TOKENS["color"].items():
    for surface in ("background", "surface", "sunken"):
        require_contrast(f"{mode} ink on {surface}", colours["ink"], colours[surface])
        require_contrast(f"{mode} inkMuted on {surface}", colours["inkMuted"], colours[surface])
    require_contrast(f"{mode} accent on background", colours["accent"], colours["background"])
    require_contrast(f"{mode} accent on surface", colours["accent"], colours["surface"])
    require_contrast(f"{mode} onAccent on accent", colours["onAccent"], colours["accent"])
    require_contrast(f"{mode} danger on background", colours["danger"], colours["background"])

for name, theme in TOKENS["reader"].items():
    require_contrast(f"reader {name} text", theme["text"], theme["page"], 7.0)
    require_contrast(f"reader {name} muted on page", theme["muted"], theme["page"])
    require_contrast(f"reader {name} muted on bar", theme["muted"], theme["bar"])
    require_contrast(f"reader {name} accent on bar", theme["accent"], theme["bar"])

for swatch in TOKENS["cover"]["swatches"]:
    require_contrast(f"cover ink on {swatch}", TOKENS["cover"]["ink"], swatch)

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("Design tokens match on Android and iOS, and all contrast checks pass.")
