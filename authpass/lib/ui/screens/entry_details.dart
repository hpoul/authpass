// FIXME need to fix this lint
// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:ui' as ui;

import 'package:authpass/bloc/analytics.dart';
import 'package:authpass/bloc/app_data.dart';
import 'package:authpass/bloc/authpass_cloud_bloc.dart';
import 'package:authpass/bloc/kdbx/storage_exception.dart';
import 'package:authpass/bloc/kdbx_bloc.dart';
import 'package:authpass/env/_base.dart';
import 'package:authpass/ui/common_fields.dart';
import 'package:authpass/ui/screens/app_bar_menu.dart';
import 'package:authpass/ui/screens/barcodescan_screen.dart';
import 'package:authpass/ui/screens/cloud/cloud_auth.dart';
import 'package:authpass/ui/screens/entry_totp.dart';
import 'package:authpass/ui/screens/group_list.dart';
import 'package:authpass/ui/screens/hud.dart';
import 'package:authpass/ui/screens/password_generator.dart';
import 'package:authpass/ui/screens/password_list.dart';
import 'package:authpass/ui/widgets/icon_selector.dart';
import 'package:authpass/ui/widgets/keyboard_handler.dart';
import 'package:authpass/ui/widgets/link_button.dart';
import 'package:authpass/ui/widgets/primary_button.dart';
import 'package:authpass/ui/widgets/shortcut/authpass_intents.dart';
import 'package:authpass/utils/base32utils.dart';
import 'package:authpass/utils/constants.dart';
import 'package:authpass/utils/dialog_utils.dart';
import 'package:authpass/utils/extension_methods.dart';
import 'package:authpass/utils/format_utils.dart';
import 'package:authpass/utils/otpauth.dart';
import 'package:authpass/utils/password_generator.dart';
import 'package:authpass/utils/path_utils.dart';
import 'package:authpass/utils/platform.dart';
import 'package:authpass/utils/theme_utils.dart';
import 'package:clock/clock.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:kdbx/kdbx.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:otp/otp.dart';
import 'package:otpauth_migration/otpauth_migration.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';
import 'package:tuple/tuple.dart';

final _logger = Logger('entry_details');

class EntryDetailsScreen extends StatefulWidget {
  const EntryDetailsScreen({super.key, required this.entry});

  static Route<void> route({required KdbxEntry entry}) => MaterialPageRoute(
      settings: const RouteSettings(name: '/entry'),
      builder: (context) => EntryDetailsScreen(
            entry: entry,
          ));

  final KdbxEntry entry;

  @override
  _EntryDetailsScreenState createState() => _EntryDetailsScreenState();
}

class _EntryDetailsScreenState extends State<EntryDetailsScreen>
    with
        TaskStateMixin<EntryDetailsScreen>,
        StreamSubscriberMixin<EntryDetailsScreen>,
        KdbxObjectSavableStateMixin<EntryDetailsScreen> {
  @override
  KdbxFile get file => widget.entry.file;

  @override
  Changeable<KdbxNode> get kdbxObject => widget.entry;
  @override
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  final entryDetailsKey = GlobalKey<_EntryDetailsState>();
  EntryViewModel? entryViewModel;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final kdbxBloc = context.watch<KdbxBloc>();
    if (entryViewModel == null) {
      entryViewModel = EntryViewModel(widget.entry, kdbxBloc);
      handleSubscription(widget.entry.file.dirtyObjectsChanged.listen((event) {
        setState(() {
          entryViewModel = EntryViewModel(widget.entry, kdbxBloc);
        });
      }));
    }
  }

  @override
  Widget build(BuildContext context) {
    final env = Provider.of<Env>(context);
    final vm = entryViewModel!;
    // final vm = EntryViewModel(widget.entry, context.watch<KdbxBloc>());
    final entry = widget.entry;
    final loc = AppLocalizations.of(context);
    final analytics = context.watch<Analytics>();
    return Scaffold(
      appBar: AppBar(
        title: Text(vm.label?.takeUnlessBlank() ?? loc.noTitle),
        actions: <Widget>[
          ...?!isDirty
              ? null
              : [
                  IconButton(
                    icon: const Icon(Icons.save),
                    onPressed: saveCallback,
                  ),
                ],
          AppBarMenu.createOverflowMenuButton(
            context,
            builder: (context) => [
              if (entry.isInRecycleBin()) ...[
                PopupMenuItem(
                  value: () async {
                    final e = entry;
                    final result = await DialogUtils.showConfirmDialog(
                      context: context,
                      params: ConfirmDialogParams(
                        content: loc.permanentlyDeleteEntryConfirm(
                            e.label ?? CharConstants.empty),
                      ),
                    );
                    if (!result) {
                      analytics.events.trackPermanentlyDeleteEntryCancel();
                      return;
                    }
                    subscriptions.cancelSubscriptions();
                    final scaffoldManager = ScaffoldMessenger.of(context);
                    Navigator.of(context).pop();
                    entry.file.deletePermanently(entry);
                    analytics.events.trackPermanentlyDeleteEntry();
                    scaffoldManager.showSnackBar(SnackBar(
                        content: Text(loc.permanentlyDeletedEntrySnackBar)));
                  },
                  child: ListTile(
                    leading: const Icon(Icons.delete_forever),
                    title: Text(loc.deletePermanentlyAction),
                  ),
                ),
                PopupMenuItem(
                  value: () async {
                    final previousParent = entry.previousParentGroup
                        .get()
                        ?.let((that) => entry.file.findGroupByUuid(that));
                    final entryDetails = entryDetailsKey.currentState;
                    if (entryDetails == null) {
                      return;
                    }
                    await entryDetails._showMoveToGroup(
                      loc,
                      vm.entry,
                      toGroup: previousParent == null ||
                              previousParent.isInRecycleBin() ||
                              previousParent == entry.file.recycleBin
                          ? null
                          : previousParent,
                    );
                  },
                  child: ListTile(
                    leading: const Icon(Icons.restore_from_trash),
                    title: Text(loc.restoreFromRecycleBinAction),
                  ),
                ),
              ] else ...[
                PopupMenuItem(
                  value: () {
                    final oldGroup = entry.parent;
                    entry.file.deleteEntry(entry);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(loc.deletedEntry),
                      action: SnackBarAction(
                          label: loc.undoButtonLabel,
                          onPressed: () {
                            entry.file.move(entry, oldGroup!);
                          }),
                    ));
                  },
                  child: ListTile(
                    leading: const Icon(Icons.delete),
                    title: Text(loc.deleteAction),
                  ),
                ),
              ],
              ...?!env.isDebug
                  ? null
                  : [
                      PopupMenuItem(
                        value: () {
                          Clipboard.setData(ClipboardData(
                              text: entry.toXml().toXmlString(pretty: true)));
                        },
                        child: ListTile(
                          leading: const Icon(Icons.bug_report),
                          title: Text(nonNls('Debug: Copy XML')),
                        ),
                      ),
                    ]
            ],
          )
        ],
      ),
