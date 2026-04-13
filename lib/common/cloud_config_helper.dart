class CloudConfigHelper {
  static ({String params, bool tfoEnabled, bool needsUpdate}) parseTfoParams(
    String params,
    bool? savedTfoEnabled,
  ) {
    bool tfoEnabled = savedTfoEnabled ?? true;
    bool needsUpdate = false;

    if (RegExp(r'(^|&)tfo=false($|&)').hasMatch(params)) {
      tfoEnabled = false;
      needsUpdate = true;
    } else if (RegExp(r'(^|&)tfo=true($|&)').hasMatch(params)) {
      tfoEnabled = true;
      needsUpdate = true;
    } else if (savedTfoEnabled == null) {
      needsUpdate = true;
    }

    String newParams = params.replaceAll(
      RegExp(r'(^|&)tfo=(true|false)(?=&|$)'),
      '',
    );

    newParams = newParams.replaceAll(RegExp(r'&+'), '&');
    if (newParams.startsWith('&')) newParams = newParams.substring(1);
    if (newParams.endsWith('&')) {
      newParams = newParams.substring(0, newParams.length - 1);
    }

    return (
      params: newParams,
      tfoEnabled: tfoEnabled,
      needsUpdate: needsUpdate,
    );
  }

  static String buildUrlWithParams(
    String baseUrl,
    String savedParams,
    bool tfoEnabled,
  ) {
    String cleanParams = savedParams.replaceAll(RegExp(r'&+'), '&');
    if (cleanParams.startsWith('&')) cleanParams = cleanParams.substring(1);
    if (cleanParams.endsWith('&')) {
      cleanParams = cleanParams.substring(0, cleanParams.length - 1);
    }

    String query = '';
    if (cleanParams.isNotEmpty) query += '$cleanParams&';
    query += 'tfo=${tfoEnabled ? "true" : "false"}';

    String base = baseUrl;
    String ext = '';
    final extMatch = RegExp(r'\.([a-zA-Z0-9]+)$').firstMatch(base);
    if (extMatch != null) {
      ext = extMatch.group(0)!;
      base = base.substring(0, base.length - ext.length);
    }

    if (base.contains('?')) {
      if (!base.endsWith('?') && !base.endsWith('&')) {
        base += '&';
      }
    } else {
      base += '?';
    }

    var newUrl = base + query;
    newUrl = newUrl.replaceAll('?&', '?').replaceAll('&&', '&');
    newUrl += ext;
    return newUrl;
  }
}
