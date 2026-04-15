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
    if (newParams.endsWith('&')) {
      newParams = newParams.substring(0, newParams.length - 1);
    }
    if (newParams.isNotEmpty && !newParams.startsWith('&')) {
      newParams = '&$newParams';
    }

    return (
      params: newParams,
      tfoEnabled: tfoEnabled,
      needsUpdate: needsUpdate,
    );
  }
}