//      floatingActionButton: FloatingActionButton(
//        child: Icon(Icons.add),
//        onPressed: () {},
//      ),
      body: PopScope(
        canPop: !isFormDirty,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) {
            return;
          }
          final navigator = Navigator.of(context);
          if (await DialogUtils.showConfirmDialog(
            context: context,
            params: ConfirmDialogParams(
                title: loc.unsavedChangesWarningTitle,
                content: loc.unsavedChangesWarningBody,
                positiveButtonText: loc.unsavedChangesDiscardActionLabel),
          )) {
            navigator.pop();
          }
        },
        child: Form(
          key: formKey,
          onChanged: () {
            if (!isFormDirty) {
              setState(() => isFormDirty = true);
            }
          },
          child: EntryDetails(
            key: entryDetailsKey,
            entry: vm,
            onSavedPressed: !isDirty && !entry.isDirty ? null : saveCallback,
          ),
        ),
      ),
    );
  }
}

mixin KdbxObjectSavableStateMixin<T extends StatefulWidget>
    on State<T>, TaskStateMixin<T>, StreamSubscriberMixin<T> {
  GlobalKey<FormState> get formKey;

  KdbxFile get file;

  bool _isObjectDirty = false;

  bool get isDirty => _isObjectDirty || isFormDirty;
  bool isFormDirty = false;

  Changeable<KdbxNode> get kdbxObject;

  @override
  void initState() {
    super.initState();
    _registerListener();
  }

  @override
  void didUpdateWidget(T oldWidget) {
    super.didUpdateWidget(oldWidget);
    _registerListener();
  }

  void _registerListener() {
    subscriptions.cancelSubscriptions();
    handleSubscription(kdbxObject.changes.listen((change) {
      _logger.finer(
          '_isObjectDirty = ${change.isDirty} (before: $_isObjectDirty / formDirty: $isFormDirty');
      setState(() {
        _isObjectDirty = change.isDirty;
      });
    }));
  }

  @protected
  VoidCallback? get saveCallback => asyncTaskCallback(() async {
        final loc = AppLocalizations.of(context);
        final form = formKey.currentState;
        if (form == null) {
          return;
        }
        if (form.validate()) {
          form.save();
          setState(() => isFormDirty = false);
          final kdbxBloc = Provider.of<KdbxBloc>(context, listen: false);
          if (kdbxBloc.fileForKdbxFile(file).fileSource.supportsWrite) {
            try {
              await kdbxBloc.saveFile(file);
            } on StorageException catch (e, stackTrace) {
              _logger.warning('Error while saving database.', e, stackTrace);
              await DialogUtils.showErrorDialog(context,
                  loc.errorWhileSavingTitle, loc.errorWhileSavingBody(e));
              return;
            } catch (e, stackTrace) {
              _logger.severe('Error while saving database.', e, stackTrace);
              if (mounted) {
                await DialogUtils.showErrorDialog(context,
                    loc.errorWhileSavingTitle, loc.errorWhileSavingBody(e));
              }
              rethrow;
            }
          } else {
            await DialogUtils.showSimpleAlertDialog(
              context,
              null,
              loc.databaseDoesNotSupportSaving,
              routeAppend: 'databaseNoSupportSaving',
            );
          }
        }
      });
}

enum FieldType {
  string,
  otp,
}

class EntryDetails extends StatefulWidget {
  const EntryDetails(
      {super.key, required this.entry, required this.onSavedPressed});

  final EntryViewModel entry;
  final VoidCallback? onSavedPressed;

  @override
  _EntryDetailsState createState() => _EntryDetailsState();
}

