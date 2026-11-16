#!/usr/bin/env python3
"""Generate a standard, shared-scheme Xcode project without requiring XcodeGen."""
import argparse
import hashlib
import json
import plistlib
import re
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

# `xcodebuild -exportLocalizations` refuses to run when the project's
# development language differs from a string catalog's source language, so
# extraction needs a throwaway project whose development language is Chinese.
# The shipped project keeps English as its development language: devices in
# languages the app doesn't ship then see English rather than Chinese.
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--development-language", default="en",
                    help="Only for -exportLocalizations; regenerating without it restores en.")
OPTIONS = parser.parse_args()
objects = {}

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(key_name, isa, **values):
    key = uid(key_name)
    objects[key] = {"isa": isa, **values}
    return key

def build(name, settings):
    return add(name, "XCBuildConfiguration", buildSettings=settings, name=name.rsplit("/", 1)[-1])

def configs(name, base, release_extra=None):
    debug = build(name + "/Debug", {**base, "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "ONLY_ACTIVE_ARCH": "YES", "ENABLE_TESTABILITY": "YES"})
    release = build(name + "/Release", {**base, "SWIFT_OPTIMIZATION_LEVEL": "-O", **(release_extra or {})})
    return add(name + "/ConfigList", "XCConfigurationList", buildConfigurations=[debug, release], defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

app_id = uid("AppTarget")
test_id = uid("TestTarget")
app_product = add("AppProduct", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path="iPadn.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("TestProduct", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0", path="iPadnTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
app_files, sources = [], []
for path in sorted((ROOT / "iPadn").rglob("*.swift")):
    relative = path.relative_to(ROOT / "iPadn").as_posix()
    reference = add("File/" + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="<group>")
    app_files.append(reference)
    sources.append(add("Build/" + relative, "PBXBuildFile", fileRef=reference))
# Compile the verified preparation core into the main app. The runner has its
# own @main and UI sources, so those never enter the iPadn source phase.
decrypter_core_refs = []
decrypter_core_files = []
for path in sorted((ROOT / "Decrypter/Core").iterdir()):
    if path.suffix not in {".swift", ".c", ".h"}: continue
    kind = {".swift": "sourcecode.swift", ".c": "sourcecode.c.c", ".h": "sourcecode.c.h"}[path.suffix]
    reference = add("Decrypter/Core/" + path.name, "PBXFileReference", lastKnownFileType=kind, path=path.name, sourceTree="<group>")
    decrypter_core_refs.append(reference)
    if path.suffix in {".swift", ".c"}:
        decrypter_core_files.append(reference)
        sources.append(add("Decrypter/AppBuild/" + path.name, "PBXBuildFile", fileRef=reference))
resources = []
# String catalogs hold every user-facing string. The source language stays
# Chinese (the keys are the Chinese text); English is translated in the catalog.
for path, file_type in [("Resources/SAPRuntime", "folder"), ("Resources/RevealAnimations", "folder"), ("Resources/Assets.xcassets", "folder.assetcatalog"), ("Resources/PrivacyInfo.xcprivacy", "text.xml"), ("Resources/app-name-directory.json", "text.json"),
                       ("Resources/Localizable.xcstrings", "text.json.xcstrings"), ("Resources/InfoPlist.xcstrings", "text.json.xcstrings")]:
    reference = add("File/" + path, "PBXFileReference", lastKnownFileType=file_type, path=path, sourceTree="<group>")
    app_files.append(reference)
    resources.append(add("Build/" + path, "PBXBuildFile", fileRef=reference))
# Xcode requires .strings resources for App Shortcuts when targeting iOS 16.
shortcut_catalog = json.loads((ROOT / "iPadn/Resources/AppShortcuts.xcstrings").read_text(encoding="utf-8"))["strings"]
shortcut_languages = sorted(next(iter(shortcut_catalog.values()))["localizations"])
shortcut_children = []
for language in shortcut_languages:
    path = f"Resources/{language}.lproj/AppShortcuts.strings"
    lines = []
    for key, entry in shortcut_catalog.items():
        value = entry["localizations"][language]["stringUnit"]["value"]
        lines.append(f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};")
    strings_file = ROOT / "iPadn" / path
    strings_file.parent.mkdir(parents=True, exist_ok=True)
    strings_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    shortcut_children.append(add("File/" + path, "PBXFileReference", lastKnownFileType="text.plist.strings",
                                 name=language, path=path, sourceTree="<group>"))
shortcut_group = add("File/Resources/AppShortcuts.xcstrings", "PBXVariantGroup", children=shortcut_children,
                     name="AppShortcuts.strings", sourceTree="<group>")
app_files.append(shortcut_group)
resources.append(add("Build/Resources/AppShortcuts.xcstrings", "PBXBuildFile", fileRef=shortcut_group))
# The primary icon is the dark 立体 icon. AppIconAuto and AppIconFlat follow
# the system appearance; the others are fixed light or dark. AppIconDark is
# kept for installs that chose it before the primary icon became dark.
ALTERNATE_ICONS = ["AppIconAuto", "AppIconFlat", "AppIconLight", "AppIconDark", "AppIconFlatLight", "AppIconFlatDark"]
# Alternate icons also ship as standalone PNGs for SpringBoard and signing tools.
for path in sorted((ROOT / "iPadn/Resources/AlternateIcons").glob("*.png")):
    relative = path.relative_to(ROOT / "iPadn").as_posix()
    reference = add("File/" + relative, "PBXFileReference", lastKnownFileType="image.png", path=relative, sourceTree="<group>")
    app_files.append(reference)
    resources.append(add("Build/" + relative, "PBXBuildFile", fileRef=reference))
app_files.append(add("InfoPlist", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
test_files, test_sources = [], []
for path in sorted((ROOT / "iPadnTests").glob("*.swift")):
    reference = add("TestFile/" + path.name, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
    test_files.append(reference)
    test_sources.append(add("TestBuild/" + path.name, "PBXBuildFile", fileRef=reference))
package = add("ZIPFoundation", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/weichsel/ZIPFoundation.git",
              requirement={"kind": "exactVersion", "version": "0.9.19"})
app_package = add("ZIPFoundation/App", "XCSwiftPackageProductDependency", package=package, productName="ZIPFoundation")
test_package = add("ZIPFoundation/Tests", "XCSwiftPackageProductDependency", package=package, productName="ZIPFoundation")
app_framework = add("ZIPFoundation/AppBuild", "PBXBuildFile", productRef=app_package)
test_framework = add("ZIPFoundation/TestBuild", "PBXBuildFile", productRef=test_package)
app_group = add("AppGroup", "PBXGroup", children=app_files, path="iPadn", sourceTree="<group>")
test_group = add("TestGroup", "PBXGroup", children=test_files, path="iPadnTests", sourceTree="<group>")
products = add("Products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
root_group = add("MainGroup", "PBXGroup", children=[app_group, test_group, products], sourceTree="<group>")
app_sources = add("AppSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=sources, runOnlyForDeploymentPostprocessing="0")
app_resources = add("AppResources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=resources, runOnlyForDeploymentPostprocessing="0")
app_frameworks = add("AppFrameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[app_framework], runOnlyForDeploymentPostprocessing="0")
assemble = add("AssembleWASM", "PBXShellScriptBuildPhase", buildActionMask="2147483647", files=[],
               inputPaths=["$(SRCROOT)/scripts/assemble_runtime.py", "$(SRCROOT)/vendor/SAPRuntime"],
               outputPaths=["$(SRCROOT)/iPadn/Resources/SAPRuntime/" + name for name in ["sap.wasm", "index.html", "sap-signer.js", "wasm_exec.js", "unicorn_x86.js", "libCoreADI.so", "libstoreservicescore.so"]],
               name="Verify local signing runtime", runOnlyForDeploymentPostprocessing="0", shellPath="/bin/bash",
               shellScript='set -euo pipefail\npython3 "$SRCROOT/scripts/assemble_runtime.py"\n', alwaysOutOfDate="1")
tests_sources = add("TestsSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=test_sources, runOnlyForDeploymentPostprocessing="0")
tests_frameworks = add("TestsFrameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[test_framework], runOnlyForDeploymentPostprocessing="0")
test_resources = []
for path in sorted((ROOT / "iPadnTests/Fixtures").glob("*.p12")):
    relative = path.relative_to(ROOT / "iPadnTests").as_posix()
    reference = add("TestFile/" + relative, "PBXFileReference", lastKnownFileType="file", path=relative, sourceTree="<group>")
    objects[test_group]["children"].append(reference)
    test_resources.append(add("TestBuild/" + relative, "PBXBuildFile", fileRef=reference))
tests_resources = add("TestsResources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=test_resources, runOnlyForDeploymentPostprocessing="0")
base = {"IPHONEOS_DEPLOYMENT_TARGET": "16.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17", "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "SWIFT_STRICT_CONCURRENCY": "targeted", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
project_configs = configs("Project", base, {"SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"})
app_settings = {"PRODUCT_BUNDLE_IDENTIFIER": "app.local.iPadn", "PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic",
                "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1,2", "INFOPLIST_FILE": "iPadn/Info.plist",
                "GENERATE_INFOPLIST_FILE": "NO", "MARKETING_VERSION": "2.1.3", "CURRENT_PROJECT_VERSION": "35",
                "SWIFT_OBJC_BRIDGING_HEADER": "Decrypter/Core/Bridging.h",
                "SWIFT_EMIT_LOC_STRINGS": "YES", "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
                "ENABLE_PREVIEWS": "YES", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                # Empty unless scripts/build_unsigned_ipa.sh built the Mac PKG bridge.
                "IPADN_MACPKG_LDFLAGS": "",
                # Empty unless scripts/build_unsigned_ipa.sh built the native installation library.
                "IPADN_NATIVE_LDFLAGS": "",
                "OTHER_LDFLAGS": ["$(inherited)", "-weak_framework", "Translation", "-lz", "$(IPADN_MACPKG_LDFLAGS)", "$(IPADN_NATIVE_LDFLAGS)"]}
test_settings = {"PRODUCT_BUNDLE_IDENTIFIER": "app.local.iPadnTests", "PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic",
                 "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1,2", "GENERATE_INFOPLIST_FILE": "YES",
                 "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/iPadn.app/iPadn", "BUNDLE_LOADER": "$(TEST_HOST)",
                 "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]}
app_configs = configs("App", app_settings)
test_configs = configs("Tests", test_settings)
proxy = add("TestProxy", "PBXContainerItemProxy", containerPortal=uid("Project"), proxyType="1", remoteGlobalIDString=app_id, remoteInfo="iPadn")
dependency = add("TestDependency", "PBXTargetDependency", target=app_id, targetProxy=proxy)
add("AppTarget", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=[assemble, app_sources, app_frameworks, app_resources],
    buildRules=[], dependencies=[], name="iPadn", packageProductDependencies=[app_package], productName="iPadn",
    productReference=app_product, productType="com.apple.product-type.application")
add("TestTarget", "PBXNativeTarget", buildConfigurationList=test_configs, buildPhases=[tests_sources, tests_frameworks, tests_resources],
    buildRules=[], dependencies=[dependency], name="iPadnTests", packageProductDependencies=[test_package], productName="iPadnTests",
    productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
ui_id = uid("UITestTarget")
ui_product = add("UITestProduct", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0", path="iPadnUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
ui_file = add("UITestFile", "PBXFileReference", lastKnownFileType="sourcecode.swift", path="InteractionTests.swift", sourceTree="<group>")
ui_group = add("UITestGroup", "PBXGroup", children=[ui_file], path="iPadnUITests", sourceTree="<group>")
objects[root_group]["children"].append(ui_group)
objects[products]["children"].append(ui_product)
ui_build = add("UITestBuild", "PBXBuildFile", fileRef=ui_file)
ui_sources = add("UITestSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[ui_build], runOnlyForDeploymentPostprocessing="0")
ui_settings = {k: v for k, v in test_settings.items() if k not in ["TEST_HOST", "BUNDLE_LOADER"]}
ui_settings.update({"PRODUCT_BUNDLE_IDENTIFIER": "app.local.iPadnUITests", "TEST_TARGET_NAME": "iPadn"})
ui_configs = configs("UITests", ui_settings)
add("UITestTarget", "PBXNativeTarget", buildConfigurationList=ui_configs, buildPhases=[ui_sources], buildRules=[], dependencies=[dependency], name="iPadnUITests", productName="iPadnUITests", productReference=ui_product, productType="com.apple.product-type.bundle.ui-testing")
# Live Activity extension: the pairing steps and code on the Lock Screen and in the Dynamic Island.
extension_id = uid("ExtensionTarget")
extension_product = add("ExtensionProduct", "PBXFileReference", explicitFileType="wrapper.app-extension", includeInIndex="0", path="iPadnLiveActivity.appex", sourceTree="BUILT_PRODUCTS_DIR")
objects[products]["children"].append(extension_product)
extension_files, extension_sources = [], []
for path in sorted((ROOT / "iPadnLiveActivity").glob("*.swift")):
    reference = add("ExtensionFile/" + path.name, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
    extension_files.append(reference)
    extension_sources.append(add("ExtensionBuild/" + path.name, "PBXBuildFile", fileRef=reference))
extension_files.append(add("ExtensionInfoPlist", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
# The extension runs in its own process and reads its own string catalog.
extension_catalog = add("ExtensionFile/Localizable.xcstrings", "PBXFileReference", lastKnownFileType="text.json.xcstrings", path="Localizable.xcstrings", sourceTree="<group>")
extension_files.append(extension_catalog)
extension_resources = add("ExtensionResources", "PBXResourcesBuildPhase", buildActionMask="2147483647",
                          files=[add("ExtensionBuild/Localizable.xcstrings", "PBXBuildFile", fileRef=extension_catalog)], runOnlyForDeploymentPostprocessing="0")
objects[root_group]["children"].append(add("ExtensionGroup", "PBXGroup", children=extension_files, path="iPadnLiveActivity", sourceTree="<group>"))
extension_phase = add("ExtensionSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=extension_sources, runOnlyForDeploymentPostprocessing="0")
extension_settings = {"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "PRODUCT_BUNDLE_IDENTIFIER": "app.local.iPadn.LiveActivity", "PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic",
                      "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1,2", "INFOPLIST_FILE": "iPadnLiveActivity/Info.plist",
                      "GENERATE_INFOPLIST_FILE": "NO", "MARKETING_VERSION": app_settings["MARKETING_VERSION"],
                      "CURRENT_PROJECT_VERSION": app_settings["CURRENT_PROJECT_VERSION"], "SKIP_INSTALL": "YES",
                      "APPLICATION_EXTENSION_API_ONLY": "YES",
                      "SWIFT_EMIT_LOC_STRINGS": "YES", "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
                      "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]}
extension_configs = configs("Extension", extension_settings)
add("ExtensionTarget", "PBXNativeTarget", buildConfigurationList=extension_configs, buildPhases=[extension_phase, extension_resources], buildRules=[], dependencies=[],
    name="iPadnLiveActivity", productName="iPadnLiveActivity", productReference=extension_product,
    productType="com.apple.product-type.app-extension")
extension_proxy = add("ExtensionProxy", "PBXContainerItemProxy", containerPortal=uid("Project"), proxyType="1", remoteGlobalIDString=extension_id, remoteInfo="iPadnLiveActivity")
objects[app_id]["dependencies"].append(add("ExtensionDependency", "PBXTargetDependency", target=extension_id, targetProxy=extension_proxy))
embed = add("EmbedExtension", "PBXBuildFile", fileRef=extension_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
objects[app_id]["buildPhases"].append(add("EmbedExtensions", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="",
    dstSubfolderSpec="13", files=[embed], name="Embed Foundation Extensions", runOnlyForDeploymentPostprocessing="0"))
# A separately installed runner is required on stock iOS. Keep its app inside
# a ZIP resource (HelperTemplate.ipa), not as nested executable code in iPadn.
runner_id = uid("DecrypterRunnerTarget")
runner_product = add("DecrypterRunnerProduct", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path="DecrypterRunner.app", sourceTree="BUILT_PRODUCTS_DIR")
objects[products]["children"].append(runner_product)
core_group = add("DecrypterCoreGroup", "PBXGroup", children=decrypter_core_refs, path="Decrypter/Core", sourceTree="<group>")
runner_files, runner_sources, runner_resources = [], [], []
for reference in decrypter_core_files:
    runner_sources.append(add("Decrypter/RunnerCoreBuild/" + reference, "PBXBuildFile", fileRef=reference))
for path in sorted((ROOT / "Decrypter/Runner").rglob("*")):
    if not path.is_file() or path.suffix not in {".swift", ".png", ".h", ".plist"}: continue
    relative = path.relative_to(ROOT / "Decrypter/Runner").as_posix()
    kind = {".swift":"sourcecode.swift", ".png":"image.png", ".h":"sourcecode.c.h", ".plist":"text.plist.xml"}[path.suffix]
    reference = add("Decrypter/Runner/" + relative, "PBXFileReference", lastKnownFileType=kind, path=relative, sourceTree="<group>")
    runner_files.append(reference)
    if path.suffix == ".swift": runner_sources.append(add("Decrypter/RunnerBuild/" + relative, "PBXBuildFile", fileRef=reference))
    if path.suffix == ".png": runner_resources.append(add("Decrypter/RunnerResource/" + relative, "PBXBuildFile", fileRef=reference))
runner_group = add("DecrypterRunnerGroup", "PBXGroup", children=runner_files, path="Decrypter/Runner", sourceTree="<group>")
objects[root_group]["children"].extend([core_group, runner_group])
runner_source_phase = add("DecrypterRunnerSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=runner_sources, runOnlyForDeploymentPostprocessing="0")
runner_resource_phase = add("DecrypterRunnerResources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=runner_resources, runOnlyForDeploymentPostprocessing="0")
runner_framework_phase = add("DecrypterRunnerFrameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
runner_settings = {"PRODUCT_BUNDLE_IDENTIFIER":"com.w3b32.ipadn.decrypter.runner", "PRODUCT_NAME":"DecrypterRunner", "IPHONEOS_DEPLOYMENT_TARGET":"17.4", "TARGETED_DEVICE_FAMILY":"1,2", "INFOPLIST_FILE":"Decrypter/Runner/Info.plist", "SWIFT_OBJC_BRIDGING_HEADER":"Decrypter/Runner/Bridging.h", "GENERATE_INFOPLIST_FILE":"NO", "CODE_SIGN_STYLE":"Automatic", "CODE_SIGNING_ALLOWED":"NO", "CODE_SIGNING_REQUIRED":"NO", "CODE_SIGN_IDENTITY":"", "SKIP_INSTALL":"YES", "DEVELOPMENT_TEAM":"", "OTHER_LDFLAGS":["$(inherited)", "-lz"]}
runner_configs = configs("DecrypterRunner", runner_settings)
add("DecrypterRunnerTarget", "PBXNativeTarget", buildConfigurationList=runner_configs, buildPhases=[runner_source_phase, runner_framework_phase, runner_resource_phase], buildRules=[], dependencies=[], name="DecrypterRunner", productName="DecrypterRunner", productReference=runner_product, productType="com.apple.product-type.application")
runner_proxy = add("DecrypterRunnerProxy", "PBXContainerItemProxy", containerPortal=uid("Project"), proxyType="1", remoteGlobalIDString=runner_id, remoteInfo="DecrypterRunner")
objects[app_id]["dependencies"].append(add("DecrypterRunnerDependency", "PBXTargetDependency", target=runner_id, targetProxy=runner_proxy))
runner_package_phase = add("PackageDecrypterRunner", "PBXShellScriptBuildPhase", buildActionMask="2147483647", files=[],
    inputPaths=["$(SRCROOT)/scripts/package_decrypter_runner.py", "$(BUILT_PRODUCTS_DIR)/DecrypterRunner.app/Info.plist"],
    outputPaths=["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/HelperTemplate.ipa"],
    name="Embed unsigned Decrypter runner template", runOnlyForDeploymentPostprocessing="0", shellPath="/bin/bash", alwaysOutOfDate="1",
    shellScript='set -euo pipefail\nif [ "$PLATFORM_NAME" != "iphoneos" ]; then exit 0; fi\npython3 "$SRCROOT/scripts/package_decrypter_runner.py" "$BUILT_PRODUCTS_DIR/DecrypterRunner.app" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/HelperTemplate.ipa"\n')
objects[app_id]["buildPhases"].append(runner_package_phase)
project_id = add("Project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "1", "LastUpgradeCheck": "1600",
    "TargetAttributes": {app_id: {"CreatedOnToolsVersion": "16.0"}, test_id: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_id}}},
    # English is the fallback for devices whose language the app doesn't ship,
    # while the Chinese source strings stay the keys of the string catalogs.
    buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion=OPTIONS.development_language,
    hasScannedForEncodings="0", knownRegions=["zh-Hans", "en", "zh-Hant", "ja", "ko", "ru", "es", "fr", "de", "pt-BR", "ar", "Base"], mainGroup=root_group, productRefGroup=products,
    projectDirPath="", projectRoot="", targets=[app_id, test_id, ui_id, extension_id, runner_id], packageReferences=[package])

def render(value, indent=0):
    tab = "\t" * indent
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (indent + 1) + render(str(k)) + " = " + render(v, indent + 1) + ";\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (indent + 1) + render(v, indent + 1) + ",\n" for v in value) + tab + ")"
    text = str(value)
    return text if re.fullmatch(r"[A-Za-z0-9_.]+", text) else json.dumps(text, ensure_ascii=False)

project = {"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project_id}
directory = ROOT / "iPadn.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render(project) + "\n")

scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
build_action = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
entries = ET.SubElement(build_action, "BuildActionEntries")
def buildable(parent, ident, name, product):
    return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=ident,
                         BuildableName=product, BlueprintName=name, ReferencedContainer="container:iPadn.xcodeproj")
entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
buildable(entry, app_id, "iPadn", "iPadn.app")
tests = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn", shouldUseLaunchSchemeArgsEnv="YES")
testable = ET.SubElement(ET.SubElement(tests, "Testables"), "TestableReference", skipped="NO")
buildable(testable, test_id, "iPadnTests", "iPadnTests.xctest")
ui_testable = ET.SubElement(tests.find("Testables"), "TestableReference", skipped="NO")
buildable(ui_testable, ui_id, "iPadnUITests", "iPadnUITests.xctest")
launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
buildable(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), app_id, "iPadn", "iPadn.app")
profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
buildable(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), app_id, "iPadn", "iPadn.app")
ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
ET.indent(scheme)
scheme_dir = directory / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "iPadn.xcscheme").write_bytes(ET.tostring(scheme, encoding="utf-8", xml_declaration=True))
workspace = directory / "project.xcworkspace"
workspace.mkdir(exist_ok=True)
(workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')

info = {"CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)", "CFBundleDisplayName": "iPadn", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSRequiresIPhoneOS": True, "UILaunchScreen": {}, "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "CFBundleURLTypes": [{"CFBundleURLName": "app.local.iPadn", "CFBundleURLSchemes": ["ipadn"]}],
        "LSApplicationQueriesSchemes": ["itms-services"],
        # audio keeps iPadn answering while the user pairs in Settings (on-device pairing only).
        "UIBackgroundModes": ["fetch", "audio"], "BGTaskSchedulerPermittedIdentifiers": ["app.local.iPadn.update-check"],
        "NSSupportsLiveActivities": True,
        "CADisableMinimumFrameDurationOnPhone": True,
        "CFBundleIcons": {"CFBundleAlternateIcons": {name: {"CFBundleIconFiles": [name + "60x60"], "UIPrerenderedIcon": False}
                                                    for name in ALTERNATE_ICONS}},
        "CFBundleIcons~ipad": {"CFBundleAlternateIcons": {name: {"CFBundleIconFiles": [name + "60x60", name + "76x76", name + "83x83"], "UIPrerenderedIcon": False}
                                                         for name in ALTERNATE_ICONS}},
        "CFBundleDocumentTypes": [{"CFBundleTypeName": "IPA 安装包", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
                                   "LSItemContentTypes": ["com.apple.itunes.ipa", "public.zip-archive"]}],
        "UTImportedTypeDeclarations": [{"UTTypeIdentifier": "com.apple.itunes.ipa", "UTTypeDescription": "iOS App Archive",
                                        "UTTypeConformsTo": ["public.zip-archive"], "UTTypeTagSpecification": {"public.filename-extension": ["ipa"]}}],
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True,
                                    "NSExceptionDomains": {"127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True}}},
        "NSLocalNetworkUsageDescription": "通过本机回环地址加载签名资源和提供安装包文件，并查找本机的安装服务。",
        # Native installation finds this device's remote pairing port, and on
        # iOS 27 advertises iPadn as a computer the device can pair with.
        "NSBonjourServices": ["_remotepairing._tcp", "_remotepairing-pairable-host._tcp"]}
(ROOT / "iPadn/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
privacy = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
           "NSPrivacyAccessedAPITypes": [
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]},
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons": ["C617.1"]},
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace", "NSPrivacyAccessedAPITypeReasons": ["85F4.1"]},
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime", "NSPrivacyAccessedAPITypeReasons": ["35F9.1"]}
           ]}
(ROOT / "iPadn/Resources/PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(privacy, sort_keys=False))
print(f"Generated {directory.name}: {len(sources)} app sources, {len(test_sources)} test source, {len(objects)} project objects")
