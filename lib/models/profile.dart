import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'clash_config.dart';
import 'state.dart';

part 'generated/profile.freezed.dart';
part 'generated/profile.g.dart';

typedef FetchManagedConfigCallback =
    Future<(Uint8List, String?)> Function(String paramString);
FetchManagedConfigCallback? _fetchManagedConfigCallback;
final Map<int, Uint8List> oixCloudConfigCache = {};

void registerFetchManagedConfig(FetchManagedConfigCallback callback) {
  _fetchManagedConfigCallback = callback;
}

@freezed
abstract class SubscriptionInfo with _$SubscriptionInfo {
  const factory SubscriptionInfo({
    @Default(0) int upload,
    @Default(0) int download,
    @Default(0) int total,
    @Default(0) int expire,
  }) = _SubscriptionInfo;

  factory SubscriptionInfo.fromJson(Map<String, Object?> json) =>
      _$SubscriptionInfoFromJson(json);

  factory SubscriptionInfo.formHString(String? info) {
    if (info == null) return const SubscriptionInfo();
    final list = info.split(';');
    Map<String, int?> map = {};
    for (final i in list) {
      final keyValue = i.trim().split('=');
      if (keyValue.length >= 2) {
        map[keyValue[0]] = int.tryParse(keyValue[1]);
      }
    }
    return SubscriptionInfo(
      upload: map['upload'] ?? 0,
      download: map['download'] ?? 0,
      total: map['total'] ?? 0,
      expire: map['expire'] ?? 0,
    );
  }
}

@freezed
abstract class Profile with _$Profile {
  const factory Profile({
    required int id,
    @Default('') String label,
    String? currentGroupName,
    @Default('') String url,
    DateTime? lastUpdateDate,
    required Duration autoUpdateDuration,
    SubscriptionInfo? subscriptionInfo,
    @Default(true) bool autoUpdate,
    @Default({}) Map<String, String> selectedMap,
    @Default({}) Set<String> unfoldSet,
    @Default(OverwriteType.standard) OverwriteType overwriteType,
    int? scriptId,
    int? order,
  }) = _Profile;

  factory Profile.fromJson(Map<String, Object?> json) =>
      _$ProfileFromJson(json);

  factory Profile.normal({String? label, String url = ''}) {
    final id = snowflake.id;
    return Profile(
      label: label ?? '',
      url: url,
      id: id,
      autoUpdateDuration: defaultUpdateDuration,
    );
  }
}

@freezed
abstract class ProfileRuleLink with _$ProfileRuleLink {
  const factory ProfileRuleLink({
    int? profileId,
    required int ruleId,
    RuleScene? scene,
    String? order,
  }) = _ProfileRuleLink;
}

extension ProfileRuleLinkExt on ProfileRuleLink {
  String get key {
    final splits = <String?>[
      profileId?.toString(),
      ruleId.toString(),
      scene?.name,
    ];
    return splits.where((item) => item != null).join('_');
  }
}

// @freezed
// abstract class Overwrite with _$Overwrite {
//   const factory Overwrite({
//     @Default(OverwriteType.standard) OverwriteType type,
//     @Default(StandardOverwrite()) StandardOverwrite standardOverwrite,
//     @Default(ScriptOverwrite()) ScriptOverwrite scriptOverwrite,
//   }) = _Overwrite;
//
//   factory Overwrite.fromJson(Map<String, Object?> json) =>
//       _$OverwriteFromJson(json);
// }

@freezed
abstract class StandardOverwrite with _$StandardOverwrite {
  const factory StandardOverwrite({
    @Default([]) List<Rule> addedRules,
    @Default([]) List<int> disabledRuleIds,
  }) = _StandardOverwrite;

  factory StandardOverwrite.fromJson(Map<String, Object?> json) =>
      _$StandardOverwriteFromJson(json);
}

@freezed
abstract class ScriptOverwrite with _$ScriptOverwrite {
  const factory ScriptOverwrite({int? scriptId}) = _ScriptOverwrite;

  factory ScriptOverwrite.fromJson(Map<String, Object?> json) =>
      _$ScriptOverwriteFromJson(json);
}

extension ProfilesExt on List<Profile> {
  Profile? getProfile(int? profileId) {
    final index = indexWhere((profile) => profile.id == profileId);
    return index == -1 ? null : this[index];
  }

  String _getLabel(String label, int id) {
    final realLabel = label.takeFirstValid([id.toString()]);
    final hasDup =
        indexWhere(
          (element) => element.label == realLabel && element.id != id,
        ) !=
        -1;
    if (hasDup) {
      return _getLabel(utils.getOverwriteLabel(realLabel), id);
    } else {
      return label;
    }
  }

