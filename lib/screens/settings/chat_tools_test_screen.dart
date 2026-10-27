import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_tool.dart';
import '../../state/app_state.dart';
import '../../widgets/chat_tool_results.dart';
import 'chat_tools_page.dart';

/// Full-screen manual tool runner: arguments in, one bounded run, and a
/// readable result or error. Back is blocked while the operation is running,
/// and Run cannot be started twice.
class ChatToolTestScreen extends StatefulWidget {
  const ChatToolTestScreen({
    super.key,
    required this.tool,
    required this.conversationId,
  });

  final ChatToolDefinition tool;
  final String? conversationId;

  @override
  State<ChatToolTestScreen> createState() => _ChatToolTestScreenState();
}

class _ChatToolTestScreenState extends State<ChatToolTestScreen> {
  final TextEditingController _arguments = TextEditingController();
  bool _running = false;
  Object? _result;
  Object? _error;

  @override
  void dispose() {
    _arguments.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    final raw = _arguments.text.trim().isEmpty ? '{}' : _arguments.text;
    Map<String, dynamic> arguments;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Arguments must be a JSON object.');
      }
      arguments = Map<String, dynamic>.from(decoded);
    } catch (error) {
      setState(() {
        _error = 'Invalid JSON arguments: ${friendlyError(error)}';
        _result = null;
      });
      return;
    }

    setState(() {
      _running = true;
      _result = null;
      _error = null;
    });
    try {
      final state = context.read<AppState>();
      final value = await state.testChatTool(
        widget.tool.name,
        arguments,
        conversationId: widget.conversationId,
      );
      if (!mounted) return;
      setState(() => _result = value);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = 'Test ${readableToolName(widget.tool.name)}';
    return PopScope(
      canPop: !_running,
      child: Scaffold(
        key: const Key('chat-tool-test-screen'),
        appBar: AppBar(
          title: Text(title),
          automaticallyImplyLeading: !_running,
        ),
        body: SafeArea(
          top: false,
          child: SingleChildScrollView(
            key: const Key('chat-tool-test-list'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.tool.description,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('chat-tool-test-arguments'),
                  controller: _arguments,
                  minLines: 5,
                  maxLines: 8,
                  enabled: !_running,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'Arguments JSON',
                    hintText: '{"formula":"2d6+3"}',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'This runs the operation only and does not start a character '
                  'reply.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('chat-tool-test-run'),
                  onPressed: _running ? null : _run,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run'),
                ),
                const SizedBox(height: 16),
                if (_running)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (_error != null)
                  _ResultBlock(
                    label: 'Error',
                    text: friendlyError(_error!),
                    isError: true,
                  )
                else if (_result != null)
                  _ResultBlock(label: 'Result', text: prettyJson(_result!))
                else
                  Text(
                    'Run the tool to see JSON or text it returns.',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultBlock extends StatelessWidget {
  const _ResultBlock({
    required this.label,
    required this.text,
    this.isError = false,
  });

  final String label;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: isError ? scheme.error : scheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isError
                ? scheme.errorContainer.withValues(alpha: .7)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            key: Key(
              isError ? 'chat-tool-test-error' : 'chat-tool-test-result',
            ),
            text,
          ),
        ),
      ],
    );
  }
}
