// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:process/process.dart';

import '../application_package.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/os.dart';
import '../base/platform.dart';
import '../base/version.dart';
import '../build_info.dart';
import '../device.dart';
import '../device_port_forwarder.dart';
import '../features.dart';
import '../project.dart';
import 'chrome.dart';
import 'firefox.dart';

class WebApplicationPackage extends ApplicationPackage {
  WebApplicationPackage(this.flutterProject) : super(id: flutterProject.manifest.appName);

  final FlutterProject flutterProject;

  @override
  String get name => flutterProject.manifest.appName;

  /// The location of the web source assets.
  Directory get webSourcePath => flutterProject.directory.childDirectory('web');
}

abstract class WebDevice extends Device {
  WebDevice(super.id, {required super.logger})
    : super(category: Category.web, platformType: PlatformType.web, ephemeral: false);

  @override
  Uri? get devToolsUri => _devToolsUri;
  Uri? _devToolsUri;

  set devToolsUri(Uri? uri) => _devToolsUri = uri;

  @override
  Future<CpuArch> get cpuArch async => CpuArch.unknown;
}

/// A web device that supports a chromium browser.
abstract class ChromiumDevice extends WebDevice {
  ChromiumDevice({
    required String name,
    required this.chromeLauncher,
    required FileSystem fileSystem,
    required super.logger,
  }) : _fileSystem = fileSystem,
       _logger = logger,
       super(name);

  final ChromiumLauncher chromeLauncher;

  final FileSystem _fileSystem;
  final Logger _logger;

  /// The active chrome instance.
  Chromium? _chrome;

  // This device does not actually support hot reload, but the current implementation of the resident runner
  // requires both supportsHotReload and supportsHotRestart to be true in order to allow hot restart.
  @override
  bool get supportsHotReload => true;

  @override
  bool get supportsHotRestart => true;

  @override
  bool get supportsStartPaused => true;

  @override
  bool get supportsFlutterExit => false;

  @override
  bool get supportsScreenshot => false;

  @override
  bool supportsRuntimeMode(BuildMode buildMode) => buildMode != BuildMode.jitRelease;

  @override
  void clearLogs() {}

  DeviceLogReader? _logReader;

  @override
  DeviceLogReader getLogReader({ApplicationPackage? app, bool includePastLogs = false}) {
    return _logReader ??= NoOpDeviceLogReader(app?.name);
  }

  @override
  Future<bool> installApp(ApplicationPackage app, {String? userIdentifier}) async => true;

  @override
  Future<bool> isAppInstalled(ApplicationPackage app, {String? userIdentifier}) async => true;

  @override
  Future<bool> isLatestBuildInstalled(ApplicationPackage app) async => true;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  Future<String?> get emulatorId async => null;

  @override
  Future<bool> isSupported() async => chromeLauncher.canFindExecutable();

  @override
  DevicePortForwarder? get portForwarder => const NoOpDevicePortForwarder();

  @override
  Future<LaunchResult> startApp(
    ApplicationPackage? package, {
    String? mainPath,
    String? route,
    required DebuggingOptions debuggingOptions,
    Map<String, Object?> platformArgs = const <String, Object?>{},
    bool prebuiltApplication = false,
    String? userIdentifier,
  }) async {
    // See [ResidentWebRunner.run] in flutter_tools/lib/src/resident_web_runner.dart
    // for the web initialization and server logic.
    final String url = _resolveLaunchUrl(debuggingOptions, platformArgs);
    final launchChrome = platformArgs['no-launch-chrome'] != true;
    if (launchChrome) {
      _chrome = await chromeLauncher.launch(
        url,
        cacheDir: _fileSystem.currentDirectory
            .childDirectory('.dart_tool')
            .childDirectory('chrome-device'),
        headless: debuggingOptions.webRunHeadless,
        debugPort: debuggingOptions.webBrowserDebugPort,
        webBrowserFlags: debuggingOptions.webBrowserFlags,
      );
    }
    _logger.sendEvent('app.webLaunchUrl', <String, Object>{'url': url, 'launched': launchChrome});
    return LaunchResult.succeeded(vmServiceUri: Uri.parse(url));
  }

  @override
  Future<bool> stopApp(ApplicationPackage? app, {String? userIdentifier}) async {
    final Future<void>? future = _chrome?.close();
    _chrome = null;
    await future;
    return true;
  }

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.web_javascript;

  @override
  Future<bool> uninstallApp(ApplicationPackage app, {String? userIdentifier}) async => true;

  @override
  bool isSupportedForProject(FlutterProject flutterProject) {
    return flutterProject.web.existsSync();
  }

  @override
  Future<void> dispose() async {
    _logReader?.dispose();
    await portForwarder?.dispose();
  }
}