  VM2<List<Profile>, Profile> copyAndAddProfile(Profile profile) {
    final List<Profile> profilesTemp = List.from(this);
    final index = profilesTemp.indexWhere(
      (element) => element.id == profile.id,
    );
    final updateProfile = profile.copyWith(
      label: _getLabel(profile.label, profile.id),
    );
    if (index == -1) {
      profilesTemp.add(updateProfile);
    } else {
      profilesTemp[index] = updateProfile;
    }
    return VM2(profilesTemp, updateProfile);
  }
}

extension ProfileExtension on Profile {
  ProfileType get type =>
      url.isEmpty == true ? ProfileType.file : ProfileType.url;

  bool get realAutoUpdate => url.isEmpty == true ? false : autoUpdate;

  String get realLabel => label.takeFirstValid([id.toString()]);

  bool get isoixCloudProfile {
    if (url == 'oixcloud://managed') return true;
    final apiDomain = secrets.API_DOMAIN.trim();
    if (apiDomain.isEmpty) return false;
    return url.toLowerCase().contains(apiDomain.toLowerCase());
  }

  String get fileName => '$id.yaml';

  String get updatingKey => 'profile_$id';

  Future<Profile?> checkAndUpdateAndCopy() async {
    if (isoixCloudProfile) {
      if (oixCloudConfigCache.containsKey(id)) return null;
      return update();
    }
    final mFile = await _getFile(false);
    final isExists = await mFile.exists();
    if (isExists || url.isEmpty) {
      return null;
    }
    return update();
  }

  Future<File> _getFile([bool autoCreate = true]) async {
    final fileName = id.toString();
    final path = await appPath.getProfilePath(fileName);
    final file = File(path);

    final isExists = await file.exists();
    if (!isExists && autoCreate) {
      final createdFile = await file.create(recursive: true);
      return createdFile;
    }

    return file;
  }

  Future<File> get file async {
    return _getFile();
  }

  Future<Profile> update() async {
    if (isoixCloudProfile) {
      final prefs = await SharedPreferences.getInstance();
      final savedParams = prefs.getString('cloud_service_config_params') ?? '';
      final tfoEnabled = prefs.getBool('cloud_service_tfo') ?? true;
      final paramWithTfo =
          savedParams + (tfoEnabled ? '&tfo=true' : '&tfo=false');
      final fetch = _fetchManagedConfigCallback;
      if (fetch == null) throw Exception('fetchManagedConfig not registered');
      // Ensure token is injected even if CloudAccountNotifier._init() hasn't completed yet
      const secureStorage = FlutterSecureStorage();
      final token = await secureStorage.read(key: 'cloud_token');
      if (token != null && token.isNotEmpty) {
        CloudApiService().setToken(token);
      }
      final (bytes, userinfo) = await fetch(paramWithTfo);
      final profileWithLabel = label.isNotEmpty
          ? this
          : copyWith(label: 'oixCloud');
      return profileWithLabel
          .copyWith(subscriptionInfo: SubscriptionInfo.formHString(userinfo))
          .saveFile(bytes);
    }

    final response = await request.getFileResponseForUrl(url);
    final disposition = response.headers.value('content-disposition');
    final userinfo = response.headers.value('subscription-userinfo');
    return await copyWith(
      label: label.takeFirstValid([
        utils.getFileNameForDisposition(disposition),
        id.toString(),
      ]),
      subscriptionInfo: SubscriptionInfo.formHString(userinfo),
    ).saveFile(response.data ?? Uint8List.fromList([]));
  }

  Future<Profile> saveFile(Uint8List bytes) async {
    if (isoixCloudProfile) {
      final base64String = base64Encode(bytes);
      final message = await coreController.validateConfigWithBytes(
        base64String,
      );
      commonPrint.log('validateConfigWithBytes result: "$message"');
      if (message.isNotEmpty) {
        commonPrint.log('validateConfig failed', logLevel: LogLevel.warning);
        throw message;
      }
      oixCloudConfigCache[id] = Uint8List.fromList(gzip.encode(bytes));
      return copyWith(lastUpdateDate: DateTime.now());
    }

    final path = await appPath.tempFilePath;
    final tempFile = File(path);
    await tempFile.safeWriteAsBytes(bytes);
    commonPrint.log('====== saveFile bytes length: ${bytes.length}');
    final message = await coreController.validateConfig(path);
    if (message.isNotEmpty) {
      commonPrint.log('====== validateConfig Message: $message');
      throw message;
    }
    final mFile = await file;
    await tempFile.copy(mFile.path);
    await tempFile.safeDelete();
    return copyWith(lastUpdateDate: DateTime.now());
  }

  Future<Profile> saveFileWithPath(String path) async {
    final message = await coreController.validateConfig(path);
    if (message.isNotEmpty) {
      throw message;
    }
    final mFile = await file;
    await File(path).copy(mFile.path);
    return copyWith(lastUpdateDate: DateTime.now());
  }
}
