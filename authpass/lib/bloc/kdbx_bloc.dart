import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:typed_data';

import 'package:authpass/bloc/analytics.dart';
import 'package:authpass/bloc/app_data.dart';
import 'package:authpass/bloc/kdbx/file_content.dart';
import 'package:authpass/bloc/kdbx/file_source.dart';
import 'package:authpass/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:authpass/bloc/kdbx/file_source_local.dart';
import 'package:authpass/bloc/kdbx/file_source_web_none.dart'
    if (dart.library.js_interop) 'package:authpass/bloc/kdbx/file_source_web.dart';
import 'package:authpass/bloc/kdbx/storage_exception.dart';
import 'package:authpass/bloc/kdbx_argon2_ffi.dart'
    if (dart.library.js_interop) 'package:authpass/bloc/kdbx_argon2_web.dart';
import 'package:authpass/cloud_storage/authpasscloud/authpass_cloud_provider.dart';
import 'package:authpass/cloud_storage/cloud_storage_bloc.dart';
import 'package:authpass/cloud_storage/cloud_storage_provider.dart';
import 'package:authpass/env/_base.dart';
import 'package:authpass/main.dart';
import 'package:authpass/theme.dart';
import 'package:authpass/utils/constants.dart';
import 'package:authpass/utils/extension_methods.dart';
import 'package:authpass/utils/path_utils.dart';
import 'package:authpass/utils/platform.dart';
import 'package:biometric_storage/biometric_storage.dart';
import 'package:built_collection/built_collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:kdbx/kdbx.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('kdbx_bloc');

class FileExistsException extends KdbxException {
  FileExistsException({
    required this.path,
  });

  final String path;

  @NonNls
  @override
  String toString() {
    return 'FileExistsException{path: $path}';
  }
}

class FileAlreadyOpenException extends KdbxException {
  FileAlreadyOpenException({
    required this.newFileSource,
    required this.newFile,
    required this.openFileSource,
    required this.openFile,
  }) : assert(newFile.body.rootGroup.uuid == openFile.body.rootGroup.uuid);

  FileSource newFileSource;
  KdbxFile newFile;
  FileSource openFileSource;
  KdbxFile openFile;

  @NonNls
  @override
  String toString() {
    final map = {
      'newFileSource': newFileSource.toString(),
      'openFileSource': openFileSource.toString(),
      'uuid': newFile.body.rootGroup.uuid,
      'databaseName': newFile.body.meta.databaseName.get(),
    };
    return 'FileAlreadyOpenException{$map}';
  }
}

class QuickUnlockStorage {
  QuickUnlockStorage({
    required this.cloudStorageBloc,
    required this.env,
    required this.analytics,
  });

  final CloudStorageBloc cloudStorageBloc;
  final Env env;
  final Analytics analytics;
  bool? _supported;

  static var debugForceNoBiometricSupport = false;

  /// should only be used if used in non interactive callbacks.
  bool? get supportsBiometricKeystoreAlready => _supported;

  Future<bool> supportsBiometricKeyStore() async {
    if (debugForceNoBiometricSupport) {
      _logger.warning('debugForceNoBiometricSupport enabled.');
      return false;
    }
    if (_supported != null) {
      return _supported!;
    }
    final canAuthenticate = await BiometricStorage().canAuthenticate();
    _logger.finer('supportBiometricKeyStore: $canAuthenticate');
    return _supported = (canAuthenticate == CanAuthenticateResponse.success);
  }

  Future<BiometricStorageFile>? _storageFileCached;

  @NonNls
  Future<BiometricStorageFile> _storageFile() => _storageFileCached ??=
      BiometricStorage().getStorage('${env.storageNamespace ?? ''}QuickUnlock');

  Future<void> deleteQuickUnlock() async {
    final storageFile = await _storageFile();
    await storageFile.delete();
  }

  Future<void> updateQuickUnlockFile(
      Map<FileSource, Credentials> fileCredentials) async {
    if (!(await supportsBiometricKeyStore())) {
      _logger.severe(
          'updateQuickUnlockFile must not be called when biometric store is not supported.');
      return;
    }
    final quickUnlockCredentials = fileCredentials.map(
      (key, value) => MapEntry(key.uuid, base64.encode(value.getHash())),
    );
    _logger.fine('Getting storage file.');
    final storage = await _storageFile();
    _logger.fine('got storage, writing credentials.'
        ' ${quickUnlockCredentials.length}');
    try {
      if (quickUnlockCredentials.isEmpty) {
        _logger.fine('Deleting quick unlock.');
        await storage.delete();
      } else {
        await storage.write(json.encode(quickUnlockCredentials));
      }
    } catch (e, stackTrace) {
      _logger.severe(
          'Error while writing quick unlock credentials.', e, stackTrace);
      rethrow;
    } finally {
      _logger.finer('all done.');
    }
  }

