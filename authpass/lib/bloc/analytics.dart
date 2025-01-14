import 'package:analytics_event/analytics_event.dart';
import 'package:authpass/env/_base.dart';
import 'package:authpass/ui/screens/password_list.dart';
import 'package:authpass/utils/constants.dart';
import 'package:authpass/utils/platform.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:matomo_tracker/matomo_tracker.dart' as matomo;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:string_literal_finder_annotations/string_literal_finder_annotations.dart';

part 'analytics.g.dart';

final _logger = Logger('analytics');

@NonNls
const _propertyMappingPlatform = 'platform';
@NonNls
const _propertyMappingBuildNumber = 'buildnumber';

class Analytics {
  Analytics({required this.env}) {
    _init();
  }

  @NonNls
  static void trackError(
      ErrorSource source, @NonNls String description, bool fatal) {
    final e = matomo.EventInfo(
      category: 'log',
      action: source.eventAction,
      name: description,
    );
    _errorMatomo?.trackEvent(eventInfo: e);
  }

  final Env env;
  final AnalyticsEvents events = _$AnalyticsEvents();

  matomo.MatomoTracker? _matomo;
  final List<void Function(matomo.MatomoTracker m)> _gaQ = [];
  String? _dbg;
  bool _gaQDisable = false;

  /// global analytics tracker we use for error reporting.
  static matomo.MatomoTracker? _errorMatomo;
  static const _gaPropertyMapping = <String, String>{
    _propertyMappingPlatform: 'cd1', // NON-NLS
    'userType': 'cd2', // NON-NLS
    'device': 'cd3', // NON-NLS
    'systemBrightness': 'cd4', // NON-NLS
  };
  @NonNls
  static const _matomoPropertyMapping = <String, String>{
    _propertyMappingPlatform: 'dimension1',
    _propertyMappingBuildNumber: 'dimension2',
  };

  Future<void> _init() async {
    final matomoConfig = env.secrets?.analyticsMatomo;
    if (matomoConfig != null) {
      if (AuthPassPlatform.isAndroid) {
        const miscChannel = MethodChannel('app.authpass/misc');
        final isFirebaseTestLab = await miscChannel
            .invokeMethod<bool>('isFirebaseTestLab'); // NON-NLS
        if (isFirebaseTestLab != null && isFirebaseTestLab) {
          _logger.info(
              'running in firebase test lab. not initializing analytics.');
          return;
        }
      }

      _dbg = '(ga)'; // NON-NLS
      final matomoTracker = matomo.MatomoTracker.instance;
      await matomoTracker.initialize(
        siteId: matomoConfig.siteId,
        url: matomoConfig.url,
      );
      _matomo = matomoTracker;
      // _ga = await analyticsCreate(
      //   env.secrets!.analyticsGoogleAnalyticsId!,
      //   info.appName,
      //   [info.version, CharConstants.plus, info.buildNumber].join(),
      //   userAgent: userAgent,
      // );
//      _ga.onSend.listen((event) {
//        _logger.finer('analytics send: $event');
//      });
//       _ga!.setSessionValue(_sessionParamUa, userAgent);
      _errorMatomo = _matomo;
      matomoTracker.trackDimensions(dimensions: {
        _matomoPropertyMapping[_propertyMappingPlatform]!:
            AuthPassPlatform.operatingSystem,
      });
      for (final cb in _gaQ) {
        cb(matomoTracker);
      }
      _gaQ.clear();
    } else {
      _gaQDisable = true;
      _gaQ.clear();
      _logger.info('No analytics Id defined. Not tracking anything.');
      // _errorMatomo = _matomo = usage.AnalyticsMock();
      _dbg = '(noop)'; // NON-NLS
    }

    _logger
        .finest('$_dbg Registering analytics tracker. ${_matomo?.visitor.id}');
    events.registerTracker(nonNls((final action, params) {
      final eventParams = <String, String?>{};
      int? value;
      String? category;
      String? actionOverride;

      final labelParams = <String>[];
      for (final entry in params.entries) {
        final customKey = _gaPropertyMapping[entry.key];
//        _logger.fine('entry.key: ${entry.key} = ${entry.value.runtimeType}');
        if (entry.key == 'value' && entry.value is int) {
          value = entry.value as int?;
        } else if (entry.key == 'category' && entry.value is String) {
          category = entry.value as String?;
        } else if (entry.key == 'action' && entry.value is String) {
          actionOverride = entry.value as String;
        } else if (customKey == null) {
          labelParams.add('${entry.key}=${entry.value}');
        } else {
          eventParams[customKey] = entry.value?.toString();
        }
      }
      labelParams.sort();

      if (actionOverride != null) {
        category = actionOverride;
      }

      final label = labelParams.join(',');
//      _amplitude?.logEvent(name: event, properties: params);
      _sendEvent(
        category ?? 'track',
        actionOverride ?? action,
        label: label,
        value: value,
        parameters: eventParams,
      );
    }));
  }

