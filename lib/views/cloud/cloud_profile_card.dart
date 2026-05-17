import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

class CloudProfileCard extends ConsumerStatefulWidget {
  final CloudProfile profile;

  const CloudProfileCard({super.key, required this.profile});

  @override
  ConsumerState<CloudProfileCard> createState() => _CloudProfileCardState();
}

class _CloudProfileCardState extends ConsumerState<CloudProfileCard> {
  OixParams _params = const OixParams();

  @override
  void initState() {
    super.initState();
    _loadParams();
  }

  Future<void> _loadParams() async {
    final loaded = await OixParamsStorage.load();
    if (mounted) {
      setState(() => _params = loaded);
    }
  }

  Future<void> _commit(OixParams next) async {
    setState(() => _params = next);
    await OixParamsStorage.save(next);

    final clashProfileList = ref
        .read(profilesProvider)
        .where((p) => p.isoixCloudProfile)
        .toList();
    if (clashProfileList.isNotEmpty) {
      final updatedProfile = await appController.safeRun(
        () => appController.updateProfile(
          clashProfileList.first,
          showLoading: true,
          applyIfCurrent: false,
        ),
        title: AppLocalizations.current.update,
      );
      if (updatedProfile != null) {
        appController.applyProfileDebounce(silence: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final tier = SubscriptionTier.fromServer(profile.subscription);
    final clashProfile = ref
        .watch(profilesProvider)
        .where((p) => p.isoixCloudProfile)
        .firstOrNull;
    final isOverseas = _params.level == NetworkLevel.overseas;
    final isEmergency = _params.level == NetworkLevel.emergency;

    return CommonCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                InkWell(
                  onTap: () => launchUrl(
                    Uri.parse('https://${Secrets.primarySiteDomain}/user'),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: context.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.account_circle,
                      color: context.colorScheme.onPrimaryContainer,
                      size: 32,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.subscription,
                        style: context.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        AppLocalizations.current.expireDate(
                          profile.expireTime.toString(),
                        ),
                        style: context.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildInfo(
              context,
              Icons.today,
              AppLocalizations.current.todayUsed,
              profile.todayUsed,
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: profile.usageProgress),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(profile.totalUsed),
                Text(AppLocalizations.current.remaining(profile.remaining)),
              ],
            ),
            const Divider(height: 32),
            _buildInfo(
              context,
              Icons.account_balance_wallet,
              AppLocalizations.current.balance,
              profile.balance,
            ),
            const SizedBox(height: 12),
            _buildInfo(
              context,
              Icons.monetization_on,
              AppLocalizations.current.commission,
              profile.commission,
            ),
            const SizedBox(height: 12),
            _buildInfo(
              context,
              Icons.stars,
              AppLocalizations.current.points,
              profile.points,
            ),
            if (clashProfile != null) ...[
              const Divider(height: 16),
              ListItem.switchItem(
                padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
                title: Text(
                  AppLocalizations.current.overseasNetworkEnvironment,
                ),
                subtitle: Text(
                  AppLocalizations.current.overseasNetworkEnvironmentDesc,
                  style: const TextStyle(fontSize: 12),
                ),
                delegate: SwitchDelegate<bool>(
                  value: isOverseas,
                  onChanged: (val) {
                    final next = val
                        ? _params.copyWith(
                            level: NetworkLevel.overseas,
                            type: null,
                          )
                        : _restoreDefault(tier);
                    _commit(next);
                  },
                ),
              ),
              if (tier.canUseEmergency) ...[
                const Divider(height: 16),
                ListItem.switchItem(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 0,
                    vertical: 8,
                  ),
                  title: Text(AppLocalizations.current.emergencyMode),
                  subtitle: Text(
                    AppLocalizations.current.emergencyModeDesc,
                    style: const TextStyle(fontSize: 12),
                  ),
                  delegate: SwitchDelegate<bool>(
                    value: isEmergency,
                    onChanged: (val) {
                      final next = val
                          ? _params.copyWith(
                              level: NetworkLevel.emergency,
                              type: null,
                            )
                          : _restoreDefault(tier);
                      _commit(next);
                    },
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Restore the level/type to the tier's defaults, preserving switches and extras.
  OixParams _restoreDefault(SubscriptionTier tier) {
    final defaults = tier.defaultParams;
    return _params.copyWith(level: defaults.level, type: defaults.type);
  }

  Widget _buildInfo(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    return Row(
      children: [
        Icon(icon, size: 20, color: context.colorScheme.primary),
        const SizedBox(width: 12),
        Text(label, style: context.textTheme.bodyMedium),
        const Spacer(),
        Text(
          value,
          style: context.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