  Future<Map<FileSource, Credentials>> loadQuickUnlockFile(
      AppDataBloc appDataBloc) async {
    if (!(await supportsBiometricKeyStore())) {
      _logger.fine('Biometric store not supported. no quickunlock.');
      return {};
    }
    final storage = await _storageFile();
    final jsonContent = await storage.read();
    if (jsonContent == null) {
      _logger.finer('No quick unlock available.');
      return {};
    }
    final map = json.decode(jsonContent) as Map<String, dynamic>;
    final appData = await appDataBloc.store.load();
    return Map.fromEntries(map.entries.map((entry) {
      final file = appData.recentFileByUuid(entry.key);
      if (file == null) {
        return null;
      }
      return MapEntry(file.toFileSource(cloudStorageBloc),
          HashCredentials(base64.decode(entry.value as String)));
    }).whereNotNull());
  }
}

/// response to [KdbxBloc.readKdbxFile] will either be an exception OR a file.
class ReadFileResponse {
  ReadFileResponse(this.file, this.exception, this.exceptionType);
  final KdbxFile? file;
  final Object? exception;
  final String? exceptionType;
}

class KdbxOpenedFile {
  KdbxOpenedFile({
    required this.fileSource,
    required this.openedFile,
    required this.kdbxFile,
    required this.kdbxFileContent,
  });

  final FileSource fileSource;
  final OpenedFile openedFile;
  final KdbxFile kdbxFile;

  /// the file content which was used to originally read the [kdbxFile]
  final FileContent kdbxFileContent;
}

class OpenedKdbxFiles {
  OpenedKdbxFiles(Map<FileSource, KdbxOpenedFile> files)
      : _files = Map.unmodifiable(files);
  final Map<FileSource, KdbxOpenedFile> _files;

  int get length => _files.length;

//  bool get isNotEmpty => _files.isNotEmpty;

  KdbxOpenedFile? operator [](FileSource? fileSource) => _files[fileSource!];
  Iterable<MapEntry<FileSource, KdbxOpenedFile>> get entries => _files.entries;
  Iterable<KdbxOpenedFile> get values => _files.values;

  bool containsKey(FileSource file) => _files.containsKey(file);

//  Map<K2, V2> map<K2, V2>(
//          MapEntry<K2, V2> Function(FileSource key, KdbxOpenedFile value) f) =>
//      _files.map(f);
}

/// Result information for [KdbxBloc.openFile] method calls.
class OpenFileResult {
  OpenFileResult({
    this.kdbxOpenedFile,
    this.fileContent,
    this.unlockStopwatch,
    this.loadStopwatch,
  });
  final KdbxOpenedFile? kdbxOpenedFile;
  final FileContent? fileContent;
  final Stopwatch? unlockStopwatch;
  final Stopwatch? loadStopwatch;
}

abstract class KdbxBlocDelegate {
  void conflictMerged(FileSource fileSource, KdbxFile file, MergeContext merge);
}

typedef OpenedFileUpdater = void Function(OpenedFileBuilder b);

class KdbxBloc {
  KdbxBloc({
    required this.env,
    required this.appDataBloc,
    required this.analytics,
    required this.cloudStorageBloc,
  }) : quickUnlockStorage = QuickUnlockStorage(
            cloudStorageBloc: cloudStorageBloc,
            env: env,
            analytics: analytics) {
    if (AuthPassPlatform.isWeb) {
      KdbxFormat.dartWebWorkaround = true;
    }
    _openedFiles
        .map((value) => Map.fromEntries(value.entries
            .map((entry) => MapEntry(entry.value.kdbxFile, entry.value))))
        .listen((data) => _openedFilesByKdbxFile = data);
  }

  final Env env;
  final AppDataBloc appDataBloc;
  final Analytics analytics;
  final CloudStorageBloc cloudStorageBloc;
  final QuickUnlockStorage quickUnlockStorage;
  late final KdbxFormat kdbxFormat = KdbxFormat(FlutterArgon2());
  KdbxBlocDelegate? delegate;

