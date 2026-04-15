import 'package:dio/dio.dart';
import 'dart:convert';
import 'dart:math';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';

// -- Constants --
const int _defaultConnectTimeoutMs = 10000;
const int _defaultReceiveTimeoutMs = 15000;
const int _httpOk = 200;
const int _httpServerError = 500;

// -- DTOs --
class CloudApiResponse<T> {
  final int ret;
  final String? msg;
  final T? data;
  final String? smart;

  CloudApiResponse({required this.ret, this.msg, this.data, this.smart});

  factory CloudApiResponse.fromJson(dynamic jsonData) {
    if (jsonData is String) {
      try {
        jsonData = jsonDecode(jsonData);
      } catch (_) {}
    }
    if (jsonData is Map) {
      return CloudApiResponse<T>(
        ret: jsonData['ret'] is int
            ? jsonData['ret']
            : int.tryParse(jsonData['ret']?.toString() ?? '') ?? 0,
        msg: jsonData['msg']?.toString(),
        data: jsonData['data'],
        smart: jsonData['smart']?.toString(),
      );
    }
    return CloudApiResponse<T>(ret: 0, msg: 'Invalid response format');
  }

  bool get isSuccess => ret == _httpOk;
}

class CloudApiService {
  final Dio _dio;
  String? _cachedToken;

