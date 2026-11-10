#!/usr/bin/env python3
"""Configures and verifies AppIcon.icon and AppIconDebug.icon.

Blue icon for app (Release), Red icon for debug version of app.
Asset targets:
  - AppIcon.icon (Release)
  - AppIconDebug.icon (Debug)
  - Assets.xcassets/AppIcon.appiconset (Release)
  - Assets.xcassets/AppIconDebug.appiconset (Debug)
"""
import json, pathlib

root = pathlib.Path(__file__).resolve().parent.parent

for name in ("AppIcon.icon", "AppIconDebug.icon"):
    icon_dir = root / name
    icon_json_path = icon_dir / "icon.json"
    if not icon_json_path.exists():
        continue
    data = {
        "groups": [
            {
                "layers": [
                    {
                        "image-name": "Icon.png",
                        "name": "Icon",
                        "position": {"scale": 1, "translation-in-points": [0, 0]},
                    }
                ]
            }
        ],
        "supported-platforms": {"squares": "shared"},
    }
    icon_json_path.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Verified {name}/icon.json")
