// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'analytics.dart';

// **************************************************************************
// AnalyticsEventGenerator
// **************************************************************************

// ignore_for_file: unnecessary_statements

// useNullSafetySyntax: true
class _$AnalyticsEvents extends AnalyticsEvents with AnalyticsEventStubsImpl {
  _$AnalyticsEvents([TrackAnalytics? tracker]) {
    tracker != null ? registerTracker(tracker) : null;
  }

  @override
  void trackLaunch({required Brightness? systemBrightness}) => trackEvent(
        'launch',
        <String, Object?>{'systemBrightness': systemBrightness.toString()},
      );

  @override
  void _trackInit({
    required String? userType,
    required String device,
    required String platform,
    required String buildnumber,
    required int value,
  }) =>
      trackEvent(
        'init',
        <String, Object?>{
          'userType': userType,
          'device': device,
          'platform': platform,
          'buildnumber': buildnumber,
          'value': value,
        },
      );

  @override
  void trackOnboardingNew({
    String category = 'onboarding',
    String action = 'click',
    String label = 'onboardingNewbie',
  }) =>
      trackEvent(
        'onboardingNew',
        <String, Object?>{
          'category': category,
          'action': action,
          'label': label,
        },
      );

  @override
  void trackOnboardingExisting({
    String category = 'onboarding',
    String action = 'click',
    String label = 'onboardingExisting',
  }) =>
      trackEvent(
        'onboardingExisting',
        <String, Object?>{
          'category': category,
          'action': action,
          'label': label,
        },
      );

  @override
  void trackActionPressed({required String action}) => trackEvent(
        'actionPressed',
        <String, Object?>{'action': action},
      );

  @override
  void trackCreateFileAt({
    required String cloudStorageId,
    required String category,
  }) =>
      trackEvent(
        'createFileAt',
        <String, Object?>{
          'cloudStorageId': cloudStorageId,
          'category': category,
        },
      );

  @override
  void trackCreateFile() => trackEvent(
        'createFile',
        <String, Object?>{},
      );

  @override
  void trackOpenFile({required String type}) => trackEvent(
        'openFile',
        <String, Object?>{'type': type},
      );

  @override
  void trackOpenFile2({
    required String generator,
    required String version,
  }) =>
      trackEvent(
        'openFile2',
        <String, Object?>{
          'generator': generator,
          'version': version,
        },
      );

  @override
  void trackSelectEntry({EntrySelectionType? type}) => trackEvent(
        'selectEntry',
        <String, Object?>{'type': type.toString()},
      );

  @override
  void trackCopyField({required String key}) => trackEvent(
        'copyField',
        <String, Object?>{'key': key},
      );

  @override
  void trackAddField({required String key}) => trackEvent(
        'addField',
        <String, Object?>{'key': key},
      );

  @override
  void trackCloseAllFiles({required int count}) => trackEvent(
        'closeAllFiles',
        <String, Object?>{'count': count},
      );

  @override
  void trackLockAllFiles({required int count}) => trackEvent(
        'lockAllFiles',
        <String, Object?>{'count': count},
      );

  @override
  void trackUserType({String? userType}) => trackEvent(
        'userType',
        <String, Object?>{'userType': userType},
      );

  @override
  void trackCloseFile() => trackEvent(
        'closeFile',
        <String, Object?>{},
      );

  @override
  void trackPasswordListEmpty() => trackEvent(
        'passwordListEmpty',
        <String, Object?>{},
      );

  @override
  void trackQuickUnlock({int? value}) => trackEvent(
        'quickUnlock',
        <String, Object?>{'value': value},
      );

  @override
  void trackSave({
    required String type,
    int? value,
  }) =>
      trackEvent(
        'save',
        <String, Object?>{
          'type': type,
          'value': value,
        },
      );

  @override
  void trackSaveConflict({
    required String type,
    int? value,
    required bool success,
  }) =>
      trackEvent(
        'saveConflict',
        <String, Object?>{
          'type': type,
          'value': value,
          'success': success,
        },
      );

  @override
  void trackSaveCount({
    required String? generator,
    required int value,
  }) =>
      trackEvent(
        'saveCount',
        <String, Object?>{
          'generator': generator,
          'value': value,
        },
      );

  @override
  void trackDrawerOpen() => trackEvent(
        'drawerOpen',
        <String, Object?>{},
      );

  @override
  void trackAttachmentAction(
    String action, {
    String category = 'attachment',
  }) =>
      trackEvent(
        'attachmentAction',
        <String, Object?>{
          'action': action,
          'category': category,
        },
      );

