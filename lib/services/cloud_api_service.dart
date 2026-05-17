import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart';

// -- Constants --
const int _defaultConnectTimeoutMs = 10000;
const int _defaultReceiveTimeoutMs = 15000;
const int _httpOk = 200;
const int _httpServerError = 500;

String _apiV1BaseUrl(String domain) => 'https://$domain/api/v1';

// Allows accepting bad TLS certs in local dev. Off by default in debug too;
// requires an explicit `--dart-define=ALLOW_INSECURE_TLS=true` to enable so
// a leaked debug build cannot silently MITM.
const _allowInsecureTls = bool.fromEnvironment(
  'ALLOW_INSECURE_TLS',
  defaultValue: false,
);

HttpClientAdapter _createDirectApiAdapter() {
  return createFlClashHttpClientAdapter(
    findProxy: (_) => 'DIRECT',
    allowBadCertificate: () => kDebugMode && _allowInsecureTls,
  );
}

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

class CloudApiException implements Exception {
  final String message;

  const CloudApiException(this.message);

  static bool isUnauthorized(Object error) {
    final message = clean(error).toLowerCase();
    return message == 'unauthorized' ||
        message.contains('unauthorized') ||
        message.contains('401');
  }

  static String clean(Object error) {
    if (error is CloudApiException) {
      return _cleanMessage(error.message);
    }
    return _cleanMessage(error.toString());
  }

  static String _cleanMessage(String value) {
    var message = value.trim();
    final prefixes = [
      RegExp(r'^_?Excep(?:t)?ion[:：]\s*', caseSensitive: false),
      RegExp(r'^CloudApiException[:：]\s*', caseSensitive: false),
      RegExp(r'^Health check fail(?:e)?d[:：]\s*', caseSensitive: false),
    ];
    var changed = true;
    while (changed) {
      changed = false;
      for (final prefix in prefixes) {
        final updated = message.replaceFirst(prefix, '').trim();
        if (updated != message) {
          message = updated;
          changed = true;
        }
      }
    }
    if (message.isEmpty || message.toLowerCase() == 'null') {
      return 'Connection failed';
    }
    return message;
  }

  @override
  String toString() => clean(this);
}

class CloudApiService {
  final Dio _dio;
  String? _cachedToken;

  static final RegExp _bearerTokenPattern = RegExp(
    r'^Bearer\s+(.+)$',
    caseSensitive: false,
  );
  static final RegExp _queryTokenPattern = RegExp(
    r'^(?:access_token|token)=(.+)$',
    caseSensitive: false,
  );

