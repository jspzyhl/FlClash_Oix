import 'package:freezed_annotation/freezed_annotation.dart';

part 'generated/cloud_account.freezed.dart';
part 'generated/cloud_account.g.dart';

@freezed
abstract class CloudProfile with _$CloudProfile {
  const factory CloudProfile({
    required String subscription,
    required DateTime expireTime,
    required String todayUsed,
    required String totalUsed,
    required String totalTraffic,
    required double usageProgress,
    required String remaining,
    required String balance,
    required String commission,
    required String points,
  }) = _CloudProfile;

  factory CloudProfile.fromJson(Map<String, dynamic> json) => _$CloudProfileFromJson(json);
}

@freezed
abstract class CloudNotification with _$CloudNotification {
  const factory CloudNotification({
    required String cleanMessage,
    required DateTime publishTime,
  }) = _CloudNotification;

  factory CloudNotification.fromJson(Map<String, dynamic> json) => _$CloudNotificationFromJson(json);
}

@freezed
abstract class CloudAccountState with _$CloudAccountState {
  const factory CloudAccountState({
    @Default(false) bool isLoading,
    @Default(false) bool isRefreshing,
    @Default(false) bool isSyncing,
    @Default(false) bool isLoggedIn,
    String? token,
    CloudProfile? profile,
    CloudNotification? latestNotification,
    String? error,
  }) = _CloudAccountState;
}