  void trackScreen(@NonNls String screenName) {
    _requireMatomo((matomo) {
      matomo.trackPageViewWithName(
        actionName: screenName,
        path: screenName,
      );
      _logger.finer('$_dbg screen($screenName)');
    });
  }

  void trackGenericEvent(
    @NonNls String category,
    @NonNls String action, {
    @NonNls String? label,
    int? value,
    @NonNls Map<String, String>? parameters,
  }) =>
      _sendEvent(
        category,
        action,
        label: label,
        value: value,
        parameters: parameters,
      );

  @NonNls
  void trackTiming(
    @NonNls String variableName,
    int timeMs, {
    @NonNls String? category,
    @NonNls String? label,
  }) {
    _requireMatomo((m) {
      m.trackEvent(
          eventInfo: matomo.EventInfo(
        category: 'timing',
        action: category ?? '',
        name: label == null ? variableName : '$variableName.$label',
        value: timeMs,
      ));
      _logger.finest('$_dbg timing($variableName, $timeMs, '
          'category: $category, label: $label)');
    });
  }

  @NonNls
  void _sendEvent(String category, String action,
      {String? label, int? value, Map<String, String?>? parameters}) {
    _requireMatomo((m) {
      if (label == null || label == '') {
        label = 'unknown';
      }
      m.trackEvent(
        eventInfo: matomo.EventInfo(
          category: category,
          action: action,
          name: label,
          value: value,
        ),
      );
    });
    _logger.finer(
        '$_dbg event($category, $action, $label, $value) - parameters: $parameters');
  }

  @NonNls
  void updateSizes({
    double? viewportSizeWidth,
    double? viewportSizeHeight,
    double? displaySizeWidth,
    double? displaySizeHeight,
    double? devicePixelRatio,
  }) {
    _requireMatomo((m) {
      m.trackEvent(
          eventInfo: matomo.EventInfo(
        category: 'sizes',
        action: 'viewport',
        name: '${viewportSizeWidth!.round()}x${viewportSizeHeight!.round()}',
      ));

      final sr = [displaySizeWidth, displaySizeHeight]
          .map((e) => (e! / devicePixelRatio!).round())
          .join('x');
      m.trackEvent(
          eventInfo: matomo.EventInfo(
        category: 'sizes',
        action: 'display',
        name: sr,
      ));
    });
  }

  void _requireMatomo(void Function(matomo.MatomoTracker matomo) callback) {
    if (_gaQDisable) {
      return;
    }
    final m = _matomo;
    if (m == null) {
      _gaQ.add((m) {
        try {
          callback(m);
        } catch (e, stackTrace) {
          _logger.warning('Error during analytics.', e, stackTrace);
        }
      });
    } else {
      try {
        callback(m);
      } catch (e, stackTrace) {
        _logger.warning('Error during analytics.', e, stackTrace);
      }
    }
  }
}

const _unknown = 'unknown'; // NON-NLS

Future<String> deviceInfo() async {
  // get information about the current device.
  if (AuthPassPlatform.isAndroid) {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    return androidInfo.model;
  }
  if (AuthPassPlatform.isIOS) {
    final iosInfo = await DeviceInfoPlugin().iosInfo;
    return iosInfo.utsname.machine;
  }
  return [
    _unknown,
    AuthPassPlatform.operatingSystemVersion,
    AuthPassPlatform.operatingSystem
  ].join(CharConstants.space);
}

abstract class AnalyticsEvents implements AnalyticsEventStubs {
  void trackLaunch({required Brightness? systemBrightness});

  Future<void> trackInit(
          {required String? userType, required int value}) async =>
      _trackInit(
        userType: userType,
        device: await deviceInfo(),
        value: value,
        buildnumber: (await PackageInfo.fromPlatform()).buildNumber,
        platform: AuthPassPlatform.operatingSystem,
      );

  void _trackInit({
    required String? userType,
    required String device,
    required String platform,
    required String buildnumber,
    required int value,
  });

  void trackOnboardingNew({
    @NonNls String category = 'onboarding', // NON-NLS
    @NonNls String action = 'click', // NON-NLS
    @NonNls String label = 'onboardingNewbie', // NON-NLS
  });

  void trackOnboardingExisting({
    @NonNls String category = 'onboarding', // NON-NLS
    @NonNls String action = 'click', // NON-NLS
    @NonNls String label = 'onboardingExisting', // NON-NLS
  });

