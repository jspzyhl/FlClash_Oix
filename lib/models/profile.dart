import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'clash_config.dart';
import 'state.dart';

part 'generated/profile.freezed.dart';
part 'generated/profile.g.dart';

typedef FetchManagedConfigCallback =
    Future<(Uint8List, String?)> Function(String paramString);
FetchManagedConfigCallback? _fetchManagedConfigCallback;
const oixCloudManagedProfileUrl = 'oixcloud://managed';

/// Hook the cloud-account layer registers so [Profile.update] can wait for
/// token bootstrap to finish before issuing a managed-config fetch.
Future<void> Function()? _ensureCloudReady;
final Map<int, Uint8List> oixCloudConfigCache = {};
final AesGcm _profileCipher = AesGcm.with256bits();

const _flclashEncryptedMagic = 'FLEN';
const _flclashEncryptedVersion = 0x02;

bool isEncryptedProfileBytes(Uint8List bytes) {
  return bytes.length >= 5 &&
      bytes[0] == 0x46 &&
      bytes[1] == 0x4C &&
      bytes[2] == 0x45 &&
      bytes[3] == 0x4E &&
      bytes[4] == _flclashEncryptedVersion;
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Future<Uint8List> encryptProfileBytes(Uint8List bytes) async {
  final profileKey = Secrets.profileKey.trim();
  if (profileKey.isEmpty) {
    throw Exception('PROFILE_KEY is not configured');
  }

  final secretKey = SecretKey(sha256.convert(utf8.encode(profileKey)).bytes);
  final nonce = _randomBytes(12);
  final secretBox = await _profileCipher.encrypt(
    bytes,
    secretKey: secretKey,
    nonce: nonce,
  );

  return Uint8List.fromList([
    ...ascii.encode(_flclashEncryptedMagic),
    _flclashEncryptedVersion,
    ...nonce,
    ...secretBox.cipherText,
    ...secretBox.mac.bytes,
  ]);
}

Future<Uint8List> ensureEncryptedProfileBytes(Uint8List bytes) async {
  if (isEncryptedProfileBytes(bytes)) {
    return bytes;
  }
  return encryptProfileBytes(bytes);
}

void registerFetchManagedConfig(FetchManagedConfigCallback callback) {
  _fetchManagedConfigCallback = callback;
}

void registerEnsureCloudReady(Future<void> Function() ensure) {
  _ensureCloudReady = ensure;
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
    if (url == oixCloudManagedProfileUrl) return true;
    final normalizedUrl = url.toLowerCase();
    return Secrets.apiDomains.any(normalizedUrl.contains);
  }

  String get fileName => '$id.yaml';

  String get updatingKey => 'profile_$id';

  bool get useEncryptedDiskStore => isoixCloudProfile && system.isAndroid;

  Future<bool> hasLocalConfigSnapshot() async {
    if (isoixCloudProfile && !useEncryptedDiskStore) {
      return oixCloudConfigCache.containsKey(id);
    }

    return await getExistingFilePath() != null;
  }

  Future<String?> getExistingFilePath() async {
    final mFile = await _getFile(false);
    if (!await mFile.exists()) return null;

    if (!useEncryptedDiskStore) {
      return mFile.path;
    }

    if (!await coreController.isInit) {
      return mFile.path;
    }

    final message = await coreController.validateConfig(mFile.path);
    if (message.isEmpty) {
      return mFile.path;
    }

    commonPrint.log(
      'discarding invalid oixCloud snapshot $id: $message',
      logLevel: LogLevel.warning,
    );
    await mFile.safeDelete();
    return null;
  }

  Future<Profile?> checkAndUpdateAndCopy() async {
    if (isoixCloudProfile) {
      if (await hasLocalConfigSnapshot()) return null;
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

  Future<void> _replaceWithEncryptedSnapshot(Uint8List bytes) async {
    final encryptedBytes = await ensureEncryptedProfileBytes(bytes);
    final mFile = await _getFile(false);
    final tempFile = File(await appPath.getProfilePath('.$id'));

    try {
      if (!await tempFile.exists()) {
        await tempFile.create(recursive: true);
      }
      await tempFile.writeAsBytes(encryptedBytes, flush: true);
      await tempFile.rename(mFile.path);
    } catch (_) {
      await tempFile.safeDelete();
      rethrow;
    }
  }

  Future<Profile> update() async {
    if (isoixCloudProfile) {
      final fetch = _fetchManagedConfigCallback;
      if (fetch == null) throw Exception('fetchManagedConfig not registered');

      // Wait for cloud-account bootstrap so the API client has its token.
      await _ensureCloudReady?.call();

      final params = await OixParamsStorage.load();
      final paramWithTfo = params.encodeWithTfo();
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

      if (useEncryptedDiskStore) {
        oixCloudConfigCache.remove(id);
        await _replaceWithEncryptedSnapshot(bytes);
      } else {
        oixCloudConfigCache[id] = Uint8List.fromList(gzip.encode(bytes));
      }

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