class _EntryDetailsState extends State<EntryDetails>
    with StreamSubscriberMixin {
  List<Tuple3<GlobalKey<_EntryFieldState>, KdbxKey, CommonField?>>? _fieldKeys;

  IntentActionRegistration? _shortcutRegistration;

  @override
  void dispose() {
    _shortcutRegistration?.dispose();
    super.dispose();
  }

  void _initShortcutListener(
      KeyboardShortcutEvents events, CommonFields commonFields) {
    _shortcutRegistration?.dispose();
    _shortcutRegistration = events.registerActions({
      CopyPasswordIntent: CallbackAction(onInvoke: (_) {
        final context = FocusManager.instance.primaryFocus?.context;
        if (context != null) {
          _logger.fine('context: $context');
          if (context.widget is EditableText) {
            final ctrl = (context.widget as EditableText).controller;
            if (!ctrl.selection.isCollapsed && ctrl.selection.isNormalized) {
              final data = ctrl.selection.textInside(ctrl.text);
              if (data.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: data));
                if (mounted) {
                  final loc = AppLocalizations.of(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(loc.copiedToClipboard)));
                }
                return;
              }
            }
          }

          final entryFieldState =
              context.findAncestorStateOfType<_EntryFieldState>();
          if (entryFieldState != null) {
            entryFieldState.copyValue();
            return;
          }
          if (widget is EditableText) {
            return;
          }
        }

        _copyField([commonFields.password]);
        return null;
      }),
      CopyUsernameIntent: CallbackAction(onInvoke: (_) {
        _copyField([commonFields.userName]);
        return null;
      }),
      CopyTotpIntent: CallbackAction(onInvoke: (_) {
        _logger.fine('Copying ${commonFields.otpAuth}');
        _copyField([
          commonFields.otpAuth,
          commonFields.otpAuthCompat2,
          commonFields.otpAuthCompat1,
        ]);
        return null;
      }),
      OpenUrlIntent: CallbackAction(onInvoke: (_) {
        _fieldStateFor(commonFields.url)?.openUrl();
        return null;
      }),
      CopyUrlIntent: CallbackAction(onInvoke: (_) {
        _fieldStateFor(commonFields.url)?.copyValue();
        return null;
      }),
      // DismissIntent: CallbackAction(onInvoke: (_) {
      //   FocusManager.instance.primaryFocus?.unfocus();
      // }),
      // CancelSearchFilterIntent: CallbackAction(onInvoke: (_) {
      // final primaryFocus = FocusManager.instance.primaryFocus;
      // if (primaryFocus)
      //     ?.unfocus();
      //   }),
    });
  }

  _EntryFieldState? _fieldStateFor(CommonField commonField) => _fieldKeys!
      .firstWhereOrNull((f) => f.item2 == commonField.key)
      ?.item1
      .currentState;

  Future<bool> _copyField(List<CommonField> commonFields) async {
    for (final commonField in commonFields) {
      if (await _copyFieldValue(commonField)) {
        return true;
      }
    }
    final loc = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(loc.copiedFieldEmpty(commonFields.first.displayName)),
    ));
    return false;
  }

  Future<bool> _copyFieldValue(CommonField commonField) async {
    final field = _fieldStateFor(commonField);
    if (field != null) {
      if (await field.copyValue()) {
        return true;
      }
    }
    final loc = AppLocalizations.of(context);
    final entry = widget.entry.entry;
    final value = entry.getString(commonField.key);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (value == null || value.getText() == null) {
      return false;
    }
    await Clipboard.setData(
        ClipboardData(text: value.getText() ?? CharConstants.empty));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(loc.copiedFieldToClipboard(commonField.displayName)),
    ));
    return true;
  }

  void _initFields(CommonFields commonFields) {
    final entry = widget.entry.entry;
    final nonCommonKeys =
        entry.stringEntries.where((str) => !commonFields.isCommon(str.key));
    final oldKeys = _fieldKeys == null
        ? <KdbxKey, GlobalKey<_EntryFieldState>>{}
        : Map.fromEntries(_fieldKeys!.map((e) => MapEntry(e.item2, e.item1)));
    _fieldKeys = commonFields.fields
        .where((f) => f.showByDefault || entry.getString(f.key) != null)
        .map((f) => Tuple3<GlobalKey<_EntryFieldState>, KdbxKey, CommonField?>(
            oldKeys[f.key] ??
                GlobalKey<_EntryFieldState>(debugLabel: f.key.toString()),
            f.key,
            f))
        .followedBy(nonCommonKeys.map((f) => Tuple3(
            oldKeys[f.key] ??
                GlobalKey<_EntryFieldState>(debugLabel: f.key.toString()),
            f.key,
            null)))
        .toList();
    _logger.fine('Listing on changes for ${widget.entry.label}');
    handleSubscription(entry.changes.listen((event) {
      _logger.fine('Widget entry changed.');
      setState(() {});
    }));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _logger.info('_EntryDetailsState.didChangeDependencies');
    if (_fieldKeys == null) {
      subscriptions.cancelSubscriptions();
      _initFields(Provider.of<CommonFields>(context));
      _initShortcutListener(Provider.of<KeyboardShortcutEvents>(context),
          Provider.of<CommonFields>(context));
    }
  }

  @override
  void didUpdateWidget(EntryDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    _logger.fine('_EntryDetailsState.didUpdateWidget');
    if (oldWidget.entry != widget.entry) {
      _logger.info('_EntryDetailsState: widget.entry changed.');
      _initFields(Provider.of<CommonFields>(context));
    }
  }

  @override
  Widget build(BuildContext context) {
    final commonFields = Provider.of<CommonFields>(context);
    final kdbxBloc = context.watch<KdbxBloc>();
    final vm = widget.entry;
    final entry = widget.entry.entry;
    final formatUtils = Provider.of<FormatUtils>(context);
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16.0),
        child: SafeArea(
          top: false,
          left: false,
          child: Column(
            children: <Widget>[
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  const SizedBox(width: 16),
                  EntryIcon(
                    vm: vm,
                    size: 64,
                    fallback: (context) => IconSelectorFormField(
                      initialValue: SelectedIcon.fromObject(entry),
                      onSaved: (icon) {
                        // TODO is it possible for icon to be null here?!
                        icon?.when(predefined: (predefined) {
                          entry.customIcon = null;
                          entry.icon.set(predefined);
                        }, custom: (custom) {
                          entry.customIcon = custom;
                        });
                      },
                      kdbxFile: entry.file,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const SizedBox(height: 16),
                        EntryMetaInfo(
                          label: loc.entryInfoFile,
                          value: entry.file.body.meta.databaseName.get(),
                        ),
                        EntryMetaInfo(
                          label: loc.entryInfoGroup,
                          value: vm.groupNames.join(' » '), // NON-NLS
                          onTap: () async {
                            await _showMoveToGroup(loc, vm.entry);
                          },
                        ),
                        EntryMetaInfo(
                          label: loc.entryInfoLastModified,
                          value: formatUtils.formatDateFull(
                              vm.entry.times.lastModificationTime.get()!),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              ..._fieldKeys!
                  .map(
                    (f) => EntryField(
                      fieldType: commonFields.isTotp(f.item2)
                          ? FieldType.otp
                          : FieldType.string,
                      key: f.item1,
                      entry: entry,
                      fieldKey: f.item2,
                      commonField: f.item3,
                      onChangedMetadata: () => setState(() {
                        _initFields(
                            Provider.of<CommonFields>(context, listen: false));
                      }),
                    ),
                  )
                  .expand((el) => [el, const SizedBox(height: 8)]),
              AddFieldButton(
                onAddField: (key) async {
                  final cf = commonFields[key];
                  if (cf == commonFields.otpAuth) {
                    final secret = await _askForTotpSecret(context);
                    if (secret == null) {
                      return;
                    }
                    _logger.finer('Got otp auth: $secret');
                    entry.setString(key,
                        ProtectedValue.fromString(secret.toUri().toString()));
                  } else {
                    entry.setString(
                        key,
                        cf?.protect == true
                            ? ProtectedValue.fromString(CharConstants.empty)
                            : PlainValue(CharConstants.empty));
                  }
                  Provider.of<Analytics>(context, listen: false)
                      .events
                      .trackAddField(key: key.key);
                  _initFields(
                      Provider.of<CommonFields>(context, listen: false));
                  setState(() {});
                },
              ),
              const Divider(),
              ...entry.binaryEntries.map((e) {
                final info = kdbxBloc.attachmentInfo(e.value);
                return InkWell(
                  onTap: () async {
                    await showModalBottomSheet<void>(
                        context: context,
                        builder: (context) => AttachmentBottomSheet(
                              entry: entry,
                              attachment: e,
                            ));
                  },
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 500),
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 8,
                    ),
                    child: Row(
                      children: <Widget>[
                        info == null
                            ? const Icon(Icons.attach_file)
                            : const Icon(Icons.cloud),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(e.key.key,
                                  style: theme.textTheme.titleMedium),
                              const SizedBox(height: 2),
                              info == null
                                  ? Text(loc.sizeBytes(e.value.value.length),
                                      style: theme.textTheme.bodySmall)
                                  : Text(
                                      loc.sizeBytesStoredAuthPassCloud(
                                          info.size),
                                      style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              LinkButton(
                icon: const Icon(Icons.attach_file),
                onPressed: _attachFile,
                child: Text(loc.entryAddAttachment),
              ),
              const SizedBox(height: 16),
              Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    LinkButton(
                      icon: const Icon(Icons.undo_outlined),
                      onPressed: () => setState(() {
                        _initFields(
                            Provider.of<CommonFields>(context, listen: false));
                      }),
                      child: Text(loc.resetValue),
                    ),
                    const SizedBox(width: 16),
                    PrimaryButton(
                      icon: const Icon(Icons.save),
                      onPressed: widget.onSavedPressed,
                      child: Text(loc.saveButtonLabel),
                    ),
                  ]
              )
            ],
          ),
        ),
      ),
    );
  }

  Future<KdbxGroup?> _showMoveToGroup(AppLocalizations loc, KdbxEntry entry,
      {final KdbxGroup? toGroup}) async {
    final file = entry.file;
    final newGroup = toGroup ??
        (await Navigator.of(context).push(GroupListFlat.route(
          {entry.parent!},
          groupListMode: GroupListMode.singleSelect,
          rootGroup: entry.file.body.rootGroup,
        )))
            ?.firstOrNull;
    if (newGroup != null) {
      final oldGroup = entry.parent;
      file.move(entry, newGroup);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(loc.movedEntryToGroup(newGroup.name.get()!)),
          action: SnackBarAction(
              label: loc.undoButtonLabel,
              onPressed: () {
                file.move(entry, oldGroup!);
              }),
        ),
      );
    }
    return newGroup;
  }

  Future<void> _attachFile() async {
    if (AuthPassPlatform.isIOS || AuthPassPlatform.isAndroid) {
      await FilePickerWritable().openFile((fileInfo, file) async {
        final fileName = fileInfo.fileName ?? file.path;
        final bytes = await file.readAsBytes();
        await _attachFileContent(fileName, bytes);
        return fileInfo;
      });
    } else {
      final file = await openFile(acceptedTypeGroups: []);
      if (file != null) {
        final fileName = path.basename(file.path);
        final bytes = await file.readAsBytes();
        await _attachFileContent(fileName, bytes);
      }
    }
  }

  Future<void> _attachFileContent(String fileName, Uint8List bytes) async {
    final analytics = Provider.of<Analytics>(context, listen: false);
    final loc = AppLocalizations.of(context);
    final kdbxBloc = widget.entry.kdbxBloc;

    final attachmentProvider =
        await kdbxBloc.attachmentProviderForFileSource(widget.entry.entry.file);

    if (attachmentProvider is! AttachmentProviderAuthPassCloud &&
        bytes.lengthInBytes > 10 * 1024) {
      if (!await DialogUtils.showConfirmDialog(
        context: context,
        params: ConfirmDialogParams(
          content: loc.entryAttachmentSizeWarning,
        ),
      )) {
        analytics.events.trackAttachmentAdd(
          AttachmentAddType.canceled,
          path.extension(fileName),
          bytes.lengthInBytes,
        );
        return;
      }
    }
    analytics.events.trackAttachmentAdd(
      AttachmentAddType.success,
      path.extension(fileName),
      bytes.lengthInBytes,
    );
    await attachmentProvider.attachFile(
      entry: widget.entry.entry,
      fileName: fileName,
      bytes: bytes,
    );
  }

  Future<OtpAuth?> _askForTotpSecret(BuildContext context) async {
    Future<OtpAuth?> cleanOtpCodeCode(String totpCode) async {
      try {
        if (totpCode.startsWith(OtpAuth.URI_PREFIX)) {
          return OtpAuth.fromUri(Uri.parse(totpCode));
        }
        if (totpCode.startsWith(OtpAuth.MIGRATION_URI_PREFIX)) {
          final migration = OtpAuthMigration();
          final uris = migration.decode(totpCode);
          if (uris.length != 1) {
            final loc = AppLocalizations.of(context);
            await DialogUtils.showErrorDialog(
              context,
              loc.otpUnsupportedMigrationTitle,
              loc.otpUnsupportedMigrationBody(uris.length),
              routeAppend: 'invalidTotpMigration',
            );
            return null;
          }
          return OtpAuth.fromUri(Uri.parse(uris.first));
        }
        final value = base32Decode(totpCode);
        _logger.fine('Got totp secret with ${value.lengthInBytes} bytes.');
        return OtpAuth(secret: value);
      } catch (e, stackTrace) {
        _logger.warning('Invalid base32 code?', e, stackTrace);
        final loc = AppLocalizations.of(context);
        await DialogUtils.showSimpleAlertDialog(
          context,
          loc.otpInvalidKeyTitle,
          loc.otpInvalidKeyBody,
          routeAppend: 'totpInvalidKey',
        );
        return await _askForTotpSecret(context);
      }
    }

    if (AuthPassPlatform.isIOS || AuthPassPlatform.isAndroid) {
      try {
        _logger.finer('Opening barcode scanner.');
//        final barcode = await FlutterBarcodeScanner.scanBarcode(
//            '#ff6666', 'Cancel', true, ScanMode.QR);

        final loc = AppLocalizations.of(context);
        final barcodeResult = await BarcodeScanHelper.scanBarcode(
          context,
          titleText: loc.scanQrCodeTitle,
          formats: [
            BarcodeFormat.qrCode,
            BarcodeFormat.microQRCode,
          ],
        );

        if (barcodeResult case ScanResultValid(barcode: final barcode)) {
          return cleanOtpCodeCode(barcode.text);
        }

//        final scanResult = await barcode.BarcodeScanner.scan();
//        _logger.fine('Got scan result of type ${scanResult.type} -'
//            ' ${scanResult.format} (${scanResult.formatNote})');
//        if (scanResult != null &&
//            scanResult.type == barcode.ResultType.Barcode) {
//          return _cleanOtpCodeCode(scanResult.rawContent);
//        }
      } catch (e, stackTrace) {
        _logger.warning('Error during barcode scanning.', e, stackTrace);
      }
    }
    final loc = AppLocalizations.of(context);
    final totpCode = await SimplePromptDialog(
      title: loc.otpPromptTitle,
      helperText: loc.otpPromptHelperText,
    ).show(context);
    if (totpCode == null) {
      return null;
    }
    return cleanOtpCodeCode(totpCode);
  }
}

