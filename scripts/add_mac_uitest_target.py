#!/usr/bin/env python3
"""Add the native ApertureMacUITests target to project.pbxproj."""
from pathlib import Path

p = Path("Aperture.xcodeproj/project.pbxproj")
s = p.read_text()
if "B10000050000000000000005" in s:
    print("Mac UI test target already present")
    raise SystemExit

def before(anchor, text):
    global s
    assert s.count(anchor) == 1, (anchor, s.count(anchor))
    s = s.replace(anchor, text + anchor)

def after(anchor, text):
    global s
    assert s.count(anchor) == 1, (anchor, s.count(anchor))
    s = s.replace(anchor, anchor + text)

before("/* End PBXContainerItemProxy section */", '''\t\tB10000010000000000000001 /* PBXContainerItemProxy */ = {
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = C213B9832EE8BF80002D0531 /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = A10000080000000000000008;
\t\t\tremoteInfo = ApertureMac;
\t\t};
''')
before("/* End PBXFileReference section */", '\t\tB10000020000000000000002 /* ApertureMacUITests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ApertureMacUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };\n')
before("/* End PBXFileSystemSynchronizedRootGroup section */", '''\t\tB10000030000000000000003 /* MacUITests */ = {
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = MacUITests;
\t\t\tsourceTree = "<group>";
\t\t};
''')
before("/* End PBXFrameworksBuildPhase section */", '''\t\tB10000040000000000000004 /* Frameworks */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = ();
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
''')
after('''\t\tC3F3B102300FBE9600CF6CB4 /* Recovered References */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tF10000010000000000000001 /* UITests */,
''', '\t\t\t\tB10000030000000000000003 /* MacUITests */,\n')
after('\t\t\t\tF10000020000000000000002 /* ApertureUITests.xctest */,\n', '\t\t\t\tB10000020000000000000002 /* ApertureMacUITests.xctest */,\n')
before("/* End PBXNativeTarget section */", '''\t\tB10000050000000000000005 /* ApertureMacUITests */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = B100000A000000000000000A /* Build configuration list for PBXNativeTarget "ApertureMacUITests" */;
\t\t\tbuildPhases = (
\t\t\t\tB10000060000000000000006 /* Sources */,
\t\t\t\tB10000040000000000000004 /* Frameworks */,
\t\t\t\tB10000070000000000000007 /* Resources */,
\t\t\t);
\t\t\tbuildRules = ();
\t\t\tdependencies = (B10000080000000000000008 /* PBXTargetDependency */,);
\t\t\tfileSystemSynchronizedGroups = (B10000030000000000000003 /* MacUITests */,);
\t\t\tname = ApertureMacUITests;
\t\t\tpackageProductDependencies = ();
\t\t\tproductName = ApertureMacUITests;
\t\t\tproductReference = B10000020000000000000002 /* ApertureMacUITests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.ui-testing";
\t\t};
''')
after('''\t\t\t\t\tA10000080000000000000008 = {
\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;
\t\t\t\t\t};
''', '''\t\t\t\t\tB10000050000000000000005 = {
\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;
\t\t\t\t\t\tTestTargetID = A10000080000000000000008;
\t\t\t\t\t};
''')
after('\t\t\t\tF10000060000000000000006 /* ApertureUITests */,\n', '\t\t\t\tB10000050000000000000005 /* ApertureMacUITests */,\n')
before("/* End PBXResourcesBuildPhase section */", '''\t\tB10000070000000000000007 /* Resources */ = {
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = ();
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
''')
before("/* End PBXSourcesBuildPhase section */", '''\t\tB10000060000000000000006 /* Sources */ = {
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = ();
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
''')
before("/* End PBXTargetDependency section */", '''\t\tB10000080000000000000008 /* PBXTargetDependency */ = {
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = A10000080000000000000008 /* ApertureMac */;
\t\t\ttargetProxy = B10000010000000000000001 /* PBXContainerItemProxy */;
\t\t};
''')
configs = '''\t\tB10000090000000000000009 /* Debug */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tDEVELOPMENT_TEAM = W5364U7YZB;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = io.tailscale.Aperture.MacUITests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated;
\t\t\t\tSWIFT_STRICT_CONCURRENCY = complete;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tTEST_TARGET_NAME = ApertureMac;
\t\t\t};
\t\t\tname = Debug;
\t\t};
\t\tB100000B000000000000000B /* Release */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tDEVELOPMENT_TEAM = W5364U7YZB;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = io.tailscale.Aperture.MacUITests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated;
\t\t\t\tSWIFT_STRICT_CONCURRENCY = complete;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tTEST_TARGET_NAME = ApertureMac;
\t\t\t};
\t\t\tname = Release;
\t\t};
'''
before("/* End XCBuildConfiguration section */", configs)
before("/* End XCConfigurationList section */", '''\t\tB100000A000000000000000A /* Build configuration list for PBXNativeTarget "ApertureMacUITests" */ = {
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tB10000090000000000000009 /* Debug */,
\t\t\t\tB100000B000000000000000B /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t};
''')
p.write_text(s)
print("Added ApertureMacUITests")
