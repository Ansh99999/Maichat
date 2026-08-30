import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../services/drive_client.dart';
import '../../state/app_state.dart';

/// Connecting a Google account, and the one honest explanation of why it asks
/// for a client id and secret.
///
/// There is no MaiChat server to hold an OAuth client, and a sideloaded app
/// cannot keep a secret anyway, so the app uses the user's own Google Cloud
/// project. The scope asked for is `drive.file`: it can only see the files it
/// creates itself, never the rest of the Drive.
class DriveSettingsPage extends StatefulWidget {
  const DriveSettingsPage({super.key});

  @override
  State<DriveSettingsPage> createState() => _DriveSettingsPageState();
}

class _DriveSettingsPageState extends State<DriveSettingsPage> {
  late final TextEditingController _id;
  late final TextEditingController _secret;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final drive = context.read<AppState>().backupPrefs.drive;
    _id = TextEditingController(text: drive.clientId);
    _secret = TextEditingController(text: drive.clientSecret);
  }

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _connect(AppState state) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.connectDrive(
        clientId: _id.text,
        clientSecret: _secret.text,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connected to Google Drive.')),
      );
    } on DriveException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'The sign-in did not finish ($error).';
      });
    }
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final drive = state.backupPrefs.drive;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottom),
        children: [
          if (drive.isConnected)
            Card(
              elevation: 0,
              color: scheme.secondaryContainer,
              child: ListTile(
                leading: Icon(Icons.cloud_done_outlined,
                    color: scheme.onSecondaryContainer),
                title: const Text('Connected'),
                subtitle: Text(
                  drive.email.isEmpty
                      ? 'Backups go to a "MaiChat Backups" folder'
                      : '${drive.email} · "MaiChat Backups"',
                ),
                trailing: TextButton(
                  onPressed: _busy ? null : state.disconnectDrive,
                  child: const Text('Disconnect'),
                ),
              ),
            )
          else
            Text(
              'MaiChat has no server of its own, so it uses your Google project '
              'to talk to your Drive. In the Google Cloud console: enable the '
              'Drive API, create an OAuth client of type "Desktop app", then '
              'paste its ID and secret here. The app asks only for access to '
              'the files it creates itself.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _id,
            decoration: const InputDecoration(
              labelText: 'Client ID',
              hintText: '…apps.googleusercontent.com',
            ),
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _secret,
            decoration: const InputDecoration(labelText: 'Client secret'),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : () => _connect(state),
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link),
            label: Text(
              _busy
                  ? 'Waiting for Google…'
                  : drive.isConnected
                      ? 'Connect again'
                      : 'Connect',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Signing in opens your browser and comes back to the app on its own. '
            'The grant is kept on this device only.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
