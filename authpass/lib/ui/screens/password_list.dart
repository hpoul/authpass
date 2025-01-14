import 'dart:async';
import 'dart:collection';

import 'package:authpass/bloc/analytics.dart';
import 'package:authpass/bloc/app_data.dart';
import 'package:authpass/bloc/authpass_cloud_bloc.dart';
import 'package:authpass/bloc/kdbx/file_source.dart';
import 'package:authpass/bloc/kdbx/file_source_local.dart';
import 'package:authpass/bloc/kdbx/file_source_ui.dart';
import 'package:authpass/bloc/kdbx_bloc.dart';
import 'package:authpass/env/_base.dart';
import 'package:authpass/ui/common_fields.dart';
import 'package:authpass/ui/screens/app_bar_menu.dart';
import 'package:authpass/ui/screens/cloud/cloud_auth.dart';
import 'package:authpass/ui/screens/cloud/cloud_mailbox.dart';
import 'package:authpass/ui/screens/entry_details.dart';
import 'package:authpass/ui/screens/group_list.dart';
import 'package:authpass/ui/screens/locked_screen.dart';
import 'package:authpass/ui/screens/password_list_drawer.dart';
import 'package:authpass/ui/screens/select_file_screen.dart';
import 'package:authpass/ui/widgets/backup_warning_banner.dart';
import 'package:authpass/ui/widgets/keyboard_handler.dart';
import 'package:authpass/ui/widgets/primary_button.dart';
import 'package:authpass/ui/widgets/savefile/save_file_diag_button.dart';
import 'package:authpass/ui/widgets/shortcut/authpass_intents.dart';
import 'package:authpass/utils/cache_manager.dart';
import 'package:authpass/utils/constants.dart';
import 'package:authpass/utils/dialog_utils.dart';
import 'package:authpass/utils/extension_methods.dart';
import 'package:authpass/utils/format_utils.dart';
import 'package:authpass/utils/platform.dart';
import 'package:authpass/utils/predefined_icons.dart';
import 'package:authpass/utils/theme_utils.dart';
import 'package:autofill_service/autofill_service.dart';
import 'package:badges/badges.dart' as badges;
import 'package:built_collection/built_collection.dart';
import 'package:cached_network_image/cached_network_image.dart';

// import 'package:collection/collection.dart' show IterableExtension;
import 'package:diac_client/diac_client.dart';
import 'package:flinq/flinq.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_async_utils/flutter_async_utils.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:kdbx/kdbx.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

final _logger = Logger('password_list');

class EntryViewModel implements Comparable<EntryViewModel> {
  EntryViewModel(this.entry, this.kdbxBloc)
      : label = entry.label,
        _labelComparable = entry.label?.toLowerCase() ?? CharConstants.empty,
        groupNames = _createGroupNames(entry.parent!),
        fileColor = kdbxBloc.fileForKdbxFile(entry.file).openedFile.color;

  static const websiteKey = KdbxKeyCommon.URL;

  final KdbxBloc kdbxBloc;
  final KdbxEntry entry;

  late final String? website = _normalizeUrl();
  final String? label;
  final String _labelComparable;
  final List<String> groupNames;
  final Color? fileColor;

  static final hasSchemaRegexp = RegExp(r'^https?://');
  static final hasNewline = RegExp('[\r\n]');

  static List<String> _createGroupNames(KdbxGroup group) =>
      group.breadcrumbs.map((e) => e.name.get()!).toList();

  String? _normalizeUrl() {
    final url = entry.getString(websiteKey)?.getText()?.trim();
    if (url == null || url.isEmpty) {
      return null;
    }
    try {
      // If the url contains newlines, just take the first line.
      var urlToParse = url.split(hasNewline).first;
      if (!url.startsWith(hasSchemaRegexp)) {
        urlToParse = 'http://$urlToParse'; // NON-NLS
      }
      final parsed = Uri.parse(urlToParse);
      final resolved = parsed.resolve('/'); // NON-NLS
//      _logger
//          .finer('url $url ($parsed) with scheme $ret resolved to $resolved');
      return resolved.toString();
    } catch (e) {
      return null;
    }
  }

  @override
  int compareTo(EntryViewModel other) {
    if (entry == other.entry) {
      return 0;
    }
    return _labelComparable
        .compareTo(other._labelComparable)
        .unlessZero(() => entry.uuid.uuid.compareTo(other.entry.uuid.uuid));
  }
}

extension on int {
  int unlessZero(int Function() cb) => this == 0 ? cb() : this;
}

typedef OnEntrySelected = void Function(
    KdbxEntry entry, EntrySelectionType type);

class PasswordList extends StatelessWidget {
  const PasswordList(
      {super.key, required this.onEntrySelected, this.selectedEntry});

  static const routeSettings = RouteSettings(name: '/passwordList');

  static Widget phonePasswordList(BuildContext context) {
    return PasswordList(
      onEntrySelected: (entry, type) {
        if (type == EntrySelectionType.activeOpen) {
          Navigator.of(context).push(EntryDetailsScreen.route(entry: entry));
        }
      },
    );
  }

  static Route<void> route() => MaterialPageRoute(
        settings: routeSettings,
        builder: (context) => phonePasswordList(context),
      );

  final KdbxEntry? selectedEntry;
  final OnEntrySelected onEntrySelected;

  @override
  Widget build(BuildContext context) {
    final kdbxBloc = Provider.of<KdbxBloc>(context);

    final streams =
        kdbxBloc.openedFilesKdbx.map((file) => file.dirtyObjectsChanged);
    if (streams.isEmpty) {
      Provider.of<Analytics>(context).events.trackPasswordListEmpty();
      final loc = AppLocalizations.of(context);
      return Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: PrimaryButton(
          onPressed: () {
            Navigator.of(context, rootNavigator: true)
                .pushAndRemoveUntil(SelectFileScreen.route(), (_) => false);
          },
          child: Text(loc.openFile),
        ),
      );
    }
    return StreamBuilder<bool>(
        stream: Rx.merge(streams).map((x) => true),
        builder: (context, snapshot) {
          @NonNls
          final isAutofill =
              View.maybeOf(context)?.platformDispatcher.defaultRouteName ==
                  '/autofill';
          return PasswordListContent(
            appData: context.watch<AppData>(),
            kdbxBloc: kdbxBloc,
            openedKdbxFiles: kdbxBloc.openedFilesKdbx,
            selectedEntry: selectedEntry,
            onEntrySelected: onEntrySelected,
            isAutofillSelector: isAutofill,
          );
        });
  }
}

enum EntrySelectionType {
  /// entry was highlighted (e.g. via search or up/down arrows) must not switch context.
  passiveHighlight,

  /// entry was actively selected by the user (e.g. via tap).
  activeOpen,
}

