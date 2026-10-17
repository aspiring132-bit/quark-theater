#!/usr/bin/env python3
"""Cross-platform deterministic project checks. Does not compile Swift."""
import re
import subprocess
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / "scripts/generate_xcode_project.py"), "--check"], check=True)
pbx = (root / "QuarkTheater.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
definitions = re.findall(r"^\s*([A-F0-9]{24}) = \{", pbx, re.MULTILINE)
references = set(re.findall(r"\b[A-F0-9]{24}\b", pbx))
assert len(definitions) == len(set(definitions)), "Duplicate PBX object definitions"
assert references == set(definitions), "Unresolved PBX object references"
scheme = ET.parse(root / "QuarkTheater.xcodeproj/xcshareddata/xcschemes/QuarkTheater.xcscheme")
args = scheme.findall(".//CommandLineArgument")
assert all(a.get("isEnabled") == "NO" for a in args if a.get("argument") == "--mock"), "Mock must be opt-in"
test_args = scheme.findall(".//TestAction/CommandLineArguments/CommandLineArgument")
assert any(a.get("argument") == "--testing" and a.get("isEnabled") == "YES" for a in test_args), "Hosted tests must opt out of session restoration"
tests = scheme.findall(".//TestableReference")
assert len(tests) == 1 and tests[0].get("skipped") == "NO", "Tests must be included"
ET.parse(root / "QuarkTheater.xcodeproj/project.xcworkspace/contents.xcworkspacedata")
config = (root / "Config/Shared.xcconfig").read_text(encoding="utf-8")
for setting in ["TARGETED_DEVICE_FAMILY = 3", "TVOS_DEPLOYMENT_TARGET = 26.0", "SWIFT_VERSION = 6.0"]:
    assert setting in config, "Missing build setting: " + setting
test_count = sum(len(re.findall(r"\bfunc test\w+\s*\(", p.read_text(encoding="utf-8"))) for p in (root / "QuarkTheaterTests").rglob("*.swift"))
print(f"PASS: {len(definitions)} PBX objects; references, shared scheme, target settings and generation verified.")
print(f"Located {test_count} XCTest methods. Tests NOT executed. Swift/Apple SDK compilation NOT checked.")
