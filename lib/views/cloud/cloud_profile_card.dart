import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class CloudProfileCard extends StatelessWidget {
  final CloudProfile profile;

  const CloudProfileCard({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    return CommonCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                InkWell(
                  onTap: () => launchUrl(Uri.parse('https://${secrets.BASE_DOMAIN.trim()}/user')),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: context.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.account_circle, color: context.colorScheme.onPrimaryContainer, size: 32),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(profile.subscription, style: context.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                      Text(AppLocalizations.current.expireDate(profile.expireTime.toString()), style: context.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildInfo(context, Icons.today, AppLocalizations.current.todayUsed, profile.todayUsed),
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
            _buildInfo(context, Icons.account_balance_wallet, AppLocalizations.current.balance, profile.balance),
            const SizedBox(height: 12),
            _buildInfo(context, Icons.monetization_on, AppLocalizations.current.commission, profile.commission),
            const SizedBox(height: 12),
            _buildInfo(context, Icons.stars, AppLocalizations.current.points, profile.points),
          ],
        ),
      ),
    );
  }

  Widget _buildInfo(BuildContext context, IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 20, color: context.colorScheme.primary),
        const SizedBox(width: 12),
        Text(label, style: context.textTheme.bodyMedium),
        const Spacer(),
        Text(value, style: context.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
