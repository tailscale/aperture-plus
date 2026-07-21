#!/usr/bin/env python3
"""Add an ApertureUITests UI-test target to Aperture.xcodeproj.

The project uses Xcode synchronized folder groups, so a new `UITests/`
PBXFileSystemSynchronizedRootGroup handles compilation membership automatically
(like the existing App/ and TSNet/ groups) — no per-file PBXBuildFile entries.

Run once:
    python3 scripts/add_uitest_target.py
"""
import sys
from pathlib import Path

PROJ = Path("Aperture.xcodeproj/project.pbxproj")
T = "\t"

# New 24-char hex object IDs (project-local, non-conflicting with existing C2... IDs).
UITestsGroup      = "F10000010000000000000001"  # PBXFileSystemSynchronizedRootGroup
XctestProduct     = "F10000020000000000000002"  # PBXFileReference (.xctest)
SourcesPhase      = "F10000030000000000000003"  # PBXSourcesBuildPhase
FrameworksPhase   = "F10000040000000000000004"  # PBXFrameworksBuildPhase
ResourcesPhase    = "F10000050000000000000005"  # PBXResourcesBuildPhase
NativeTarget      = "F10000060000000000000006"  # PBXNativeTarget
ContainerProxy    = "F10000070000000000000007"  # PBXContainerItemProxy
TargetDep         = "F10000080000000000000008"  # PBXTargetDependency
ConfigList        = "F10000090000000000000009"  # XCConfigurationList
DebugCfg          = "F100000A000000000000000A"  # XCBuildConfiguration
ReleaseCfg        = "F100000B000000000000000B"  # XCBuildConfiguration

# Existing IDs we reference.
AppTarget  = "C20F24732EF19A5900F57D67"   # Aperture native target
ProjObject = "C213B9832EE8BF80002D0531"   # Project object


def insert_before(content, anchor, block):
    assert anchor in content, f"anchor not found: {anchor[:60]}"
    assert content.count(anchor) == 1, f"anchor not unique: {anchor[:60]}"
    return content.replace(anchor, block + anchor, 1)


def insert_after(content, anchor, block):
    assert anchor in content, f"anchor not found: {anchor[:60]}"
    assert content.count(anchor) == 1, f"anchor not unique: {anchor[:60]}"
    return content.replace(anchor, anchor + block, 1)