class AttachmentBottomSheet extends StatelessWidget {
  const AttachmentBottomSheet({
    super.key,
    required this.entry,
    required this.attachment,
  });

  final KdbxEntry entry;
  final MapEntry<KdbxKey, KdbxBinary> attachment;

  @override
  Widget build(BuildContext context) {
    final analytics = Provider.of<Analytics>(context);
    final loc = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.open_in_new),
          title: Text(loc.entryAttachmentOpenActionLabel),
          onTap: () async {
            analytics.events.trackAttachmentAction('open');
            Navigator.of(context).pop();
            final kdbxBloc = context.read<KdbxBloc>();
            final provider =
                await kdbxBloc.attachmentProviderForFileSource(entry.file);
            final bytes = await provider.readAttachmentBytes(
                entry.file, attachment.value);
            final f = await PathUtils().saveToTempDirectory(bytes,
                dirPrefix: 'openbinary', fileName: attachment.key.key);
            _logger.fine('Opening ${f.path}');
            final result = await OpenFilex.open(f.path);
            _logger.fine('finished opening $result');
          },
        ),
        if (AuthPassPlatform.isIOS || AuthPassPlatform.isAndroid)
          ListTile(
            leading: const Icon(Icons.share),
            title: Text(loc.entryAttachmentShareActionLabel),
            onTap: () async {
              analytics.events.trackAttachmentAction('share');
              final kdbxBloc = context.read<KdbxBloc>();
              final provider =
                  await kdbxBloc.attachmentProviderForFileSource(entry.file);
              final bytes = await provider.readAttachmentBytes(
                  entry.file, attachment.value);
              final mimeType = lookupMimeType(
                attachment.key.key,
                headerBytes: bytes.length > defaultMagicNumbersMaxLength
                    ? Uint8List.sublistView(
                        bytes, 0, defaultMagicNumbersMaxLength)
                    : null,
              )!;
              _logger.fine('Opening attachment with mimeType $mimeType');

              final tempDir = await PathUtils().getTemporaryDirectory();
              final f = await tempDir.childFile(attachment.key.key).create();
              await f.writeAsBytes(bytes);

              try {
                await Share.shareXFiles([XFile(f.path, mimeType: mimeType)],
                    subject: loc.entryAttachmentShareSubject);
              } finally {
                unawaited(f.delete());
              }

              // Share.file('Attachment', attachment.key.key,
              //     attachment.value.value, mimeType);
              Navigator.of(context).pop();
            },
          ),
        if (AuthPassPlatform.isIOS || AuthPassPlatform.isAndroid)
          ListTile(
            leading: const Icon(Icons.save),
            title: Text(loc.entryAttachmentSaveActionLabel),
            onTap: () async {
              analytics.events.trackAttachmentAction('saveToDevice');
              Navigator.of(context).pop();
              final kdbxBloc = context.read<KdbxBloc>();
              final provider =
                  await kdbxBloc.attachmentProviderForFileSource(entry.file);
              final bytes = await provider.readAttachmentBytes(
                  entry.file, attachment.value);
              await FilePickerWritable().openFileForCreate(
                  fileName: attachment.key.key,
                  writer: (file) async {
                    _logger.fine('Opening ${file.path}');
                    await file.writeAsBytes(bytes);
                  });
            },
          ),
        ListTile(
          leading: const Icon(Icons.delete),
          title: Text(loc.entryAttachmentRemoveActionLabel),
          onTap: () async {
            analytics.events.trackAttachmentAction('remove');
            Navigator.of(context).pop();
            final confirm = await DialogUtils.showConfirmDialog(
                context: context,
                params: ConfirmDialogParams(
                    content:
                        loc.entryAttachmentRemoveConfirm(attachment.key.key)));
            if (confirm) {
              entry.removeBinary(attachment.key);
            }
          },
        ),
      ],
    );
  }
}

