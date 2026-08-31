// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:process/process.dart';

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/platform.dart';
import '../base/utils.dart';

/// An environment variable used to override the location of Firefox.
const kFirefoxEnvironment = 'FIREFOX_EXECUTABLE';

/// The expected Firefox executable name on Linux.
const kLinuxFirefoxExecutable = 'firefox';

/// The expected Firefox executable name on macOS.
const kMacOSFirefoxExecutable = '/Applications/Firefox.app/Contents/MacOS/firefox';

/// The expected Firefox executable name on Windows.
const kWindowsFirefoxExecutable = r'Mozilla Firefox\firefox.exe';

typedef FirefoxFinder = String Function(Platform, FileSystem);

const _kFirefoxProfilePreferences = '''
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("startup.homepage_welcome_url", "about:blank");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("termsofuse.bypassNotification", true);
''';

/// Finds the Firefox executable on the current platform.
///
/// Does not verify whether the executable exists.
String findFirefoxExecutable(Platform platform, FileSystem fileSystem) {
  if (platform.environment.containsKey(kFirefoxEnvironment)) {
    return platform.environment[kFirefoxEnvironment]!;
  }
  if (platform.isLinux) {
    return kLinuxFirefoxExecutable;
  }
  if (platform.isMacOS) {
    return kMacOSFirefoxExecutable;
  }
  if (platform.isWindows) {
    final prefixes = <String>[
      if (platform.environment.containsKey('PROGRAMFILES')) platform.environment['PROGRAMFILES']!,
      if (platform.environment.containsKey('PROGRAMFILES(X86)'))
        platform.environment['PROGRAMFILES(X86)']!,
      if (platform.environment.containsKey('LOCALAPPDATA')) platform.environment['LOCALAPPDATA']!,
    ];
    final String windowsPrefix = prefixes.firstWhere((String prefix) {
      final String path = fileSystem.path.join(prefix, kWindowsFirefoxExecutable);
      return fileSystem.file(path).existsSync();
    }, orElse: () => '.');
    return fileSystem.path.join(windowsPrefix, kWindowsFirefoxExecutable);
  }
  return '';
}

/// A launcher for Firefox browsers using an isolated profile.
class FirefoxLauncher {
  FirefoxLauncher({
    required FileSystem fileSystem,
    required Platform platform,
    required ProcessManager processManager,
    required FirefoxFinder browserFinder,
    required Logger logger,
  }) : _fileSystem = fileSystem,
       _platform = platform,
       _processManager = processManager,
       _browserFinder = browserFinder,
       _logger = logger;

  final FileSystem _fileSystem;
  final Platform _platform;
  final ProcessManager _processManager;
  final FirefoxFinder _browserFinder;
  final Logger _logger;

  /// Whether the Firefox executable can be located.
  bool canFindExecutable() {
    final String firefox = _browserFinder(_platform, _fileSystem);
    if (firefox.isEmpty) {
      return false;
    }
    try {
      return _processManager.canRun(firefox);
    } on ArgumentError {
      return false;
    }
  }

  /// The executable this launcher will use.
  String findExecutable() => _browserFinder(_platform, _fileSystem);

  /// Launches Firefox at [url] using a temporary, isolated profile.
  Future<Firefox> launch(
    String url, {
    bool headless = false,
    List<String> webBrowserFlags = const <String>[],
  }) async {
    final String executable = findExecutable();
    Directory? profile;
    try {
      profile = _fileSystem.systemTempDirectory.createTempSync('flutter_tools_firefox_device.');
      profile.childFile('prefs.js').writeAsStringSync(_kFirefoxProfilePreferences);
      final args = <String>[
        executable,
        ...webBrowserFlags,
        '-no-remote',
        '-profile',
        profile.path,
        if (headless) '-headless',
        url,
      ];

      if (_logger.isVerbose) {
        _logger.printTrace('Launching Firefox (url = $url, headless = $headless)');
        _logger.printTrace('Will use Firefox executable at $executable');
      }

      final Process process = await _processManager.start(args);
      process.stdout.transform(utf8LineDecoder).listen((String line) {
        _logger.printTrace('[FIREFOX]: $line');
      });
      process.stderr.transform(utf8LineDecoder).listen((String line) {
        _logger.printTrace('[FIREFOX]: $line');
      });
      final int? earlyExitCode = await Future.any<int?>(<Future<int?>>[
        process.exitCode,
        Future<int?>.delayed(const Duration(milliseconds: 100)),
      ]);
      if (earlyExitCode != null) {
        throwToolExit('Firefox failed to start and exited with code $earlyExitCode.');
      }
      return Firefox(
        process: process,
        profile: profile,
        logger: _logger,
        platform: _platform,
        processManager: _processManager,
      );
    } on Object {
      try {
        if (profile?.existsSync() ?? false) {
          profile?.deleteSync(recursive: true);
        }
      } on FileSystemException {
        // Preserve the launch error if temporary profile cleanup also fails.
      }
      rethrow;
    }
  }
}

/// A running Firefox browser instance.
class Firefox {
  Firefox({
    required Process process,
    required Directory profile,
    required Logger logger,
    required Platform platform,
    required ProcessManager processManager,
  }) : _process = process,
       _profile = profile,
       _logger = logger,
       _platform = platform,
       _processManager = processManager {
    unawaited(_process.exitCode.whenComplete(_deleteProfile));
    unawaited(
      _process.exitCode.then((int code) {
        if (!_didClose && code != 0) {
          _logger.printError('Firefox process PID $pid exited unexpectedly with code $code.');
        }
      }),
    );
  }

  final Process _process;
  final Directory _profile;
  final Logger _logger;
  final Platform _platform;
  final ProcessManager _processManager;
  var _didClose = false;

  int get pid => _process.pid;

  /// Resolves to Firefox's exit code when its main process exits.
  Future<int> get onExit => _process.exitCode;

  @visibleForTesting
  Process get process => _process;

  Future<void> _deleteProfile() async {
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        if (_profile.existsSync()) {
          _profile.deleteSync(recursive: true);
        }
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// Stops Firefox and waits for its main process to exit.
  Future<void> close() async {
    _didClose = true;
    if (_logger.isVerbose) {
      _logger.printTrace('Shutting down Firefox.');
    }
    await _process.exitCode.timeout(
      Duration.zero,
      onTimeout: () {
        ProcessSignal.sigterm.kill(_process);
        return 0;
      },
    );
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () async {
        _logger.printWarning(
          'Failed to exit Firefox (pid: $pid) using SIGTERM. Will force termination instead.',
        );
        if (_platform.isWindows) {
          try {
            await _processManager.run(<String>['taskkill', '/F', '/T', '/PID', '$pid']);
          } on Object {
            // Fall through to the timeout warning below.
          }
        } else {
          ProcessSignal.sigkill.kill(_process);
        }
        return _process.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _logger.printWarning(
              'Failed to force Firefox (pid: $pid) to exit. Giving up. A Firefox process might '
              'still be running.',
            );
            return 0;
          },
        );
      },
    );
    await _deleteProfile();
  }
}
