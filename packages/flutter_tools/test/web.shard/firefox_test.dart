// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/web/firefox.dart';

import '../src/common.dart';
import '../src/fake_process_manager.dart';

void main() {
  testWithoutContext('findFirefoxExecutable uses environment override', () {
    final fileSystem = MemoryFileSystem.test();
    final platform = FakePlatform(
      environment: <String, String>{kFirefoxEnvironment: 'custom-firefox'},
    );

    expect(findFirefoxExecutable(platform, fileSystem), 'custom-firefox');
  });

  testWithoutContext('findFirefoxExecutable uses platform defaults', () {
    expect(findFirefoxExecutable(FakePlatform(), MemoryFileSystem.test()), kLinuxFirefoxExecutable);
    expect(
      findFirefoxExecutable(FakePlatform(operatingSystem: 'macos'), MemoryFileSystem.test()),
      kMacOSFirefoxExecutable,
    );
  });

  testWithoutContext('findFirefoxExecutable finds a Windows installation', () {
    final fileSystem = MemoryFileSystem.test(style: FileSystemStyle.windows);
    final File firefox = fileSystem.file(r'C:\Program Files\Mozilla Firefox\firefox.exe')
      ..createSync(recursive: true);
    final platform = FakePlatform(
      operatingSystem: 'windows',
      environment: <String, String>{'PROGRAMFILES': r'C:\Program Files'},
    );

    expect(findFirefoxExecutable(platform, fileSystem), firefox.path);
  });

  testWithoutContext('launches Firefox with an isolated profile and browser flags', () async {
    final fileSystem = MemoryFileSystem.test();
    final processExit = Completer<void>();
    final processManager = FakeProcessManager.list(<FakeCommand>[
      FakeCommand(
        command: <Pattern>[
          'example_firefox',
          '--private-window',
          '-no-remote',
          '-profile',
          RegExp(r'flutter_tools_firefox_device\.[^/]+$'),
          '-headless',
          'http://localhost:1234',
        ],
        completer: processExit,
      ),
    ]);
    final launcher = FirefoxLauncher(
      fileSystem: fileSystem,
      platform: FakePlatform(environment: <String, String>{kFirefoxEnvironment: 'example_firefox'}),
      processManager: processManager,
      browserFinder: findFirefoxExecutable,
      logger: BufferLogger.test(),
    );

    final Firefox firefox = await launcher.launch(
      'http://localhost:1234',
      headless: true,
      webBrowserFlags: <String>['--private-window'],
    );

    final Directory profile = fileSystem.systemTempDirectory
        .listSync()
        .whereType<Directory>()
        .single;
    final String preferences = profile.childFile('prefs.js').readAsStringSync();
    expect(preferences, contains('user_pref("browser.aboutwelcome.enabled", false);'));
    expect(preferences, contains('user_pref("termsofuse.bypassNotification", true);'));
    expect(processManager, hasNoRemainingExpectations);
    final Future<int> onExit = firefox.onExit;
    processExit.complete();
    expect(await onExit, 0);
    await firefox.close();
    expect(profile.existsSync(), isFalse);
  });

  testWithoutContext('reports an immediate Firefox startup failure', () async {
    final fileSystem = MemoryFileSystem.test();
    final processManager = FakeProcessManager.list(<FakeCommand>[
      FakeCommand(
        command: <Pattern>[
          'example_firefox',
          '-no-remote',
          '-profile',
          RegExp(r'flutter_tools_firefox_device\.[^/]+$'),
          'http://localhost:1234',
        ],
        exitCode: 1,
      ),
    ]);
    final launcher = FirefoxLauncher(
      fileSystem: fileSystem,
      platform: FakePlatform(environment: <String, String>{kFirefoxEnvironment: 'example_firefox'}),
      processManager: processManager,
      browserFinder: findFirefoxExecutable,
      logger: BufferLogger.test(),
    );

    await expectLater(
      launcher.launch('http://localhost:1234'),
      throwsToolExit(message: 'Firefox failed to start and exited with code 1.'),
    );
    expect(fileSystem.systemTempDirectory.listSync(), isEmpty);
  });

  testWithoutContext('waits for and stops the Firefox process tree on Windows', () async {
    final fileSystem = MemoryFileSystem.test(style: FileSystemStyle.windows);
    final processExit = Completer<void>();
    final processManager = FakeProcessManager.list(<FakeCommand>[
      FakeCommand(
        command: <Pattern>[
          'example_firefox',
          '-wait-for-browser',
          '-no-remote',
          '-profile',
          RegExp(r'flutter_tools_firefox_device\.[^\\]+$'),
          'http://localhost:1234',
        ],
        completer: processExit,
      ),
      FakeCommand(
        command: <Pattern>['taskkill', '/F', '/T', '/PID', RegExp(r'\d+')],
        onRun: (_) => processExit.complete(),
      ),
    ]);
    final launcher = FirefoxLauncher(
      fileSystem: fileSystem,
      platform: FakePlatform(
        operatingSystem: 'windows',
        environment: <String, String>{kFirefoxEnvironment: 'example_firefox'},
      ),
      processManager: processManager,
      browserFinder: findFirefoxExecutable,
      logger: BufferLogger.test(),
    );

    final Firefox firefox = await launcher.launch('http://localhost:1234');
    await firefox.close();

    expect(processManager, hasNoRemainingExpectations);
    expect(fileSystem.systemTempDirectory.listSync(), isEmpty);
  });
}
