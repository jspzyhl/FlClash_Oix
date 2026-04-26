import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
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
            options.headers['Authorization'] = 'Bearer $_cachedToken';
            options.queryParameters['access_token'] = _cachedToken;
          }

          if (kDebugMode) {
            debugPrint('--> [${options.method}] ${options.uri}');
            if (options.data != null) {
              debugPrint('Body: [**REDACTED FOR SECURITY**]');
            }
          }

          handler.next(options);
        },
        onResponse: (response, handler) {
          if (kDebugMode) {
            debugPrint(
              '<-- [${response.statusCode}] ${response.requestOptions.uri}',
            );
          }
          if (response.statusCode == 401 ||
              (response.data is Map && response.data['ret'] == 401)) {
            _cachedToken = null;
          }
          handler.next(response);
        },
        onError: (DioException e, handler) {
          if (e.response?.statusCode == 401) {
            _cachedToken = null;
          }
          if (kDebugMode) {
            debugPrint('<-- Error: ${e.message} at ${e.requestOptions.uri}');
          }
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

    final requiredKeys = ['plan', 'plan_time', 'used', 'traffic', 'today_used', 'unused', 'money', 'aff_money', 'integral'];
    for (final key in requiredKeys) {
      if (!info.containsKey(key)) {
        throw FormatException('Missing required field: $key');
      }
      if (info[key] != null && info[key] is! String && info[key] is! num) {
        throw FormatException('Invalid type for field: $key');
      }
    }

    CloudNotification? announcement;
    if (info['announcement'] is Map) {
      final ann = info['announcement'];
      announcement = CloudNotification(
        cleanMessage: ann['content']?.toString() ?? '',
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

    final usedBytes = _parseTraffic(info['used']?.toString());
    final totalBytes = _parseTraffic(info['traffic']?.toString());
    final progress = totalBytes > 0
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
      points: info['integral']?.toString() ?? '50 / 50',
    );

    return (profile: profile, announcement: announcement);
  }

  /// Parses a human traffic string ("1.5 GB", "200 MiB", "42") into bytes.
  /// Multipliers always follow the 1024 (binary) convention regardless of
  /// whether the unit is written `MB` or `MiB` — the server uses both forms
  /// interchangeably.
  int _parseTraffic(String? value) {
    if (value == null || value.trim().isEmpty) return 0;

    final trafficRegex = RegExp(
      r'^(\d+(?:\.\d+)?)\s*([KMGT])?(i)?B?$',
      caseSensitive: false,
    );
    final match = trafficRegex.firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Invalid traffic format: $value');
    }

    final numValue = double.tryParse(match.group(1) ?? '0') ?? 0.0;
    final unit = (match.group(2) ?? '').toUpperCase();
    final multiplier = switch (unit) {
      'T' => 1 << 40,
      'G' => 1 << 30,
      'M' => 1 << 20,
      'K' => 1 << 10,
      _ => 1,
    };
    return (numValue * multiplier).round();
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

  String _flclashTimestamp() {
    return (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
  }

  String _flclashSignature(String timestamp) {
    final key = utf8.encode(secrets.FLCLASH_APP_SECRET);
    final msg = utf8.encode(timestamp);
    final hmac = Hmac(sha256, key);
    return hmac.convert(msg).toString();
  }

  Future<(Uint8List, String?)> fetchManagedConfig(String paramString) async {
    try {
      final queryParameters = <String, dynamic>{};
      final cleaned = paramString.startsWith('&')
          ? paramString.substring(1)
          : paramString;
      if (cleaned.isNotEmpty) {
        Uri.splitQueryString(cleaned).forEach((k, v) {
          queryParameters[k] = v;
        });
      }

      final timestamp = _flclashTimestamp();
      final signature = _flclashSignature(timestamp);

      final res = await _dio.get<Map<String, dynamic>>(
        '/managed/flclash/direct',
        queryParameters: queryParameters,
        options: Options(
          headers: {
            'X-Flclash-Timestamp': timestamp,
            'X-Flclash-Signature': signature,
          },
          responseType: ResponseType.json,
        ),
      );

      if (res.statusCode != 200) {
        throw Exception('Server returned ${res.statusCode}');
      }

      if (res.data?['ret'] == 401) {
        setToken(null);
        throw Exception('Unauthorized');
      }

      final configB64 = res.data?['config'] as String?;
      final userinfo = res.data?['userinfo'] as String?;
      
      if (configB64 == null || configB64.isEmpty) {
        throw Exception('Empty config returned from server');
      }
      return (base64Decode(configB64), userinfo);
    } catch (e) {
      if (e is DioException) {
        throw Exception('Network error: ${e.type.name}');
      }
      rethrow;
    }
  }
}

// -- Interceptor to handle Retries --
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final int retries;
  Dio? _directDio;

  RetryInterceptor({required this.dio, this.retries = 2});

  // Allows accepting bad TLS certs in local dev. Off by default in debug too;
  // requires an explicit `--dart-define=ALLOW_INSECURE_TLS=true` to enable so
  // a leaked debug build cannot silently MITM.
  static const _allowInsecureTls = bool.fromEnvironment(
    'ALLOW_INSECURE_TLS',
    defaultValue: false,
  );

  Dio _getDirectDio() {
    final existing = _directDio;
    if (existing != null) return existing;
    final direct = Dio(dio.options.copyWith());
    direct.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (_) => 'DIRECT';
        client.badCertificateCallback = (_, _, _) =>
            kDebugMode && _allowInsecureTls;
        return client;
      },
    );
    _directDio = direct;
    return direct;
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (!_shouldRetry(err) ||
        err.requestOptions.extra['retryHandled'] == true) {
      return super.onError(err, handler);
    }

    final baseExtra = Map<String, dynamic>.from(err.requestOptions.extra)
      ..['retryHandled'] = true;
    DioException lastError = err;

    for (int attempt = 1; attempt <= retries; attempt++) {
      await Future.delayed(
        Duration(milliseconds: 500 * pow(2, attempt).toInt()),
      );
      try {
        final response = await dio.fetch(
          err.requestOptions.copyWith(extra: baseExtra),
        );
        return handler.resolve(response);
      } on DioException catch (e) {
        lastError = e;
        if (!_shouldRetry(e)) break;
      }
    }

    if (_shouldRetry(lastError)) {
      try {
        final response = await _getDirectDio().fetch(
          err.requestOptions.copyWith(extra: baseExtra),
        );
        return handler.resolve(response);
      } on DioException catch (e) {
        lastError = e;
      }
    }

    return super.onError(lastError, handler);
  }

  bool _shouldRetry(DioException err) {
    return err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError;
  }
}
