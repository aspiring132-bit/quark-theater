#!/usr/bin/env python3
"""Focused checks for the production TVVLCKit project integration."""
from pathlib import Path
import json
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("project_generator", ROOT / "scripts/generate_xcode_project.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

outputs = module.generate()
pbx = outputs[ROOT / "QuarkTheater.xcodeproj/project.pbxproj"]
assert "KSPlayer" not in pbx, "KSPlayer project/package references must be removed"
assert "kingslay/KSPlayer" not in pbx, "KSPlayer remote package reference must be removed"
assert "TVVLCKit.xcframework" in pbx, "production VLC framework is not represented"
assert "PBXCopyFilesBuildPhase" in pbx, "VLC embed phase is missing"
assert "CodeSignOnCopy" in pbx, "VLC framework is not configured for signing"
assert "packageReferences = ();" in pbx, "the production project must not declare Swift packages"
assert "packageProductDependencies" not in pbx, "the app must not link a Swift package product"
resolved = json.loads((ROOT / "QuarkTheater.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text(encoding="utf-8"))
assert resolved.get("pins") == [], "the production project must not retain stale Swift package pins"
vlc_ref = module.identifier("framework:TVVLCKit")
assert pbx.count(vlc_ref) >= 4, "VLC should be represented in the app/test link and embed phases"
assert "name = TVVLCKit.xcframework" in pbx, "VLC framework file reference is missing"
for name in ("AudioToolbox", "AVFoundation", "CoreMedia", "CoreText", "CoreVideo", "OpenGLES", "Security", "VideoToolbox", "libbz2", "libc++", "libiconv", "libxml2", "libz"):
    assert name in pbx, f"missing VLC system dependency: {name}"
print("VLC project integration checks passed")
