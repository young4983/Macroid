#!/usr/bin/env python3
"""Deterministic Xcode project generation; no third-party generator dependency."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1] / 'macos'
sources = sorted(p.name for p in (root / 'Sources').glob('*.swift'))
resources = ['Macroid.apk', 'adb', 'adb-NOTICE.txt', 'Macroid.icns', 'THIRD_PARTY_NOTICES.md', 'scrcpy-Apache-2.0.txt']
localized_resources = ['Localizable.strings', 'InfoPlist.strings']
languages = ['en', 'zh-Hans']
def uid(value): return hashlib.sha256(value.encode()).hexdigest()[:24].upper()
def obj(key, body): return f'{uid(key)} = {{ {body} }};'
def refs(values): return '(' + ', '.join(uid(v) for v in values) + ',)'

objects = []
for name in sources:
    objects += [obj('src-' + name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{name}"; sourceTree = "<group>";'),
                obj('build-' + name, f'isa = PBXBuildFile; fileRef = {uid("src-" + name)};')]
for name in resources:
    objects += [obj('res-' + name, f'isa = PBXFileReference; lastKnownFileType = file; path = "{name}"; sourceTree = "<group>";'),
                obj('build-' + name, f'isa = PBXBuildFile; fileRef = {uid("res-" + name)};')]
for name in localized_resources:
    for language in languages:
        objects.append(obj(f'res-{language}-{name}', f'isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = "{language}"; path = "{language}.lproj/{name}"; sourceTree = "<group>";'))
    objects += [obj('res-' + name, f'isa = PBXVariantGroup; name = "{name}"; sourceTree = "<group>"; children = ' + refs([f'res-{language}-{name}' for language in languages]) + ';'),
                obj('build-' + name, f'isa = PBXBuildFile; fileRef = {uid("res-" + name)};')]
resources += localized_resources
objects += [obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Macroid.app; sourceTree = BUILT_PRODUCTS_DIR;'),
            obj('sources', 'isa = PBXGroup; path = Sources; sourceTree = "<group>"; children = ' + refs(['src-' + n for n in sources]) + ';'),
            obj('resources', 'isa = PBXGroup; path = Resources; sourceTree = "<group>"; children = ' + refs(['res-' + n for n in resources]) + ';'),
            obj('products', 'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ' + refs(['product']) + ';'),
            obj('main', 'isa = PBXGroup; sourceTree = "<group>"; children = ' + refs(['sources', 'resources', 'products']) + ';'),
            obj('sources-phase', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ' + refs(['build-' + n for n in sources]) + '; runOnlyForDeploymentPostprocessing = 0;'),
            obj('resource-phase', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ' + refs(['build-' + n for n in resources]) + '; runOnlyForDeploymentPostprocessing = 0;'),
            obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')]
for config in ['Debug', 'Release']:
    common = 'CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 13.0; SDKROOT = macosx; SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = minimal;'
    objects.append(obj('project-' + config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {common} }};'))
    settings = 'PRODUCT_NAME = Macroid; PRODUCT_BUNDLE_IDENTIFIER = io.macroid.desktop; INFOPLIST_FILE = Info.plist; GENERATE_INFOPLIST_FILE = NO; ENABLE_APP_SANDBOX = NO; CODE_SIGN_STYLE = Automatic; COMBINE_HIDPI_IMAGES = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";'
    settings += ' SWIFT_OPTIMIZATION_LEVEL = ' + ('"-Onone"; DEBUG_INFORMATION_FORMAT = dwarf;' if config == 'Debug' else '"-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
    objects.append(obj('target-' + config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {settings} }};'))
objects += [obj('project-configs', 'isa = XCConfigurationList; buildConfigurations = ' + refs(['project-Debug', 'project-Release']) + '; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;'),
            obj('target-configs', 'isa = XCConfigurationList; buildConfigurations = ' + refs(['target-Debug', 'target-Release']) + '; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;'),
            obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("target-configs")}; buildPhases = {refs(["sources-phase", "frameworks", "resource-phase"])}; buildRules = (); dependencies = (); name = Macroid; productName = Macroid; productReference = {uid("product")}; productType = "com.apple.product-type.application";'),
            obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2610; }}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, "zh-Hans", Base); mainGroup = {uid("main")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["target"])};')]
project = root / 'Macroid.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')
schemes = project / 'xcshareddata' / 'xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="Macroid.app" BlueprintName="Macroid" ReferencedContainer="container:Macroid.xcodeproj"/>'
(schemes / 'Macroid.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2610" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
