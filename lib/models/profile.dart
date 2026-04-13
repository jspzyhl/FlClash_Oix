import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'clash_config.dart';
import 'state.dart';

part 'generated/profile.freezed.dart';
part 'generated/profile.g.dart';

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
      map[keyValue[0]] = int.tryParse(keyValue[1]);
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
    final apiDomain = secrets.API_DOMAIN.trim();
    if (apiDomain.isEmpty) return false;
    return url.toLowerCase().contains(apiDomain.toLowerCase());
  }

  String get fileName => '$id.yaml';

  String get updatingKey => 'profile_$id';

  Future<Profile?> checkAndUpdateAndCopy() async {
    final mFile = await _getFile(false);
    final isExists = await mFile.exists();
    if (isExists || url.isEmpty) {
      return null;
    }
    return update();
  }

  Future<File> _getFile([bool autoCreate = true]) async {
    final fileName = isoixCloudProfile ? '.${id.toString()}' : id.toString();
    final path = await appPath.getProfilePath(fileName);
    final file = File(path);

    if (isoixCloudProfile) {
      final oldPath = await appPath.getProfilePath(id.toString());
      final oldFile = File(oldPath);
      final oldIsExists = await oldFile.exists();
      if (oldIsExists) {
        await oldFile.rename(path);
      }
    }

    final isExists = await file.exists();
    if (!isExists && autoCreate) {
      final createdFile = await file.create(recursive: true);
      if (isoixCloudProfile) {
        await system.hideFile(path);
      }
      return createdFile;
    }

    if (isoixCloudProfile && isExists) {
      await system.hideFile(path);
    }

    return file;
  }

  Future<File> get file async {
    return _getFile();
  }

  Future<Profile> update() async {
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
    final path = await appPath.tempFilePath;
    final tempFile = File(path);
    await tempFile.safeWriteAsBytes(bytes);
    commonPrint.log('====== saveFile bytes length: ${bytes.length}');
    final message = await coreController.validateConfig(path);
    commonPrint.log('====== validateConfig Message: $message');
    if (message.isNotEmpty) {
      throw message;
    }
    final mFile = await file;
    await tempFile.copy(mFile.path);
    await tempFile.safeDelete();
    if (isoixCloudProfile) {
      await system.hideFile(mFile.path);
    }
    return copyWith(lastUpdateDate: DateTime.now());
  }

  Future<Profile> saveFileWithPath(String path) async {
    final message = await coreController.validateConfig(path);
    if (message.isNotEmpty) {
      throw message;
    }
    final mFile = await file;
    await File(path).copy(mFile.path);
    if (isoixCloudProfile) {
      await system.hideFile(mFile.path);
    }
    return copyWith(lastUpdateDate: DateTime.now());
  }
}
