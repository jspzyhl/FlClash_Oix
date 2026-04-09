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

  @override
  void initState() {
    super.initState();
    _loadoixParams();
  }

  Future<void> _loadoixParams() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('cloud_service_config_params') ?? '';
    if (mounted) {
      setState(() {
        _savedParams = value;
      });
    }
  }

  Future<void> _updateSync(String newParams) async {
    final prefs = await SharedPreferences.getInstance();
    final oldParams = prefs.getString('cloud_service_config_params') ?? '';
    var text = newParams;
    text = text.replaceAll(RegExp(r'&+'), '&');
    if (text == '&') text = '';
    if (text.isNotEmpty && !text.startsWith('&')) {
      text = '&$text';
    }

    setState(() {
      _savedParams = text;
    });
    await prefs.setString('cloud_service_config_params', text);

    final clashProfileList = ref
        .read(profilesProvider)
        .where((p) => p.isoixCloudProfile)
        .toList();
    if (clashProfileList.isNotEmpty) {
      final clashProfile = clashProfileList.first;
      final baseUrl = await CloudApiService().getManagedUrl();
      String fallbackUrl = clashProfile.url;
      if (baseUrl != null) {
        String base = baseUrl;
        String ext = '';
        final extMatch = RegExp(r'\.([a-zA-Z0-9]+)$').firstMatch(base);
        if (extMatch != null) {
          ext = extMatch.group(0)!;
          base = base.substring(0, base.length - ext.length);
        }
        if (base.contains('?')) {
          if (!base.endsWith('?')) base += '&';
        } else {
          base += '?';
        }
        var newUrl = base + text;
        newUrl = newUrl.replaceAll('?&', '?').replaceAll('&&', '&');
        if (newUrl.endsWith('&')) {
          newUrl = newUrl.substring(0, newUrl.length - 1);
        }
        if (newUrl.endsWith('?')) {
          newUrl = newUrl.substring(0, newUrl.length - 1);
        }
        newUrl += ext;
        final newProfile = clashProfile.copyWith(url: newUrl);
        appController.putProfile(newProfile);
        await appController.safeRun(() async {
          await appController.updateProfile(newProfile, showLoading: true);
        });
      } else {
        if (oldParams.isNotEmpty && fallbackUrl.contains(oldParams)) {
          fallbackUrl = fallbackUrl.replaceAll(oldParams, '');
        }

        String base = fallbackUrl;
        String ext = '';
        final extMatch = RegExp(r'\.([a-zA-Z0-9]+)$').firstMatch(base);
        if (extMatch != null) {
          ext = extMatch.group(0)!;
          base = base.substring(0, base.length - ext.length);
        }
        if (base.contains('?')) {
          if (!base.endsWith('?')) base += '&';
        } else {
          base += '?';
        }
        var newUrl = base + text;
        newUrl = newUrl.replaceAll('?&', '?').replaceAll('&&', '&');
        if (newUrl.endsWith('&')) {
          newUrl = newUrl.substring(0, newUrl.length - 1);
        }
        if (newUrl.endsWith('?')) {
          newUrl = newUrl.substring(0, newUrl.length - 1);
        }
        newUrl += ext;

        final newProfile = clashProfile.copyWith(url: newUrl);
        appController.putProfile(newProfile);
        await appController.safeRun(() async {
          await appController.updateProfile(newProfile, showLoading: true);
        });
      }
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
                title: const Text('海外网络环境'),
                subtitle: const Text(
                  '如果您当前位于中国大陆以外地区，请开启此选项',
                  style: TextStyle(fontSize: 12),
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