/// The Mozilla Firefox browser using the DWDS WebSocket connection.
class FirefoxDevice extends WebDevice {
  FirefoxDevice({
    required this.firefoxLauncher,
    required ProcessManager processManager,
    required super.logger,
  }) : _processManager = processManager,
       _logger = logger,
       super(kFirefoxDeviceId);

  static const kFirefoxDeviceId = 'firefox';
  static const kFirefoxDeviceName = 'Firefox';

  final FirefoxLauncher firefoxLauncher;
  final ProcessManager _processManager;
  final Logger _logger;
  Firefox? _firefox;
  Future<int>? _browserExit;
  DeviceLogReader? _logReader;

  /// Resolves when the Firefox process exits, if Firefox has been launched.
  Future<int>? get browserExit => _browserExit;

  @override
  String get name => kFirefoxDeviceName;

  @override
  bool get supportsFlutterExit => false;

  @override
  bool get supportsStartPaused => false;

  @override
  bool supportsRuntimeMode(BuildMode buildMode) => buildMode != BuildMode.jitRelease;

  @override
  void clearLogs() {}

  @override
  DeviceLogReader getLogReader({ApplicationPackage? app, bool includePastLogs = false}) {
    return _logReader ??= NoOpDeviceLogReader(app?.name);
  }

  @override
  Future<bool> installApp(ApplicationPackage app, {String? userIdentifier}) async => true;

  @override
  Future<bool> isAppInstalled(ApplicationPackage app, {String? userIdentifier}) async => true;

  @override
  Future<bool> isLatestBuildInstalled(ApplicationPackage app) async => true;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  Future<String?> get emulatorId async => null;

  @override
  Future<bool> isSupported() async => firefoxLauncher.canFindExecutable();

  @override
  DevicePortForwarder? get portForwarder => const NoOpDevicePortForwarder();

  @override
  late final Future<String> sdkNameAndVersion = _computeSdkNameAndVersion();

  Future<String> _computeSdkNameAndVersion() async {
    if (!await isSupported()) {
      return 'unknown';
    }
    final ProcessResult result = await _processManager.run(<String>[
      firefoxLauncher.findExecutable(),
      '--version',
    ]);
    return result.exitCode == 0 ? (result.stdout as String).trim() : 'unknown';
  }

  @override
  Future<LaunchResult> startApp(
    ApplicationPackage? package, {
    String? mainPath,
    String? route,
    required DebuggingOptions debuggingOptions,
    Map<String, Object?> platformArgs = const <String, Object?>{},
    bool prebuiltApplication = false,
    String? userIdentifier,
  }) async {
    final String url = _resolveLaunchUrl(debuggingOptions, platformArgs);
    final launchFirefox = platformArgs['no-launch-chrome'] != true;
    if (debuggingOptions.webBrowserDebugPort != null) {
      _logger.printWarning('--web-browser-debug-port is not supported by the Firefox device.');
    }
    if (launchFirefox) {
      if (_firefox != null) {
        throwToolExit('Only one instance of Firefox can be started.');
      }
      final Firefox firefox = await firefoxLauncher.launch(
        url,
        headless: debuggingOptions.webRunHeadless,
        webBrowserFlags: debuggingOptions.webBrowserFlags,
      );
      _firefox = firefox;
      _browserExit = firefox.onExit;
      unawaited(
        _browserExit!.whenComplete(() {
          if (identical(_firefox, firefox)) {
            _firefox = null;
          }
        }),
      );
      _logger.printStatus(
        'Firefox debugging is limited. Breakpoints, stepping, and expression evaluation are not '
        'supported.',
      );
    }
    _logger.sendEvent('app.webLaunchUrl', <String, Object>{'url': url, 'launched': launchFirefox});
    return LaunchResult.succeeded(vmServiceUri: Uri.parse(url));
  }

  @override
  Future<bool> stopApp(ApplicationPackage? app, {String? userIdentifier}) async {
    final Future<void>? future = _firefox?.close();
    _firefox = null;
    _browserExit = null;
    await future;
    return true;
  }

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.web_javascript;

  @override
  Future<bool> uninstallApp(ApplicationPackage app, {String? userIdentifier}) async => true;

  @override
  bool isSupportedForProject(FlutterProject flutterProject) => flutterProject.web.existsSync();

  @override
  Future<void> dispose() async {
    _logReader?.dispose();
    await portForwarder?.dispose();
  }
}

/// The Google Chrome browser based on Chromium.
class GoogleChromeDevice extends ChromiumDevice {
  GoogleChromeDevice({
    required Platform platform,
    required ProcessManager processManager,
    required ChromiumLauncher chromiumLauncher,
    required super.logger,
    required super.fileSystem,
  }) : _platform = platform,
       _processManager = processManager,
       super(name: 'chrome', chromeLauncher: chromiumLauncher);

  final Platform _platform;
  final ProcessManager _processManager;

