#!/usr/bin/env python3
"""Prepare an isolated iPhone test app from the example project without editing it."""
import json
from pathlib import Path
import plistlib
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "build" / "device-smoke-project"
BUNDLE = "com.timoliver.WebServerKitDeviceSmoke"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name in ("Sources", "Framework"):
        destination = OUTPUT / name
        if destination.exists():
            assert destination.is_symlink() and destination.resolve() == ROOT / name
        else:
            destination.symlink_to(ROOT / name, target_is_directory=True)
    example = OUTPUT / "Examples" / "iOS"
    shutil.copytree(ROOT / "Examples" / "iOS", example, dirs_exist_ok=True)
    shutil.copy2(ROOT / "Scripts" / "DeviceSmoke" / "ViewController.swift", example / "ViewController.swift")
    # The current SDK requires a scene lifecycle on iOS 27. Keep this change in
    # the generated probe; the shipping example is not modified by preparation.
    delegate = example / "AppDelegate.swift"
    delegate.write_text(delegate.read_text() + '\nfinal class SceneDelegate: UIResponder, UIWindowSceneDelegate {\n  var window: UIWindow?\n}\n')
    info_path = example / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleDisplayName="WSK Device Test",
                NSLocalNetworkUsageDescription="Test HTTP and WebDAV transfers with your Mac on this local network.",
                NSBonjourServices=["_http._tcp", "_webdav._tcp"])
    info.pop("UIMainStoryboardFile", None)
    info["UIApplicationSceneManifest"] = {
        "UIApplicationSupportsMultipleScenes": False,
        "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{
            "UISceneConfigurationName": "Device Smoke",
            "UISceneDelegateClassName": "$(PRODUCT_MODULE_NAME).SceneDelegate",
            "UISceneStoryboardFile": "Main",
        }]},
    }
    info_path.write_bytes(plistlib.dumps(info))
    project = OUTPUT / "WebServerKit.xcodeproj"
    project.mkdir(exist_ok=True)
    source = (ROOT / "WebServerKit.xcodeproj" / "project.pbxproj").read_text()
    # Only the iOS example's two configurations: keep the framework's identity.
    for identifier in ("E2DDD20B1BE69EE5002CE867", "E2DDD20C1BE69EE5002CE867"):
        expression = rf"({identifier} /\* (?:Debug|Release) \*/ = \{{.*?buildSettings = \{{)(.*?)(\n\t\t\t\}};)"
        match = re.search(expression, source, re.S)
        assert match, identifier
        settings = match.group(2).replace('"net.pol-online.WebServerKitExample"', '"' + BUNDLE + '"')
        settings = '\n\t\t\t\tCODE_SIGN_STYLE = Automatic;' + settings
        source = source[:match.start(2)] + settings + source[match.end(2):]
    (project / "project.pbxproj").write_text(source)
    print(json.dumps({"project": str(project), "bundle_id": BUNDLE,
                      "scheme": "WebServerKit Example (iOS)"}))


if __name__ == "__main__":
    main()
