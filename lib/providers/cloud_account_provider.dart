import 'dart:convert';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/utils/safe_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CloudAccountNotifier extends Notifier<CloudAccountState> {
  DateTime? _lastRefreshTime;
  SharedPreferences? _prefs;
  Future<void>? _initFuture;
  Future<void>? _signInFuture;

  String _requireNormalizedToken(String token) {
    final normalizedToken = CloudApiService.normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Access token is empty');
    }
    return normalizedToken;
  }

  Future<SharedPreferences> get _safePrefs async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Awaitable handle to the one-shot init. Call sites that need the token
  /// before issuing API calls should `await ensureReady()` to avoid the
  /// race where `_init()` hasn't yet pushed the token into [CloudApiService].
  Future<void> ensureReady() => _initFuture ?? Future.value();

  @override
  CloudAccountState build() {
    _initFuture = _init();
    registerEnsureCloudReady(ensureReady);
    return const CloudAccountState();
  }

  Future<void> _init() async {
    final prefs = await _safePrefs;
    String? token = await SafeStorage.read('cloud_token');

    // Migrate plain-text token to secure storage if necessary.
    if (token == null || token.isEmpty) {
      final oldToken = prefs.getString('cloud_token');
      if (oldToken != null && oldToken.isNotEmpty) {
        token = oldToken;
        await SafeStorage.write('cloud_token', token);
        await prefs.remove('cloud_token');
      }
    }

    if (token == null || token.isEmpty) {
      CloudApiService().setToken(null);
      await _clearCache();
      await _clearManagedProfiles();
      return;
    }

    CloudApiService().setToken(token);

    final cached = _readCachedProfile(prefs);
    state = state.copyWith(
      isLoggedIn: true,
      profile: cached.profile,
      latestNotification: cached.notification,
    );

    refreshProfile();
  }

  ({CloudProfile? profile, CloudNotification? notification}) _readCachedProfile(
    SharedPreferences prefs,
  ) {
    CloudProfile? profile;
    CloudNotification? notification;
    try {
      final s = prefs.getString('cloud_profile');
      if (s != null) profile = CloudProfile.fromJson(jsonDecode(s));
    } catch (e) {
      commonPrint.log(
        'discarding corrupted cloud_profile cache: $e',
        logLevel: LogLevel.warning,
      );
      prefs.remove('cloud_profile');
    }
    try {
      final s = prefs.getString('cloud_notification');
      if (s != null) notification = CloudNotification.fromJson(jsonDecode(s));
    } catch (e) {
      commonPrint.log(
        'discarding corrupted cloud_notification cache: $e',
        logLevel: LogLevel.warning,
      );
      prefs.remove('cloud_notification');
    }
    return (profile: profile, notification: notification);
  }

  Future<void> _saveCache(
    CloudProfile profile,
    CloudNotification? notification,
  ) async {
    final prefs = await _safePrefs;
    await prefs.setString('cloud_profile', jsonEncode(profile.toJson()));
    if (notification != null) {
      await prefs.setString(
        'cloud_notification',
        jsonEncode(notification.toJson()),
      );
    }
  }

  Future<void> _clearCache() async {
    final prefs = await _safePrefs;
    await prefs.remove('cloud_profile');
    await prefs.remove('cloud_notification');
    await OixParamsStorage.clear();
  }

  Future<void> _deleteProfileLocally(
    int id, {
    required int? fallbackProfileId,
  }) async {
    oixCloudConfigCache.remove(id);
    ref.read(profilesProvider.notifier).del(id);
    await appController.clearEffect(id);
    if (ref.read(currentProfileIdProvider) != id) {
      return;
    }
    ref.read(currentProfileIdProvider.notifier).value = fallbackProfileId;
  }

  Future<void> _clearManagedProfiles() async {
    final currentProfiles = ref.read(profilesProvider);
    final sourceProfiles = currentProfiles.isNotEmpty
        ? currentProfiles
        : await database.profilesDao.all().get();
    final existing = sourceProfiles.where((p) => p.isoixCloudProfile).toList();
    final fallbackProfileId = sourceProfiles
        .where((p) => !p.isoixCloudProfile)
        .firstOrNull
        ?.id;
    for (final profile in existing) {
      if (appController.isAttach) {
        await appController.deleteProfile(profile.id);
      } else {
        await _deleteProfileLocally(
          profile.id,
          fallbackProfileId: fallbackProfileId,
        );
      }
    }
  }

  Future<void> _activateManagedProfile(
    Profile profile, {
    bool requestStartIfNeeded = true,
  }) async {
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
    if (!appController.isAttach) {
      return;
    }
    if (appController.isStart) {
      await appController.applyProfile(silence: true, force: true);
      return;
    }
    if (requestStartIfNeeded) {
      await appController.requestStartCore();
    }
  }

  Future<void> _addManagedProfile(String url) async {
    final profile = await appController.addProfileFormURL(url);
    if (profile != null) {
      await _activateManagedProfile(profile, requestStartIfNeeded: false);
    }
  }

  Future<void> _syncExistingManagedProfile(
    List<Profile> existing, {
    bool showLoading = false,
    bool showSuccessMessage = false,
  }) async {
    await _dedupOixProfiles(existing);
    final profile = existing.first;
    await appController.updateProfile(profile, showLoading: showLoading);
    if (showSuccessMessage) {
      globalState.showNotifier(AppLocalizations.current.getProfileSuccess);
    }
    await _activateManagedProfile(profile);
  }

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) {
    return _runSignIn(() async {
      final result = await CloudApiService().login(email, password);
      await _completeSignIn(
        token: _requireNormalizedToken(result.token),
        profile: result.profile,
        announcement: result.announcement,
      );
    });
  }

  Future<void> signInWithToken(String token) {
    return _runSignIn(() async {
      final normalizedToken = _requireNormalizedToken(token);
      CloudApiService().setToken(normalizedToken);
      final userInfo = await CloudApiService().getUserInfo();
      await _completeSignIn(
        token: normalizedToken,
        profile: userInfo.profile,
        announcement: userInfo.announcement,
      );
    });
  }

  Future<void> _runSignIn(Future<void> Function() action) {
    final inFlight = _signInFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = () async {
      state = state.copyWith(isLoading: true, error: null);
      try {
        await action();
      } catch (e) {
        CloudApiService().setToken(null);
        state = state.copyWith(isLoading: false, error: e.toString());
        rethrow;
      } finally {
        _signInFuture = null;
      }
    }();

    _signInFuture = future;
    return future;
  }

  Future<void> _completeSignIn({
    required String token,
    required CloudProfile profile,
    required CloudNotification? announcement,
  }) async {
    CloudApiService().setToken(token);
    await SafeStorage.write('cloud_token', token);
    _lastRefreshTime = DateTime.now();
    await _saveCache(profile, announcement);
    state = state.copyWith(
      isLoading: false,
      isLoggedIn: true,
      profile: profile,
      latestNotification: announcement,
    );
    globalState.showNotifier(AppLocalizations.current.loginSuccess);

    await _injectDefaultParams(profile);
    await importManagedProfile(oixCloudManagedProfileUrl);
  }

  Future<void> refreshProfile({bool force = false}) async {
    if (!state.isLoggedIn) return;
    if (!force && _lastRefreshTime != null) {
      if (DateTime.now().difference(_lastRefreshTime!) <
          const Duration(minutes: 30)) {
        return;
      }
    }

    state = state.copyWith(isRefreshing: true, error: null);
    try {
      final oldSubscription = state.profile?.subscription;
      final userInfo = await CloudApiService().getUserInfo();
      _lastRefreshTime = DateTime.now();
      await _saveCache(
        userInfo.profile,
        userInfo.announcement ?? state.latestNotification,
      );

      if (oldSubscription != null &&
          oldSubscription != userInfo.profile.subscription) {
        await _injectDefaultParams(userInfo.profile);
      }

      state = state.copyWith(
        isRefreshing: false,
        profile: userInfo.profile,
        latestNotification: userInfo.announcement ?? state.latestNotification,
      );
    } catch (e) {
      CloudApiService().setToken(null);
      state = state.copyWith(isRefreshing: false, error: e.toString());
    }
  }

  Future<void> _injectDefaultParams(CloudProfile profile) async {
    final tier = SubscriptionTier.fromServer(profile.subscription);
    final newDefault = tier.defaultParams;

    final oldDefaultRaw = await OixParamsStorage.loadDefaultRaw();
    final hasUserParams = await OixParamsStorage.hasConfig();
    final userParams = await OixParamsStorage.load();

    OixParams effective = userParams;

    final newDefaultEncoded = newDefault.encode();
    if (oldDefaultRaw != newDefaultEncoded) {
      await OixParamsStorage.saveDefaultRaw(newDefaultEncoded);
    }

    // No prior user params, OR user params equal the OLD default (auto-upgrade).
    // Compare via encodeWithoutTfo: tier defaults never carry tfo, but stored
    // user params do — including tfo in the comparison would always disagree.
    if (!hasUserParams ||
        (userParams.encodeWithoutTfo() == oldDefaultRaw &&
            oldDefaultRaw != newDefaultEncoded)) {
      effective = newDefault;
    }

    effective = effective.stripEmergencyIfUnsupported(tier);
    // Ensure tfo has a concrete value once we touch storage.
    effective = effective.copyWith(tfo: effective.tfo ?? true);

    if (!hasUserParams || effective != userParams) {
      await OixParamsStorage.save(effective);
    }
  }

  Future<void> syncManagedConfig() async {
    if (!state.isLoggedIn) return;

    state = state.copyWith(isSyncing: true, error: null);
    try {
      if (state.profile != null) {
        await _injectDefaultParams(state.profile!);
      }

      final existing = _existingOixProfiles();
      if (existing.isEmpty) {
        if (state.profile != null) {
          await _addManagedProfile(oixCloudManagedProfileUrl);
        }
      } else {
        await _syncExistingManagedProfile(existing);
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      state = state.copyWith(isSyncing: false);
    }
  }

  Future<void> importManagedProfile(String url) async {
    final existing = _existingOixProfiles();
    if (existing.isEmpty) {
      await _addManagedProfile(url);
      return;
    }

    try {
      await _syncExistingManagedProfile(
        existing,
        showLoading: true,
        showSuccessMessage: true,
      );
    } catch (e) {
      globalState.showNotifier(e.toString());
    }
  }

  List<Profile> _existingOixProfiles() {
    return ref
        .read(profilesProvider)
        .where((p) => p.isoixCloudProfile)
        .toList();
  }

  Future<void> _dedupOixProfiles(List<Profile> existing) async {
    for (int i = 1; i < existing.length; i++) {
      await appController.deleteProfile(existing[i].id);
    }
  }

  Future<void> signOut() async {
    await SafeStorage.delete('cloud_token');
    final prefs = await _safePrefs;
    await prefs.remove('cloud_token');
    await _clearCache();

    CloudApiService().setToken(null);
    oixCloudConfigCache.clear();
    state = const CloudAccountState();
    await _clearManagedProfiles();
  }
}

final cloudAccountProvider =
    NotifierProvider<CloudAccountNotifier, CloudAccountState>(
      CloudAccountNotifier.new,
    );