  static const kChromeDeviceId = 'chrome';
  static const kChromeDeviceName = 'Chrome';

  @override
  String get name => kChromeDeviceName;

  @override
  late final Future<String> sdkNameAndVersion = _computeSdkNameAndVersion();

  Future<String> _computeSdkNameAndVersion() async {
    if (!await isSupported()) {
      return 'unknown';
    }
    // See https://bugs.chromium.org/p/chromium/issues/detail?id=158372
    var version = 'unknown';
    if (_platform.isWindows) {
      if (_processManager.canRun('reg')) {
        final ProcessResult result = await _processManager.run(<String>[
          r'reg',
          'query',
          r'HKEY_CURRENT_USER\Software\Google\Chrome\BLBeacon',
          '/v',
          'version',
        ]);
        if (result.exitCode == 0) {
          final List<String> parts = (result.stdout as String).split(RegExp(r'\s+'));
          if (parts.length > 2) {
            version = 'Google Chrome ${parts[parts.length - 2]}';
          }
        }
      }
    } else {
      final String chrome = chromeLauncher.findExecutable();
      final ProcessResult result = await _processManager.run(<String>[chrome, '--version']);
      if (result.exitCode == 0) {
        version = result.stdout as String;
      }
    }
    return version.trim();
  }
}

/// The Microsoft Edge browser based on Chromium.
class MicrosoftEdgeDevice extends ChromiumDevice {
  MicrosoftEdgeDevice({
    required ChromiumLauncher chromiumLauncher,
    required super.logger,
    required super.fileSystem,
    required ProcessManager processManager,
  }) : _processManager = processManager,
       super(name: 'edge', chromeLauncher: chromiumLauncher);

  final ProcessManager _processManager;

  // The first version of Edge with chromium support.
  static const _kFirstChromiumEdgeMajorVersion = 79;

  static const kEdgeDeviceId = 'edge';
  static const kEdgeDeviceName = 'Edge';

  @override
  String get name => kEdgeDeviceName;

  Future<bool> _meetsVersionConstraint() async {
    final String rawVersion = (await sdkNameAndVersion).replaceFirst('Microsoft Edge ', '');
    final Version? version = Version.parse(rawVersion);
    if (version == null) {
      return false;
    }
    return version.major >= _kFirstChromiumEdgeMajorVersion;
  }

  @override
  late final Future<String> sdkNameAndVersion = _getSdkNameAndVersion();

  Future<String> _getSdkNameAndVersion() async {
    if (_processManager.canRun('reg')) {
      final ProcessResult result = await _processManager.run(<String>[
        r'reg',
        'query',
        r'HKEY_CURRENT_USER\Software\Microsoft\Edge\BLBeacon',
        '/v',
        'version',
      ]);
      if (result.exitCode == 0) {
        final List<String> parts = (result.stdout as String).split(RegExp(r'\s+'));
        if (parts.length > 2) {
          return 'Microsoft Edge ${parts[parts.length - 2]}';
        }
      }
    }
    // Return a non-null string so that the tool can validate the version
    // does not meet the constraint above in _meetsVersionConstraint.
    return '';
  }
}

class WebDevices extends PollingDeviceDiscovery {
  WebDevices({
    required FileSystem fileSystem,
    required Logger logger,
    required Platform platform,
    required ProcessManager processManager,
    required FeatureFlags featureFlags,
  }) : _featureFlags = featureFlags,
       _webServerDevice = WebServerDevice(logger: logger),
       super(GoogleChromeDevice.kChromeDeviceName) {
    final operatingSystemUtils = OperatingSystemUtils(
      fileSystem: fileSystem,
      platform: platform,
      logger: logger,
      processManager: processManager,
    );
    _chromeDevice = GoogleChromeDevice(
      fileSystem: fileSystem,
      logger: logger,
      platform: platform,
      processManager: processManager,
      chromiumLauncher: ChromiumLauncher(
        browserFinder: findChromeExecutable,
        fileSystem: fileSystem,
        platform: platform,
        processManager: processManager,
        operatingSystemUtils: operatingSystemUtils,
        logger: logger,
      ),
    );
    _firefoxDevice = FirefoxDevice(
      firefoxLauncher: FirefoxLauncher(
        fileSystem: fileSystem,
        platform: platform,
        processManager: processManager,
        browserFinder: findFirefoxExecutable,
        logger: logger,
      ),
      processManager: processManager,
      logger: logger,
    );
    if (platform.isWindows) {
      _edgeDevice = MicrosoftEdgeDevice(
        chromiumLauncher: ChromiumLauncher(
          browserFinder: findEdgeExecutable,
          fileSystem: fileSystem,
          platform: platform,
          processManager: processManager,
          operatingSystemUtils: operatingSystemUtils,
          logger: logger,
        ),
        processManager: processManager,
        logger: logger,
        fileSystem: fileSystem,
      );
    }
  }

