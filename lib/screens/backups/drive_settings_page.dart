import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../services/drive_client.dart';
import '../../state/app_state.dart';

/// Connecting a Google account.
///
/// One button when the app ships with a Google client of its own; the client id
/// and secret move into an Advanced fold for anyone who would rather use their
/// own project. The scope asked for is `drive.file`, which grants access only to
/// the files this app creates — never the rest of the Drive.
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

  /// [own] connects with whatever is typed into the Advanced fields; without it
  /// the app's own client is used.
  Future<void> _connect(AppState state, {bool own = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.connectDrive(
        clientId: own ? _id.text : '',
        clientSecret: own ? _secret.text : '',
      );
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connected to Google Drive.')),
      );
    } on DriveException catch (error) {
      _fail(error.message);
    } catch (error) {
      _fail('The sign-in did not finish ($error).');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final drive = state.backupPrefs.drive;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final bundled = state.driveHasBundledClient;

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
              bundled
                  ? 'Backups go into a "MaiChat Backups" folder in your Drive. '
                      'Signing in opens your browser and comes back to the app '
                      'on its own. MaiChat asks only for access to the files it '
                      'creates itself — it cannot see anything else in there.'
                  : 'This build ships without a Google client of its own, so it '
                      'needs one from your Google Cloud project: enable the '
                      'Drive API, create an OAuth client of type "Desktop app", '
                      'then paste its ID and secret below.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: 20),
          if (bundled)
            FilledButton.icon(
              onPressed: _busy ? null : () => _connect(state),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_outlined),
              label: Text(
                _busy
                    ? 'Waiting for Google…'
                    : drive.isConnected
                        ? 'Connect a different account'
                        : 'Connect Google Drive',
              ),
            ),
          const SizedBox(height: 8),
          _ClientFold(
            id: _id,
            secret: _secret,
            busy: _busy,
            // Where the app has no client of its own, the fields *are* the
            // sign-in rather than an advanced alternative to it.
            open: !bundled,
            onConnect: () => _connect(state, own: true),
          ),
          const SizedBox(height: 12),
          Text(
            'The grant is kept on this device only, beside your API keys.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
/// The client id and secret, for somebody who would rather use their own Google
/// project than the one the app ships with.
class _ClientFold extends StatelessWidget {
  const _ClientFold({
    required this.id,
    required this.secret,
    required this.busy,
    required this.open,
    required this.onConnect,
  });

  final TextEditingController id;
  final TextEditingController secret;
  final bool busy;
  final bool open;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: open,
      tilePadding: EdgeInsets.zero,
      title: Text(open ? 'Google client' : 'Use my own Google client'),
      childrenPadding: const EdgeInsets.only(bottom: 12),
      children: [
        TextField(
          controller: id,
          decoration: const InputDecoration(
            labelText: 'Client ID',
            hintText: '…apps.googleusercontent.com',
          ),
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: secret,
          decoration: const InputDecoration(labelText: 'Client secret'),
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: busy ? null : onConnect,
            icon: const Icon(Icons.link),
            label: const Text('Connect with this client'),
          ),
        ),
      ],
    );
  }
}
