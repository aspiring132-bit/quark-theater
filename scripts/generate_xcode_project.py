#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library.

Run after adding/removing Swift files. --check never modifies files and fails if
the generated project differs. Paths and object identifiers are deterministic.
This validates project structure, NOT Swift syntax or Apple SDK compatibility.
"""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "QuarkTheater.xcodeproj"

def identifier(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:24].upper()

def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

def generate() -> dict[Path, str]:
    objects: dict[str, str] = {}
    def add(key: str, body: str) -> str:
        object_id = identifier(key)
        if object_id in objects:
            raise ValueError("Duplicate project object: " + key)
        objects[object_id] = body
        return object_id
    def array(values: list[str]) -> str:
        return "(" + ", ".join(values) + ("," if values else "") + ")"
    def settings(values: dict[str, str]) -> str:
        return "{ " + " ".join(k + " = " + quote(v) + ";" for k, v in sorted(values.items())) + " }"

    app_sources = sorted((ROOT / "QuarkTheater").rglob("*.swift"))
    test_sources = sorted((ROOT / "QuarkTheaterTests").rglob("*.swift"))
    if not app_sources or not test_sources:
        raise ValueError("Both application and test Swift sources are required.")
    config_ref = add("config:Shared", 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Shared.xcconfig; sourceTree = "<group>";')
    config_group = add("group:Config", "isa = PBXGroup; children = " + array([config_ref]) + '; path = Config; sourceTree = "<group>";')
    source_refs: dict[str, str] = {}
    for path in app_sources + test_sources:
        relative = path.relative_to(ROOT).as_posix()
        source_refs[relative] = add("file:" + relative, "isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = " + quote(path.name) + '; sourceTree = "<group>";')

    def source_group(directory: Path) -> str:
        children = []
        for entry in sorted(directory.iterdir(), key=lambda item: (item.is_file(), item.name)):
            if entry.is_dir() and any(entry.rglob("*.swift")):
                children.append(source_group(entry))
            elif entry.is_file() and entry.suffix == ".swift":
                children.append(source_refs[entry.relative_to(ROOT).as_posix()])
        return add("group:" + directory.relative_to(ROOT).as_posix(),
                   "isa = PBXGroup; children = " + array(children) + "; path = " + quote(directory.name) + '; sourceTree = "<group>";')
    app_group = source_group(ROOT / "QuarkTheater")
    test_group = source_group(ROOT / "QuarkTheaterTests")
    app_product = add("product:app", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = QuarkTheater.app; sourceTree = BUILT_PRODUCTS_DIR;')
    test_product = add("product:test", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = QuarkTheaterTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    products = add("group:Products", "isa = PBXGroup; children = " + array([app_product, test_product]) + '; name = Products; sourceTree = "<group>";')
    sqlite_ref = add("framework:sqlite3", 'isa = PBXFileReference; lastKnownFileType = sourcecode.text-based-dylib-definition; name = libsqlite3.tbd; path = usr/lib/libsqlite3.tbd; sourceTree = SDKROOT;')
    frameworks = add("group:Frameworks", "isa = PBXGroup; children = " + array([sqlite_ref]) + '; name = Frameworks; sourceTree = "<group>";')
    root_group = add("group:Root", "isa = PBXGroup; children = " + array([app_group, test_group, config_group, frameworks, products]) + '; sourceTree = "<group>";')

    def phase(key: str, kind: str, references: list[str]) -> str:
        build_files = [add("build:" + key + ":" + ref, "isa = PBXBuildFile; fileRef = " + ref + ";") for ref in references]
        return add("phase:" + key, "isa = " + kind + "; buildActionMask = 2147483647; files = " + array(build_files) + "; runOnlyForDeploymentPostprocessing = 0;")
    app_phases = [
        phase("app:sources", "PBXSourcesBuildPhase", [source_refs[p.relative_to(ROOT).as_posix()] for p in app_sources]),
        phase("app:frameworks", "PBXFrameworksBuildPhase", [sqlite_ref]),
        phase("app:resources", "PBXResourcesBuildPhase", []),
    ]
    test_phases = [
        phase("test:sources", "PBXSourcesBuildPhase", [source_refs[p.relative_to(ROOT).as_posix()] for p in test_sources]),
        phase("test:frameworks", "PBXFrameworksBuildPhase", []),
        phase("test:resources", "PBXResourcesBuildPhase", []),
    ]

    def configurations(scope: str, base: dict[str, str], shared: bool = False) -> str:
        refs = []
        for name in ["Debug", "Release"]:
            values = dict(base)
            if scope == "project":
                values.update({
                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
                    "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym",
                    "ENABLE_TESTABILITY": "YES" if name == "Debug" else "NO",
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if name == "Debug" else "",
                    "ONLY_ACTIVE_ARCH": "YES" if name == "Debug" else "NO",
                })
            body = "isa = XCBuildConfiguration; "
            if shared:
                body += "baseConfigurationReference = " + config_ref + "; "
            body += "buildSettings = " + settings(values) + "; name = " + name + ";"
            refs.append(add("configuration:" + scope + ":" + name, body))
        return add("configurationList:" + scope, "isa = XCConfigurationList; buildConfigurations = " + array(refs) + "; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

    project_config = configurations("project", {
        "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17",
    }, shared=True)
    app_config = configurations("app", {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "org.quarktheater.app",
        "PRODUCT_MODULE_NAME": "QuarkTheater", "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "Quark Theater",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.entertainment",
        "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    })
    test_config = configurations("test", {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "org.quarktheater.app.tests",
        "GENERATE_INFOPLIST_FILE": "YES", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/QuarkTheater.app/QuarkTheater",
        "BUNDLE_LOADER": "$(TEST_HOST)", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
    })
    project_id = identifier("project")
    app_id = identifier("target:app")
    test_id = identifier("target:test")
    proxy = add("proxy:app", "isa = PBXContainerItemProxy; containerPortal = " + project_id + "; proxyType = 1; remoteGlobalIDString = " + app_id + "; remoteInfo = QuarkTheater;")
    dependency = add("dependency:test:app", "isa = PBXTargetDependency; target = " + app_id + "; targetProxy = " + proxy + ";")
    add("target:app", "isa = PBXNativeTarget; buildConfigurationList = " + app_config + "; buildPhases = " + array(app_phases) + "; buildRules = (); dependencies = (); name = QuarkTheater; productName = QuarkTheater; productReference = " + app_product + '; productType = "com.apple.product-type.application";')
    add("target:test", "isa = PBXNativeTarget; buildConfigurationList = " + test_config + "; buildPhases = " + array(test_phases) + "; buildRules = (); dependencies = " + array([dependency]) + "; name = QuarkTheaterTests; productName = QuarkTheaterTests; productReference = " + test_product + '; productType = "com.apple.product-type.bundle.unit-test";')
    add("project", 'isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = { ' + app_id + ' = { CreatedOnToolsVersion = 16.0; }; ' + test_id + ' = { CreatedOnToolsVersion = 16.0; TestTargetID = ' + app_id + '; }; }; }; buildConfigurationList = ' + project_config + '; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base); mainGroup = ' + root_group + '; productRefGroup = ' + products + '; projectDirPath = ""; projectRoot = ""; targets = ' + array([app_id, test_id]) + ";")
    pbx = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
    pbx += "".join("\t\t" + key + " = { " + value + " };\n" for key, value in sorted(objects.items()))
    pbx += "\t};\n\trootObject = " + project_id + ";\n}\n"
    def buildable(object_id: str, name: str, target: str) -> str:
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{object_id}" BuildableName="{name}" BlueprintName="{target}" ReferencedContainer="container:QuarkTheater.xcodeproj"/>'
    app_buildable = buildable(app_id, "QuarkTheater.app", "QuarkTheater")
    test_buildable = buildable(test_id, "QuarkTheaterTests.xctest", "QuarkTheaterTests")
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_buildable}</BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test_buildable}</BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{test_buildable}</TestableReference></Testables>
    <CommandLineArguments><CommandLineArgument argument="--testing" isEnabled="YES"/></CommandLineArguments>
    <MacroExpansion>{app_buildable}</MacroExpansion>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="NO">
    <BuildableProductRunnable runnableDebuggingMode="0">{app_buildable}</BuildableProductRunnable>
    <CommandLineArguments><CommandLineArgument argument="--mock" isEnabled="NO"/></CommandLineArguments>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal">
    <BuildableProductRunnable runnableDebuggingMode="0">{app_buildable}</BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    workspace = '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n'
    return {
        PROJECT / "project.pbxproj": pbx,
        PROJECT / "xcshareddata/xcschemes/QuarkTheater.xcscheme": scheme,
        PROJECT / "project.xcworkspace/contents.xcworkspacedata": workspace,
    }

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    outputs = generate()
    for path, contents in outputs.items():
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != contents:
                stale.append(path.relative_to(ROOT).as_posix())
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8", newline="\n")
    if stale:
        print("STALE project files; run python3 scripts/generate_xcode_project.py:\n" + "\n".join(stale))
        return 1
    count = len(list((ROOT / "QuarkTheater").rglob("*.swift")))
    tests = len(list((ROOT / "QuarkTheaterTests").rglob("*.swift")))
    print(f"{'Checked' if args.check else 'Generated'} Xcode project: {count} app and {tests} test Swift files.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