def main():
    content = PROJ.read_text()

    if NativeTarget in content:
        print("UI test target already present; aborting to avoid duplicates.")
        return 0

    # --- 1. PBXContainerItemProxy (new section) before PBXCopyFilesBuildPhase ---
    proxy = (
        "/* Begin PBXContainerItemProxy section */\n"
        f"{T}{T}{ContainerProxy} /* PBXContainerItemProxy */ = {{\n"
        f"{T}{T}{T}isa = PBXContainerItemProxy;\n"
        f"{T}{T}{T}containerPortal = {ProjObject} /* Project object */;\n"
        f"{T}{T}{T}proxyType = 1;\n"
        f"{T}{T}{T}remoteGlobalIDString = {AppTarget} /* Aperture */;\n"
        f"{T}{T}{T}remoteInfo = Aperture;\n"
        f"{T}{T}}};\n"
        "/* End PBXContainerItemProxy section */\n\n"
    )
    content = insert_before(content, "/* Begin PBXCopyFilesBuildPhase section */", proxy)

    # --- 2. PBXFileReference: add .xctest product after Aperture.app ---
    # NOTE: every segment is an f-string so that `{{`/`}}` map to `{`/`}`.
    # Mixing f-string and plain segments would leave doubled braces.
    app_ref = (
        f"{T}{T}C20F24742EF19A5900F57D67 /* Aperture.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; path = Aperture.app; "
        f"sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    xctest_ref = (
        f"\n{T}{T}{XctestProduct} /* ApertureUITests.xctest */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ApertureUITests.xctest; "
        f"sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    content = insert_after(content, app_ref, xctest_ref)

    # --- 3. PBXFileSystemSynchronizedRootGroup: add UITests group ---
    uigroup = (
        f"\n{T}{T}{UITestsGroup} /* UITests */ = {{\n"
        f"{T}{T}{T}isa = PBXFileSystemSynchronizedRootGroup;\n"
        f"{T}{T}{T}path = UITests;\n"
        f"{T}{T}{T}sourceTree = \"<group>\";\n"
        f"{T}{T}}};"
    )
    content = insert_before(
        content,
        "/* End PBXFileSystemSynchronizedRootGroup section */",
        uigroup,
    )

    # --- 4. PBXFrameworksBuildPhase: add UITest frameworks phase ---
    fwphase = (
        f"\n{T}{T}{FrameworksPhase} /* Frameworks */ = {{\n"
        f"{T}{T}{T}isa = PBXFrameworksBuildPhase;\n"
        f"{T}{T}{T}buildActionMask = 2147483647;\n"
        f"{T}{T}{T}files = (\n"
        f"{T}{T}{T});\n"
        f"{T}{T}{T}runOnlyForDeploymentPostprocessing = 0;\n"
        f"{T}{T}}};"
    )
    content = insert_before(content, "/* End PBXFrameworksBuildPhase section */", fwphase)

    # --- 5. PBXGroup: add UITests to main group children; .xctest to Products ---
    main_children_old = (
        f"{T}{T}{T}C20F24932EF1B4A700F57D67 /* TSNet */,\n"
        f"{T}{T}{T}C213B98C2EE8BF80002D0531 /* Products */,"
    )
    main_children_new = (
        f"{T}{T}{T}C20F24932EF1B4A700F57D67 /* TSNet */,\n"
        f"{T}{T}{T}{UITestsGroup} /* UITests */,\n"
        f"{T}{T}{T}C213B98C2EE8BF80002D0531 /* Products */,"
    )
    content = content.replace(main_children_old, main_children_new, 1)

    products_old = (
        f"{T}{T}{T}C20F24742EF19A5900F57D67 /* Aperture.app */,\n"
        f"{T}{T}{T});"
    )
    products_new = (
        f"{T}{T}{T}C20F24742EF19A5900F57D67 /* Aperture.app */,\n"
        f"{T}{T}{T}{XctestProduct} /* ApertureUITests.xctest */,\n"
        f"{T}{T}{T});"
    )
    # This children-list pattern (app, then `);`) is unique to the Products group.
    content = content.replace(products_old, products_new, 1)

    # --- 6. PBXNativeTarget: add the UITest target ---
    native_target = (
        f"\n{T}{T}{NativeTarget} /* ApertureUITests */ = {{\n"
        f"{T}{T}{T}isa = PBXNativeTarget;\n"
        f"{T}{T}{T}buildConfigurationList = {ConfigList} /* Build configuration list for PBXNativeTarget \"ApertureUITests\" */;\n"
        f"{T}{T}{T}buildPhases = (\n"
        f"{T}{T}{T}{T}{SourcesPhase} /* Sources */,\n"
        f"{T}{T}{T}{T}{FrameworksPhase} /* Frameworks */,\n"
        f"{T}{T}{T}{T}{ResourcesPhase} /* Resources */,\n"
        f"{T}{T}{T});\n"
        f"{T}{T}{T}buildRules = (\n"
        f"{T}{T}{T});\n"
        f"{T}{T}{T}dependencies = (\n"
        f"{T}{T}{T}{T}{TargetDep} /* PBXTargetDependency */,\n"
        f"{T}{T}{T});\n"
        f"{T}{T}{T}fileSystemSynchronizedGroups = (\n"
        f"{T}{T}{T}{T}{UITestsGroup} /* UITests */,\n"
        f"{T}{T}{T});\n"
        f"{T}{T}{T}name = ApertureUITests;\n"
        f"{T}{T}{T}packageProductDependencies = (\n"
        f"{T}{T}{T});\n"
        f"{T}{T}{T}productName = ApertureUITests;\n"
        f"{T}{T}{T}productReference = {XctestProduct} /* ApertureUITests.xctest */;\n"
        f"{T}{T}{T}productType = \"com.apple.product-type.bundle.ui-testing\";\n"
        f"{T}{T}}};"
    )
    content = insert_before(content, "/* End PBXNativeTarget section */", native_target)

    # --- 7. PBXProject: add target to `targets` array + TargetAttributes ---
    targets_old = (
        f"{T}{T}{T}targets = (\n"
        f"{T}{T}{T}{T}{AppTarget} /* Aperture */,\n"
        f"{T}{T}{T});"
    )
    targets_new = (
        f"{T}{T}{T}targets = (\n"
        f"{T}{T}{T}{T}{AppTarget} /* Aperture */,\n"
        f"{T}{T}{T}{T}{NativeTarget} /* ApertureUITests */,\n"
        f"{T}{T}{T});"
    )
    content = content.replace(targets_old, targets_new, 1)

    attrs_old = (
        f"{T}{T}{T}TargetAttributes = {{\n"
        f"{T}{T}{T}{T}{AppTarget} = {{\n"
        f"{T}{T}{T}{T}{T}CreatedOnToolsVersion = 26.0;\n"
        f"{T}{T}{T}{T}}};\n"
        f"{T}{T}{T}}};"
    )
    attrs_new = (
        f"{T}{T}{T}TargetAttributes = {{\n"
        f"{T}{T}{T}{T}{AppTarget} = {{\n"
        f"{T}{T}{T}{T}{T}CreatedOnToolsVersion = 26.0;\n"
        f"{T}{T}{T}{T}}};\n"
        f"{T}{T}{T}{T}{NativeTarget} = {{\n"
        f"{T}{T}{T}{T}{T}CreatedOnToolsVersion = 26.0;\n"
        f"{T}{T}{T}{T}{T}TestTargetID = {AppTarget} /* Aperture */;\n"
        f"{T}{T}{T}{T}}};\n"
        f"{T}{T}{T}}};"
    )
    content = content.replace(attrs_old, attrs_new, 1)

    # --- 8. PBXResourcesBuildPhase: add UITest resources phase ---
    resphase = (
        f"\n{T}{T}{ResourcesPhase} /* Resources */ = {{\n"
        f"{T}{T}{T}isa = PBXResourcesBuildPhase;\n"
        f"{T}{T}{T}buildActionMask = 2147483647;\n"
        f"{T}{T}{T}files = (\n"
        f"{T}{T}{T});\n"
        f"{T}{T}{T}runOnlyForDeploymentPostprocessing = 0;\n"
        f"{T}{T}}};"
    )
    content = insert_before(content, "/* End PBXResourcesBuildPhase section */", resphase)

    # --- 9. PBXSourcesBuildPhase: add UITest sources phase ---
    srcphase = (
        f"\n{T}{T}{SourcesPhase} /* Sources */ = {{\n"
        f"{T}{T}{T}isa = PBXSourcesBuildPhase;\n"
        f"{T}{T}{T}buildActionMask = 2147483647;\n"
        f"{T}{T}{T}files = (\n"
        f"{T}{T}{T});\n"
        f"{T}{T}{T}runOnlyForDeploymentPostprocessing = 0;\n"
        f"{T}{T}}};"
    )
    content = insert_before(content, "/* End PBXSourcesBuildPhase section */", srcphase)

    # --- 10. PBXTargetDependency (new section) before XCBuildConfiguration ---
    tdep = (
        "/* Begin PBXTargetDependency section */\n"
        f"{T}{T}{TargetDep} /* PBXTargetDependency */ = {{\n"
        f"{T}{T}{T}isa = PBXTargetDependency;\n"
        f"{T}{T}{T}target = {AppTarget} /* Aperture */;\n"
        f"{T}{T}{T}targetProxy = {ContainerProxy} /* PBXContainerItemProxy */;\n"
        f"{T}{T}}};\n"
        "/* End PBXTargetDependency section */\n\n"
    )
    content = insert_before(content, "/* Begin XCBuildConfiguration section */", tdep)

    # --- 11. XCBuildConfiguration: add Debug + Release configs for UITest target ---
    debug_cfg = (
        f"\n{T}{T}{DebugCfg} /* Debug */ = {{\n"
        f"{T}{T}{T}isa = XCBuildConfiguration;\n"
        f"{T}{T}{T}buildSettings = {{\n"
        f"{T}{T}{T}{T}CODE_SIGN_STYLE = Automatic;\n"
        f"{T}{T}{T}{T}CURRENT_PROJECT_VERSION = 1;\n"
        f"{T}{T}{T}{T}DEVELOPMENT_TEAM = W5364U7YZB;\n"
        f"{T}{T}{T}{T}ENABLE_USER_SCRIPT_SANDBOXING = NO;\n"
        f"{T}{T}{T}{T}GENERATE_INFOPLIST_FILE = YES;\n"
        f"{T}{T}{T}{T}MARKETING_VERSION = 1.0;\n"
        f"{T}{T}{T}{T}PRODUCT_BUNDLE_IDENTIFIER = io.tailscale.Aperture.UITests;\n"
        f"{T}{T}{T}{T}PRODUCT_NAME = \"$(TARGET_NAME)\";\n"
        f"{T}{T}{T}{T}SWIFT_EMIT_LOC_STRINGS = NO;\n"
        f"{T}{T}{T}{T}SWIFT_VERSION = 6.0;\n"
        f"{T}{T}{T}{T}TARGETED_DEVICE_FAMILY = \"1,2\";\n"
        f"{T}{T}{T}{T}TEST_TARGET_NAME = Aperture;\n"
        f"{T}{T}{T}}};\n"
        f"{T}{T}{T}name = Debug;\n"
        f"{T}{T}}};"
    )
    release_cfg = (
        f"\n{T}{T}{ReleaseCfg} /* Release */ = {{\n"
        f"{T}{T}{T}isa = XCBuildConfiguration;\n"
        f"{T}{T}{T}buildSettings = {{\n"
        f"{T}{T}{T}{T}CODE_SIGN_STYLE = Automatic;\n"
        f"{T}{T}{T}{T}CURRENT_PROJECT_VERSION = 1;\n"
        f"{T}{T}{T}{T}DEVELOPMENT_TEAM = W5364U7YZB;\n"
        f"{T}{T}{T}{T}ENABLE_USER_SCRIPT_SANDBOXING = NO;\n"
        f"{T}{T}{T}{T}GENERATE_INFOPLIST_FILE = YES;\n"
        f"{T}{T}{T}{T}MARKETING_VERSION = 1.0;\n"
        f"{T}{T}{T}{T}PRODUCT_BUNDLE_IDENTIFIER = io.tailscale.Aperture.UITests;\n"
        f"{T}{T}{T}{T}PRODUCT_NAME = \"$(TARGET_NAME)\";\n"
        f"{T}{T}{T}{T}SWIFT_EMIT_LOC_STRINGS = NO;\n"
        f"{T}{T}{T}{T}SWIFT_VERSION = 6.0;\n"
        f"{T}{T}{T}{T}TARGETED_DEVICE_FAMILY = \"1,2\";\n"
        f"{T}{T}{T}{T}TEST_TARGET_NAME = Aperture;\n"
        f"{T}{T}{T}}};\n"
        f"{T}{T}{T}name = Release;\n"
        f"{T}{T}}};"
    )
    content = insert_before(content, "/* End XCBuildConfiguration section */", debug_cfg + release_cfg)

    # --- 12. XCConfigurationList: add config list for UITest target ---
    cfglist = (
        f"\n{T}{T}{ConfigList} /* Build configuration list for PBXNativeTarget \"ApertureUITests\" */ = {{\n"
        f"{T}{T}{T}isa = XCConfigurationList;\n"
        f"{T}{T}{T}buildConfigurations = (\n"
        f"{T}{T}{T}{T}{DebugCfg} /* Debug */,\n"
        f"{T}{T}{T}{T}{ReleaseCfg} /* Release */,\n"
        f"{T}{T}{T});\n"
        f"{T}{T}{T}defaultConfigurationIsVisible = 0;\n"
        f"{T}{T}{T}defaultConfigurationName = Release;\n"
        f"{T}{T}}};"
    )
    content = insert_before(content, "/* End XCConfigurationList section */", cfglist)

    PROJ.write_text(content)
    print(f"Wrote {PROJ} ({len(content)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
