import 'dart:io';

import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';

IOHttpClientAdapter createFlClashHttpClientAdapter({
  required String Function(Uri uri) findProxy,
  bool Function()? allowBadCertificate,
  String? Function()? userAgent,
}) {
  return IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      bool allowBadCertificateCallback() =>
          allowBadCertificate?.call() ?? false;
      client.badCertificateCallback = (_, _, _) =>
          allowBadCertificateCallback();
      client.findProxy = (uri) {
        final ua = userAgent?.call();
        if (ua != null && ua.isNotEmpty) {
          client.userAgent = ua;
        }
        return findProxy(uri);
      };
      client.connectionFactory = (uri, proxyHost, proxyPort) {
        return FlClashHostOverrides.connect(
          uri,
          proxyHost,
          proxyPort,
          onBadCertificate: (_) => allowBadCertificateCallback(),
        );
      };
      return client;
    },
  );
}

class FlClashHostOverrides {
  const FlClashHostOverrides._();

  static String? resolve(String host) {
    return Secrets.resolveHostOverride(host);
  }

  static Future<ConnectionTask<Socket>> connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort, {
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
  }) async {
    final hasProxy = proxyHost != null;
    final targetHost = hasProxy ? proxyHost : resolve(uri.host) ?? uri.host;
    final targetPort = hasProxy ? proxyPort! : uri.port;
    if (!hasProxy && uri.isScheme('https')) {
      final socketTask = await Socket.startConnect(targetHost, targetPort);
      final secureSocket = socketTask.socket.then(
        (socket) => SecureSocket.secure(
          socket,
          host: uri.host,
          context: context,
          onBadCertificate: onBadCertificate,
        ),
      );
      return ConnectionTask.fromSocket<Socket>(secureSocket, socketTask.cancel);
    }
    return Socket.startConnect(targetHost, targetPort);
  }
}

class FlClashHttpOverrides extends HttpOverrides {
  static String handleFindProxy(Uri url) {
    final isApiDomain = Secrets.isApiDomain(url.host);
    if (url.host == localhost || isApiDomain) {
      return 'DIRECT';
    }
    final port = appController.config.patchClashConfig.mixedPort;
    final isStart = appController.isStart;
    final displayUrl = isApiDomain
        ? Uri(scheme: url.scheme, host: url.host, path: url.path)
        : url;
    commonPrint.log('find $displayUrl proxy:$isStart');
    if (!isStart) return 'DIRECT';
    return 'PROXY localhost:$port';
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (_, _, _) => kDebugMode;
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      return FlClashHostOverrides.connect(
        uri,
        proxyHost,
        proxyPort,
        context: context,
        onBadCertificate: (_) => kDebugMode,
      );
    };
    client.findProxy = handleFindProxy;
    return client;
  }
}