class EntryMetaInfo extends StatelessWidget {
  const EntryMetaInfo({
    super.key,
    this.label,
    this.value,
    this.onTap,
  });

  final String? label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Row(
//          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            ...?onTap == null
                ? null
                : [
                    const Icon(Icons.edit, size: 16, color: Colors.black45),
                    const SizedBox(width: 8),
                  ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label!, style: theme.textTheme.bodySmall),
                  Text(
                    value!,
                    style: theme.textTheme.bodyLarge!
                        .copyWith(color: theme.textTheme.bodySmall!.color),
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AddFieldButton extends StatefulWidget {
  const AddFieldButton({super.key, required this.onAddField});

  final void Function(KdbxKey key) onAddField;

  @override
  _AddFieldButtonState createState() => _AddFieldButtonState();
}

class _AddFieldButtonState extends State<AddFieldButton> {
  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return LinkButton(
      icon: const Icon(Icons.add_circle_outline),
      onPressed: () async {
        final rb = context.findRenderObject() as RenderBox;
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        final position = RelativeRect.fromRect(
          Rect.fromPoints(
            rb.localToGlobal(Offset.zero, ancestor: overlay),
            rb.localToGlobal(rb.size.bottomRight(Offset.zero),
                ancestor: overlay),
          ),
          Offset.zero & overlay.size,
        );
        final commonFields = Provider.of<CommonFields>(context, listen: false);
        final custom = CommonField(
          displayName: loc.entryCustomField,
          key: KdbxKey('__custom'), // NON-NLS
        );
        final fields = commonFields.fields.followedBy([custom]).map(
          (f) => PopupMenuItem(
            value: f.key,
            child: ListTile(leading: Icon(f.icon), title: Text(f.displayName)),
          ),
        );
        final key = await showMenu<KdbxKey>(
          context: context,
          position: position,
          items: [
            ...fields,
          ],
          initialValue: custom.key,
        );
        if (key != null) {
          if (key == custom.key) {
            await _selectCustomKey();
          } else {
            widget.onAddField(key);
          }
        }
      },
      child: Text(loc.entryAddField),
    );
  }

  Future<void> _selectCustomKey() async {
    final loc = AppLocalizations.of(context);
    final key = await SimplePromptDialog(
      title: loc.entryCustomFieldTitle,
      labelText: loc.entryCustomFieldInputLabel,
    ).show(context);
    if (key != null && key.isNotEmpty) {
      widget.onAddField(KdbxKey(key));
    }
  }
}

class EntryField extends StatefulWidget {
  const EntryField({
    super.key,
    required this.fieldType,
    required this.entry,
    required this.fieldKey,
    this.commonField,
    required this.onChangedMetadata,
  });

  final FieldType fieldType;
  final KdbxEntry entry;
  final KdbxKey fieldKey;
  final CommonField? commonField;
  final VoidCallback onChangedMetadata;

  @override
  _EntryFieldState createState() =>
      // ignore: no_logic_in_create_state
      fieldType == FieldType.otp ? _OtpEntryFieldState() : _EntryFieldState();
}

enum EntryAction {
  copy,
  copyRawData,
  rename,
  protect,
  delete,
  show,
  passwordGenerator,
  generateEmail,
}

abstract class FieldDelegate {
  Future<void> generatePassword();

  Future<void> openUrl();
}

class _EntryFieldState extends State<EntryField>
    with StreamSubscriberMixin, TaskStateMixin
    implements FieldDelegate {
  final GlobalKey _formFieldKey = GlobalKey();
  late TextEditingController _controller;
  bool _isValueObscured = false;
  final FocusNode _focusNode = FocusNode();
  late CommonFields _commonFields;

  IntentActionRegistration? _keyboardRegistration;

  StringValue? get _fieldValue => widget.entry.getString(widget.fieldKey);

  set _fieldValue(StringValue? value) {
    widget.entry.setString(widget.fieldKey, value);
  }

  bool get _isProtected => _fieldValue == null
      ? widget.commonField?.protect == true
      : _fieldValue is ProtectedValue;

  String? get _valueCurrent =>
      (_isValueObscured
          ? widget.entry.getString(widget.fieldKey)?.getText()
          : _controller.text) ??
      _fieldValue?.getText();

  final GlobalKey<HighlightWidgetState> _highlightWidgetKey =
      GlobalKey<HighlightWidgetState>();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_focusNodeChanged);
    _initController();
  }