  final _openedFiles =
      BehaviorSubject<OpenedKdbxFiles>.seeded(OpenedKdbxFiles({}));
  late Map<KdbxFile, KdbxOpenedFile> _openedFilesByKdbxFile;
  final _openedFilesQuickUnlock = <FileSource>{};

  Iterable<MapEntry<FileSource, KdbxFile>> get openedFilesWithSources =>
      _openedFiles.value.entries
          .map((entry) => MapEntry(entry.key, entry.value.kdbxFile));

  OpenedKdbxFiles get openedFiles => _openedFiles.value;
  List<KdbxFile> get openedFilesKdbx =>
      _openedFiles.value.values.map((value) => value.kdbxFile).toList();
  ValueStream<OpenedKdbxFiles> get openedFilesChanged => _openedFiles.stream;

  Future<int>? _quickUnlockCheckRunning;

  void dispose() {
    _openedFiles.close();
//    super.dispose();
  }

  Future<KdbxOpenedFile> updateOpenedFile(
      KdbxOpenedFile file, OpenedFileUpdater updater) async {
    final updatedFile = (file.openedFile.toBuilder()..update(updater)).build();
    await appDataBloc.update((b, data) {
      b.previousFiles.map((f) {
        if (!f.isSameFileAs(file.openedFile)) {
          return f;
        }
//          return (f.toBuilder()..update(updater)).build();
        return updatedFile;
      });
    });
    final newFile = KdbxOpenedFile(
      fileSource: file.fileSource,
      openedFile: updatedFile,
      kdbxFile: file.kdbxFile,
      kdbxFileContent: file.kdbxFileContent,
    );
    _openedFiles.add(OpenedKdbxFiles({
      ..._openedFiles.value._files,
      file.fileSource: newFile,
    }));
    _logger.info('new values: ${_openedFiles.value}');
    return newFile;
  }

  Stream<OpenFileResult> openFile(FileSource file, Credentials credentials,
      {bool addToQuickUnlock = false}) async* {
    Uint8List? previous;
    late KdbxOpenedFile openedFile;
    await for (final fileContent in file.content()) {
      _logger.finer('$file got from ${fileContent.source}');
      final loadStopwatch = Stopwatch()..start();
      if (previous != null) {
        if (ByteUtils.eq(previous, fileContent.content)) {
          _logger.finer('$file: No changes detected. Nothing to do.');
          continue;
        } else {
          if (openedFile.kdbxFile.isDirty) {
            // ooooopsie.
            throw StateError('File was changed locally while '
                'loading new file from remote storage.');
          }
        }
      }
      previous = fileContent.content;
      loadStopwatch.stop();
      final unlockStopwatch = Stopwatch()..start();
      openedFile = await _openFileContent(
          file, credentials, fileContent, addToQuickUnlock);
      addToQuickUnlock = false;

      if (file is FileSourceCloudStorage) {
        final provider = file.provider;
        if (provider is AuthPassCloudProvider) {
          unawaited((() async {
            await Future<void>.delayed(const Duration(seconds: 2));
            _logger.fine('touch files.');
            await provider.openedFile(this, openedFile);
          })());
        }
      }

      yield OpenFileResult(
        kdbxOpenedFile: openedFile,
        fileContent: fileContent,
        unlockStopwatch: unlockStopwatch..stop(),
        loadStopwatch: loadStopwatch,
      );
    }
    _logger.finer('$file: Done.');
  }