class PasswordListContent extends StatefulWidget {
  const PasswordListContent({
    super.key,
    required this.appData,
    required this.kdbxBloc,
    required this.openedKdbxFiles,
    required void Function(KdbxEntry entry, EntrySelectionType type)
        onEntrySelected,
    required this.isAutofillSelector,
    this.selectedEntry,
  }) : _onEntrySelected = onEntrySelected;

  final AppData appData;
  final KdbxBloc kdbxBloc;
  final List<KdbxFile> openedKdbxFiles;

  @NonNls
  final bool isAutofillSelector;
  final void Function(KdbxEntry entry, EntrySelectionType type)
      _onEntrySelected;
  final KdbxEntry? selectedEntry;

  void onEntrySelected(
      BuildContext context, KdbxEntry entry, EntrySelectionType type) {
    if (isAutofillSelector) {
      if (type == EntrySelectionType.activeOpen) {
        final cf = Provider.of<CommonFields>(context, listen: false);
        final username = entry.getString(cf.userName.key)?.getText();
        final password = entry.getString(cf.password.key)?.getText();
        AutofillService().resultWithDataset(
            label: entry.label, username: username, password: password);
        // not sure if this actually works.
        context.read<Analytics>().events.trackAutofillSelect();
        return;
      }
    }
    _onEntrySelected(entry, type);
    Provider.of<Analytics>(context, listen: false)
        .events
        .trackSelectEntry(type: type);
  }

  @override
  _PasswordListContentState createState() => _PasswordListContentState();
}

class PasswordListFilterIsolateRunner {
  static List<EntryViewModel> filterEntries(
    AppData appData,
    List<EntryViewModel> allEntries,
    String query, {
    int maxResults = 30,
  }) {
    _logger.info('We have to filter for $query');
    final searchKeys = appData.searchFields == CharConstants.star
        ? null
        : (appData.searchFields
                ?.split(CharConstants.comma)
                .map((e) => KdbxKey(e))
                .toSet() ??
            searchFields);
    final terms = query.toLowerCase().split(CharConstants.space);
    return allEntries
        .where((entry) => matches(searchKeys, entry, terms))
        // take no more than 30 for now.
        .take(maxResults)
        .toList(growable: false);
  }

  static final searchFields = CommonFields.defaultSearchFields;

  static bool matches(
    Set<KdbxKey>? searchFields,
    EntryViewModel entry,
    List<String> filterTerms,
  ) {
    for (final term in filterTerms) {
      final matchesNoGroupName = entry.groupNames
          .where((string) => string.toLowerCase().contains(term))
          .isEmpty;
      if (searchFields == null) {
        if (entry.entry.stringEntries
                .where((element) =>
                    element.value?.getText()?.toLowerCase().contains(term) ==
                    true)
                .isEmpty &&
            matchesNoGroupName) {
          return false;
        }
        continue;
      }
      if (searchFields
              .where((field) =>
                  entry.entry
                      .getString(field)
                      ?.getText()
                      ?.toLowerCase()
                      .contains(term) ==
                  true)
              .isEmpty &&
          matchesNoGroupName) {
        return false;
      }
    }
    return true;
  }
}

class GroupFilterEntry {
  const GroupFilterEntry({required this.group, required this.isRecursive});

  final KdbxGroup group;
  final bool isRecursive;
}

class GroupFilter {
  const GroupFilter({
    this.groups = const [],
    required this.showRecycleBin,
    required this.showActive,
    required String name,
  })  : _name = name,
        nameLoc = null;

  const GroupFilter._({
    required this.showRecycleBin,
    required this.showActive,
    required this.nameLoc,
  })  : groups = const [],
        _name = null;

  static final defaultGroupFilter = GroupFilter._(
      showRecycleBin: false,
      showActive: true,
      nameLoc: (loc) => loc.passwordFilterHideDeleted);
  static final recycleBin = GroupFilter._(
      showRecycleBin: true,
      showActive: false,
      nameLoc: (loc) => loc.passwordFilterOnlyDeleted);

  final List<GroupFilterEntry> groups;

  /// show items which are in the recycle bins.
  final bool showRecycleBin;

  /// show items which are not in recycle bins.
  final bool showActive;

  /// Name to display.
  final String? _name;

  final String Function(AppLocalizations loc)? nameLoc;

  String name(AppLocalizations loc) {
    return _name ?? nameLoc!(loc);
  }

  Iterable<KdbxEntry> getEntries(List<KdbxFile> files) {
    if (groups.isNotEmpty) {
      return groups.expand((groupSelected) {
        final groups = groupSelected.isRecursive
            ? groupSelected.group.getAllGroups()
            : [groupSelected.group];
        if (showRecycleBin && showActive) {
          return groups.expand((g) => g.entries);
        } else if (showActive) {
          return groups
              .where((g) => g == groupSelected.group || g.file.recycleBin != g)
              .expand((g) => g.entries);
        } else if (showRecycleBin) {
          return groups
              .where((g) => g.file.recycleBin == g)
              .expand((g) => g.entries);
        } else {
          throw StateError('Impossible. (showRecycleBin: $showRecycleBin,'
              'showActive: $showActive)');
        }
      });
    }
    return files.expand((f) {
      if (showRecycleBin && showActive) {
        return f.body.rootGroup.getAllEntries();
      } else {
        final recycleBin = f.recycleBin;
        if (showRecycleBin) {
          return recycleBin?.entries ?? [];
        } else {
          return f.body.rootGroup
              .getAllGroups()
              .where((g) => g != recycleBin)
              .expand((e) => e.entries);
        }
      }
    });
  }
}

class _CancelSearchFilterAction extends Action<CancelSearchFilterIntent> {
  _CancelSearchFilterAction(this.state);

  final _PasswordListContentState state;

  @override
  bool isActionEnabled = false;

  void updateEnabled() {
    final isEnabled = state._filterQuery != null;
    if (isActionEnabled != isEnabled) {
      isActionEnabled = isEnabled;
      notifyActionListeners();
    }
  }

  @override
  bool consumesKey(CancelSearchFilterIntent intent) {
    _logger.fine('_CancelSearchFilterAction.consumesKey() = $isActionEnabled');
    return isActionEnabled;
  }

  @override
  Object? invoke(CancelSearchFilterIntent intent) {
    state._cancelFilter();
    return null;
  }
}