  CloudApiService._()
    : _dio = Dio(
        BaseOptions(
          baseUrl: 'https://${secrets.API_DOMAIN.trim()}/api/v1',
          connectTimeout: const Duration(
            milliseconds: _defaultConnectTimeoutMs,
          ),
          receiveTimeout: const Duration(
            milliseconds: _defaultReceiveTimeoutMs,
          ),
          followRedirects: true,
          validateStatus: (status) =>
              status != null && status < _httpServerError,
          headers: {
            'User-Agent': 'FlClash for oixCloud',
            'Accept': 'application/json',
          },
        ),
      ) {
    _dio.interceptors.addAll([
      // Logging & Authorization Interceptor
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.extra['skipAuth'] != true &&
              _cachedToken != null &&
              _cachedToken!.isNotEmpty) {
            if (options.method == 'POST' || options.method == 'PUT') {
              if (options.data == null) {
                options.data = FormData.fromMap({'access_token': _cachedToken!});
              } else if (options.data is Map) {
                options.data['access_token'] = _cachedToken;
              } else if (options.data is FormData) {
                options.data.fields.add(
                  MapEntry('access_token', _cachedToken!),
                );
              }
            } else {
              options.queryParameters['access_token'] = _cachedToken;
            }
          }

          if (kDebugMode) {
            debugPrint('--> [${options.method}] ${options.uri}');
            if (options.data != null)
              debugPrint(
                'Body: ${options.data is FormData ? (options.data as FormData).fields : options.data}',
              );
          }

          handler.next(options);
        },
        onResponse: (response, handler) {
          if (kDebugMode)
            debugPrint(
              '<-- [${response.statusCode}] ${response.requestOptions.uri}',
            );
          handler.next(response);
        },
        onError: (DioException e, handler) {
          if (kDebugMode)
            debugPrint('<-- Error: ${e.message} at ${e.requestOptions.uri}');
          handler.next(e);
        },
      ),
      // Retry Interceptor
      RetryInterceptor(dio: _dio),
    ]);
  }

  static final CloudApiService _instance = CloudApiService._();
  factory CloudApiService() => _instance;

  void setToken(String? token) {
    if (token == null || token.isEmpty) {
      _cachedToken = null;
    } else {
      _cachedToken = token;
    }
  }

  Future<void> checkServiceHealth() async {
    try {
      final res = await _dio.get(
        'https://${secrets.API_DOMAIN.trim()}/check',
        options: Options(extra: {'skipAuth': true}),
      );
      if (res.statusCode != _httpOk) {
        throw Exception('Service unavailable (Status: ${res.statusCode})');
      }
    } catch (e) {
      if (e is DioException) {
        throw Exception('Health check failed: ${e.message}');
      }
      throw Exception('Health check failed: $e');
    }
  }

  ({CloudProfile profile, CloudNotification? announcement}) _parseUserInfo(
    dynamic infoData,
  ) {
    if (infoData is! Map) {
      throw Exception('Invalid user data format');
    }
    final info = infoData;

    CloudNotification? announcement;
    if (info['announcement'] is Map) {
      final ann = info['announcement'];
      final md = ann['markdown']?.toString();
      final content = ann['content']?.toString();
      announcement = CloudNotification(
        cleanMessage: (md != null && md.isNotEmpty) ? md : (content ?? ''),
        publishTime:
            DateTime.tryParse(ann['date']?.toString() ?? '') ?? DateTime.now(),
      );
    }

    DateTime expireTime;
    try {
      final pt = info['plan_time']?.toString() ?? '';
      expireTime = DateTime.tryParse(pt) ?? DateTime.now();
    } catch (_) {
      expireTime = DateTime.now();
    }

    double usedBytes = _parseTraffic(info['used']?.toString());
    double totalBytes = _parseTraffic(info['traffic']?.toString());
    double progress = totalBytes > 0
        ? (usedBytes / totalBytes).clamp(0.0, 1.0)
        : 0.0;

    final profile = CloudProfile(
      subscription: info['plan']?.toString() ?? 'Default',
      expireTime: expireTime,
      todayUsed: info['today_used']?.toString() ?? '0',
      totalUsed: info['used']?.toString() ?? '0',
      totalTraffic: info['traffic']?.toString() ?? '0',
      usageProgress: progress,
      remaining: info['unused']?.toString() ?? '0',
      balance: info['money']?.toString() ?? '0.00',
      commission: info['aff_money']?.toString() ?? '0.00',
      points: info['integral']?.toString() ?? '0 / 50',
    );

    return (profile: profile, announcement: announcement);
  }

  double _parseTraffic(String? value) {
    if (value == null || value.trim().isEmpty) return 0.0;

    final trafficRegex = RegExp(
      r'([\d.]+)\s*([KMGT]?)?B?',
      caseSensitive: false,
    );
    final match = trafficRegex.firstMatch(value.trim());
    if (match == null) return 0.0;

    final numValue = double.tryParse(match.group(1) ?? '0') ?? 0.0;

    final unit = (match.group(2) ?? '').toUpperCase();

    switch (unit) {
      case 'T':
        return numValue * 1024 * 1024 * 1024 * 1024;
      case 'G':
        return numValue * 1024 * 1024 * 1024;
      case 'M':
        return numValue * 1024 * 1024;
      case 'K':
        return numValue * 1024;
      default:
        return numValue;
    }
  }

  void _validateInput(String email, String password) {
    if (email.isEmpty || !RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(email)) {
      throw Exception('Invalid email format');
    }
    if (password.isEmpty) {
      throw Exception('Password cannot be empty');
    }
  }

  Future<
    ({String token, CloudProfile profile, CloudNotification? announcement})
  >
  login(String email, String password) async {
    _validateInput(email, password);

    final res = await _dio.post(
      '/login',
      data: FormData.fromMap({'email': email, 'passwd': password}),
      options: Options(extra: {'skipAuth': true}),
    );

    final responseDto = CloudApiResponse<Map<dynamic, dynamic>>.fromJson(
      res.data,
    );

    if (responseDto.isSuccess && responseDto.data != null) {
      final info = responseDto.data!;
      if (info['token'] != null) {
        final tokenStr = info['token']?.toString() ?? '';
        if (tokenStr.isEmpty) throw Exception('API returned empty token');

        setToken(tokenStr);
        final parsed = _parseUserInfo(info);
        return (
          token: tokenStr,
          profile: parsed.profile,
          announcement: parsed.announcement,
        );
      }
    }

    throw Exception(responseDto.msg ?? 'Login failed: Invalid response');
  }

  Future<({CloudProfile profile, CloudNotification? announcement})>
  getUserInfo() async {
    final res = await _dio.post('/information');
    final responseDto = CloudApiResponse<Map<dynamic, dynamic>>.fromJson(
      res.data,
    );

    if (!responseDto.isSuccess || responseDto.data == null) {
      throw Exception(responseDto.msg ?? 'Failed to parse user info');
    }

    return _parseUserInfo(responseDto.data!);
  }

  Future<(Uint8List, String?)> fetchManagedConfig(String paramString) async {
    final queryParameters = <String, dynamic>{};
    final cleaned = paramString.startsWith('&')
        ? paramString.substring(1)
        : paramString;
    if (cleaned.isNotEmpty) {
      Uri.splitQueryString(cleaned).forEach((k, v) {
        queryParameters[k] = v;
      });
    }

    final res = await _dio.get<Map<String, dynamic>>(
      '/managed/flclash/direct',
      queryParameters: queryParameters,
      options: Options(
        headers: {'X-Flclash-Key': secrets.FLCLASH_KEY.trim()},
        responseType: ResponseType.json,
      ),
    );

    if (res.statusCode != 200) {
      throw Exception('Server returned ${res.statusCode}');
    }

    final configB64 = res.data?['config'] as String?;
    final userinfo = res.data?['userinfo'] as String?;
    if (configB64 == null || configB64.isEmpty) {
      throw Exception('Empty config returned from server');
    }
    return (base64Decode(configB64), userinfo);
  }
}

// -- Interceptor to handle Retries --
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final int retries;

  RetryInterceptor({required this.dio, this.retries = 3});

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    var extra = Map<String, dynamic>.from(err.requestOptions.extra);
    int retryCount = extra['retryCount'] ?? 0;

    if (_shouldRetry(err) && retryCount < retries) {
      retryCount++;
      extra['retryCount'] = retryCount;
      extra['skipAuth'] = true;

      final delay = Duration(
        milliseconds: 500 * pow(2, retryCount).toInt(),
      ); // Exponential backoff
      await Future.delayed(delay);

      try {
        final response = await dio.fetch(
          err.requestOptions.copyWith(extra: extra),
        );
        return handler.resolve(response);
      } catch (e) {
        return super.onError(err, handler);
      }
    }
    return super.onError(err, handler);
  }

  bool _shouldRetry(DioException err) {
    return err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError;
  }
}
