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
    uitest_sources = sorted((ROOT / "QuarkTheaterUITests").rglob("*.swift"))
    if not app_sources or not test_sources or not uitest_sources:
        raise ValueError("Application, unit-test and UI-test Swift sources are required.")
    config_ref = add("config:Shared", 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Shared.xcconfig; sourceTree = "<group>";')
    config_group = add("group:Config", "isa = PBXGroup; children = " + array([config_ref]) + '; path = Config; sourceTree = "<group>";')
    source_refs: dict[str, str] = {}
    for path in app_sources + test_sources + uitest_sources:
        relative = path.relative_to(ROOT).as_posix()
        source_refs[relative] = add("file:" + relative, "isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = " + quote(path.name) + '; sourceTree = "<group>";')

    assets_dir = ROOT / "QuarkTheater" / "Assets.xcassets"
    assets_ref = add("file:QuarkTheater/Assets.xcassets", 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";') if assets_dir.exists() else None

    def source_group(directory: Path) -> str:
        children = []
        for entry in sorted(directory.iterdir(), key=lambda item: (item.is_file(), item.name)):
            if entry.name == "Assets.xcassets" and assets_ref:
                children.append(assets_ref)
            elif entry.is_dir() and any(entry.rglob("*.swift")):
                children.append(source_group(entry))
            elif entry.is_file() and entry.suffix == ".swift":
                children.append(source_refs[entry.relative_to(ROOT).as_posix()])
        return add("group:" + directory.relative_to(ROOT).as_posix(),
                   "isa = PBXGroup; children = " + array(children) + "; path = " + quote(directory.name) + '; sourceTree = "<group>";')
    app_group = source_group(ROOT / "QuarkTheater")
    test_group = source_group(ROOT / "QuarkTheaterTests")
    uitest_group = source_group(ROOT / "QuarkTheaterUITests")
    app_product = add("product:app", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = QuarkTheater.app; sourceTree = BUILT_PRODUCTS_DIR;')
    test_product = add("product:test", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = QuarkTheaterTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    uitest_product = add("product:uitest", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = QuarkTheaterUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    products = add("group:Products", "isa = PBXGroup; children = " + array([app_product, test_product, uitest_product]) + '; name = Products; sourceTree = "<group>";')
    vlc_dir = ROOT / "Frameworks" / "TVVLCKit.xcframework"
    if not vlc_dir.exists():
        raise ValueError("Bundled Frameworks/TVVLCKit.xcframework is required for the production project.")
    vlc_enabled = True
    system_libraries = {"sqlite3": "libsqlite3.tbd"}
    if vlc_enabled:
        system_libraries.update({
            "bz2": "libbz2.tbd",
            "c++": "libc++.tbd",
            "iconv": "libiconv.tbd",
            "xml2": "libxml2.tbd",
            "z": "libz.tbd",
        })
    library_refs = {
        key: add("framework:" + key, 'isa = PBXFileReference; lastKnownFileType = sourcecode.text-based-dylib-definition; name = ' + quote(value) + '; path = ' + quote('usr/lib/' + value) + '; sourceTree = SDKROOT;')
        for key, value in system_libraries.items()
    }
    sdk_frameworks = {
        "AudioToolbox": "AudioToolbox.framework",
        "AVFoundation": "AVFoundation.framework",
        "CoreMedia": "CoreMedia.framework",
        "CoreText": "CoreText.framework",
        "CoreVideo": "CoreVideo.framework",
        "OpenGLES": "OpenGLES.framework",
        "Security": "Security.framework",
        "VideoToolbox": "VideoToolbox.framework",
    } if vlc_enabled else {}
    sdk_framework_refs = {
        key: add("sdkframework:" + key, 'isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = ' + value + '; path = System/Library/Frameworks/' + value + '; sourceTree = SDKROOT;')
        for key, value in sdk_frameworks.items()
    }
    vlc_ref = add("framework:TVVLCKit", 'isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; name = TVVLCKit.xcframework; path = Frameworks/TVVLCKit.xcframework; sourceTree = "<group>";') if vlc_enabled else None
    framework_group_children = list(library_refs.values()) + list(sdk_framework_refs.values())
    if vlc_ref:
        framework_group_children.append(vlc_ref)
    frameworks = add("group:Frameworks", "isa = PBXGroup; children = " + array(framework_group_children) + '; name = Frameworks; sourceTree = "<group>";')
    root_group = add("group:Root", "isa = PBXGroup; children = " + array([app_group, test_group, uitest_group, config_group, frameworks, products]) + '; sourceTree = "<group>";')

    def phase(key: str, kind: str, references: list[str], extra_build_files: list[str] = []) -> str:
        build_files = [add("build:" + key + ":" + ref, "isa = PBXBuildFile; fileRef = " + ref + ";") for ref in references] + extra_build_files
        return add("phase:" + key, "isa = " + kind + "; buildActionMask = 2147483647; files = " + array(build_files) + "; runOnlyForDeploymentPostprocessing = 0;")
    app_framework_refs = list(library_refs.values()) + list(sdk_framework_refs.values())
    if vlc_ref:
        app_framework_refs.append(vlc_ref)
    app_framework_build_files = [add("build:app:frameworks:" + ref, "isa = PBXBuildFile; fileRef = " + ref + ";") for ref in app_framework_refs]
    app_framework_phase = add("phase:app:frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = " + array(app_framework_build_files) + "; runOnlyForDeploymentPostprocessing = 0;")
    app_phases = [
        phase("app:sources", "PBXSourcesBuildPhase", [source_refs[p.relative_to(ROOT).as_posix()] for p in app_sources]),
        app_framework_phase,
        phase("app:resources", "PBXResourcesBuildPhase", [assets_ref] if assets_ref else []),
    ]
    if vlc_ref:
        vlc_embed_build_file = add("build:app:embed:TVVLCKit", "isa = PBXBuildFile; fileRef = " + vlc_ref + "; settings = { ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); };")
        vlc_embed_phase = add("phase:app:embed", "isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 10; files = " + array([vlc_embed_build_file]) + "; name = Frameworks; runOnlyForDeploymentPostprocessing = 0;")
        app_phases.append(vlc_embed_phase)
    test_framework_refs = [vlc_ref] if vlc_ref else []
    test_phases = [
        phase("test:sources", "PBXSourcesBuildPhase", [source_refs[p.relative_to(ROOT).as_posix()] for p in test_sources]),
        phase("test:frameworks", "PBXFrameworksBuildPhase", test_framework_refs),
        phase("test:resources", "PBXResourcesBuildPhase", []),
    ]
    uitest_phases = [
        phase("uitest:sources", "PBXSourcesBuildPhase", [source_refs[p.relative_to(ROOT).as_posix()] for p in uitest_sources]),
        phase("uitest:frameworks", "PBXFrameworksBuildPhase", []),
        phase("uitest:resources", "PBXResourcesBuildPhase", []),
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
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "org.quarktheater.app.wangbin",
        "PRODUCT_MODULE_NAME": "QuarkTheater", "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": "1.6", "CURRENT_PROJECT_VERSION": "2",
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
    uitest_config = configurations("uitest", {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "org.quarktheater.app.uitests",
        "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "QuarkTheater",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
    })
    project_id = identifier("project")
    app_id = identifier("target:app")
    test_id = identifier("target:test")
    uitest_id = identifier("target:uitest")
    proxy = add("proxy:app", "isa = PBXContainerItemProxy; containerPortal = " + project_id + "; proxyType = 1; remoteGlobalIDString = " + app_id + "; remoteInfo = QuarkTheater;")
    dependency = add("dependency:test:app", "isa = PBXTargetDependency; target = " + app_id + "; targetProxy = " + proxy + ";")
    uitest_dependency = add("dependency:uitest:app", "isa = PBXTargetDependency; target = " + app_id + "; targetProxy = " + proxy + ";")
    add("target:app", "isa = PBXNativeTarget; buildConfigurationList = " + app_config + "; buildPhases = " + array(app_phases) + "; buildRules = (); dependencies = (); name = QuarkTheater; productName = QuarkTheater; productReference = " + app_product + '; productType = "com.apple.product-type.application";')
    add("target:test", "isa = PBXNativeTarget; buildConfigurationList = " + test_config + "; buildPhases = " + array(test_phases) + "; buildRules = (); dependencies = " + array([dependency]) + "; name = QuarkTheaterTests; productName = QuarkTheaterTests; productReference = " + test_product + '; productType = "com.apple.product-type.bundle.unit-test";')
    add("target:uitest", "isa = PBXNativeTarget; buildConfigurationList = " + uitest_config + "; buildPhases = " + array(uitest_phases) + "; buildRules = (); dependencies = " + array([uitest_dependency]) + "; name = QuarkTheaterUITests; productName = QuarkTheaterUITests; productReference = " + uitest_product + '; productType = "com.apple.product-type.bundle.ui-testing";')
    add("project", 'isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = { ' + app_id + ' = { CreatedOnToolsVersion = 16.0; DevelopmentTeam = LY2UZ2U7D2; ProvisioningStyle = Automatic; }; ' + test_id + ' = { CreatedOnToolsVersion = 16.0; TestTargetID = ' + app_id + '; }; ' + uitest_id + ' = { CreatedOnToolsVersion = 16.0; TestTargetID = ' + app_id + '; }; }; }; buildConfigurationList = ' + project_config + '; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base); mainGroup = ' + root_group + '; packageReferences = (); productRefGroup = ' + products + '; projectDirPath = ""; projectRoot = ""; targets = ' + array([app_id, test_id, uitest_id]) + ";")
    pbx = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
    pbx += "".join("\t\t" + key + " = { " + value + " };\n" for key, value in sorted(objects.items()))
    pbx += "\t};\n\trootObject = " + project_id + ";\n}\n"
    def buildable(object_id: str, name: str, target: str) -> str:
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{object_id}" BuildableName="{name}" BlueprintName="{target}" ReferencedContainer="container:QuarkTheater.xcodeproj"/>'
    app_buildable = buildable(app_id, "QuarkTheater.app", "QuarkTheater")
    test_buildable = buildable(test_id, "QuarkTheaterTests.xctest", "QuarkTheaterTests")
    uitest_buildable = buildable(uitest_id, "QuarkTheaterUITests.xctest", "QuarkTheaterUITests")
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_buildable}</BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test_buildable}</BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{uitest_buildable}</BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{test_buildable}</TestableReference><TestableReference skipped="NO">{uitest_buildable}</TestableReference></Testables>
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
    uitests = len(list((ROOT / "QuarkTheaterUITests").rglob("*.swift")))
    print(f"{'Checked' if args.check else 'Generated'} Xcode project: {count} app, {tests} test and {uitests} UI-test Swift files.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