  void _initController() {
    if (_fieldValue is ProtectedValue || widget.commonField?.protect == true) {
      _isValueObscured = true;
      _controller = TextEditingController();
    } else {
      _controller = TextEditingController(
          text: _fieldValue?.getText() ?? CharConstants.empty);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _commonFields = Provider.of<CommonFields>(context);
    if (widget.fieldKey == _commonFields.password.key) {
      _keyboardRegistration?.dispose();
      final keyboardShortcutEvents = context.watch<KeyboardShortcutEvents>();
      _keyboardRegistration = keyboardShortcutEvents.registerActions({
        GeneratePassword: CallbackAction(onInvoke: (_) => _generatePassword()),
      });
    }
  }

  void _focusNodeChanged() {
    if (!_isProtected) {
      return;
    }
    _logger.info(
        'Focus changed to ${_focusNode.hasFocus} (primary: ${_focusNode.hasPrimaryFocus})');
    if (!_focusNode.hasFocus) {
      setState(() {
        _fieldValue = ProtectedValue.fromString(_controller.text);
        _isValueObscured = true;
        _logger.finer('${widget.fieldKey} _isProtected= $_isValueObscured');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    _logger.finer('building ${widget.fieldKey} ($_isValueObscured)');
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey(widget.fieldKey),
      background: Container(
        alignment: Alignment.centerLeft,
        color: theme.brightness == Brightness.light
            ? Colors.lightBlueAccent
            : Colors.blueAccent,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.lock),
            const SizedBox(height: 4),
            Text(loc.swipeCopyField),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
//        await ClipboardManager.copyToClipBoard(_value.getText());
        await copyValue();
        return false;
      },
      child: HighlightWidget(
        key: _highlightWidgetKey,
        childOnHighlight: Text(loc.doneCopiedField,
            style: theme.textTheme.bodyMedium!
                .copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  shadows: const [
                    Shadow(
                      color: Colors.black,
                      blurRadius: 1,
                    )
                  ],
                  letterSpacing: 1,
                )
                .apply(fontSizeFactor: 1.2)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Expanded(
                child: _buildEntryFieldEditor(),
              ),
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                child: AnimatedCrossFade(
                  duration: const Duration(milliseconds: 300),
                  firstChild: PopupMenuButton<EntryAction>(
                    icon: const Icon(Icons.more_vert),
                    offset: const Offset(0, 32),
                    onSelected: _handleMenuEntrySelected,
                    itemBuilder: _buildMenuEntries,
                  ),
                  secondChild: const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: CircularProgressIndicator(),
                  ),
                  crossFadeState: task == null
                      ? CrossFadeState.showFirst
                      : CrossFadeState.showSecond,
                ),
              ),
//            IconButton(
//              icon: Icon(Icons.content_copy),
//              tooltip: 'Copy to clipboard',
//              onPressed: () {
//                ClipboardManager.copyToClipBoard(_value.getText());
//              },
//            ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleMenuEntrySelected(EntryAction entryAction) async {
    switch (entryAction) {
      case EntryAction.copy:
        await copyValue();
        break;
      case EntryAction.copyRawData:
        // only used by [_OtpEntryFieldState]
        throw UnsupportedError('Field does not support this action.');
      case EntryAction.rename:
        final loc = AppLocalizations.of(context);
        final key = await SimplePromptDialog(
          title: loc.entryRenameFieldPromptTitle,
          labelText: loc.entryRenameFieldPromptLabel,
          initialValue: widget.fieldKey.key,
        ).show(context);
        if (key != null) {
          widget.entry.renameKey(widget.fieldKey, KdbxKey(key));
          widget.onChangedMetadata();
        }
        break;
      case EntryAction.passwordGenerator:
        await _launchPasswordGenerator();
        break;
      case EntryAction.protect:
        setState(() {
          if (_isProtected) {
            _fieldValue = PlainValue(_valueCurrent ?? CharConstants.empty);
            _isValueObscured = false;
          } else {
            _logger.fine(
                'protected: $_isProtected, obscured: $_isValueObscured, current: $_valueCurrent');
            _fieldValue =
                ProtectedValue.fromString(_valueCurrent ?? CharConstants.empty);
            _isValueObscured = true;
          }
          _initController();
        });
        break;
      case EntryAction.delete:
        widget.entry.removeString(widget.fieldKey);
        widget.onChangedMetadata();
        break;
      case EntryAction.show:
        FullScreenHud.show(context, (context) {
          return FullScreenHud(
            value: _valueCurrent ?? CharConstants.empty,
          );
        });
        break;
      case EntryAction.generateEmail:
        context.events.trackEntryAction(EntryActionType.generateEmail);
        final bloc = context.read<AuthPassCloudBloc>();
        if (bloc.tokenStatus != TokenStatus.confirmed) {
          await Navigator.of(context).push(AuthPassCloudAuthScreen.route());
        } else {
          await asyncRunTask(() async {
            final address =
                await bloc.createMailbox(entryUuid: widget.entry.uuid.uuid);
            setState(() {
              _isValueObscured = false;
              _controller.text = address!;
              _fieldValue = PlainValue(_controller.text);
              copyValue();
            });
          });
        }
        break;
    }
  }

  List<PopupMenuEntry<EntryAction>> _buildMenuEntries(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return <PopupMenuEntry<EntryAction>>[
      PopupMenuItem(
        value: EntryAction.copy,
        child: ListTile(
          leading: const Icon(Icons.content_copy),
          title: Text(loc.swipeCopyField),
        ),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: EntryAction.rename,
        child: ListTile(
          leading: const Icon(Icons.edit),
          title: Text(loc.fieldRename),
        ),
      ),
      PopupMenuItem(
        value: EntryAction.passwordGenerator,
        child: ListTile(
          leading: const Icon(FontAwesomeIcons.shuffle),
          title: Text(loc.generatePassword),
//            subtitle: null,
        ),
      ),
      ...?_buildMenuEntriesAuthPassCloud(context),
      PopupMenuItem(
        value: EntryAction.protect,
        child: ListTile(
          leading: Icon(
              _isProtected ? Icons.no_encryption : Icons.enhanced_encryption),
          title: Text(_isProtected ? loc.fieldUnprotect : loc.fieldProtect),
        ),
      ),
      PopupMenuItem(
        value: EntryAction.delete,
        child: ListTile(
          leading: const Icon(Icons.delete),
          title: Text(loc.deleteAction),
        ),
      ),
      PopupMenuItem(
        value: EntryAction.show,
        child: ListTile(
//                    leading: Icon(Icons.present_to_all),
          leading: const Icon(FontAwesomeIcons.qrcode),
          title: Text(loc.fieldPresent),
        ),
      ),
    ];
  }

  @override
  Future<void> openUrl() async {
    context.events.trackEntryAction(EntryActionType.openUrl);
    final url = _valueCurrent!;
    final loc = AppLocalizations.of(context);
    String? openError;
    try {
      var parsed = Uri.parse(url);
      if (!parsed.hasScheme) {
        parsed = Uri.parse('http://$url'); // NON-NLS
      }
      _logger.finer('Opening url $url ($parsed)');
      if (await DialogUtils.openUrl(parsed.toString())) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(loc.launchedUrl(url))));
      } else {
        openError = loc.unableToLaunchUrlNoHandler;
      }
    } catch (e, stackTrace) {
      openError = e.toString();
      _logger.severe('Unable to open url, $url', e, stackTrace);
    }
    if (openError != null) {
      await DialogUtils.showErrorDialog(context, loc.unableToLaunchUrlTitle,
          loc.unableToLaunchUrlDescription(url, openError));
    }
  }

  @override
  Future<void> generatePassword() => _generatePassword();

  Future<void> _generatePassword() async {
    context.events.trackEntryAction(EntryActionType.generatePassword);
    final appData =
        await Provider.of<AppDataBloc>(context, listen: false).store.load();
    final characterSets = CharacterSet.characterSetFromIds(
        appData.passwordGeneratorCharacterSets);
    if (characterSets.isEmpty) {
      characterSets.addAll([CharacterSet.alphaNumeric, CharacterSet.numeric]);
    }
    final length = appData.passwordGeneratorLength ?? 16;
    _generatedPassword(
      PasswordGenerator.singleton().generatePassword(
        CharacterSetCollection(characterSets.toList()),
        length,
      ),
    );
  }

  Future<void> _launchPasswordGenerator() async {
    final password = await Navigator.of(context).push(
        PasswordGeneratorScreen.route(finishButton: FinishButtonStyle.done));
    if (password != null) {
      setState(() {
        _generatedPassword(password);
      });
    }
  }

  void _generatedPassword(String password) {
    setState(() {
      _isValueObscured = false;
      _controller.text = password;
      _fieldValue = ProtectedValue.fromString(_controller.text);
      _controller.selection =
          TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
      _focusNode.requestFocus();
    });
    copyValue();
  }

  Future<bool> copyValue() async {
    _highlightWidgetKey.currentState!.triggerHighlight();
    Provider.of<Analytics>(context, listen: false)
        .events
        .trackCopyField(key: widget.fieldKey.key);
    await Clipboard.setData(
        ClipboardData(text: _valueCurrent ?? CharConstants.empty));
    return true;
  }

  Widget _buildEntryFieldEditor() =>
      _isValueObscured && _valueCurrent?.isEmpty == false
          ? _buildObscuredEntryFieldEditor()
          : _buildStringEntryFieldEditor();

  Widget _buildObscuredEntryFieldEditor() {
    return ObscuredEntryFieldEditor(
      onPressed: () {
        setState(() {
          _controller.text = _valueCurrent ?? CharConstants.empty;
          _controller.selection = TextSelection(
              baseOffset: 0, extentOffset: _controller.text.length);
          _isValueObscured = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _focusNode.requestFocus();
            _logger.finer('requesting focus.');
          });
        });
      },
      onShowPressed: () {
        _handleMenuEntrySelected(EntryAction.show);
      },
      fieldKey: widget.fieldKey,
      commonField: widget.commonField,
    );
  }

  Widget _buildStringEntryFieldEditor() {
    return StringEntryFieldEditor(
      onSaved: (value) {
        if (value == null) {
          _fieldValue = null;
        } else {
          final newValue = _isProtected
              ? ProtectedValue.fromString(value)
              : PlainValue(value);
          _fieldValue = newValue;
        }
      },
      fieldKey: widget.fieldKey,
      commonField: widget.commonField,
      controller: _controller,
      formFieldKey: _formFieldKey,
      focusNode: _focusNode,
      delegate: this,
    );
  }

  @override
  void dispose() {
    _logger
        .fine('EntryFieldState.dispose() - ${widget.key} (${widget.fieldKey})');
    _keyboardRegistration?.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  List<PopupMenuEntry<EntryAction>>? _buildMenuEntriesAuthPassCloud(
      BuildContext context) {
    final authPassCloud = context.read<AuthPassCloudBloc>();
    if (authPassCloud.featureFlags.authpassCloud != true) {
      return null;
    }
    if (authPassCloud.tokenStatus != TokenStatus.confirmed) {
      return null;
    }
    final loc = AppLocalizations.of(context);
    return [
      PopupMenuItem(
          value: EntryAction.generateEmail,
          child: ListTile(
            leading: const Icon(Icons.cloud),
            title: Text(loc.fieldGenerateEmail),
            subtitle: const Text(Env.AuthPassCloud),
          )),
    ];
  }
}