  Future<KdbxOpenedFile> _openFileContent(
      FileSource file,
      Credentials credentials,
      FileContent fileContent,
      bool addToQuickUnlock) async {
    final readArgs = KdbxReadArgs(fileContent.content, credentials);
//    final kdbxReadFile = await compute(
//        staticReadKdbxFile, readArgs,
//        debugLabel: 'readKdbxFile');
    final kdbxReadFile = await readKdbxFile(kdbxFormat, readArgs);
    final kdbxReadFileException = kdbxReadFile.exception;
    if (kdbxReadFileException != null) {
      final mapping = <Type, Exception Function()>{
        KdbxInvalidKeyException: () => KdbxInvalidKeyException(),
        KdbxCorruptedFileException: () => KdbxCorruptedFileException(''),
      }.map((key, value) => MapEntry(key.toString(), value));
      final exception = mapping[kdbxReadFile.exceptionType!];
      if (exception != null) {
        throw exception();
      }
      throw kdbxReadFileException;
    }
    final kdbxFile = kdbxReadFile.file!;

    // make sure kdbxFile is not already opened with another FileSource.
    final openedUuid = kdbxFile.body.rootGroup.uuid;
    for (final openedFile in _openedFiles.value.values) {
      if (openedFile.kdbxFile.body.rootGroup.uuid == openedUuid &&
          openedFile.fileSource != file) {
        throw FileAlreadyOpenException(
          newFileSource: file,
          newFile: kdbxFile,
          openFileSource: openedFile.fileSource,
          openFile: openedFile.kdbxFile,
        );
      }
    }

    final openedFile = await appDataBloc.openedFile(
      file,
      name: kdbxFile.body.meta.databaseName.get(),
      defaultColor: _defaultNextColor(),
    );
    final kdbxOpenedFile = KdbxOpenedFile(
      fileSource: file,
      openedFile: openedFile,
      kdbxFile: kdbxFile,
      kdbxFileContent: fileContent,
    );
    _openedFiles.add(OpenedKdbxFiles({
      ..._openedFiles.value._files,
      file: kdbxOpenedFile,
    }));
    analytics.events.trackOpenFile(type: file.typeDebug);
    analytics.events.trackOpenFile2(
      generator: kdbxFile.body.meta.generator.get() ?? 'NULL',
      version: '${kdbxFile.header.version}',
    );

    if (addToQuickUnlock) {
      _openedFilesQuickUnlock.add(file);
      _logger.fine('adding file to quick unlock.');
      await _updateQuickUnlockStore();
    }
    return kdbxOpenedFile;
  }

  Color? _defaultNextColor() {
    for (final color in AuthPassTheme.defaultColorOrder) {
      if (!openedFiles.values
          .any((file) => file.openedFile.colorCode == color.value)) {
        return color;
      }
    }
    return null;
  }

  /// writes all opened files into secure storage.
  Future<void> _updateQuickUnlockStore({FileSource? ifRequiredFor}) async {
    if (ifRequiredFor != null) {
      if (!_openedFilesQuickUnlock.contains(ifRequiredFor)) {
        return;
      }
    }
    final openedFiles = _openedFiles.value;
    await quickUnlockStorage.updateQuickUnlockFile(
        Map.fromEntries(_openedFilesQuickUnlock.map((fileSource) {
      final openedFile = openedFiles[fileSource];
      if (openedFile == null) {
        _logger.warning(
            'File was closed, but was still listed in quick unlock files.');
        return null;
      }
      return MapEntry(fileSource, openedFile.kdbxFile.credentials);
    }).whereNotNull()));
  }

  bool _isOpen(FileSource file) => _openedFiles.value.containsKey(file);

  Future<void> continueLoadInBackground(
    StreamIterator<OpenFileResult> openIt, {
    @NonNls required String debugName,
    required FileSource fileSource,
  }) async {
    try {
      while (await openIt.moveNext()) {
        final r = openIt.current;
        _logger.fine('load:$debugName new data from ${r.fileContent!.source}');
      }
    } catch (e, stackTrace) {
      _logger.severe(
          'load:$debugName error while loading subsequent '
          'data from $fileSource.',
          e,
          stackTrace);
      rethrow;
    }
    _logger.fine('load:$debugName finished.');
  }

  bool hasQuickUnlockOpen() => _openedFilesQuickUnlock.isNotEmpty;

  Future<int> reopenQuickUnlock(AppLocalizations loc,
          [TaskProgress? progress]) =>
      _quickUnlockCheckRunning ??= (() async {
        try {
          _logger.finer('Checking quick unlock.');
          final unlockFiles =
              await quickUnlockStorage.loadQuickUnlockFile(appDataBloc);
          var filesOpened = 0;
          for (final file
              in unlockFiles.entries.where((entry) => !_isOpen(entry.key))) {
            try {
//              progress.progressLabel = 'Loading $fileLabel';
//              await file.key.contentPreCache();
              progress!.progressLabel = loc.openFileProgress(
                  file.key.displayName, filesOpened + 1, unlockFiles.length);
              final open = StreamIterator(openFile(file.key, file.value));
              await open.moveNext();
              filesOpened++;
              unawaited(continueLoadInBackground(open,
                  debugName:
                      '${file.key.displayName} … (${filesOpened + 1} / ${unlockFiles.length})',
                  fileSource: file.key));
            } catch (e, stackTrace) {
              _logger.severe(
                  'Panic, error while trying to open file from '
                  'quick unlock. ignoring file for now. ${file.key}',
                  e,
                  stackTrace);
            }
          }
          analytics.events.trackQuickUnlock(value: filesOpened);
          _openedFilesQuickUnlock.clear();
          _openedFilesQuickUnlock.addAll(unlockFiles.keys);
          // Update the amount of login attempts
          for (final unlockFile in _openedFilesQuickUnlock) {
            await appDataBloc.update((b, appData) => {
                  b.quickUnlockCounter?[unlockFile.uuid] != null
                      ? b.quickUnlockCounter![unlockFile.uuid] =
                          b.quickUnlockCounter![unlockFile.uuid]! + 1
                      : MapBuilder({unlockFile.uuid: 1})
                });
          }
          return filesOpened;
        } on AuthException catch (e, stackTrace) {
          if (e.code == AuthExceptionCode.userCanceled) {
            _logger.info('User canceled quick unlock.');
            return 0;
          }
          _logger.severe('Error during quick unlock.', e, stackTrace);
          return 0;
        }
      })()
          .whenComplete(() => _quickUnlockCheckRunning = null);

