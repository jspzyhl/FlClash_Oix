import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/cupertino.dart';

class Request {
  late final Dio dio;
  late final Dio _clashDio;
  String? userAgent;

  Request() {
    dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _clashDio = Dio();
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = appController.ua;
          return FlClashHttpOverrides.handleFindProxy(uri);
        };
        return client;
      },
    );

    final interceptor = InterceptorsWrapper(
      onRequest: (options, handler) {
        if (secrets.API_DOMAIN.isNotEmpty && secrets.API_DOMAIN_IP.isNotEmpty) {
          if (options.uri.host == secrets.API_DOMAIN.trim()) {
            options.headers['Host'] = secrets.API_DOMAIN.trim();
            options.path = options.uri.replace(host: secrets.API_DOMAIN_IP.trim()).toString();
          }
        }
        return handler.next(options);
      },
    );

    dio.interceptors.add(interceptor);
    _clashDio.interceptors.add(interceptor);
  }

  Future<Response<T>> _getWithRedirect<T>(
    String url, {
    required Options options,
  }) async {
    final opts = options.copyWith(
      followRedirects: false,
      validateStatus: (status) => status != null && status < 400,
    );

    var response = await _clashDio.get<T>(url, options: opts);
    int redirectCount = 0;
    while ([
          HttpStatus.movedTemporarily,
          HttpStatus.movedPermanently,
          HttpStatus.seeOther,
          HttpStatus.temporaryRedirect,
          HttpStatus.permanentRedirect,
        ].contains(response.statusCode) &&
        redirectCount < 5) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || location.isEmpty) break;
      final redirectUrl = Uri.parse(url).resolve(location).toString();
      response = await _clashDio.get<T>(redirectUrl, options: opts);
      redirectCount++;
    }

    if (response.statusCode != null && response.statusCode! >= 400) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
      );
    }
    return response;
  }

  Future<Response<Uint8List>> getFileResponseForUrl(String url) async {
    try {
      return await _getWithRedirect<Uint8List>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
    } catch (e) {
      commonPrint.log('getFileResponseForUrl error ${e.toString()}');
      if (e is DioException) {
        if (e.type == DioExceptionType.unknown) {
          throw appLocalizations.unknownNetworkError;
        } else if (e.type == DioExceptionType.badResponse) {
          throw appLocalizations.networkException;
        }
        rethrow;
      }
      throw appLocalizations.unknownNetworkError;
    }
  }

  Future<Response<String>> getTextResponseForUrl(String url) async {
    return _getWithRedirect<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
  }

  Future<MemoryImage?> getImage(String url) async {
    if (url.isEmpty) return null;
    final response = await dio.get<Uint8List>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data;
    if (data == null) return null;
    return MemoryImage(data);
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final response = await dio.get(
        'https://${secrets.API_DOMAIN.trim()}/api/v1/version/get',
        options: Options(responseType: ResponseType.json),
      );
      if (response.statusCode != 200) return null;
      final data = response.data as Map<String, dynamic>?;
      if (data == null || (data['ret'] as int?) != 200) return null;

      final versionData = data['data'];
      final String? remoteVersion = versionData is Map<String, dynamic>
          ? versionData['version'] as String?
          : versionData as String?;

      if (remoteVersion == null) return null;

      final currentBuildNumber =
          int.tryParse(globalState.packageInfo.buildNumber) ?? 0;
      final remoteBuildNumber =
          int.tryParse(remoteVersion.split('+').last) ?? 0;

      final hasUpdate = remoteBuildNumber > currentBuildNumber;

      if (!hasUpdate) return null;

      return <String, dynamic>{
        'tag_name': 'v${globalState.packageInfo.version}+$remoteVersion',
        'body': '',
      };
    } catch (e) {
      commonPrint.log('checkForUpdate failed', logLevel: LogLevel.warning);
      return null;
    }
  }

  final Map<String, IpInfo Function(Map<String, dynamic>)> _ipInfoSources = {
    'https://ipwho.is': IpInfo.fromIpWhoIsJson,
    'https://api.myip.com': IpInfo.fromMyIpJson,
    'https://ipapi.co/json': IpInfo.fromIpApiCoJson,
    'https://ident.me/json': IpInfo.fromIdentMeJson,
    'http://ip-api.com/json': IpInfo.fromIpAPIJson,
    'https://api.ip.sb/geoip': IpInfo.fromIpSbJson,
    'https://ipinfo.io/json': IpInfo.fromIpInfoIoJson,
  };

  Future<Result<IpInfo?>> checkIp({CancelToken? cancelToken}) async {
    var failureCount = 0;
    final token = cancelToken ?? CancelToken();
    final futures = _ipInfoSources.entries.map((source) async {
      final Completer<Result<IpInfo?>> completer = Completer();
      handleFailRes() {
        if (!completer.isCompleted && failureCount == _ipInfoSources.length) {
          completer.complete(Result.success(null));
        }
      }

      final future = dio
          .get<Map<String, dynamic>>(
            source.key,
            cancelToken: token,
            options: Options(responseType: ResponseType.json),
          )
          .timeout(const Duration(seconds: 10));
      future
          .then((res) {
            if (res.statusCode == HttpStatus.ok && res.data != null) {
              completer.complete(Result.success(source.value(res.data!)));
              return;
            }
            failureCount++;
            handleFailRes();
          })
          .catchError((e) {
            failureCount++;
            if (e is DioException && e.type == DioExceptionType.cancel) {
              completer.complete(Result.error('cancelled'));
            }
            handleFailRes();
          });
      return completer.future;
    });
    final res = await Future.any(futures);
    token.cancel();
    return res;
  }

  Future<bool> pingHelper() async {
    try {
      final response = await dio
          .get(
            'http://$localhost:$helperPort/ping',
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      return (response.data as String) == globalState.coreSHA256;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startCoreByHelper(String arg) async {
    try {
      final response = await dio
          .post(
            'http://$localhost:$helperPort/start',
            data: json.encode({'path': appPath.corePath, 'arg': arg}),
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final data = response.data as String;
      return data.isEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> stopCoreByHelper() async {
    try {
      final response = await dio
          .post(
            'http://$localhost:$helperPort/stop',
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final data = response.data as String;
      return data.isEmpty;
    } catch (_) {
      return false;
    }
  }
}

final request = Request();