  void trackActionPressed({@NonNls required String action});

  void trackCreateFileAt({
    required String cloudStorageId,
    @NonNls required String category,
  });

  void trackCreateFile();

  void trackOpenFile({@NonNls required String type});

  void trackOpenFile2(
      {@NonNls required String generator, @NonNls required String version});

  void trackSelectEntry({EntrySelectionType? type});

  void trackCopyField({@NonNls required String key});

  void trackAddField({@NonNls required String key});

  void trackCloseAllFiles({required int count});

  void trackLockAllFiles({required int count});

  void trackUserType({@NonNls String? userType});

  void trackCloseFile();

  /// weird case of empty password list.
  void trackPasswordListEmpty();

  void trackQuickUnlock({int? value});

  void trackSave({required String type, int? value});
  void trackSaveConflict({
    required String type,
    int? value,
    required bool success,
  });
  void trackSaveCount({required String? generator, required int value});

  void trackDrawerOpen();

  @NonNls
  void trackAttachmentAction(
    @NonNls String action, {
    @NonNls String category = 'attachment',
  });

  @NonNls
  void trackAttachmentAdd(
    AttachmentAddType action,
    String ext,
    int value, {
    @NonNls String category = 'attachmentAdd',
  });

  @NonNls
  void trackCloudAuth(
    CloudAuthAction action, {
    String label = 'auth',
    String category = 'cloud',
  });

  @NonNls
  void trackGroupDelete(GroupDeleteResult result, {String category = 'group'});
  @NonNls
  void trackGroupCreate({String category = 'group'});

  @NonNls
  void trackPermanentlyDeleteEntry({
    String category = 'entry',
    String action = 'perm-delete',
    String label = 'confirm',
  });
  @NonNls
  void trackPermanentlyDeleteEntryCancel({
    String category = 'entry',
    String action = 'perm-delete',
    String label = 'cancel',
  });
  @NonNls
  void trackPermanentlyDeleteGroup({
    String category = 'group',
    String action = 'perm-delete',
    String label = 'confirm',
  });
  @NonNls
  void trackPermanentlyDeleteGroupCancel({
    String category = 'group',
    String action = 'perm-delete',
    String label = 'cancel',
  });

  @NonNls
  void trackPreferences({
    @NonNls required String setting,
    @NonNls required String to,
  }) =>
      _trackPreferences(action: setting, to: to, category: 'preferences');
  void _trackPreferences({
    required String action,
    required String to,
    String? category,
  });

  @NonNls
  void trackAutofillFilter({
    @NonNls required String filter,
    String category = 'autofill',
    String action = 'filter',
    required int value,
  });
  @NonNls
  void trackAutofillSelect({
    String category = 'autofill',
    String action = 'select',
  });

  @NonNls
  void trackTryUnlock({
    required TryUnlockResult action,
    required String ext,
    required String source,
    String category = 'tryUnlock',
  });

  @NonNls
  void trackCopyPassword({
    String category = 'copyClipboard',
    String action = 'swipe',
    String label = 'password',
  });

  @NonNls
  void trackCopyUsername({
    String category = 'copyClipboard',
    String action = 'swipe',
    String label = 'username',
  });

  @NonNls
  void trackEntryAction(EntryActionType label, {String action = 'entry'});

  void trackBackupBanner(BannerAction action);

  void trackAutofillBanner(BannerAction action);

  void trackRememberPasswordBanner(BannerAction action);
}

enum BannerAction {
  shown,
  dismissed,
  saved,
}

enum EntryActionType {
  generateEmail,
  generatePassword,
  openUrl,
}

enum TryUnlockResult {
  success,
  invalidCredential,
  alreadyOpen,
  failure,
  invalidFileStructure,
}

extension TryUnlockResultExt on TryUnlockResult {
  static const DOT_POS = 16;
  String get name {
    assert(runtimeType.toString().length == DOT_POS - 1);
    return toString().substring(DOT_POS);
  }
}

enum GroupDeleteResult {
  hasSubgroups,
  hasEntries,
  deleted,
  undo,
}

enum CloudAuthAction {
  authSend,
  authResend,
  authSuccess,
  authCanceled,
}

enum AttachmentAddType {
  success,
  canceled,
}

extension ContextEvents on BuildContext {
  AnalyticsEvents get events =>
      Provider.of<Analytics>(this, listen: false).events;
}

enum ErrorSource {
  flutter('errorFlutter'),
  dart('errorDart'),
  app('errorApp'),
  ;

  const ErrorSource(@NonNls this.eventAction);
  final String eventAction;
}
