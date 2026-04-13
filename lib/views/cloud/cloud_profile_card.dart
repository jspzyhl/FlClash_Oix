import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/services/cloud_api_service.dart';
import 'package:url_launcher/url_launcher.dart';

class CloudProfileCard extends ConsumerStatefulWidget {
  final CloudProfile profile;

  const CloudProfileCard({super.key, required this.profile});

  @override
  ConsumerState<CloudProfileCard> createState() => _CloudProfileCardState();
}

class _CloudProfileCardState extends ConsumerState<CloudProfileCard> {
  String _savedParams = '';
  bool _tfoEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadoixParams();
  }

  Future<void> _loadoixParams() async {
    final prefs = await SharedPreferences.getInstance();
    var value = prefs.getString('cloud_service_config_params') ?? '';
    final tfoObj = prefs.getBool('cloud_service_tfo');

    final result = CloudConfigHelper.parseTfoParams(value, tfoObj);
    var newParams = result.params;
    if (newParams.isNotEmpty) newParams = '&$newParams';

    if (result.needsUpdate) {
      _updateSync(newParams, tfoEnabled: result.tfoEnabled);
    } else {
      if (mounted) {
        setState(() {
          _savedParams = newParams;
          _tfoEnabled = result.tfoEnabled;
        });
      }
    }
  }

  Future<void> _updateSync(String newParams, {bool? tfoEnabled}) async {
    final prefs = await SharedPreferences.getInstance();
    final oldParams = prefs.getString('cloud_service_config_params') ?? '';
    final oldTfoEnabled = prefs.getBool('cloud_service_tfo') ?? true;
    final currentTfo = tfoEnabled ?? _tfoEnabled;

    final result = CloudConfigHelper.parseTfoParams(newParams, currentTfo);
    var text = result.params;
    if (text.isNotEmpty) text = '&$text';

    setState(() {
      _savedParams = text;
      _tfoEnabled = currentTfo;
    });

    await prefs.setString('cloud_service_config_params', text);
    await prefs.setBool('cloud_service_tfo', currentTfo);

    final paramWithTfo = text + (currentTfo ? '&tfo=true' : '&tfo=false');
    final oldParamWithTfo =
        oldParams + (oldTfoEnabled ? '&tfo=true' : '&tfo=false');

    final clashProfileList = ref
        .read(profilesProvider)
        .where((p) => p.isoixCloudProfile)
        .toList();
    if (clashProfileList.isNotEmpty) {
      final clashProfile = clashProfileList.first;
      await appController.safeRun(
        () async {
          final baseUrl = await CloudApiService().getManagedUrl();
          String fallbackUrl = clashProfile.url;
          final Profile newProfile;
          if (baseUrl != null) {
            final newUrl = baseUrl.appendUrlParams(paramWithTfo);
            commonPrint.log('[_updateSync] download url updated | clashIsStart:${appController.isStart}');
            newProfile = clashProfile.copyWith(url: newUrl);
          } else {
            if (oldParamWithTfo.isNotEmpty) {
              if (fallbackUrl.contains(oldParamWithTfo)) {
                fallbackUrl = fallbackUrl.replaceAll(oldParamWithTfo, '');
              } else {
                final asQuery = '?' + oldParamWithTfo.substring(1);
                if (fallbackUrl.contains(asQuery)) {
                  fallbackUrl = fallbackUrl.replaceAll(asQuery, '?');
                }
              }
              if (fallbackUrl.endsWith('?') || fallbackUrl.endsWith('&')) {
                fallbackUrl = fallbackUrl.substring(0, fallbackUrl.length - 1);
              }
            }
            final newUrl = fallbackUrl.appendUrlParams(paramWithTfo);
            commonPrint.log('[_updateSync] fallback url updated | clashIsStart:${appController.isStart}');
            newProfile = clashProfile.copyWith(url: newUrl);
          }
          appController.putProfile(newProfile);
          await appController.updateProfile(newProfile, showLoading: true);
        },
        title: AppLocalizations.current.update,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final clashProfile = ref
        .watch(profilesProvider)
        .where((p) => p.isoixCloudProfile)
        .firstOrNull;
    final isOverseas = _savedParams.contains(RegExp(r'(^|&)lv=1($|&)'));
    return CommonCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                InkWell(
                  onTap: () => launchUrl(
                    Uri.parse('https://${secrets.BASE_DOMAIN.trim()}/user'),
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
                    String text = _savedParams;
                    if (val) {
                      text = text.replaceAll(RegExp(r'&lv=[^&]*'), '');
                      text = text.replaceAll(RegExp(r'&type=[^&]*'), '');
                      text += '&lv=1';
                    } else {
                      text = text.replaceAll(RegExp(r'&lv=1($|&)?'), '');
                      if (profile.subscription == 'Pass Bronze') {
                        text += '&lv=2';
                      } else {
                        text += '&type=love';
                      }
                    }
                    _updateSync(text);
                  },
                ),
              ),
              const Divider(height: 16),
              ListItem.switchItem(
                padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
                title: Text(AppLocalizations.current.tcpFastOpen),
                subtitle: Text(
                  AppLocalizations.current.tcpFastOpenDesc,
                  style: const TextStyle(fontSize: 12),
                ),
                delegate: SwitchDelegate<bool>(
                  value: _tfoEnabled,
                  onChanged: (val) {
                    _updateSync(_savedParams, tfoEnabled: val);
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
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