  Future<void> close(KdbxFile file) async {
    _logger.fine('Close file.');
    analytics.events.trackCloseFile();
    final fileSource = fileForKdbxFile(file).fileSource;
    _openedFiles.add(OpenedKdbxFiles(
        Map.from(_openedFiles.value._files)..remove(fileSource)));
    file.dispose();
    if (_openedFilesQuickUnlock.remove(fileSource)) {
      _logger.fine('file was in quick unlock. need to persist it.');
      await _updateQuickUnlockStore();
    } else {
      _logger.fine('file was not in quick unlock.');
    }
  }

  Future<void> closeAllFiles({required bool clearQuickUnlock}) async {
    _logger.finer('Closing all files, clearing quick unlock.');
    for (final file in _openedFiles.value.values) {
      file.kdbxFile.dispose();
    }
    if (clearQuickUnlock) {
      // clear all quick unlock data.
      _openedFilesQuickUnlock.clear();
      await quickUnlockStorage.updateQuickUnlockFile({});
      analytics.events.trackCloseAllFiles(count: _openedFiles.value.length);
    } else {
      analytics.events.trackLockAllFiles(count: _openedFiles.value.length);
    }
    _openedFiles.add(OpenedKdbxFiles({}));
  }

  static Future<ReadFileResponse> staticReadKdbxFile(
      KdbxReadArgs readArgs) async {
    initIsolate();
    final kdbxFormat = KdbxFormat(FlutterArgon2());
    return readKdbxFile(kdbxFormat, readArgs);
  }

  static Future<ReadFileResponse> readKdbxFile(
      KdbxFormat kdbxFormat, KdbxReadArgs readArgs) async {
    try {
      _logger.finer('reading kdbx file ...');
      final fileContent = readArgs.content;
      final kdbxFile = await kdbxFormat.read(fileContent, readArgs.credentials);
      _logger.finer('done reading');
      return ReadFileResponse(kdbxFile, null, null);
    } catch (e, stackTrace) {
      _logger.warning('Error while reading kdbx file.', e, stackTrace);
      return ReadFileResponse(null, e.toString(), e.runtimeType.toString());
    }
  }

  /// Creates a new file in the application document directory by the given name.
  /// Throws a [FileExistsException] if a file of the same name already exists.
  Future<FileSource> createFile({
    required String password,
    required String databaseName,
    bool openAfterCreate = false,
    CloudStorageSaveTarget? target,
  }) async {
    analytics.events.trackCreateFile();
    assert(!(databaseName.endsWith(AppConstants.kdbxExtension)));
    final credentials = Credentials(ProtectedValue.fromString(password));
    final kdbxFile = kdbxFormat.create(
      credentials,
      databaseName,
      generator: Env.AuthPass,
    );
    final bytes =
        await _saveFileToBytes<Uint8List>(kdbxFile, (bytes) async => bytes);
    FileSource fileSource;
    if (target == null) {
      final localSource = await _localFileSourceForDbName(databaseName);
      await localSource.contentWrite(bytes, metadata: <String, dynamic>{});
      fileSource = localSource;
    } else {
      final entity = await target.provider.createEntity(
        CloudStorageSelectorSaveResult(
            target.parent, _fileNameForDbName(databaseName)),
        bytes,
      );
      fileSource = entity;
    }
    if (openAfterCreate) {
      await openFile(fileSource, credentials).last;
    }
    return fileSource;
  }

  String _fileNameForDbName(String databaseName) =>
      [databaseName, AppConstants.kdbxExtension].join();

