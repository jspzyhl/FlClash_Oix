import 'dart:convert';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/common/common.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CloudAccountNotifier extends Notifier<CloudAccountState> {
  DateTime? _lastRefreshTime;

  @override
  CloudAccountState build() {
    _init();
    return const CloudAccountState();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('cloud_token');

    if (token != null && token.isNotEmpty) {
      CloudProfile? cachedProfile;
      CloudNotification? cachedNotification;

      try {
        final profileStr = prefs.getString('cloud_profile');
        if (profileStr != null) {
          cachedProfile = CloudProfile.fromJson(jsonDecode(profileStr));
        }

        final notificationStr = prefs.getString('cloud_notification');
        if (notificationStr != null) {
          cachedNotification = CloudNotification.fromJson(
            jsonDecode(notificationStr),
          );
        }
      } catch (_) {}

      state = state.copyWith(
        isLoggedIn: true,
        profile: cachedProfile,
        latestNotification: cachedNotification,
      );

      CloudApiService().setToken(token);

      // refresh asynchronously without blocking
      refreshProfile();
    }
  }

  Future<void> _saveCache(
    CloudProfile profile,
    CloudNotification? notification,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cloud_profile', jsonEncode(profile.toJson()));
    if (notification != null) {
      await prefs.setString(
        'cloud_notification',
        jsonEncode(notification.toJson()),
      );
    }
  }

  Future<void> _clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cloud_profile');
    await prefs.remove('cloud_notification');
    await prefs.remove('cloud_service_config_params');
    await prefs.remove('cloud_service_default_params');
    await prefs.remove('cloud_service_tfo');
  }

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await CloudApiService().login(email, password);
      final token = result.token;

      CloudApiService().setToken(token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cloud_token', token);

      _lastRefreshTime = DateTime.now();
      await _saveCache(result.profile, result.announcement);
      state = state.copyWith(
        isLoading: false,
        isLoggedIn: true,
        profile: result.profile,
        latestNotification: result.announcement,
      );

      globalState.showNotifier(AppLocalizations.current.loginSuccess);

      final injectedUrl = await _injectDefaultParams(result.profile);
      await importManagedProfile(injectedUrl);
    } catch (e) {
      CloudApiService().setToken(null);
      state = state.copyWith(isLoading: false, error: e.toString());
      rethrow;
    }
  }

  Future<void> signInWithToken(String token) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      CloudApiService().setToken(token);
      final userInfo = await CloudApiService().getUserInfo();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cloud_token', token);

      await _saveCache(userInfo.profile, userInfo.announcement);
      state = state.copyWith(
        isLoading: false,
        isLoggedIn: true,
        profile: userInfo.profile,
        latestNotification: userInfo.announcement,
      );

      globalState.showNotifier(AppLocalizations.current.loginSuccess);

      final injectedUrl = await _injectDefaultParams(userInfo.profile);
      await importManagedProfile(injectedUrl);
    } catch (e) {
      CloudApiService().setToken(null);
      state = state.copyWith(isLoading: false, error: e.toString());
      rethrow;
    }
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
      final userInfo = await CloudApiService().getUserInfo();
      _lastRefreshTime = DateTime.now();
      await _saveCache(
        userInfo.profile,
        userInfo.announcement ?? state.latestNotification,
      );
      state = state.copyWith(
        isRefreshing: false,
        profile: userInfo.profile,
        latestNotification: userInfo.announcement ?? state.latestNotification,
      );
    } catch (e) {
      state = state.copyWith(isRefreshing: false, error: e.toString());
    }
  }

  Future<String> _injectDefaultParams(CloudProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final hasSavedParams = prefs.containsKey('cloud_service_config_params');
    String savedParams = prefs.getString('cloud_service_config_params') ?? '';

    if (!hasSavedParams &&
        profile.subscription.isNotEmpty &&
        profile.subscription != 'Pass Iron' &&
        profile.subscription != 'null') {
      if (profile.subscription == 'Pass Bronze') {
        savedParams = '&lv=2';
      } else {
        savedParams = '&type=love';
      }
    }

    final tfoObj = prefs.getBool('cloud_service_tfo');
    final parseResult = CloudConfigHelper.parseTfoParams(savedParams, tfoObj);
    bool tfoEnabled = parseResult.tfoEnabled;
    bool needsUpdate = parseResult.needsUpdate;
    savedParams = parseResult.params;

    if (needsUpdate) {
      await prefs.setBool('cloud_service_tfo', tfoEnabled);
    }

    if (!hasSavedParams ||
        savedParams != (prefs.getString('cloud_service_config_params') ?? '')) {
      await prefs.setString('cloud_service_config_params', savedParams);
    }

    if (!hasSavedParams) {
      await prefs.setString('cloud_service_default_params', savedParams);
    }

    return 'oixcloud://managed';
  }

  Future<void> syncManagedConfig() async {
    if (!state.isLoggedIn) return;

    state = state.copyWith(isSyncing: true, error: null);
    try {
      final existingProfiles = ref
          .read(profilesProvider)
          .where((p) => p.isoixCloudProfile)
          .toList();

      if (state.profile != null) {
        final injectedUrl = await _injectDefaultParams(state.profile!);
        if (existingProfiles.isEmpty) {
          final profile = await appController.addProfileFormURL(injectedUrl);
          if (profile != null) {
            ref.read(currentProfileIdProvider.notifier).value = profile.id;
          }
        } else {
          for (int i = 1; i < existingProfiles.length; i++) {
            await appController.deleteProfile(existingProfiles[i].id);
          }
          await appController.updateProfiles();
        }
      } else if (existingProfiles.isNotEmpty) {
        await appController.updateProfiles();
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      state = state.copyWith(isSyncing: false);
    }
  }

  Future<void> importManagedProfile(String url) async {
    final existingProfiles = ref
        .read(profilesProvider)
        .where((p) => p.isoixCloudProfile)
        .toList();
    if (existingProfiles.isEmpty) {
      final profile = await appController.addProfileFormURL(url);
      if (profile != null) {
        ref.read(currentProfileIdProvider.notifier).value = profile.id;
      }
    } else {
      for (int i = 1; i < existingProfiles.length; i++) {
        await appController.deleteProfile(existingProfiles[i].id);
      }

      bool updated = false;
      try {
        await appController.updateProfile(
          existingProfiles.first,
          showLoading: true,
        );
        updated = true;
      } catch (e) {
        globalState.showNotifier(e.toString());
      }

      if (updated) {
        globalState.showNotifier(AppLocalizations.current.getProfileSuccess);
        await appController.requestStartCore();
      }
    }
  }

  Future<void> signOut({bool revokeToken = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cloud_token');
    await _clearCache();

    CloudApiService().setToken(null);
    state = const CloudAccountState();

    final existingProfiles = ref
        .read(profilesProvider)
        .where((p) => p.isoixCloudProfile)
        .toList();
    for (final p in existingProfiles) {
      await appController.deleteProfile(p.id);
    }
  }
}

final cloudAccountProvider =
    NotifierProvider<CloudAccountNotifier, CloudAccountState>(
      CloudAccountNotifier.new,
    );
