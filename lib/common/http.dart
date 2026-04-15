import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';

class FlClashHttpOverrides extends HttpOverrides {
  static String handleFindProxy(Uri url) {
    if ([localhost].contains(url.host)) {
      return 'DIRECT';
    }
    final port = appController.config.patchClashConfig.mixedPort;
    final isStart = appController.isStart;
    final displayUrl = url.toString().contains(secrets.API_DOMAIN.trim())
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
