import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'dart:io';
import 'dart:convert';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';

class CloudApiService {
  final Dio _dio;
  String? _token;

  CloudApiService._()
    : _dio = Dio(
        BaseOptions(
          baseUrl: 'https://${secrets.API_DOMAIN.trim()}/api/v1',
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          followRedirects: true,
          validateStatus: (status) => status != null && status < 500,
          headers: {
            'User-Agent': 'FlClash for oixCloud',
          },
        ),
      ) {
    if (secrets.API_DOMAIN.isNotEmpty && secrets.API_DOMAIN_IP.isNotEmpty) {
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
            if (uri.host == secrets.API_DOMAIN.trim()) {
              return Socket.startConnect(secrets.API_DOMAIN_IP.trim(), uri.port);
            }
            return Socket.startConnect(proxyHost ?? uri.host, proxyPort ?? uri.port);
          };
          return client;
        },
      );
    }
  }

  static final CloudApiService _instance = CloudApiService._();
  factory CloudApiService() => _instance;

  void setToken(String? token) {
    _token = token;
  }

  Future<String?> checkServiceHealth() async {
    try {
      final res = await _dio.get('https://${secrets.API_DOMAIN.trim()}/check');
      if (res.statusCode == 200) {
        return null;
      }
      return 'Status: ${res.statusCode}';
    } catch (e) {
      if (e is DioException) {
        return e.message;
      }
      return e.toString();
    }
  }

  ({CloudProfile profile, CloudNotification? announcement}) _parseUserInfo(
    Map<dynamic, dynamic> info,
  ) {
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
      final pt = info['plan_time'].toString();
      expireTime = DateTime.tryParse(pt) ?? DateTime.now();
    } catch (_) {
      expireTime = DateTime.now();
    }

    double parseTraffic(String value) {
      if (value.isEmpty) return 0.0;
      final trafficRegex = RegExp(
        r'([\d.]+)\s*([KMGT]?)?B?',
        caseSensitive: false,
      );
      final match = trafficRegex.firstMatch(value);
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

    double usedMb = parseTraffic(info['used']?.toString() ?? '');
    double totalMb = parseTraffic(info['traffic']?.toString() ?? '');
    double progress = totalMb > 0 ? (usedMb / totalMb).clamp(0.0, 1.0) : 0.0;

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

  Future<
    ({String token, CloudProfile profile, CloudNotification? announcement})
  >
  login(String email, String password) async {
    final res = await _dio.post(
      '/login',
      data: FormData.fromMap({'email': email, 'passwd': password}),
    );

    var data = res.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }

    if (data is Map && data['ret'] == 200 && data['data'] != null) {
      final info = data['data'];
      final parsed = _parseUserInfo(info);
      return (
        token: info['token'] as String,
        profile: parsed.profile,
        announcement: parsed.announcement,
      );
    }
    throw Exception(
      data is Map
          ? (data['msg'] ?? 'Login failed')
          : 'Login failed: Invalid response',
    );
  }

  Future<({CloudProfile profile, CloudNotification? announcement})>
  getUserInfo() async {
    final res = await _dio.post(
      '/information',
      data: FormData.fromMap({'access_token': _token}),
    );

    var data = res.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }

    if (data is! Map || data['ret'] != 200 || data['data'] == null) {
      throw Exception(
        data is Map
            ? (data['msg'] ?? 'Failed to get user info')
            : 'Failed to parse user info',
      );
    }

    return _parseUserInfo(data['data']);
  }

  Future<String?> getManagedUrl() async {
    final apiRouter = secrets.API_ROUTER.trim();

    final res = await _dio.post(
      apiRouter,
      data: FormData.fromMap({'access_token': _token}),
    );
    var data = res.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }

    if (data is Map && data['ret'] == 200 && data['smart'] != null) {
      return data['smart'];
    }
    return null;
  }
}
