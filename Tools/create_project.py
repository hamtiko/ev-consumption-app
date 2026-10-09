"""Regenerate the checked-in Xcode project. No XcodeGen or external dependencies."""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1] / 'ChargeLedger'
objects = {}
def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(object_name, isa, **fields):
    key = ident(object_name)
    objects[key] = {'isa': isa, **fields}
    return key

def render(value, indent=0):
    if isinstance(value, dict):
        lines = ['{']
        for key, item in value.items():
            lines.append('\t' * (indent + 1) + key + ' = ' + render(item, indent + 1) + ';')
        lines.append('\t' * indent + '}')
        return '\n'.join(lines)
    if isinstance(value, list):
        return '(\n' + ''.join('\t' * (indent + 1) + render(item, indent + 1) + ',\n' for item in value) + '\t' * indent + ')'
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)

app_refs, app_build = [], []
for path in sorted((root / 'App').glob('*.swift')):
    ref = add('file:' + path.name, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=path.name, sourceTree='<group>')
    app_refs.append(ref)
    app_build.append(add('build:' + path.name, 'PBXBuildFile', fileRef=ref))
assets = add('assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='Assets.xcassets', sourceTree='<group>')
app_refs.append(assets)
asset_build = add('assets-build', 'PBXBuildFile', fileRef=assets)
app_group = add('app-group', 'PBXGroup', children=app_refs, path='App', sourceTree='<group>')
test_refs, test_build = [], []
for path in [root / 'ChargeLedgerTests/AppTests.swift', root / 'Core/Tests/ChargeLedgerCoreTests/LedgerTests.swift']:
    ref = add('file:' + path.name, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=str(path.relative_to(root)), sourceTree='SOURCE_ROOT')
    test_refs.append(ref)
    test_build.append(add('build:' + path.name, 'PBXBuildFile', fileRef=ref))
test_group = add('test-group', 'PBXGroup', children=test_refs, name='Tests', sourceTree='<group>')
core_folder = add('core-folder', 'PBXFileReference', lastKnownFileType='folder', path='Core', sourceTree='<group>')
app_product = add('app-product', 'PBXFileReference', explicitFileType='wrapper.application', includeInIndex=0, path='ChargeLedger.app', sourceTree='BUILT_PRODUCTS_DIR')
test_product = add('test-product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', includeInIndex=0, path='ChargeLedgerTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products', 'PBXGroup', children=[app_product, test_product], name='Products', sourceTree='<group>')
main = add('main-group', 'PBXGroup', children=[app_group, core_folder, test_group, products], sourceTree='<group>')
package = add('local-core', 'XCLocalSwiftPackageReference', relativePath='Core')
core_product = add('core-product', 'XCSwiftPackageProductDependency', package=package, productName='ChargeLedgerCore')
core_app_build = add('core-app-build', 'PBXBuildFile', productRef=core_product)
core_test_build = add('core-test-build', 'PBXBuildFile', productRef=core_product)
app_sources = add('app-sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=app_build, runOnlyForDeploymentPostprocessing=0)
test_sources = add('test-sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=test_build, runOnlyForDeploymentPostprocessing=0)
app_frameworks = add('app-frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[core_app_build], runOnlyForDeploymentPostprocessing=0)
test_frameworks = add('test-frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[core_test_build], runOnlyForDeploymentPostprocessing=0)
resources = add('resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[asset_build], runOnlyForDeploymentPostprocessing=0)
empty_resources = add('test-resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)

def configurations(name, settings):
    configs = []
    for mode in ['Debug', 'Release']:
        values = dict(settings)
        if name == 'project':
            values.update({'DEBUG_INFORMATION_FORMAT': 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym',
                           'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if mode == 'Debug' else '-O',
                           'SWIFT_COMPILATION_MODE': 'singlefile' if mode == 'Debug' else 'wholemodule'})
            if mode == 'Debug':
                values.update({'ENABLE_TESTABILITY': 'YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG $(inherited)', 'ONLY_ACTIVE_ARCH': 'YES'})
        configs.append(add(name + '-config-' + mode, 'XCBuildConfiguration', buildSettings=values, name=mode))
    return add(name + '-configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

project_configs = configurations('project', {
    'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES', 'SDKROOT': 'iphoneos',
    'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SWIFT_VERSION': '5.0', 'CODE_SIGN_STYLE': 'Automatic',
    'DEVELOPMENT_TEAM': '', 'TARGETED_DEVICE_FAMILY': '1,2', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES'
})
app_configs = configurations('app', {
    'PRODUCT_BUNDLE_IDENTIFIER': 'com.example.ChargeLedger', 'PRODUCT_NAME': '$(TARGET_NAME)',
    'GENERATE_INFOPLIST_FILE': 'YES', 'INFOPLIST_KEY_CFBundleDisplayName': 'Charge Ledger',
    'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone': 'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
    'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad': 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
    'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor',
    'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks',
    'CURRENT_PROJECT_VERSION': '1', 'MARKETING_VERSION': '0.1.0',
    'SWIFT_EMIT_LOC_STRINGS': 'YES', 'SUPPORTS_MACCATALYST': 'NO'
})
test_configs = configurations('tests', {
    'PRODUCT_BUNDLE_IDENTIFIER': 'com.example.ChargeLedgerTests', 'PRODUCT_NAME': '$(TARGET_NAME)',
    'GENERATE_INFOPLIST_FILE': 'YES', 'BUNDLE_LOADER': '$(TEST_HOST)',
    'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/ChargeLedger.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/ChargeLedger',
    'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks @loader_path/Frameworks'
})
app_target = add('app-target', 'PBXNativeTarget', buildConfigurationList=app_configs, buildPhases=[app_sources, app_frameworks, resources], buildRules=[], dependencies=[], name='ChargeLedger', packageProductDependencies=[core_product], productName='ChargeLedger', productReference=app_product, productType='com.apple.product-type.application')
proxy = add('app-proxy', 'PBXContainerItemProxy', containerPortal=ident('project'), proxyType=1, remoteGlobalIDString=app_target, remoteInfo='ChargeLedger')
dep = add('app-dependency', 'PBXTargetDependency', target=app_target, targetProxy=proxy)
test_target = add('test-target', 'PBXNativeTarget', buildConfigurationList=test_configs, buildPhases=[test_sources, test_frameworks, empty_resources], buildRules=[], dependencies=[dep], name='ChargeLedgerTests', packageProductDependencies=[core_product], productName='ChargeLedgerTests', productReference=test_product, productType='com.apple.product-type.bundle.unit-test')
project = add('project', 'PBXProject', attributes={'BuildIndependentTargetsInParallel': 'YES', 'LastUpgradeCheck': '1600', 'TargetAttributes': {app_target: {'CreatedOnToolsVersion': '16.0'}, test_target: {'CreatedOnToolsVersion': '16.0', 'TestTargetID': app_target}}}, buildConfigurationList=project_configs, compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=main, packageReferences=[package], productRefGroup=products, projectDirPath='', projectRoot='', targets=[app_target, test_target])
project_path = root / 'ChargeLedger.xcodeproj'
project_path.mkdir(exist_ok=True)
(project_path / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + render({'archiveVersion': 1, 'classes': {}, 'objectVersion': 56, 'objects': objects, 'rootObject': project}) + '\n')

scheme = ET.Element('Scheme', LastUpgradeVersion='1600', version='1.3')
def reference(parent, target, product, name):
    ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=target, BuildableName=product, BlueprintName=name, ReferencedContainer='container:ChargeLedger.xcodeproj')
build = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
entries = ET.SubElement(build, 'BuildActionEntries')
entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES', buildForProfiling='YES', buildForArchiving='YES', buildForAnalyzing='YES')
reference(entry, app_target, 'ChargeLedger.app', 'ChargeLedger')
test = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
testables = ET.SubElement(test, 'Testables')
reference(ET.SubElement(testables, 'TestableReference', skipped='NO'), test_target, 'ChargeLedgerTests.xctest', 'ChargeLedgerTests')
launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', debugServiceExtension='internal', allowLocationSimulation='YES')
reference(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'), app_target, 'ChargeLedger.app', 'ChargeLedger')
profile = ET.SubElement(scheme, 'ProfileAction', buildConfiguration='Release', shouldUseLaunchSchemeArgsEnv='YES', savedToolIdentifier='', useCustomWorkingDirectory='NO', debugDocumentVersioning='YES')
reference(ET.SubElement(profile, 'BuildableProductRunnable', runnableDebuggingMode='0'), app_target, 'ChargeLedger.app', 'ChargeLedger')
ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration='Debug')
ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
ET.indent(scheme)
scheme_dir = project_path / 'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)
ET.ElementTree(scheme).write(scheme_dir / 'ChargeLedger.xcscheme', encoding='utf-8', xml_declaration=True)
print(f'Generated Xcode project: {len(app_build)} app sources, {len(test_build)} test sources, {len(objects)} objects.')
