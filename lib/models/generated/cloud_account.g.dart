// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../cloud_account.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_CloudProfile _$CloudProfileFromJson(Map<String, dynamic> json) =>
    _CloudProfile(
      subscription: json['subscription'] as String,
      expireTime: DateTime.parse(json['expireTime'] as String),
      todayUsed: json['todayUsed'] as String,
      totalUsed: json['totalUsed'] as String,
      totalTraffic: json['totalTraffic'] as String,
      usageProgress: (json['usageProgress'] as num).toDouble(),
      remaining: json['remaining'] as String,
      balance: json['balance'] as String,
      commission: json['commission'] as String,
      points: json['points'] as String,
    );

Map<String, dynamic> _$CloudProfileToJson(_CloudProfile instance) =>
    <String, dynamic>{
      'subscription': instance.subscription,
      'expireTime': instance.expireTime.toIso8601String(),
      'todayUsed': instance.todayUsed,
      'totalUsed': instance.totalUsed,
      'totalTraffic': instance.totalTraffic,
      'usageProgress': instance.usageProgress,
      'remaining': instance.remaining,
      'balance': instance.balance,
      'commission': instance.commission,
      'points': instance.points,
    };

_CloudNotification _$CloudNotificationFromJson(Map<String, dynamic> json) =>
    _CloudNotification(
      cleanMessage: json['cleanMessage'] as String,
      publishTime: DateTime.parse(json['publishTime'] as String),
    );

Map<String, dynamic> _$CloudNotificationToJson(_CloudNotification instance) =>
    <String, dynamic>{
      'cleanMessage': instance.cleanMessage,
      'publishTime': instance.publishTime.toIso8601String(),
    };