  Future<FileSource> _localFileSourceForDbName(String databaseName) async {
    if (AuthPassPlatform.isWeb) {
      _logger.finer('in web mode - using FileSourceWeb.');
      return FileSourceWeb(
        databaseName: databaseName,
        uuid: AppDataBloc.createUuid(),
      );
    }
    final fileName = _fileNameForDbName(databaseName);
    final appDir = await PathUtils().getAppDocDirectory(ensureCreated: true);
    final localSource = FileSourceLocal(appDir.childFile(fileName),
        databaseName: databaseName, uuid: AppDataBloc.createUuid());
    if (localSource.file.existsSync()) {
      throw FileExistsException(path: localSource.file.path);
    }
    return localSource;
  }

  /// Creates a new password entry in [file] (default: the primary kdbx file),
  /// and adds it to [group] (default: main root group).
  KdbxEntry createEntry({
    KdbxFile? file,
    KdbxGroup? group,
  }) {
    file ??= group?.file;
    if (file == null) {
      if (openedFilesKdbx.isEmpty) {
        return throw StateError('No kdbxfiles are open. Specify a file.');
      }
      file = openedFilesKdbx.first;
    }
    final rootGroup = group ?? file.body.rootGroup;
    final entry = KdbxEntry.create(file, rootGroup);
    rootGroup.addEntry(entry);
    return entry;
  }

  @NonNls
  static const _customDataSaveCount = 'codeux.design.authpass.save';

  /// Wrapper around [file.save()], which adds a bit of meta data
  /// before storing it.
  Future<T> _saveFileToBytes<T>(
      KdbxFile file, FileSaveCallback<T> saveBytes) async {
    final generator = file.body.meta.generator.get();
    if (generator == null || generator.isEmpty) {
      file.body.meta.generator.set(nonNls('AuthPass (save)'));
    }
    final String saveCounter =
        file.body.meta.customData[_customDataSaveCount] ?? nonNls('0');
    final newCounter = (int.tryParse(saveCounter) ?? 0) + 1;
    file.body.meta.customData[_customDataSaveCount] = newCounter.toString();
    analytics.events.trackSaveCount(generator: generator, value: newCounter);
    return await file.saveTo(saveBytes);
  }

  Future<FileContent> saveFile(KdbxFile file,
      {FileSource? toFileSource, Credentials? updateCredentials}) async {
    final oldCredentials = file.credentials;
    if (updateCredentials != null) {
      file.credentials = updateCredentials;
    }

    final fileSource = toFileSource ?? fileForKdbxFile(file).fileSource;

    Future<void> updateQuickUnlock() async {
      if (updateCredentials == null) {
        return;
      }
      try {
        await _updateQuickUnlockStore(ifRequiredFor: fileSource);
      } on AuthException catch (e) {
        if (e.code == AuthExceptionCode.userCanceled) {
          // ignore;
          return;
        }
        rethrow;
      }
    }

    try {
      final ret = await _saveFileToBytes(file, (bytes) async {
        return await fileSource.contentWrite(bytes, metadata: null);
      });
      analytics.events
          .trackSave(type: fileSource.typeDebug, value: ret.content.length);
      analytics.trackTiming('saveFileSize', ret.content.length,
          category: 'fileSize', label: 'save');
      await updateQuickUnlock();
      return ret;
    } on StorageConflictException catch (e, stackTrace) {
      _logger.fine(
          'Got conflict while writing file. Trying to merge.', e, stackTrace);
      final content = await fileSource.content(updateCache: false).last;
      final remoteFile = await kdbxFormat.read(content.content, oldCredentials);
      final mergeResult = file.merge(remoteFile);
      try {
        _logger.fine('mergeResult: $mergeResult');
        final ret = await _saveFileToBytes(
            file,
            (bytes) async => await fileSource.contentWrite(bytes,
                metadata: content.metadata));
        delegate?.conflictMerged(fileSource, file, mergeResult);
        analytics.events.trackSaveConflict(
          type: fileSource.typeDebug,
          value: mergeResult.totalChanges(),
          success: true,
        );
        analytics.events
            .trackSave(type: fileSource.typeDebug, value: ret.content.length);
        analytics.trackTiming('saveFileSize', ret.content.length,
            category: 'fileSize', label: 'save');
        await updateQuickUnlock();
        return ret;
      } catch (e) {
        analytics.events.trackSaveConflict(
          type: fileSource.typeDebug,
          value: mergeResult.totalChanges(),
          success: false,
        );
        rethrow;
      }
    }
  }

