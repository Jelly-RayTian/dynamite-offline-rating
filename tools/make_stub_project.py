#!/usr/bin/env python3
"""Creates a tiny throw-away Xcode project whose only purpose is to let Xcode
(automatic signing) create the provisioning profile for a given bundle id.
  make_stub_project.py <dir> <bundle-id> <team-id>"""
import os, sys
d, bid, team = sys.argv[1:4]
os.makedirs(os.path.join(d, "Stub.xcodeproj"), exist_ok=True)
open(os.path.join(d, "main.m"), "w").write(
    '#import <UIKit/UIKit.h>\n@interface A : UIResponder <UIApplicationDelegate>\n@property(strong) UIWindow *window;\n@end\n'
    '@implementation A\n- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {\n'
    '  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];\n  self.window.rootViewController = [UIViewController new];\n'
    '  [self.window makeKeyAndVisible];\n  return YES;\n}\n@end\n'
    'int main(int c, char **v) { @autoreleasepool { return UIApplicationMain(c, v, nil, @"A"); } }\n')
open(os.path.join(d, "Info.plist"), "w").write(
    '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    '<plist version="1.0"><dict>\n<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>\n'
    '<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>\n<key>CFBundleName</key><string>Stub</string>\n'
    '<key>CFBundlePackageType</key><string>APPL</string>\n<key>CFBundleShortVersionString</key><string>1.0</string>\n<key>CFBundleVersion</key><string>1</string>\n'
    '<key>UILaunchScreen</key><dict/>\n</dict></plist>\n')
pbx = '''// !$*UTF8*$!
{
	archiveVersion = 1; classes = {}; objectVersion = 56;
	objects = {
		A1 /* main.m in Sources */ = {isa = PBXBuildFile; fileRef = F1; };
		F1 /* main.m */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = main.m; sourceTree = "<group>"; };
		F2 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		F3 /* Stub.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Stub.app; sourceTree = BUILT_PRODUCTS_DIR; };
		G1 = {isa = PBXGroup; children = (F1, F2, G2); sourceTree = "<group>"; };
		G2 /* Products */ = {isa = PBXGroup; children = (F3); name = Products; sourceTree = "<group>"; };
		S1 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A1); runOnlyForDeploymentPostprocessing = 0; };
		T1 /* Stub */ = {isa = PBXNativeTarget; buildConfigurationList = L2; buildPhases = (S1); buildRules = (); dependencies = (); name = Stub; productName = Stub; productReference = F3; productType = "com.apple.product-type.application"; };
		P1 /* Project */ = {isa = PBXProject; attributes = {LastUpgradeCheck = 1600; TargetAttributes = {T1 = {DevelopmentTeam = TEAM;};};}; buildConfigurationList = L1; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = G1; productRefGroup = G2; projectDirPath = ""; projectRoot = ""; targets = (T1); };
		C1 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 13.0; ONLY_ACTIVE_ARCH = YES;}; name = Debug; };
		C2 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = BUNDLEID; INFOPLIST_FILE = Info.plist; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = TEAM; TARGETED_DEVICE_FAMILY = "1,2"; CLANG_ENABLE_OBJC_ARC = YES;}; name = Debug; };
		L1 = {isa = XCConfigurationList; buildConfigurations = (C1); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
		L2 = {isa = XCConfigurationList; buildConfigurations = (C2); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
	};
	rootObject = P1;
}
'''.replace("TEAM", team).replace("BUNDLEID", bid)
open(os.path.join(d, "Stub.xcodeproj", "project.pbxproj"), "w").write(pbx)
print("stub project written to", d)