class _OtpEntryFieldState extends _EntryFieldState {
  Timer? _timer;

  String _currentOtp = CharConstants.empty;

  String? _errorMessage;

  /// elapsed seconds since the last period change.
  int _elapsed = 0;

  /// period in seconds how often the otp changes.
  int _period = 30;

  @override
  String get _valueCurrent =>
      widget.entry.getString(widget.fieldKey)?.getText() ?? CharConstants.empty;

  OtpAuth _getOtpAuth() {
    final value = widget.entry.getString(widget.fieldKey)?.getText();
    if (value == null || value.isEmpty) {
      return throw FormatException('OTP Field contains no data.', value);
    }
    if (value.startsWith(OtpAuth.URI_PREFIX)) {
      // Our own format :-) (And also used by KeeWeb)
      return OtpAuth.fromUri(Uri.parse(value));
    }
    final otpAuth = OtpAuth.fromQueryString(value);
    if (otpAuth != null) {
      return otpAuth;
    }
    // assume base32 encoded secret, with more settings stored in a second field.
    try {
      final binarySecret = base32Decode(value);
      final settings =
          _commonFields.otpAuthCompat1Settings.stringValue(widget.entry) ??
              CharConstants.empty;
      final settingsOptions = settings.isEmpty
          ? <String>[]
          : settings.split(CharConstants.semiColon);
      _logger.finest('settings: $settings');
      return OtpAuth(
        secret: binarySecret,
        period: settingsOptions.optGet(0)?.toInt() ?? OtpAuth.DEFAULT_PERIOD,
        digits: settingsOptions.optGet(1)?.toInt() ?? OtpAuth.DEFAULT_DIGITS,
      );
    } on FormatException catch (e, stackTrace) {
      // ignore format exception from base32 decoding.
      _logger.fine('Error decoding base32 secret', e, stackTrace);
    } catch (e, stackTrace) {
      _logger.fine('Error while parsing OTP format', e, stackTrace);
      throw FormatException('Error parsing Tray OTP Format $e', value);
    }
    throw FormatException('Unknown format for OTP', value);
  }

