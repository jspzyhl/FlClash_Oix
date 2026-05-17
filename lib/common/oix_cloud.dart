import 'package:fl_clash/common/secrets.dart';

const oixCloudManagedProfileUrl = 'oixcloud://managed';

bool isOixCloudProfileUrl(String url) {
  final normalizedUrl = url.trim().toLowerCase();
  if (normalizedUrl == oixCloudManagedProfileUrl) return true;

  final parsed = Uri.tryParse(normalizedUrl);
  if (parsed?.scheme == 'oixcloud') return true;

  final host = parsed?.host.trim().toLowerCase() ?? '';
  final path = parsed?.path.trim().toLowerCase() ?? '';
  final cloudDomains = {
    ...Secrets.apiDomains,
    Secrets.primarySiteDomain.trim().toLowerCase(),
    Secrets.spareSiteDomain.trim().toLowerCase(),
  }..remove('');
  final isManagedPath =
      path.contains('/managed/flclash') || path.contains('/api/v1/managed/');
  if (isManagedPath && cloudDomains.contains(host)) return true;

  return Secrets.apiDomains.any(normalizedUrl.contains);
}

typedef ManagedProfileDeduplicator<T> = Future<void> Function(List<T> profiles);

typedef ManagedProfileRefresher<T> =
    Future<T> Function(
      T profile, {
      required bool showLoading,
      required bool applyIfCurrent,
    });

typedef ManagedProfileActivator<T> =
    Future<void> Function(T profile, {required bool applyIfRunning});

class OixCloudManagedProfileUpdateFlow<T> {
  final ManagedProfileDeduplicator<T> deduplicate;
  final ManagedProfileRefresher<T> refresh;
  final ManagedProfileActivator<T> activate;

  const OixCloudManagedProfileUpdateFlow({
    required this.deduplicate,
    required this.refresh,
    required this.activate,
  });

  Future<T> refreshExisting(
    List<T> existing, {
    required bool showLoading,
  }) async {
    if (existing.isEmpty) {
      throw StateError('No oixCloud profile to refresh');
    }

    await deduplicate(existing);
    final updatedProfile = await refresh(
      existing.first,
      showLoading: showLoading,
      applyIfCurrent: false,
    );
    await activate(updatedProfile, applyIfRunning: false);
    return updatedProfile;
  }
}