  CloudApiService._()
    : _dio = Dio(
        BaseOptions(
          baseUrl: _apiV1BaseUrl(Secrets.preferredApiDomain),
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
    _dio.httpClientAdapter = _createDirectApiAdapter();
    _dio.interceptors.addAll([
      // Logging & Authorization Interceptor
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.extra['skipAuth'] != true &&
              _cachedToken != null &&
              _cachedToken!.isNotEmpty) {
            final token = _cachedToken!;
            options.headers['Authorization'] = 'Bearer $token';
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

  static String? normalizeToken(String? token) {
    if (token == null) return null;

    var normalized = _stripWrappingQuotes(token.trim());
    if (normalized.isEmpty) return null;

    final uriToken = _extractTokenFromUri(normalized);
    if (uriToken != null) {
      normalized = uriToken;
    }

    final bearerMatch = _bearerTokenPattern.firstMatch(normalized);
    if (bearerMatch != null) {
      normalized = bearerMatch.group(1)?.trim() ?? '';
    }

    final queryToken = _extractTokenFromQuery(normalized);
    if (queryToken != null) {
      normalized = queryToken;
    }

    normalized = _stripWrappingQuotes(normalized);

    return normalized.isEmpty ? null : normalized;
  }

  static String _stripWrappingQuotes(String value) {
    var normalized = value;
    while (normalized.length >= 2 &&
        ((normalized.startsWith('"') && normalized.endsWith('"')) ||
            (normalized.startsWith("'") && normalized.endsWith("'")))) {
      normalized = normalized.substring(1, normalized.length - 1).trim();
    }
    return normalized;
  }

  static String? _extractTokenFromUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return null;
    }
    return _extractTokenFromParameters(uri.queryParameters);
  }

  static String? _extractTokenFromQuery(String value) {
    final queryCandidate = value.startsWith('?') ? value.substring(1) : value;
    if (!_queryTokenPattern.hasMatch(queryCandidate) &&
        !(queryCandidate.contains('&') && queryCandidate.contains('='))) {
      return null;
    }
    try {
      return _extractTokenFromParameters(Uri.splitQueryString(queryCandidate));
    } catch (_) {
      return null;
    }
  }

  static String? _extractTokenFromParameters(Map<String, String> parameters) {
    final token = parameters['access_token'] ?? parameters['token'];
    final normalized = token?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  void setToken(String? token) {
    final normalizedToken = normalizeToken(token);
    if (normalizedToken == null || normalizedToken.isEmpty) {
      _cachedToken = null;
    } else {
      _cachedToken = normalizedToken;
    }
  }

  Future<void> checkServiceHealth() async {
    try {
      final res = await _dio.get(
        'https://${Secrets.preferredApiDomain}/check',
        options: Options(extra: {'skipAuth': true}),
      );
      if (res.statusCode != _httpOk) {
        final statusCode = res.statusCode?.toString() ?? 'unknown';
        throw CloudApiException('Service unavailable (Status: $statusCode)');
      }
    } on DioException catch (e) {
      throw CloudApiException(_formatHealthCheckError(e));
    }
  }

  static String _formatHealthCheckError(DioException error) {
    final fallback = switch (error.type) {
      DioExceptionType.connectionTimeout => 'Connection timed out',
      DioExceptionType.sendTimeout => 'Send timed out',
      DioExceptionType.receiveTimeout => 'Response timed out',
      DioExceptionType.badCertificate => 'Invalid certificate',
      DioExceptionType.badResponse =>
        'Server returned ${error.response?.statusCode ?? 'an error'}',
      DioExceptionType.cancel => 'Request canceled',
      DioExceptionType.connectionError => 'Connection failed',
      DioExceptionType.unknown => 'Unknown network error',
    };
    if (error.type != DioExceptionType.unknown) {
      return fallback;
    }
    final message = error.message?.trim();
    if (message == null || message.isEmpty || message == 'null') {
      return fallback;
    }
    return message;
  }

  ({CloudProfile profile, CloudNotification? announcement}) _parseUserInfo(
    dynamic infoData,
  ) {
    if (infoData is! Map) {
      throw Exception('Invalid user data format');
    }
    final info = infoData;

    final requiredKeys = [
      'plan',
      'plan_time',
      'used',
      'traffic',
      'today_used',
      'unused',
      'money',
      'aff_money',
      'integral',
    ];
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
    final token = _cachedToken;
    if (token == null || token.isEmpty) {
      throw Exception('Missing access token');
    }

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
    final key = utf8.encode(Secrets.flClashAppSecret);
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
      final buildNumber = globalState.packageInfo.buildNumber;

      if (buildNumber.isNotEmpty) {
        queryParameters['flclash_build'] = buildNumber;
      }

      final headers = <String, String>{
        'X-Flclash-Timestamp': timestamp,
        'X-Flclash-Signature': signature,
      };
      if (buildNumber.isNotEmpty) {
        headers['X-Flclash-Build'] = buildNumber;
      }

      final res = await _dio.get<Map<String, dynamic>>(
        '/managed/flclash/direct',
        queryParameters: queryParameters,
        options: Options(headers: headers, responseType: ResponseType.json),
      );

      if (res.statusCode != 200) {
        throw CloudApiException('Config request failed (${res.statusCode})');
      }

      if (res.data?['ret'] == 401) {
        setToken(null);
        throw const CloudApiException('Unauthorized');
      }

      final configB64 = res.data?['config'] as String?;
      final userinfo = res.data?['userinfo'] as String?;

      if (configB64 == null || configB64.isEmpty) {
        throw const CloudApiException('Server returned empty config');
      }
      try {
        return (base64Decode(configB64), userinfo);
      } on FormatException {
        throw const CloudApiException('Server returned invalid config');
      }
    } catch (e) {
      if (e is DioException) {
        throw CloudApiException(
          'Unable to get oixCloud config: ${_formatHealthCheckError(e)}',
        );
      }
      rethrow;
    }
  }
}

// -- Interceptor to handle Retries --
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final int retries;

  RetryInterceptor({required this.dio, this.retries = 2});

  static const _retryHandledKey = 'retryHandled';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (!_shouldRetry(err) ||
        err.requestOptions.extra[_retryHandledKey] == true) {
      return super.onError(err, handler);
    }

    final retryExtra = Map<String, dynamic>.from(err.requestOptions.extra)
      ..[_retryHandledKey] = true;
    DioException lastError = err;

    for (int attempt = 1; attempt <= retries; attempt++) {
      await Future.delayed(
        Duration(milliseconds: 500 * pow(2, attempt).toInt()),
      );
      try {
        final response = await dio.fetch(
          _copyRequestOptionsForRetry(err.requestOptions, retryExtra),
        );
        return handler.resolve(response);
      } on DioException catch (e) {
        lastError = e;
        if (!_shouldRetry(e)) break;
      }
    }

    final spareDomain = _spareApiDomainFor(err.requestOptions);
    if (spareDomain != null) {
      try {
        final response = await dio.fetch(
          _copyRequestOptionsForDomain(
            err.requestOptions,
            retryExtra,
            spareDomain,
          ),
        );
        return handler.resolve(response);
      } on DioException catch (e) {
        lastError = e;
      }
    }

    // Keep oixCloud API direct-only so a broken proxy cannot block recovery.
    return super.onError(lastError, handler);
  }

  RequestOptions _copyRequestOptionsForRetry(
    RequestOptions requestOptions,
    Map<String, dynamic> extra,
  ) {
    return requestOptions.copyWith(
      data: _cloneRequestData(requestOptions.data),
      extra: extra,
    );
  }

  RequestOptions _copyRequestOptionsForDomain(
    RequestOptions requestOptions,
    Map<String, dynamic> extra,
    String domain,
  ) {
    final uri = requestOptions.uri.replace(host: domain);
    return requestOptions.copyWith(
      baseUrl: '',
      path: uri.toString(),
      queryParameters: const {},
      data: _cloneRequestData(requestOptions.data),
      extra: extra,
    );
  }

  Object? _cloneRequestData(Object? data) {
    return data is FormData ? data.clone() : data;
  }

  String? _spareApiDomainFor(RequestOptions requestOptions) {
    final primaryDomain = Secrets.preferredApiDomain.toLowerCase();
    final spareDomain = Secrets.fallbackApiDomain.toLowerCase();
    if (primaryDomain.isEmpty ||
        spareDomain.isEmpty ||
        primaryDomain == spareDomain) {
      return null;
    }
    final requestHost = requestOptions.uri.host.toLowerCase();
    if (requestHost != primaryDomain) {
      return null;
    }
    return spareDomain;
  }

  bool _shouldRetry(DioException err) {
    return err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError ||
        (err.type == DioExceptionType.badResponse &&
            (err.response?.statusCode ?? 0) >= _httpServerError);
  }
}
