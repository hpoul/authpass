import 'dart:convert';

import 'package:authpass/bloc/kdbx/file_source.dart';
import 'package:authpass/bloc/kdbx/file_source_cloud_storage.dart';
import 'package:authpass/bloc/kdbx/file_source_local.dart';
import 'package:authpass/bloc/kdbx/file_source_web_none.dart'
    if (dart.library.js_interop) 'package:authpass/bloc/kdbx/file_source_web.dart';
import 'package:authpass/cloud_storage/cloud_storage_bloc.dart';
import 'package:authpass/env/_base.dart';
import 'package:authpass/utils/path_utils.dart';
import 'package:authpass/utils/uuid_util.dart';
import 'package:built_collection/built_collection.dart';
import 'package:built_value/built_value.dart';
import 'package:built_value/serializer.dart';
import 'package:built_value/standard_json_plugin.dart';
import 'package:clock/clock.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:file/local.dart';
import 'package:flutter/material.dart' show Color;
import 'package:logging/logging.dart';
import 'package:simple_json_persistence/simple_json_persistence.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

part 'app_data.g.dart';

final _logger = Logger('app_data');

enum OpenedFilesSourceType { Local, Url, CloudStorage, LocalWeb }

class SimpleEnumSerializer<T> extends PrimitiveSerializer<T> {
  SimpleEnumSerializer(this.enumValues);

//  final Type type;
  final List<T> enumValues;

  @override
  T deserialize(Serializers serializers, Object serialized,
      {FullType specifiedType = FullType.unspecified}) {
    assert(serialized is String);
    return enumValues.singleWhere((val) => val.toString() == serialized);
  }

  @override
  Object serialize(Serializers serializers, T object,
      {FullType specifiedType = FullType.unspecified}) {
    return object.toString();
  }

  @override
  Iterable<Type> get types => [T];

  @override
  String get wireName => T.toString();
}

abstract class OpenedFile implements Built<OpenedFile, OpenedFileBuilder> {
  factory OpenedFile([void Function(OpenedFileBuilder b) updates]) =
      _$OpenedFile;

  OpenedFile._();

  static Serializer<OpenedFile> get serializer => _$openedFileSerializer;

  static const SOURCE_CLOUD_STORAGE_ID = 'storageId'; // NON-NLS
  static const SOURCE_CLOUD_STORAGE_DATA = 'data'; // NON-NLS

  /// unique id to identify this open file across sessions.
  String get uuid;

  @BuiltValueField(compare: false)
  DateTime? get lastOpenedAt;

  OpenedFilesSourceType get sourceType;

  String get sourcePath;

  String get name;

  /// when the user to choose to store password behind biometric keystore
  /// we generate a (more or less) random name to store it into.
  String? get biometricStoreName;

  String? get macOsSecureBookmark;

  /// stores the identifier as returned by [FilePickerWritable]
  String? get filePickerIdentifier;

  int? get colorCode;

  Color? get color => colorCode == null ? null : Color(colorCode!);

  bool isSameFileAs(OpenedFile other) =>
      other.sourceType == sourceType && other.sourcePath == sourcePath;

  static OpenedFile fromFileSource(FileSource fileSource, String? dbName,
          [void Function(OpenedFileBuilder b)? customize]) =>
      OpenedFile(
        (b) {
          b.lastOpenedAt = clock.now().toUtc();
          b.uuid = fileSource.uuid;
          if (fileSource is FileSourceLocal) {
            b
              ..sourceType = OpenedFilesSourceType.Local
              ..sourcePath = fileSource.file.absolute.path
              ..macOsSecureBookmark = fileSource.macOsSecureBookmark
              ..filePickerIdentifier = fileSource.filePickerIdentifier
              ..name = dbName;
          } else if (fileSource is FileSourceWeb) {
            b
              ..sourceType = OpenedFilesSourceType.LocalWeb
              ..sourcePath = dbName
              ..name = dbName;
          } else if (fileSource is FileSourceUrl) {
            b
              ..sourceType = OpenedFilesSourceType.Url
              ..sourcePath = fileSource.url.toString()
              ..name = dbName;
          } else if (fileSource is FileSourceCloudStorage) {
            b
              ..sourceType = OpenedFilesSourceType.CloudStorage
              ..sourcePath = json.encode({
                SOURCE_CLOUD_STORAGE_ID: fileSource.provider.id,
                SOURCE_CLOUD_STORAGE_DATA: fileSource.fileInfo,
              })
              ..name = dbName;
          } else {
            throw ArgumentError.value(fileSource, 'fileSource',
                'Unsupported file type ${fileSource.runtimeType}');
          }
          if (customize != null) {
            customize(b);
          }
        },
      );

  FileSource toFileSource(CloudStorageBloc cloudStorageBloc) {
    switch (sourceType) {
      case OpenedFilesSourceType.Local:
        return FileSourceLocal(
          (const LocalFileSystem()).file(sourcePath),
          macOsSecureBookmark: macOsSecureBookmark,
          filePickerIdentifier: filePickerIdentifier,
          uuid: uuid,
          databaseName: name,
        );
      case OpenedFilesSourceType.LocalWeb:
        return FileSourceWeb(
          databaseName: name,
          uuid: uuid,
        );
      case OpenedFilesSourceType.Url:
        return FileSourceUrl(
          Uri.parse(sourcePath),
          uuid: uuid,
          databaseName: name,
        );
      case OpenedFilesSourceType.CloudStorage:
        final sourceInfo = json.decode(sourcePath) as Map<String, dynamic>;
        final storageId = sourceInfo[SOURCE_CLOUD_STORAGE_ID] as String?;
        final provider = cloudStorageBloc.providerById(storageId);
        if (provider == null) {
          throw StateError('Invalid cloud storage provider id $storageId '
              '(${cloudStorageBloc.availableCloudStorage.map((e) => e.id).join(',')})');
        }
        return provider.toFileSourceFromFileInfo(
          (sourceInfo[SOURCE_CLOUD_STORAGE_DATA] as Map)
              .cast<String, String?>(),
          uuid: uuid,
          databaseName: name,
          initialCachedContent: null,
        );

      // default:
      //   throw ArgumentError.value(
      //       sourceType, 'sourceType', 'Unsupported value.');
    }
  }
}