  KdbxOpenedFile fileForKdbxFile(KdbxFile file) =>
      _openedFilesByKdbxFile[file] ??
      (() {
        throw StateError('Missing file source for kdbxFile.');
      })();

  KdbxOpenedFile? fileForFileSource(FileSource fileSource) =>
      _openedFiles.value[fileSource];

  Future<KdbxOpenedFile> saveAs(
      KdbxOpenedFile oldFile, FileSource output) async {
    final content = await saveFile(oldFile.kdbxFile, toFileSource: output);
    return await _savedAs(oldFile, output, content);
  }

  Future<KdbxOpenedFile> _savedAs(KdbxOpenedFile oldFile, FileSource output,
      FileContent fileContent) async {
    final oldSource = oldFile.fileSource;
    final databaseName = oldFile.kdbxFile.body.meta.databaseName.get();
    final newOpenedFile = await appDataBloc.openedFile(
      output,
      name: databaseName,
      oldFile: oldFile.openedFile,
    );
    final newFile = KdbxOpenedFile(
      fileSource: output,
      openedFile: newOpenedFile,
      kdbxFile: oldFile.kdbxFile,
      kdbxFileContent: fileContent,
    );
    _openedFiles.add(OpenedKdbxFiles({
      ...Map.fromEntries(_openedFiles.value._files.entries
          .where((entry) => entry.key != oldSource)),
      newFile.fileSource: newFile,
    }));
    // TODO also do not update quick unlock if this file is not in quick unlock.
    if (_openedFilesQuickUnlock.isNotEmpty) {
      try {
        await _updateQuickUnlockStore();
      } on AuthException catch (e, stackTrace) {
        if (e.code == AuthExceptionCode.userCanceled) {
          _logger.warning(
              'User cancelled saving quick unlock. ignoring for now.',
              e,
              stackTrace);
        } else {
          rethrow;
        }
      }
    }
    return newFile;
  }

  Future<KdbxOpenedFile> saveAsNewFile(
      KdbxOpenedFile oldFile,
      CloudStorageSelectorSaveResult createFileInfo,
      CloudStorageProvider cs) async {
    return await _saveFileToBytes(oldFile.kdbxFile, (bytes) async {
      final entity = await cs.createEntity(createFileInfo, bytes);
      final lastContent = entity.lastContent!;
      assert(bytes == lastContent.content);
      return await _savedAs(oldFile, entity, lastContent);
    });
  }

  Future<FileSource> saveLocally(FileSource? source) async {
    final file = _openedFiles.value[source];
    if (file == null) {
      throw StateError('file for $source is not open.');
    }
    final databaseName = file.kdbxFile.body.meta.databaseName.get()!;
    final localSource = await _localFileSourceForDbName(databaseName);
    return (await saveAs(file, localSource)).fileSource;
  }

  Map<String, KdbxEntry>? _entryUuidLookup;

  KdbxEntry? findEntryByUuid(String uuid) {
    final entryUuidLookup = _entryUuidLookup ??= Map.fromEntries(
        openedFilesKdbx.expand((file) => file.body.rootGroup
            .getAllEntries()
            .map((e) => MapEntry(e.uuid.uuid, e))));

    return entryUuidLookup[uuid];
  }

  void clearEntryByUuidLookup() => _entryUuidLookup = null;

  Stream<ReloadStatus> reload(KdbxOpenedFile file) async* {
    Uint8List? bytes;
    final dirtyObjects = file.kdbxFile.dirtyObjects;
    try {
      if (file.kdbxFile.isDirty) {
        //throw StateError('File must not be dirty for now.');
        bytes = await file.kdbxFile.save();
      }
      yield ReloadStatus.downloading;
      final reloadedContent = await file.fileSource.content().last;
      assert(reloadedContent.source == FileContentSource.origin);
      if (ByteUtils.eq(reloadedContent.content, file.kdbxFileContent.content)) {
        yield ReloadStatus.didNotChange;
        return;
      }

      // try loading the new file.
      yield ReloadStatus.decrypting;
      final readArgs =
          KdbxReadArgs(reloadedContent.content, file.kdbxFile.credentials);
      final kdbxReadFile = await readKdbxFile(kdbxFormat, readArgs);

      _logger.info('\n\n\n===========\n\n\n');
      _logger.info('starting merge.');
      file.kdbxFile.merge(kdbxReadFile.file!);

      _logger.info('\n\nDONE MERGE\n\n\n\n');

      yield ReloadStatus.merged;
    } finally {
      if (bytes != null && !file.kdbxFile.isDirty) {
        dirtyObjects.forEach(file.kdbxFile.dirtyObject);
      }
    }
  }

