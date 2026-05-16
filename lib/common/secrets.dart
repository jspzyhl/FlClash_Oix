class Secrets {
  const Secrets._();

  static const String profileKey = String.fromEnvironment('PROFILE_KEY');

  static const String baseDomain = String.fromEnvironment('BASE_DOMAIN');
  static const String spareDomain = String.fromEnvironment('SPARE_DOMAIN');
  static const String apiDomain = String.fromEnvironment('API_DOMAIN');
  static const String spareApiDomain = String.fromEnvironment(
    'SPARE_API_DOMAIN',
  );

  static const String flClashAppSecret = String.fromEnvironment(
    'FLCLASH_APP_SECRET',
  );

  static const String hostOverrides = String.fromEnvironment('HOST_OVERRIDES');

  static final Map<String, String> hostOverrideMap = _parseHostOverrides(
    hostOverrides,
  );

  static String get primarySiteDomain => baseDomain.trim();

  static String get spareSiteDomain => spareDomain.trim();

  static String get primaryApiDomain => apiDomain.trim();

  static String get fallbackApiDomain => spareApiDomain.trim();

  static String get preferredApiDomain {
    return primaryApiDomain.isNotEmpty ? primaryApiDomain : fallbackApiDomain;
  }

  static List<String> get apiDomains {
    final domains = <String>[];
    for (final domain in [primaryApiDomain, fallbackApiDomain]) {
      final normalized = domain.toLowerCase();
      if (normalized.isNotEmpty && !domains.contains(normalized)) {
        domains.add(normalized);
      }
    }
    return domains;
  }

  static bool isApiDomain(String host) {
    return apiDomains.contains(host.trim().toLowerCase());
  }

  static String? resolveHostOverride(String host) {
    return hostOverrideMap[host.trim().toLowerCase()];
  }

  static Map<String, String> _parseHostOverrides(String value) {
    final overrides = <String, String>{};
    for (final item in value.split(RegExp(r'[;,]'))) {
      final separator = item.indexOf('=');
      if (separator <= 0 || separator == item.length - 1) {
        continue;
      }
      final host = item.substring(0, separator).trim().toLowerCase();
      final address = item.substring(separator + 1).trim();
      if (host.isNotEmpty && address.isNotEmpty) {
        overrides[host] = address;
      }
    }
    return overrides;
  }
}