  void _updateOtp() {
    try {
      final otpAuth = _getOtpAuth();
      final secretBase32 = base32Encode(otpAuth.secret);
      _logger.fine('uri: $otpAuth');
      final now = clock.now().millisecondsSinceEpoch;
      final totpCode = OTP.generateTOTPCodeString(
        secretBase32,
        now,
        algorithm: otpAuth.algorithm,
        length: otpAuth.digits,
        interval: otpAuth.period,
        // do not pad OTP secret if it is not of correct length.
        isGoogle: true,
      );
      setState(() {
        _elapsed = (now ~/ 1000) % otpAuth.period;
        _period = otpAuth.period;
        _currentOtp = totpCode;
        _errorMessage = null;
      });
    } on FormatException catch (e, stackTrace) {
      _logger.severe('Error while decoding otpauth url for ${widget.fieldKey}.',
          e, stackTrace);
      final loc = AppLocalizations.of(context);
      setState(() {
        _currentOtp = CharConstants.empty;
        _errorMessage = loc.otpErrorMessageGeneration(e);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timer == null) {
      _updateOtp();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _updateOtp();
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<bool> copyValue() async {
    _logger.finer('Copying OTP value.');
    _highlightWidgetKey.currentState!.triggerHighlight();
    Provider.of<Analytics>(context, listen: false)
        .events
        .trackCopyField(key: widget.fieldKey.key);
    await Clipboard.setData(ClipboardData(text: _currentOtp));
    return true;
  }

  @override
  Widget _buildEntryFieldEditor() =>
      _errorMessage?.let((it) => Text(it)) ??
      OtpFieldEntryEditor(
        period: _period,
        elapsed: _elapsed,
        otpCode: _currentOtp,
      );

  @override
  Future<void> _handleMenuEntrySelected(EntryAction entryAction) async {
    if (entryAction == EntryAction.copyRawData) {
      await Clipboard.setData(ClipboardData(text: _valueCurrent));
      return;
    }
    return super._handleMenuEntrySelected(entryAction);
  }

  @override
  List<PopupMenuEntry<EntryAction>> _buildMenuEntries(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return super
        ._buildMenuEntries(context)
        .where((item) =>
            item is PopupMenuItem &&
            const [
              EntryAction.delete,
              EntryAction.copy,
            ].contains((item as PopupMenuItem).value))
        .followedBy([
      PopupMenuItem(
        value: EntryAction.copyRawData,
        child: ListTile(
          leading: const Icon(Icons.code),
          title: Text(loc.otpCopySecretActionLabel),
        ),
      )
    ]).toList();
  }
}

class ObscuredEntryFieldEditor extends StatelessWidget {
  const ObscuredEntryFieldEditor({
    super.key,
    required this.onPressed,
    required this.onShowPressed,
    required this.commonField,
    required this.fieldKey,
  });

  final CommonField? commonField;
  final KdbxKey fieldKey;
  final VoidCallback onPressed;
  final VoidCallback onShowPressed;

  @override
  Widget build(BuildContext context) {
    final color = ThemeUtil.iconColor(Theme.of(context), null);
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);

    return Stack(
      alignment: Alignment.centerRight,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            prefixIcon:
                commonField?.icon == null ? null : Icon(commonField!.icon),
            labelText: commonField?.displayName ?? fieldKey.key,
            filled: true,
            labelStyle: TextStyle(color: color.withOpacity(0.2)),
          ),
          child: Text(
            nonNls('*') * 10,
            style: TextStyle(color: color.withOpacity(0.2)),
          ),
        ),
        Positioned.fill(
          child: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: 0.5,
                sigmaY: 0.5,
              ),
              child: LinkButton(
                onPressed: onPressed,
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.only(
                    left: 24.0,
                    right: 24.0,
                    // bottom: 16,
                  ),
                  child: Text(
                    loc.entryFieldProtected,
                    style: TextStyle(
                      color:
                          theme.isDarkTheme ? Colors.white : theme.primaryColor,
                      shadows: [
                        Shadow(
                            color: theme.isDarkTheme
                                ? Colors.black87
                                : Colors.white,
                            blurRadius: 5)
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(FontAwesomeIcons.eye),
          color: color,
          tooltip: loc.entryFieldActionRevealField,
          onPressed: onShowPressed,
        ),
      ],
    );
  }
}

class StringEntryFieldEditor extends StatelessWidget {
  const StringEntryFieldEditor({
    super.key,
    required this.onSaved,
    required this.controller,
    required this.formFieldKey,
    required this.focusNode,
    required this.commonField,
    required this.fieldKey,
    required this.delegate,
  });

  final Key formFieldKey;
  final FocusNode focusNode;
  final CommonField? commonField;
  final KdbxKey fieldKey;
  final TextEditingController? controller;
  final FormFieldSetter<String> onSaved;
  final FieldDelegate delegate;

  @override
  Widget build(BuildContext context) {
    final commonFields = Provider.of<CommonFields>(context);
    final loc = AppLocalizations.of(context);
    final color = ThemeUtil.iconColor(Theme.of(context), null);
    return Stack(alignment: Alignment.centerRight, children: [
      TextFormField(
        key: formFieldKey,
        maxLines: null,
        focusNode: focusNode,
        decoration: InputDecoration(
          filled: true,
          prefixIcon:
              commonField?.icon == null ? null : Icon(commonField!.icon),
          labelText: commonField?.displayName ?? fieldKey.key,
        ),
        keyboardType: commonField?.keyboardType,
        autocorrect: commonField?.autocorrect ?? true,
        enableSuggestions: commonField?.enableSuggestions ?? true,
        textCapitalization:
            commonField?.textCapitalization ?? TextCapitalization.sentences,
        controller: controller,
        onSaved: onSaved,
      ),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller!,
        builder: (context, value, child) {
          if (fieldKey == commonFields.password.key &&
              controller!.text.isEmpty) {
            return IconButton(
                tooltip: '${loc.menuItemGeneratePassword} (cmd+g)', // NON-NLS
                icon: const Icon(Icons.refresh),
                onPressed: delegate.generatePassword,
                color: color);
          }
          if (fieldKey == commonFields.url.key && controller!.text.isNotEmpty) {
            return IconButton(
                tooltip: '${loc.actionOpenUrl} (shift+cmd+U)', // NON-NLS
                icon: const Icon(Icons.open_in_new),
                onPressed: delegate.openUrl,
                color: color);
          }
          return const SizedBox();
        },
      ),
    ]);
  }
}

class HighlightWidget extends StatefulWidget {
  const HighlightWidget({super.key, this.child, this.childOnHighlight});

  final Widget? child;
  final Widget? childOnHighlight;

  @override
  HighlightWidgetState createState() => HighlightWidgetState();
}

class HighlightWidgetState extends State<HighlightWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  Animation<Decoration>? _decorationAnimation;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _controller.addStatusListener(_animationStatusChanged);
  }

  void _animationStatusChanged(AnimationStatus status) {
    _logger.finer('Highlight animation status changed: $status');
    if (status == AnimationStatus.completed) {
      setState(() {
        _decorationAnimation = null;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _decorationAnimation == null
        ? widget.child!
        /* Stack(children: [
            widget.child,
            Positioned.fill(
                child: Opacity(
              opacity: 0.9,
              child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.5),
                    backgroundBlendMode: BlendMode.color,
                    /*boxShadow: const [BoxShadow(blurRadius: 2)]*/
                  ),
                  child: Center(child: widget.childOnHighlight)),
            ))
          ])*/
        : Stack(
            clipBehavior: Clip.none,
            children: [
              widget.child!,
              Positioned.fill(
                top: -4,
                bottom: -4,
                child: FadeTransition(
                  opacity: _opacity,
                  child: DecoratedBoxTransition(
                      decoration: _decorationAnimation!,
                      child: Center(child: widget.childOnHighlight)),
                ),
              ),
            ],
          );
  }

  void triggerHighlight() {
    final tween = DecorationTween(
      begin: BoxDecoration(
        color: Colors.green.withOpacity(0.8),
//        backgroundBlendMode: BlendMode.color,
      ),
      end: BoxDecoration(
        color: Colors.green.withOpacity(1),
//        backgroundBlendMode: BlendMode.color,
      ),
//      end: const BoxDecoration(color: Color(0xffffffff), backgroundBlendMode: BlendMode.overlay),
    );
    setState(() {
      _decorationAnimation =
          CurvedAnimation(parent: _controller, curve: Curves.easeOut)
              .drive(tween);
      _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeIn)
          .drive(Tween(begin: 1, end: 0));
      _controller.forward(from: 0);
    });
  }
}