  Future<AttachmentProvider> attachmentProviderForFileSource(
      KdbxFile file) async {
    final appData = await appDataBloc.store.load();
    if (!appData.authPassCloudAttachmentsOrDefault) {
      _logger.info('AuthPass Cloud Attachments disabled.');
      return AttachmentProviderLocal();
    }
    final openedFile = fileForKdbxFile(file);
    final fs = openedFile.fileSource;
    if (fs is! FileSourceCloudStorage) {
      return AttachmentProviderLocal();
    }
    final provider = fs.provider;
    if (provider is! AuthPassCloudProvider) {
      return AttachmentProviderLocal();
    }
    return AttachmentProviderAuthPassCloud(
      kdbxBloc: this,
      fs: fs,
      provider: provider,
    );
  }

  AuthPassExternalAttachment? attachmentInfo(KdbxBinary binary) {
    if (!attachmentIsFromCloud(binary)) {
      return null;
    }
    final data = binary.value
        .sublist(AuthPassExternalAttachment.prefixIdentifierBytes.length);
    final infoJson = json.decode(utf8.decode(data)) as Map<String, dynamic>;
    return AuthPassExternalAttachment.fromJson(infoJson);
  }

  bool attachmentIsFromCloud(KdbxBinary binary) {
    final cloudId = AuthPassExternalAttachment.prefixIdentifierBytes;
    if (binary.value.length < cloudId.length) {
      return false;
    }
    return ByteUtils.eq(binary.value.sublist(0, cloudId.length), cloudId);
  }
}

abstract class AttachmentProvider {
  Future<Uint8List> readAttachmentBytes(KdbxFile file, KdbxBinary binary);
  Future<void> attachFile({
    required KdbxEntry entry,
    required String fileName,
    required Uint8List bytes,
  });
}

class AttachmentProviderLocal extends AttachmentProvider {
  @override
  Future<Uint8List> readAttachmentBytes(
      KdbxFile file, KdbxBinary binary) async {
    return binary.value;
  }

  @override
  Future<void> attachFile({
    required KdbxEntry entry,
    required String fileName,
    required Uint8List bytes,
  }) async {
    entry.createBinary(
      isProtected: false,
      name: fileName,
      bytes: bytes,
    );
  }
}

class AttachmentProviderAuthPassCloud extends AttachmentProvider {
  AttachmentProviderAuthPassCloud({
    required this.kdbxBloc,
    required this.provider,
    required this.fs,
  });

  final KdbxBloc kdbxBloc;
  final AuthPassCloudProvider provider;
  final FileSourceCloudStorage fs;

  @override
  Future<void> attachFile({
    required KdbxEntry entry,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final attached = await attachFileToCloud(
      entry: entry,
      fileName: fileName,
      bytes: bytes,
    );
    if (attached) {
      return;
    }
    entry.createBinary(
      isProtected: false,
      name: fileName,
      bytes: bytes,
    );
  }

  Future<bool> attachFileToCloud({
    required KdbxEntry entry,
    required String fileName,
    required Uint8List bytes,
  }) async {
    _logger.info('Lets try AuthPass Cloud Attachments.');
    try {
      final attachmentInfo = await provider.createAttachment(
          fileSource: fs, name: fileName, bytes: bytes);
      final info = [
        attachmentInfo.identifier,
        json.encode(attachmentInfo.toJson())
      ].join();
      entry.createBinary(
        isProtected: false,
        name: fileName,
        bytes: utf8.encode(info),
      );
      return true;
    } catch (e, stackTrace) {
      _logger.severe('Error while uploading attachment.', e, stackTrace);
      rethrow;
    }
  }

  @override
  Future<Uint8List> readAttachmentBytes(
      KdbxFile file, KdbxBinary binary) async {
    final info = kdbxBloc.attachmentInfo(binary);
    if (info == null) {
      return binary.value;
    }

    return await provider.loadAttachment(info);
  }
}

enum ReloadStatus {
  error,
  downloading,
  decrypting,
  didNotChange,
  merged,
}

class KdbxReadArgs {
  KdbxReadArgs(this.content, this.credentials);

  final Uint8List content;
  final Credentials credentials;
}