  @override
  void trackAttachmentAdd(
    AttachmentAddType action,
    String ext,
    int value, {
    String category = 'attachmentAdd',
  }) =>
      trackEvent(
        'attachmentAdd',
        <String, Object?>{
          'action': action.toString(),
          'ext': ext,
          'value': value,
          'category': category,
        },
      );

  @override
  void trackCloudAuth(
    CloudAuthAction action, {
    String label = 'auth',
    String category = 'cloud',
  }) =>
      trackEvent(
        'cloudAuth',
        <String, Object?>{
          'action': action.toString(),
          'label': label,
          'category': category,
        },
      );

  @override
  void trackGroupDelete(
    GroupDeleteResult result, {
    String category = 'group',
  }) =>
      trackEvent(
        'groupDelete',
        <String, Object?>{
          'result': result.toString(),
          'category': category,
        },
      );

  @override
  void trackGroupCreate({String category = 'group'}) => trackEvent(
        'groupCreate',
        <String, Object?>{'category': category},
      );

  @override
  void trackPermanentlyDeleteEntry({
    String category = 'entry',
    String action = 'perm-delete',
    String label = 'confirm',
  }) =>
      trackEvent(
        'permanentlyDeleteEntry',
        <String, Object?>{
          'category': category,
          'action': action,
          'label': label,
        },
      );

  @override
  void trackPermanentlyDeleteEntryCancel({
    String category = 'entry',
    String action = 'perm-delete',
    String label = 'cancel',
  }) =>
      trackEvent(
        'permanentlyDeleteEntryCancel',
        <String, Object?>{
          'category': category,
          'action': action,
          'label': label,
        },
      );

  @override
  void trackPermanentlyDeleteGroup({
    String category = 'group',
    String action = 'perm-delete',
    String label = 'confirm',
  }) =>
      trackEvent(
        'permanentlyDeleteGroup',
        <String, Object?>{
          'category': category,
          'action': action,
          'label': label,
        },
      );

  @override
  void trackPermanentlyDeleteGroupCancel({
    String category = 'group',
    String action = 'perm-delete',
    String label = 'cancel',
  }) =>
      trackEvent(
        'permanentlyDeleteGroupCancel',
        <String, Object?>{
          'category': category,
          'action': action,
          'label': label,
        },
      );

  @override
  void _trackPreferences({
    required String action,
    required String to,
    String? category,
  }) =>
      trackEvent(
        'preferences',
        <String, Object?>{
          'action': action,
          'to': to,
          'category': category,
        },
      );

  @override
  void trackAutofillFilter({
    required String filter,
    String category = 'autofill',
    String action = 'filter',
    required int value,
  }) =>
      trackEvent(
        'autofillFilter',
        <String, Object?>{
          'filter': filter,
          'category': category,
          'action': action,
          'value': value,
        },
      );

  @override
  void trackAutofillSelect({
    String category = 'autofill',
    String action = 'select',
  }) =>
      trackEvent(
        'autofillSelect',
        <String, Object?>{
          'category': category,
          'action': action,
        },
      );

  @override
  void trackTryUnlock({
    required TryUnlockResult action,
    required String ext,
    required String source,
    String category = 'tryUnlock',
  }) =>
      trackEvent(
        'tryUnlock',
        <String, Object?>{
          'action': action.toString(),
          'ext': ext,
          'source': source,
          'category': category,
        },
      );

  @override
  void trackCopyPassword({
    String category = 'copyClipboard',
    String action = 'swipe',
    String label = 'password',
  }) =>
      trackEvent(
        'copyPassword',
        <String, Object?>{
          'category': category,
          'action': action,
          'label': label,
        },
      );

  @override
  void trackCopyUsername({
    String category = 'copyClipboard',
    String action = 'swipe',
    String label = 'username',
  }) =>
      trackEvent(
        'copyUsername',
        <String, Object?>{
          'category': category,
          'action': action,
          'label': label,
        },
      );

  @override
  void trackEntryAction(
    EntryActionType label, {
    String action = 'entry',
  }) =>
      trackEvent(
        'entryAction',
        <String, Object?>{
          'label': label.toString(),
          'action': action,
        },
      );

  @override
  void trackBackupBanner(BannerAction action) => trackEvent(
        'backupBanner',
        <String, Object?>{'action': action.toString()},
      );

  @override
  void trackAutofillBanner(BannerAction action) => trackEvent(
        'autofillBanner',
        <String, Object?>{'action': action.toString()},
      );

  @override
  void trackRememberPasswordBanner(BannerAction action) => trackEvent(
        'rememberPasswordBanner',
        <String, Object?>{'action': action.toString()},
      );
}