  late final GoogleChromeDevice _chromeDevice;
  late final FirefoxDevice _firefoxDevice;
  final WebServerDevice _webServerDevice;
  MicrosoftEdgeDevice? _edgeDevice;
  final FeatureFlags _featureFlags;

  @override
  bool get canListAnything => featureFlags.isWebEnabled;

  @override
  Future<List<Device>> pollingGetDevices({
    Duration? timeout,
    bool forWirelessDiscovery = false,
  }) async {
    if (!_featureFlags.isWebEnabled) {
      return <Device>[];
    }
    final MicrosoftEdgeDevice? edgeDevice = _edgeDevice;
    return <Device>[
      if (WebServerDevice.showWebServerDevice) _webServerDevice,
      if (await _chromeDevice.isSupported()) _chromeDevice,
      if (await _firefoxDevice.isSupported()) _firefoxDevice,
      if (edgeDevice != null && await edgeDevice._meetsVersionConstraint()) edgeDevice,
    ];
  }

  @override
  bool get supportsPlatform => _featureFlags.isWebEnabled;

  @override
  List<String> get wellKnownIds => const <String>['chrome', 'web-server', 'edge', 'firefox'];
}

String _resolveLaunchUrl(DebuggingOptions debuggingOptions, Map<String, Object?> platformArgs) {
  if (debuggingOptions.webLaunchUrl case final String webLaunchUrl) {
    if (!_isLaunchUrlValid(webLaunchUrl)) {
      throwToolExit('"$webLaunchUrl" is not a valid HTTP URL.');
    }
    return webLaunchUrl;
  }
  return platformArgs['uri']! as String;
}

bool _isLaunchUrlValid(String url) {
  final pattern = RegExp(r'^(https?:\/\/)[^\s]+');
  return pattern.hasMatch(url);
}

/// A special device type to allow serving for arbitrary browsers.
class WebServerDevice extends WebDevice {
  WebServerDevice({required super.logger}) : _logger = logger, super('web-server');

  static const kWebServerDeviceId = 'web-server';
  static bool showWebServerDevice = false;

  final Logger _logger;

  @override
  void clearLogs() {}

  @override
  Future<String?> get emulatorId async => null;

  DeviceLogReader? _logReader;

  @override
  DeviceLogReader getLogReader({ApplicationPackage? app, bool includePastLogs = false}) {
    return _logReader ??= NoOpDeviceLogReader(app?.name);
  }

  @override
  Future<bool> installApp(ApplicationPackage app, {String? userIdentifier}) async => true;

  @override
  Future<bool> isAppInstalled(ApplicationPackage app, {String? userIdentifier}) async => true;

  @override
  Future<bool> isLatestBuildInstalled(ApplicationPackage app) async => true;

  @override
  bool get supportsFlutterExit => false;

  @override
  bool supportsRuntimeMode(BuildMode buildMode) => buildMode != BuildMode.jitRelease;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  Future<bool> isSupported() async => true;

  @override
  bool isSupportedForProject(FlutterProject flutterProject) {
    return flutterProject.web.existsSync();
  }

  @override
  String get name => 'Web Server';

  @override
  DevicePortForwarder? get portForwarder => const NoOpDevicePortForwarder();

  @override
  Future<String> get sdkNameAndVersion async => 'Flutter Tools';

  @override
  Future<LaunchResult> startApp(
    ApplicationPackage? package, {
    String? mainPath,
    String? route,
    required DebuggingOptions debuggingOptions,
    Map<String, Object?> platformArgs = const <String, Object?>{},
    bool prebuiltApplication = false,
    String? userIdentifier,
  }) async {
    final url = platformArgs['uri'] as String?;
    if (debuggingOptions.startPaused) {
      _logger.printStatus(
        'Waiting for connection from Dart debug extension at $url',
        emphasis: true,
      );
    } else {
      _logger.printStatus('$mainPath is being served at $url', emphasis: true);
    }
    _logger.printStatus(
      'The web-server device requires the Dart Debug Chrome extension for debugging. '
      'Consider using the Chrome or Edge devices for an improved development workflow.',
    );
    _logger.sendEvent('app.webLaunchUrl', <String, Object?>{'url': url, 'launched': false});
    return LaunchResult.succeeded(vmServiceUri: url != null ? Uri.parse(url) : null);
  }

  @override
  Future<bool> stopApp(ApplicationPackage? app, {String? userIdentifier}) async {
    return true;
  }

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.web_javascript;

  @override
  Future<bool> uninstallApp(ApplicationPackage app, {String? userIdentifier}) async {
    return true;
  }

  @override
  Future<void> dispose() async {
    _logReader?.dispose();
    await portForwarder?.dispose();
  }
}
