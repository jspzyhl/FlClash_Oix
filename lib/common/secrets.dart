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
}