class _PasswordListContentState extends State<PasswordListContent>
    with StreamSubscriberMixin, WidgetsBindingObserver, FutureTaskStateMixin {
  List<EntryViewModel>? _filteredEntries;

  String? get _filterQuery => __filterQuery;

  set _filterQuery(String? filterQuery) {
    __filterQuery = filterQuery;
    cancelSearchFilterAction.updateEnabled();
  }

  String? __filterQuery;
  final _filterTextEditingController = TextEditingController();
  final FocusNode _filterFocusNode = FocusNode();
  bool _speedDialOpen = false;
  final ValueNotifier<GroupFilter> _groupFilterNotifier =
      ValueNotifier(GroupFilter.defaultGroupFilter);

  IntentActionRegistration? _actionsRegistration;

  late final _CancelSearchFilterAction cancelSearchFilterAction =
      _CancelSearchFilterAction(this);

  GroupFilter get _groupFilter => _groupFilterNotifier.value;

//  List<EntryViewModel> get _allEntries => _groupFilter == null
//      ? widget.entries
//      : _groupFilter
//          .getAllEntries()
//          .map((e) => EntryViewModel(e, widget.kdbxBloc))
//          .toList();
  List<EntryViewModel>? _allEntries;

  /// on android while requesting autofill.
  AutofillMetadata? _autofillMetadata;

//  final _isolateRunner = IsolateRunner.spawn();

  AutofillServiceStatus? _autofillStatus;
  bool? _dismissedAutofillSuggestion;
  bool? _rememberPassword;
  bool? _dismissedRememberPassword;

  @override
  void initState() {
    super.initState();
    _logger.finer('Initializing password list content.');
//    _isolateRunner.then((runner) => runner.run(PasswordListFilterIsolateRunner.init, widget.entries)).then((result) {
//      _logger.finer('Initializd filter isolate $result');
//    });
    WidgetsBinding.instance.addObserver(this);
    _updateAllEntries();
    _groupFilterNotifier.addListener(_updateAllEntries);
    _updateAutofillPrefs();
    _updateAutofillMetadata();
    _updateRememberPassword(widget.appData);
    _updateDismissedBanners(widget.appData);
  }

  void _updateDismissedBanners(AppData data) {
    _dismissedLocalFilesReady = true;
    setState(() {
      _dismissedLocalFiles = data.dismissedBackupLocalFiles;
      _dismissedAutofillSuggestion = data.dismissedAutofillSuggestion;
      _dismissedRememberPassword = data.dismissedRememberPassword;
    });
  }

  Future<void> _updateAutofillPrefs() async {
    if (AuthPassPlatform.isWeb) {
      return;
    }
    _autofillStatus = await AutofillService().status();
    setState(() {});
  }

  void _updateAutofillMetadata() {
    if (widget.isAutofillSelector) {
      AutofillService().getAutofillMetadata().then((value) {
        if (_autofillMetadata == value || !mounted) {
          return;
        }
        setState(() {
          _autofillMetadata = value;
        });
        final val = value?.searchTerm?.let((term) {
              _filterTextEditingController.text = term;
              _filterTextEditingController.selection =
                  TextSelection(baseOffset: 0, extentOffset: term.length);
              return _updateFilterQuery(term);
            }) ??
            0;
        context.read<Analytics>().events.trackAutofillFilter(
              filter: '${value?.searchTerm?.isNotEmpty}',
              value: val,
            );
      });
    }
  }

  Future<void> _validatePassword() async {
    final FileSource currentFile =
        widget.kdbxBloc.openedFilesWithSources.first.key;
    await Navigator.of(context)
        .push(CredentialsScreen.route(currentFile, true));
  }

  Future<void> _updateRememberPassword(AppData data) async {
    if (data.quickUnlockCounter != null &&
        widget.kdbxBloc.openedFilesWithSources.isNotEmpty) {
      final FileSource currentFile =
          widget.kdbxBloc.openedFilesWithSources.first.key;
      if (data.quickUnlockCounter![currentFile.uuid] != null) {
        _rememberPassword = data.quickUnlockCounter![currentFile.uuid]! >= 10;
      }
      if (_rememberPassword != null &&
          _rememberPassword! &&
          data.dismissedRememberPassword != null &&
          data.dismissedRememberPassword! &&
          data.quickUnlockCounter![currentFile.uuid]! % 10 == 0) {
        await context.read<AppDataBloc>().update((builder, data) {
          builder.dismissedRememberPassword = false;
        });
      }
    }
  }

  void _updateAllEntries() {
    final watch = Stopwatch()..start();
    final allEntries = SplayTreeSet<EntryViewModel>.from(
        _groupFilter
            .getEntries(widget.openedKdbxFiles)
            .map<EntryViewModel>((e) => EntryViewModel(e, widget.kdbxBloc)),
        (EntryViewModel a, EntryViewModel b) => a.compareTo(b));
//    final allEntries = _groupFilter
//        .getEntries(widget.openedKdbxFiles)
//        .map((e) => EntryViewModel(e, widget.kdbxBloc))
//        .toSet()
//        .toList(growable: false);
//    allEntries
//        .sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    _allEntries = allEntries.toList(growable: false);
    watch.stop();
    _logger.finer('Rebuilding PasswordList. (${_allEntries!.length} entries)'
        ' ${watch.elapsedMilliseconds}ms');
    setState(() {});
  }

  @override
  void didUpdateWidget(PasswordListContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appData != widget.appData) {
      _updateDismissedBanners(widget.appData);
    }
    if (oldWidget.openedKdbxFiles != widget.openedKdbxFiles) {
      _updateAllEntries();
    }
  }

  void _selectAllFilter() =>
      _filterTextEditingController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _filterTextEditingController.text.length);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _logger.finer('didChangeAppLifecycleState($state)');
    if (state == AppLifecycleState.resumed) {
      setState(() {
        _selectAllFilter();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    subscriptions.cancelSubscriptions();
    final shortcuts = Provider.of<KeyboardShortcutEvents>(context);
    _actionsRegistration?.dispose();
    _actionsRegistration = shortcuts.registerActions({
      SearchIntent: CallbackAction(
        onInvoke: (intent) => setState(() {
          if (_filterQuery == null || _filteredEntries == null) {
            _filterQuery ??= CharConstants.empty;
            _filteredEntries = _allEntries;
          }
          _selectAllFilter();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _filterFocusNode.requestFocus();
          });
        }),
      ),
      MoveUpIntent: CallbackAction(onInvoke: (intent) => _selectNextEntry(-1)),
      MoveDownIntent: CallbackAction(onInvoke: (intent) => _selectNextEntry(1)),
      // CancelSearchFilterIntent:
      //     CallbackAction(onInvoke: (intent) => _cancelFilter()),
      CancelSearchFilterIntent: cancelSearchFilterAction,
    });
  }

  @Deprecated('was only a workaround needed for manual shortcut handling')
  // ignore: unused_element
  bool _isFocusInForeignTextField() {
    final widget =
        WidgetsBinding.instance.focusManager.primaryFocus?.context?.widget;
    if (widget == null) {
      return false;
    }
    if (widget is EditableText) {
      if (widget.controller == _filterTextEditingController) {
        return false;
      }
      return true;
    }
    return false;
  }

  void _selectNextEntry(int next) {
    final entries = _filteredEntries ?? _allEntries!;
    if (entries.isEmpty) {
      return;
    }
    final idx = entries.indexWhere((a) => a.entry == widget.selectedEntry);
    // right now we ignore the fact that the user might select a list item which is not in view.
    // https://github.com/flutter/flutter/issues/12319
    if (idx < 0) {
      widget.onEntrySelected(
          context, entries.first.entry, EntrySelectionType.passiveHighlight);
    } else {
      // new Index, modulo entry length to make sure we wrap around the end..
      final newIndex = (idx + next) % entries.length;
      widget.onEntrySelected(context, entries[newIndex].entry,
          EntrySelectionType.passiveHighlight);
    }
  }

  @override
  void dispose() {
    _logger.info('Disposing isolate runner.');
//    _isolateRunner.then<void>((runner) => runner.close());
    _filterFocusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _groupFilterNotifier.removeListener(_updateAllEntries);
    _groupFilterNotifier.dispose();
    _actionsRegistration?.dispose();
    super.dispose();
  }

  AppBar _buildDefaultAppBar(BuildContext context) {
    final kdbxBloc = Provider.of<KdbxBloc>(context);
    final isDirty = kdbxBloc.openedFiles.entries.any((element) =>
        element.key.supportsWrite &&
        element.value.kdbxFile.dirtyObjects.isNotEmpty);
    final loc = AppLocalizations.of(context);
    return AppBar(
      title: const Text('AuthPass'), // NON-NLS
      actions: <Widget>[
        ...?!isDirty
            ? null
            : [
                Builder(
                  builder: (context) => IconButton(
                    icon: Icon(
                      Icons.save,
                      semanticLabel: loc.saveButtonLabel,
                    ),
                    onPressed: () async {
                      final scaffold = ScaffoldMessenger.of(context);
                      final savedFiles = <String>[];
                      for (final entry in kdbxBloc.openedFiles.entries) {
                        if (entry.key.supportsWrite &&
                            entry.value.kdbxFile.dirtyObjects.isNotEmpty) {
                          await kdbxBloc.saveFile(entry.value.kdbxFile);
                          savedFiles.add(entry.key.displayName);
                        }
                      }
                      scaffold.showSnackBar(
                        SnackBar(
                          content: Text(loc.savedFiles(savedFiles.length,
                              savedFiles.join(Nls.COMMA_SPACE))),
                        ),
                      );
                    },
                  ),
                ),
              ],
//        IconButton(
//          icon: Icon(FontAwesomeIcons.sitemap),
//          onPressed: () async {
//            final groupFilter =
//                await Navigator.of(context).push(GroupList.route(null));
//            setState(() {
//              _groupFilter = groupFilter;
//              _filteredEntries = null;
//              _filterTextEditingController.text = '';
//            });
//          },
//        ),
        PopupMenuButton<VoidCallback>(
          icon: const Icon(FontAwesomeIcons.filter),
          tooltip: loc.filterButtonLabel,
          onSelected: (value) async {
            value();
            _logger.fine('onchanged - $value');
          },
          itemBuilder: (context) {
            final availableFilter = [
              GroupFilter.defaultGroupFilter,
              GroupFilter.recycleBin,
            ];
            if (!availableFilter.contains(_groupFilter)) {
              availableFilter.add(_groupFilter);
            }
            return <PopupMenuEntry<VoidCallback>>[
              ...availableFilter.map(
                (e) => CheckedPopupMenuItem<VoidCallback>(
                  value: () => _groupFilterNotifier.value = e,
                  checked: e == _groupFilter,
                  child: Text(e.name(loc)),
                ),
              ),
//              const Divider(),
              PopupMenuItem(
                value: () async {
                  final groupFilter = await Navigator.of(context).push(
                      GroupListFlat.route(
                          _groupFilter.groups.map((e) => e.group).toSet()));
                  if (groupFilter == null) {
                    return;
                  }
                  if (groupFilter.isEmpty) {
                    _groupFilterNotifier.value = GroupFilter.defaultGroupFilter;
                    return;
                  }
                  _createGroupFilter(loc, groupFilter);
                },
                child: ListTile(
                  leading: const Icon(Icons.folder),
                  title: Text(loc.filterCustomize),
                ),
              ),
            ];
          },
        ),
        IconButton(
            icon: const Icon(Icons.search),
            tooltip: loc.searchButtonLabel,
            onPressed: () {
              setState(() {
                _filteredEntries = _allEntries;
              });
            }),
        StreamBuilder<CloudStatus?>(
          stream: context.watch<AuthPassCloudBloc>().cloudStatus,
          initialData: null,
          builder: (context, cloudStatusSnapshot) => badges.Badge(
            badgeContent: cloudStatusSnapshot.hasData &&
                    cloudStatusSnapshot.data!.messagesUnread > 0
                ? Text(cloudStatusSnapshot.data!.messagesUnread.toString(),
                    style: const TextStyle(color: Colors.white))
                : null,
            showBadge: cloudStatusSnapshot.hasData &&
                cloudStatusSnapshot.data!.messagesUnread > 0,
            badgeStyle: badges.BadgeStyle(
              badgeColor: Theme.of(context).primaryColorDark,
            ),
            position: badges.BadgePosition.topEnd(top: 0, end: 3),
            child: PopupMenuButton<VoidCallback>(
              key: const ValueKey('appBarOverflowMenu'),
              onSelected: (item) {
                item();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: () async {
                    await Navigator.of(context).push(GroupListFlat.route(
                      {},
                      groupListMode: GroupListMode.manage,
                    ));
//                if (group != null) {
//                  _createGroupFilter({group});
//                }
                  },
                  child: ListTile(
                    leading: const Icon(Icons.category),
                    title: Text(loc.manageGroups),
                  ),
                ),
                ...?_buildAuthPassCloudMenuItems(
                    context, cloudStatusSnapshot.data),
                ...AppBarMenu.createDefaultPopupMenuItems(
                    context, kdbxBloc.openedFiles),
                PopupMenuItem(
                  value: () {
                    Provider.of<Analytics>(context, listen: false)
                        .events
                        .trackActionPressed(action: 'lockFiles');
                    Provider.of<KdbxBloc>(context, listen: false)
                        .closeAllFiles(clearQuickUnlock: false);
                    Navigator.of(context, rootNavigator: true)
                        .pushAndRemoveUntil(
                      LockedScreen.route(),
                      (_) => false,
                    );
                  },
                  child: ListTile(
                    leading: const Icon(Icons.exit_to_app),
                    title: Text(loc.lockFiles),
                  ),
                ),
              ],
            ),
          ),
        )
      ],
    );
  }

  ThemeData filterAppBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.brightness == Brightness.light) {
      return theme.copyWith(
        primaryColor: Colors.white,
        primaryIconTheme: theme.primaryIconTheme.copyWith(color: Colors.grey),
//      primaryColorBrightness: Brightness.light,
        primaryTextTheme: theme.textTheme,
      );
    } else {
      return theme.copyWith(
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: Colors.white,
          selectionColor: theme.colorScheme.secondary,
          selectionHandleColor: theme.colorScheme.secondary,
        ),
        //primaryColor: Colors.blue,
//        cursorColor: Colors.red,
      );
    }
  }

  void _cancelFilter() {
    setState(() {
      _filterQuery = null;
      _filteredEntries = null;
    });
  }

  AppBar _buildFilterAppBar(BuildContext context) {
    final theme = filterAppBarTheme(context);
    final loc = AppLocalizations.of(context);
    return AppBar(
      backgroundColor: theme.primaryColor,
      iconTheme: theme.primaryIconTheme,
      toolbarTextStyle: theme.primaryTextTheme.bodyMedium,
      titleTextStyle: theme.primaryTextTheme.titleLarge,
      // old deprecated value:
      // textTheme: theme.primaryTextTheme,
      // brightness: theme.primaryColorBrightness,
      systemOverlayStyle: theme.brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          _cancelFilter();
        },
      ),
      title: Theme(
        data: theme,
        child: TextField(
          style: theme.textTheme.titleLarge,
          // we also want the same cursorColor for mac/ios
          cursorColor: theme.textSelectionTheme.cursorColor,
          focusNode: _filterFocusNode,
          controller: _filterTextEditingController,
          onChanged: (newQuery) async {
            _logger.info('query changed to $newQuery');
            _updateFilterQuery(newQuery);
          },
          autofocus: true,
          decoration: InputDecoration(
            hintText: loc.searchHint,
            border: InputBorder.none,
            hintStyle: theme.inputDecorationTheme.hintStyle,
          ),
        ),
      ),
    );
  }

  int _updateFilterQuery(String newQuery) {
    final entries = PasswordListFilterIsolateRunner.filterEntries(
        widget.appData, _allEntries!, newQuery);
    if (!mounted) {
      _logger.severe('No longer mounted after updating filter query.', null,
          StackTrace.current);
      return 0;
    }
    setState(() {
      _filterQuery = newQuery;
      _filteredEntries = entries;
      if (_filteredEntries!.isNotEmpty &&
          (widget.selectedEntry == null ||
              !_filteredEntries!
                  .map((e) => e.entry)
                  .contains(widget.selectedEntry))) {
        widget.onEntrySelected(context, _filteredEntries!.first.entry,
            EntrySelectionType.passiveHighlight);
//                  // TODO this looks a bit like a workaround. But on MacOS we lose focus when
//                  //      we show another password entry.
//                  WidgetsBinding.instance.addPostFrameCallback((_) {
//                    _filterFocusNode.requestFocus();
//                  });
      }
    });
    return entries.length;
  }

  List<Widget>? _buildGroupFilterPrefix() {
    if (_groupFilter == GroupFilter.defaultGroupFilter) {
      return null;
    }
    final loc = AppLocalizations.of(context);
    return [
      MaterialBanner(
        backgroundColor: Colors.lightGreenAccent.withOpacity(0.2),
        content: Text(_groupFilter.name(loc)),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              _groupFilterNotifier.value = GroupFilter.defaultGroupFilter;
            },
            child: Text(loc.clear),
          )
        ],
      ),
    ];
  }

  List<Widget>? _buildAutofillListPrefix() {
    if (!widget.isAutofillSelector) {
      _logger.info(
          'not autofill: ${View.maybeOf(context)?.platformDispatcher.defaultRouteName}');
      return null;
    }
    final loc = AppLocalizations.of(context);

    final info = _autofillMetadata?.let((metadata) {
      final searchTerm = metadata.searchTerm;
      if (searchTerm != null && searchTerm == _filterQuery) {
        return [
          TextSpan(text: Nls.NL + loc.autofillFilterPrefix + Nls.SP),
          TextSpan(
              text: searchTerm,
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ];
      }
    });
    return [
      Padding(
        padding: const EdgeInsets.all(8.0),
        child: Card(
          color: Colors.lightGreen,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text.rich(
              TextSpan(
                text: loc.autofillPrompt,
                children: info,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget>? _buildListPrefix() {
    final kdbxBloc = Provider.of<KdbxBloc>(context);
    final unsupportedWrite = kdbxBloc.openedFilesWithSources.firstOrNullWhere(
      (f) => f.value.dirtyObjects.isNotEmpty && !f.key.supportsWrite,
    );
    if (unsupportedWrite == null) {
      return null;
    }
    return [UnsupportedWrite(source: unsupportedWrite.key)];
  }

  BuiltList<String>? _dismissedLocalFiles;
  bool _dismissedLocalFilesReady = false;

  List<Widget>? _buildBackupWarningBanners() {
    final kdbxBloc = context.watch<KdbxBloc>();
    final loc = AppLocalizations.of(context);
    final localFiles =
        kdbxBloc.openedFilesWithSources.where((e) => e.key is FileSourceLocal);
    final localFiles3 = localFiles
        .where((file) =>
            file.value.body.rootGroup
                .getAllGroups()
                .where((element) => element != file.value.recycleBin)
                .expand((element) => element.getAllEntries())
                .length >=
            3)
        .where((element) =>
            !(_dismissedLocalFiles?.contains(element.key.uuid) ?? false));
    if (localFiles3.isNotEmpty && _dismissedLocalFilesReady) {
      final file = localFiles3.first;
      final analytics = context.watch<Analytics>();
      analytics.events.trackBackupBanner(BannerAction.shown);
      return [
        BackupBanner(
          loc.backupWarningMessage(file.key.displayName),
          backupWidget: SaveFileAsDialogButton(
            file: kdbxBloc.fileForFileSource(file.key)!,
            onSave: (saveFuture) {
              asyncRunTask((progress) async {
                analytics.events.trackBackupBanner(BannerAction.saved);
                await saveFuture;
              }, label: loc.saving);
            },
            child: Text(loc.backupButton),
          ),
          dismissText: loc.dismissBackupButton,
          onDismiss: () {
            analytics.events.trackBackupBanner(BannerAction.dismissed);
            context.read<AppDataBloc>().update((builder, data) =>
                builder.dismissedBackupLocalFiles =
                    data.dismissedBackupLocalFiles?.toBuilder() ??
                        BuiltList<String>().toBuilder()
                      ..add(file.key.uuid));
          },
        ),
      ];
    }
    return null;
  }

  List<Widget>? _buildAutofillSuggestBanners() {
    if (_autofillStatus == null ||
        _autofillStatus != AutofillServiceStatus.disabled) {
      return null;
    }
    if (_dismissedAutofillSuggestion == true) {
      return null;
    }
    final loc = AppLocalizations.of(context);
    final analytics = context.watch<Analytics>();
    return [
      MaterialBanner(
        content: Text(loc.enableAutofillSuggestionBanner),
        actions: [
          TextButton(
            onPressed: () async {
              await context.read<AppDataBloc>().update((builder, data) {
                builder.dismissedAutofillSuggestion = true;
              });
              analytics.events.trackAutofillBanner(BannerAction.dismissed);
            },
            child: Text(loc.dismissAutofillSuggestionBannerButton),
          ),
          TextButton(
            onPressed: () async {
              await AutofillService().requestSetAutofillService();
              await _updateAutofillPrefs();
              analytics.events.trackAutofillBanner(BannerAction.saved);
            },
            child: Text(loc.enableAutofillSuggestionBannerButton),
          ),
        ],
      )
    ];
  }

  List<Widget>? _buildRememberPasswordBanners() {
    if (_rememberPassword == null || _rememberPassword == false) {
      return null;
    }
    if (_dismissedRememberPassword == true) {
      return null;
    }
    final loc = AppLocalizations.of(context);
    final analytics = context.watch<Analytics>();
    return [
      MaterialBanner(
        content: Text(loc.rememberPasswordBanner),
        actions: [
          TextButton(
            onPressed: () async {
              await context.read<AppDataBloc>().update((builder, data) {
                builder.dismissedRememberPassword = true;
              });
              analytics.events
                  .trackRememberPasswordBanner(BannerAction.dismissed);
            },
            child: Text(loc.dismissRememberPasswordBannerButton),
          ),
          TextButton(
            onPressed: () async {
              await _validatePassword();
              analytics.events.trackRememberPasswordBanner(BannerAction.saved);
            },
            child: Text(loc.validateRememberPasswordBannerButton),
          ),
        ],
      )
    ];
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filteredEntries ?? _allEntries;
    final listPrefix = [
      ...?[
        _buildBackupWarningBanners,
        _buildAutofillSuggestBanners,
        _buildRememberPasswordBanners,
      ].map((e) => e()).whereNotNull().firstOrNull,
      ...?_buildGroupFilterPrefix(),
      ...?_buildAutofillListPrefix(),
      ...?_buildListPrefix(),
    ];
    if (listPrefix.isEmpty) {
      listPrefix.add(DiacMaterialBanner(
        diac: Provider.of<DiacBloc>(context),
      ));
    }

    final theme = Theme.of(context);
    final kdbxBloc = Provider.of<KdbxBloc>(context);
    final loc = AppLocalizations.of(context);
    return Actions(
      dispatcher: LoggingActionDispatcher(),
      actions: {
        SearchIntent: SearchAction(this),
      },
      child: Scaffold(
        appBar: _filteredEntries == null
            ? _buildDefaultAppBar(context)
            : _buildFilterAppBar(context),
        drawer: Drawer(
          child: PasswordListDrawer(
            initialSelection: _groupFilter.groups.map((e) => e.group).toSet(),
            selectionChanged: (Set<KdbxGroup> selection) {
              _createGroupFilter(loc, selection);
            },
          ),
        ),
        body: ProgressOverlay(
          task: task,
          child: _allEntries!.isEmpty
              ? NoPasswordsEmptyView(
                  listPrefix: listPrefix,
                  onPrimaryButtonPressed: () {
                    final kdbxBloc =
                        Provider.of<KdbxBloc>(context, listen: false);
                    final entry = kdbxBloc.createEntry();
//                Navigator.of(context).push(EntryDetailsScreen.route(entry: entry));
                    widget.onEntrySelected(
                        context, entry, EntrySelectionType.activeOpen);
                  },
                )
              : Scrollbar(
                  child: ListView.builder(
                    itemCount: entries!.length + 1,
                    itemBuilder: (context, index) {
                      // handle [listPrefix]
                      if (index == 0) {
                        if (listPrefix.isEmpty) {
                          return const SizedBox();
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: listPrefix,
                        );
                      }
                      index--;

                      final entry = entries[index];

                      final openedFile =
                          kdbxBloc.fileForKdbxFile(entry.entry.file);
                      final fileColor = openedFile.openedFile.color;
//                _logger.finer('listview item. selectedEntry: ${widget.selectedEntry}');
                      return PasswordEntryListTileWrapper(
                        entry: entry,
                        fileColor: fileColor,
                        filterQuery: _filterQuery,
                        selectedEntry: widget.selectedEntry,
                        onEntrySelected:
                            (KdbxEntry entry, EntrySelectionType type) {
                          widget.onEntrySelected(context, entry, type);
                        },
                      );
                    },
                  ),
                ),
        ),
        floatingActionButton: _allEntries!.isEmpty ||
                _filterQuery != null ||
                _autofillMetadata != null
            ? null
            : kdbxBloc.openedFiles.length == 1 ||
                    _groupFilter.groups.length == 1
                ? FloatingActionButton(
                    tooltip: loc.addNewPassword,
                    onPressed: () {
                      final group = _groupFilter.groups.isEmpty
                          ? null
                          : _groupFilter.groups.first.group;
                      final entry = kdbxBloc.createEntry(
                        file: group?.file,
                        group: group,
                      );
                      widget.onEntrySelected(
                          context, entry, EntrySelectionType.activeOpen);
                    },
                    child: const Icon(Icons.add),
                  )
                : SpeedDial(
                    tooltip: _speedDialOpen
                        ? CharConstants.empty
                        : loc.addNewPassword,
                    onOpen: () => setState(() => _speedDialOpen = true),
                    onClose: () => setState(() => _speedDialOpen = false),
                    overlayColor: theme.brightness == Brightness.dark
                        ? Colors.black
                        : Colors.white,
                    children: kdbxBloc.openedFiles.values
                        .map(
                          (file) => SpeedDialChild(
                              label: file.fileSource.displayName,
                              child: Icon(file.fileSource.displayIcon.iconData),
                              labelBackgroundColor: Theme.of(context).cardColor,
                              backgroundColor: file.openedFile.colorCode == null
                                  ? null
                                  : Color(file.openedFile.colorCode!),
                              onTap: () {
                                final entry =
                                    kdbxBloc.createEntry(file: file.kdbxFile);
                                widget.onEntrySelected(context, entry,
                                    EntrySelectionType.activeOpen);
                              }),
                        )
                        .toList(),
                    child: Icon(_speedDialOpen ? Icons.close : Icons.add),
                  ),
      ),
    );
  }

  void _createGroupFilter(AppLocalizations loc, Set<KdbxGroup> groupFilter) {
    if (groupFilter.isEmpty) {
      _groupFilterNotifier.value = GroupFilter.defaultGroupFilter;
      return;
    }
    final name = groupFilter.length == 1
        ? loc.passwordFilterPrefixForOneGroup(
            groupFilter.first.name.get().toString())
        : loc.passwordFilterPrefixForMultipleGroups(groupFilter.length);
    _groupFilterNotifier.value = GroupFilter(
      groups: groupFilter
          .map((g) => GroupFilterEntry(group: g, isRecursive: true))
          .toList(),
      showRecycleBin: false,
      showActive: true,
      name: name,
    );
    _filteredEntries = null;
    _filterTextEditingController.text = CharConstants.empty;
  }

  List<PopupMenuItem<VoidCallback>>? _buildAuthPassCloudMenuItems(
      BuildContext context, CloudStatus? cloudStatus) {
    final bloc = context.read<AuthPassCloudBloc>();
    if (bloc.featureFlags.authpassCloud != true) {
      return null;
    }
    final loc = AppLocalizations.of(context);
    if (bloc.tokenStatus == TokenStatus.confirmed) {
      return [
        PopupMenuItem(
          value: () {
            Navigator.of(context, rootNavigator: true)
                .push(CloudMailboxTabScreen.route());
          },
          child: ListTile(
            leading: badges.Badge(
              badgeContent:
                  cloudStatus != null && cloudStatus.messagesUnread > 0
                      ? Text(
                          cloudStatus.messagesUnread.toString(),
                          style: TextStyle(
                              color: Theme.of(context)
                                  .primaryTextTheme
                                  .bodyLarge!
                                  .color),
                        )
                      : null,
              showBadge: cloudStatus != null && cloudStatus.messagesUnread > 0,
              badgeStyle: badges.BadgeStyle(
                badgeColor: Theme.of(context).primaryColor,
              ),
              child: const Icon(Icons.cloud),
            ),
            title: Text(loc.menuItemAuthPassCloudMailboxes),
          ),
        )
      ];
    } else {
      return [
        PopupMenuItem(
          value: () {
            Navigator.of(context, rootNavigator: true)
                .push(AuthPassCloudAuthScreen.route());
          },
          child: ListTile(
            leading: const Icon(Icons.cloud),
            title: Text(loc.menuItemAuthPassCloudAuthenticate),
          ),
        )
      ];
    }
  }
}

class SearchAction extends Action<SearchIntent> {
  SearchAction(this.state);

  final _PasswordListContentState state;

  @override
  Object? invoke(SearchIntent intent) {
    _logger.info('We should start search.');
    return null;
  }
}

class PasswordEntryListTileWrapper extends StatelessWidget {
  const PasswordEntryListTileWrapper({
    super.key,
    required this.entry,
    required this.selectedEntry,
    required this.fileColor,
    required String? filterQuery,
    required this.onEntrySelected,
  }) : _filterQuery = filterQuery;

  final EntryViewModel entry;
  final KdbxEntry? selectedEntry;
  final Color? fileColor;
  final String? _filterQuery;
  final OnEntrySelected onEntrySelected;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final commonFields = Provider.of<CommonFields>(context);
    final theme = Theme.of(context);
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: loc.swipeCopyPassword): () =>
            _copyPassword(context, commonFields, loc,
                analyticsAction: 'semantic'),
        CustomSemanticsAction(label: loc.swipeCopyUsername): () =>
            _copyUsername(context, commonFields, loc,
                analyticsAction: 'semantic'),
      },
      child: Dismissible(
        key: ValueKey(entry.entry.uuid),
        resizeDuration: null,
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
              Text(loc.swipeCopyPassword),
            ],
          ),
        ),
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          color: theme.brightness == Brightness.light
              ? Colors.limeAccent
              : Colors.brown,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.account_circle),
              const SizedBox(height: 4),
              Text(loc.swipeCopyUsername),
            ],
          ),
        ),
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.endToStart) {
            await _copyUsername(context, commonFields, loc);
          } else {
            await _copyPassword(context, commonFields, loc);
          }
          return false;
        },
        child: Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: Container(
            decoration: selectedEntry != entry.entry
                ? (fileColor == null
                    ? null
                    : BoxDecoration(
                        border: Border(
                            left: BorderSide(color: fileColor!, width: 4))))
                : BoxDecoration(
                    color: theme.listTileTheme.selectedTileColor ??
                        (theme.brightness == Brightness.dark
                            ? Colors.grey[800]
                            : Colors.grey[100]),
                    border: Border(
                      right: BorderSide(
                          color: Theme.of(context).primaryColor, width: 4),
                      left: fileColor == null
                          ? BorderSide.none
                          : BorderSide(color: fileColor!, width: 4),
                    ),
                  ),
            child: PasswordEntryTile(
              vm: entry,
              isSelected: entry.entry == selectedEntry,
              filterQuery: _filterQuery,
              onTap: () {
//                      Navigator.of(context).push(EntryDetailsScreen.route(entry: entry));
                onEntrySelected(entry.entry, EntrySelectionType.activeOpen);
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copyUsername(
      BuildContext context, CommonFields commonFields, AppLocalizations loc,
      {@NonNls String analyticsAction = 'swipe'}) async {
    final analytics = context.read<Analytics>();
    final stringValue = entry.entry.getString(commonFields.userName.key);
    if (stringValue == null || stringValue.isNullOrEmpty()) {
      context.showSnackBar(loc.copyUsernameNotExists);
      return;
    }
    await Clipboard.setData(
        ClipboardData(text: stringValue.getText() ?? CharConstants.empty));
    // ignore: use_build_context_synchronously
    context.showSnackBar(loc.doneCopiedUsername);
    analytics.events.trackCopyUsername(action: analyticsAction);
  }

  Future<void> _copyPassword(
      BuildContext context, CommonFields commonFields, AppLocalizations loc,
      {@NonNls String analyticsAction = 'swipe'}) async {
    final stringValue = entry.entry.getString(commonFields.password.key);
    if (stringValue == null || stringValue.isNullOrEmpty()) {
      context.showSnackBar(loc.copyPasswordNotExists);
      return;
    }
    await Clipboard.setData(
        ClipboardData(text: stringValue.getText() ?? CharConstants.empty));
    // ignore: use_build_context_synchronously
    context.showSnackBar(loc.doneCopiedPassword);
    // ignore: use_build_context_synchronously
    context.read<Analytics>().events.trackCopyPassword(action: analyticsAction);
  }
}

class NoPasswordsEmptyView extends StatelessWidget {
  const NoPasswordsEmptyView({
    super.key,
    this.onPrimaryButtonPressed,
    this.listPrefix,
  });

  final List<Widget>? listPrefix;
  final VoidCallback? onPrimaryButtonPressed;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        ...?listPrefix,
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Align(
              alignment: const Alignment(0, -0.7),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    '🤗️', // NON-NLS
                    style: TextStyle(fontSize: 64),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    loc.emptyPasswordVaultPlaceholder,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    onPressed: onPrimaryButtonPressed,
                    child: Text(loc.emptyPasswordVaultButtonLabel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class UnsupportedWrite extends StatelessWidget {
  const UnsupportedWrite({super.key, required this.source});

  final FileSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Card(
        color: theme.colorScheme.error.withOpacity(0.2),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: <Widget>[
              Icon(Icons.warning, color: theme.colorScheme.error),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: [
                    Text(loc.changesWithoutSaving(source.displayName)),
                    const SizedBox(height: 4),
                    Text(source.displayPath, style: theme.textTheme.bodySmall),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
//                        FlatButton(
//                          child: const Text('Dismiss'),
//                          onPressed: () {},
//                        ),
                        TextButton(
                          onPressed: () {
                            final bloc =
                                Provider.of<KdbxBloc>(context, listen: false);
                            bloc.saveLocally(source);
                          },
                          child: Text(loc.changesSaveLocally),
                        )
                      ],
                    )
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PasswordEntryTile extends StatelessWidget {
  const PasswordEntryTile({
    super.key,
    required this.vm,
    required this.isSelected,
    required this.filterQuery,
    this.onTap,
  });

  final EntryViewModel vm;
  final bool isSelected;
  final String? filterQuery;
  final VoidCallback? onTap;

  Widget _defaultIcon(Color? fgColor, ThemeData theme, double size) =>
      EntryIcon.defaultIcon(vm, fgColor, theme, size);

  @override
  Widget build(BuildContext context) {
    final commonFields = Provider.of<CommonFields>(context);
    final theme = Theme.of(context);
    final isDarkTheme = theme.brightness == Brightness.dark;
    final fgColor = isSelected
        ? isDarkTheme
            ? theme.primaryColorLight
            : theme.primaryColorDark
        : null;
    final iconTheme = IconTheme.of(context);
    final size = iconTheme.size! * 1.5;
    final loc = AppLocalizations.of(context);
    _logger
        .info('devicePixelRatio: ${MediaQuery.of(context).devicePixelRatio}');

    final icon = EntryIcon(
      vm: vm,
      size: size,
      fallback: (context) => _defaultIcon(fgColor, theme, size),
    );

    return InkWell(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16),
            child: icon,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  DefaultTextStyle(
                    style: theme.textTheme.titleMedium!.copyWith(
                        fontWeight: FontWeight.normal, color: fgColor),
                    child: Text.rich(
                      _highlightFilterQuery(vm.label?.nullIfBlank()) ??
                          TextSpan(text: loc.noTitle),
//                      style: theme.textTheme.subtitle1.copyWith(fontWeight: null),
                    ),
                  ),
                  const SizedBox(height: 2),
                  DefaultTextStyle(
                    style: theme.textTheme.bodyLarge!.copyWith(
                        fontSize: 13,
                        color: fgColor ?? theme.textTheme.bodySmall!.color),
                    child: Text.rich(
                      _highlightFilterQuery(
                            commonFields.userName
                                .stringValue(vm.entry)
                                ?.nullIfBlank(),
                          ) ??
                          TextSpan(text: loc.noUsername),
                      style: theme.textTheme.bodyLarge!.copyWith(
                          fontSize: 12,
                          color: theme.textTheme.bodySmall!.color),
                    ),
                  ),
                  ...?vm.groupNames.length < 2
                      ? null
                      : [
                          Text(
                            nonNls('📁️  ') +
                                vm.groupNames
                                    .sublist(1)
                                    .join(CharConstants.chevronRight),
                            overflow: TextOverflow.fade,
                            maxLines: 1,
                            textAlign: TextAlign.right,
                            style: theme.textTheme.bodySmall!
                                .copyWith(fontSize: 10),
                          ),
                        ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  InlineSpan? _highlightFilterQuery(String? text) {
    if (text == null) {
      return null;
    }
    final filterQuery = this.filterQuery;
    if (filterQuery == null || filterQuery.isEmpty) {
      return TextSpan(text: text);
    }
    final lcText = text.toLowerCase();
    final lcFilterTerms = filterQuery.toLowerCase().split(CharConstants.space);
    final filterRegexp =
        RegExp(lcFilterTerms.map((e) => RegExp.escape(e)).join('|'));
    var previousMatchEnd = 0;
    final spans = <TextSpan>[];
    for (final match in filterRegexp.allMatches(lcText)) {
      spans.add(TextSpan(text: text.substring(previousMatchEnd, match.start)));
      spans.add(TextSpan(
          text: text.substring(match.start, match.end),
          style: const TextStyle(
              fontWeight: FontWeight.bold, color: Colors.green)));
      previousMatchEnd = match.end;
    }
    if (previousMatchEnd < text.length) {
      spans.add(TextSpan(text: text.substring(previousMatchEnd)));
    }
    return TextSpan(children: spans);
  }
}

class EntryIcon extends StatelessWidget {
  const EntryIcon({
    super.key,
    required this.vm,
    required this.fallback,
    required this.size,
  });

  final EntryViewModel vm;
  final double size;
  final Widget Function(BuildContext context) fallback;

  static final newLineRegexp = RegExp(r'[\r\n]');

  @override
  Widget build(BuildContext context) {
    final env = context.watch<Env>();
    final appData = context.watch<AppData>();
    if (!(appData.fetchWebsiteIcons ??
        env.featureFetchWebsiteIconEnabledByDefault)) {
      return fallback(context);
    }

    final url = vm.website?.trim();

    if (url == null) {
      return fallback(context);
    }

    if (url.contains(newLineRegexp)) {
      // If the url field contains a new line, it's definitely not a URL.
      // So to avoid spilling secrets over the network, ignore it altogether.
      return fallback(context);
    }

    final authPassCloudBloc = context.watch<AuthPassCloudBloc>();

    return CachedNetworkImage(
      cacheManager: context.watch<AuthPassCacheManager>(),
      width: size,
      height: size,
      imageUrl: authPassCloudBloc.imageBaseUrl.replace(
          queryParameters: <String, String>{nonNls('url'): url}).toString(),
      errorWidget: (context, _, dynamic __) {
        return fallback(context);
      },
    );
  }

  static Widget defaultIcon(
    EntryViewModel vm,
    Color? fgColor,
    ThemeData theme,
    double size,
  ) =>
      defaultIconForEntry(vm.entry, fgColor, theme, size,
          fileColor: vm.fileColor);

  static Widget defaultIconForEntry(
    KdbxEntry entry,
    Color? fgColor,
    ThemeData theme,
    double size, {
    Color? fileColor,
  }) {
    return entry.customIcon?.let((customIcon) => Image.memory(
              customIcon.data,
              width: size,
              height: size,
              fit: BoxFit.contain,
            )) ??
        Icon(
          PredefinedIcons.iconFor(entry.icon.get()!),
          color: fgColor ?? ThemeUtil.iconColor(theme, fileColor),
          size: size,
        );
  }
}

extension on AutofillMetadata {
  String? get searchTerm =>
      webDomains
          .where((element) => element.domain.isNotEmpty)
          .firstOrNull
          ?.domain ??
      packageNames
          .where((element) => element != 'android' // NON-NLS
              )
          .firstOrNull;
}