enum AppDataTheme { dark, light }

abstract class AppData implements Built<AppData, AppDataBuilder>, HasToJson {
  factory AppData([void Function(AppDataBuilder b)? updates]) = _$AppData;

  AppData._();

  static Serializer<AppData> get serializer => _$appDataSerializer;

  static const manualUserTypeAdmin = 'admin'; // NON-NLS

  BuiltList<OpenedFile> get previousFiles;

  int? get passwordGeneratorLength;

  BuiltSet<String> get passwordGeneratorCharacterSets;

  String? get manualUserType;

  DateTime? get firstLaunchedAt;

  /// Theme of the app, either light or dark (null means system default)
  AppDataTheme? get theme;

  ///UUid's of local Files whose warnings were dismissed
  BuiltList<String>? get dismissedBackupLocalFiles;

  bool? get dismissedAutofillSuggestion;

  bool? get dismissedRememberPassword;

  double? get themeVisualDensity;

  double? get themeFontSizeFactor;

  bool? get diacOptIn;

  /// remember which build id was used, so we might be
  /// able to show a changelog in the future..
  int? get lastBuildId;

  /// Android only: disable screenshots, etc. (FLAG_SECURE)
  bool? get secureWindow;
  bool get secureWindowOrDefault => secureWindow ?? false;

  /// allows overriding system locale to a specific language.
  String? get localeOverride;

  /// whether to fetch icons for password entries with websites from
  /// the internet, instead of showing kdbx icons.
  bool? get fetchWebsiteIcons;

  /// whether to use cloud attachments.
  bool? get authPassCloudAttachments;
  bool get authPassCloudAttachmentsOrDefault =>
      authPassCloudAttachments ?? false;

  /// whether to register system wide global shortcuts.
  bool get systemWideShortcuts;

  /// Fields used for searching. By default [CommonFields.defaultSearchFields]
  /// Values must be comma separated or `*` for all fields.
  String? get searchFields;

  // Records the uuid of the FileSource for every quick unlock
  BuiltMap<String, int>? quickUnlockCounter;

  @BuiltValueHook(initializeBuilder: true)
  static void _setDefaults(AppDataBuilder b) => b..systemWideShortcuts = false;

  @override
  Map<String, dynamic> toJson() =>
      serializers.serialize(this) as Map<String, dynamic>;

  OpenedFile? recentFileByUuid(String uuid) {
    return previousFiles.firstWhereOrNull((f) => f.uuid == uuid);
  }
}

@SerializersFor([
  AppData,
  OpenedFile,
])
Serializers serializers = (_$serializers.toBuilder()
      ..add(SimpleEnumSerializer<OpenedFilesSourceType>(
          OpenedFilesSourceType.values))
      ..add(SimpleEnumSerializer<AppDataTheme>(AppDataTheme.values))
      ..addPlugin(StandardJsonPlugin()))
    .build();

class AppDataBloc {
  AppDataBloc(this.env) {
    _init();
  }

  final Env env;

  final store = SimpleJsonPersistence.getForTypeWithDefault(
    (json) => serializers.deserializeWith(AppData.serializer, json)!,
    name: nonNls('AppData'),
    defaultCreator: () =>
        AppData((b) => b..firstLaunchedAt = clock.now().toUtc()),
    storeBackend: createStoreBackend(
        () async => (await PathUtils().getAppDataDirectory()).path),
  );

  static String createUuid() => UuidUtil.createUuid();

  Future<void> _init() async {
    await Future<dynamic>.delayed(const Duration(milliseconds: 100));
    final data = await store.load();
    final appInfo = await env.getAppInfo();
    if (data.firstLaunchedAt == null ||
        data.lastBuildId != appInfo.buildNumber) {
      await update((b, data) => b
        ..lastBuildId = appInfo.buildNumber
        ..firstLaunchedAt ??= clock.now().toUtc());
    }
  }

  ///
  /// if [oldFile] is defined non-essential data (e.g. colorCode) is copied from it.
  Future<OpenedFile> openedFile(FileSource file,
          {required String? name,
          OpenedFile? oldFile,
          Color? defaultColor}) async =>
      await update((b, data) {
        final recentFile = data.recentFileByUuid(file.uuid) ?? oldFile;
        final colorCode =
            recentFile?.colorCode ?? oldFile?.colorCode ?? defaultColor?.value;
        final openedFile = OpenedFile.fromFileSource(
            file, name, (b) => b..colorCode = colorCode);
        _logger.finest('openedFile: $openedFile');
        // TODO remove potential old storages?
        b.previousFiles.removeWhere((file) => file.isSameFileAs(openedFile));
        b.previousFiles.add(openedFile);
        return openedFile;
      });

  Future<T> update<T>(
      T Function(AppDataBuilder builder, AppData data) updater) async {
    final appData = await store.load();
    late T ret;
    final newAppData = appData.rebuild((b) => ret = updater(b, appData));
    await store.save(newAppData);
    return ret;
  }

  Future<AppDataTheme?> updateNextTheme() async {
    final updated = await update((builder, data) {
      final nextTheme = data.theme == null
          ? AppDataTheme.light
          : data.theme == AppDataTheme.light
              ? AppDataTheme.dark
              : null;
      return builder.theme = nextTheme;
    });
    return updated;
  }
}
