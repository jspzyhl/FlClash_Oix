import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';

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
    client.findProxy = handleFindProxy;
    return client;
  }
}
