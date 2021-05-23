import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:authpass/bloc/kdbx/file_content.dart';
import 'package:authpass/bloc/kdbx/file_source.dart';
import 'package:authpass/utils/path_utils.dart';
import 'package:authpass/utils/platform.dart';
import 'package:authpass/utils/uuid_util.dart';
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:logging/logging.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pedantic/pedantic.dart';

final _logger = Logger('file_source_local');

class FileSourceLocal extends FileSource {
  FileSourceLocal(
    this.file, {
    String? databaseName,
    required String uuid,
    this.macOsSecureBookmark,
    this.filePickerIdentifier,
    FileContent? initialCachedContent,
  }) : super(
          databaseName: databaseName,
          uuid: uuid,
          initialCachedContent: initialCachedContent,
        );

  final File file;

  /// on macos a secure bookmark is required, if we are in a sandbox.
  final String? macOsSecureBookmark;

  /// stores the complete json [FileInfo] from [FilePickerWritable]
  /// for backward compatibility might also only contains [FileInfo.identifier]
  final String? filePickerIdentifier;

  FileInfo? _filePickerInfo;

  FileInfo? get filePickerInfo {
    if (_filePickerInfo != null) {
      return _filePickerInfo;
    }
    if (filePickerIdentifier != null && filePickerIdentifier!.startsWith('{')) {
      return _filePickerInfo = FileInfo.fromJson(
          json.decode(filePickerIdentifier!) as Map<String, dynamic>);
    }
    return null;
  }

  @override
  String get typeDebug => '$runtimeType:$typeDebugFilePicker';
  String get typeDebugFilePicker {
    final uri = filePickerInfo?.uri;
    if (uri == null) {
      return macOsSecureBookmark != null ? 'macos' : 'internal';
    }
    if (AuthPassPlatform.isIOS && uri.contains('CloudDocs')) {
      return 'icloud';
    }
    final parsed = Uri.parse(uri);
    return '${parsed.scheme}:${parsed.host}';
  }

  @override
  Stream<FileContent> load() async* {
    yield await _accessFile((f) async => FileContent(await f.readAsBytes()));
  }

  Future<T> _accessFile<T>(Future<T> Function(File file) cb) async {
    if ((AuthPassPlatform.isIOS || AuthPassPlatform.isAndroid) &&
        filePickerIdentifier != null) {
      final oldFileInfo = filePickerInfo;
      final identifier = oldFileInfo?.identifier ?? filePickerIdentifier!;
      return await FilePickerWritable().readFile(
          identifier: identifier,
          reader: (fileInfo, file) async {
            _logger.finest('Got uri: ${fileInfo.uri}');
            if (fileInfo.identifier != identifier) {
              _logger.severe(
                  'Identifier changed. panic. $fileInfo vs $identifier');
            }
            return await cb(file);
          });
    } else if (AuthPassPlatform.isMacOS && macOsSecureBookmark != null) {
      final resolved =
          await SecureBookmarks().resolveBookmark(macOsSecureBookmark!);
      _logger.finer('Reading from secure  bookmark. ($resolved)');
      if (resolved != file) {
        _logger
            .warning('Stored secure bookmark resolves to a different file than'
                ' we originally opened. $resolved vs. $file');
      }
      final access = await SecureBookmarks()
          .startAccessingSecurityScopedResource(resolved);
      _logger.fine('startAccessingSecurityScopedResource: $access');
      try {
        return await cb(resolved);
      } finally {
        await SecureBookmarks().stopAccessingSecurityScopedResource(resolved);
      }
    } else if (AuthPassPlatform.isIOS && !file.existsSync()) {
      // On iOS we must not store the absolute path, but since we do, try to
      // load it relative from application support.
      _logger
          .fine('iOS file ${file.path} no longer exists, checking new paths');
      final docDir = File(path.join(
          (await PathUtils().getAppDocDirectory(ensureCreated: true)).path,
          path.basename(file.path)));
      if (docDir.existsSync()) {
        _logger.fine('${file.path} exists.');
        return cb(docDir);
      }

      final newFile = File(path.join(
          (await PathUtils().getAppDataDirectory()).path,
          path.basename(file.path)));
      _logger.fine(
          'iOS file ${file.path} no longer exists, checking ${newFile.path}');
      if (newFile.existsSync()) {
        _logger.fine('... exists, moving to ${docDir.path}');
        final renamed = newFile.renameSync(docDir.path);
        return cb(renamed);
      }
    }
    return cb(file);
  }

  @override
  String get displayPath => filePickerInfo?.uri ?? file.absolute.path;

  @override
  String get displayNameFromPath =>
      filePickerInfo?.fileName ?? path.basenameWithoutExtension(displayPath);

  @override
  Future<Map<String, dynamic>?> write(
      Uint8List bytes, Map<String, dynamic>? previousMetadata) async {
    if (filePickerIdentifier != null) {
      _logger.finer('Writing into file with file picker.');
      final identifier = filePickerInfo?.identifier ?? filePickerIdentifier;
      await createFileInNewTempDirectory('$displayNameFromPath.kdbx',
          (f) async {
        await f.writeAsBytes(bytes, flush: true);
        final fileInfo =
            await FilePickerWritable().writeFileWithIdentifier(identifier!, f);
        if (fileInfo.identifier != identifier) {
          _logger.severe('Panic, fileIdentifier changed. must no happen.');
        }
      });
    } else {
      _logger.finer('Writing into file directly.');
      await _accessFile((f) => f.writeAsBytes(bytes));
    }
    return null;
  }

  static Future<T> createFileInNewTempDirectory<T>(
      String baseName, Future<T> Function(File tempFile) callback) async {
    if (baseName.length > 30) {
      baseName = baseName.substring(0, 30);
    }
    final tempDirBase = await getTemporaryDirectory();
    final tempDir =
        Directory(path.join(tempDirBase.path, UuidUtil.createUuid()));
    await tempDir.create(recursive: true);
    final tempFile = File(path.join(
      tempDir.path,
      baseName,
    ));
    try {
      return await callback(tempFile);
    } finally {
      unawaited(tempDir
          .delete(recursive: true)
          .catchError((dynamic error, StackTrace stackTrace) {
        _logger.warning('Error while deleting temp dir.', error, stackTrace);
      }));
    }
  }

  @override
  bool get supportsWrite => true;

  @override
  FileSourceIcon get displayIcon => FileSourceIcon.hdd;

  @override
  FileSource copyWithDatabaseName(String databaseName) => FileSourceLocal(
        file,
        databaseName: databaseName,
        uuid: uuid,
        macOsSecureBookmark: macOsSecureBookmark,
        filePickerIdentifier: filePickerIdentifier,
      );

  @override
  Map<String, String?> toDebugMap() => {
        ...super.toDebugMap(),
        'filePickerIdentifier': filePickerIdentifier,
        'local':
            macOsSecureBookmark != null ? 'macOsSecureBookmark' : 'internal',
      };
}
