import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/chat_tool.dart';
import 'package:maichat/models/message_image.dart';
import 'package:maichat/widgets/chat_tool_results.dart';

void main() {
  testWidgets('shows compact call, result and expandable details', (
    tester,
  ) async {
    const call = ToolCall(
      id: 'call-1',
      name: 'roll_dice',
      arguments: {'formula': '2d6+3'},
    );
    final run = ChatToolRun(
      id: 'run-1',
      status: 'completed',
      history: [
        AgentMessage(role: AgentRole.assistant, toolCalls: const [call]),
        AgentMessage.toolResult(
          call,
          '{"total":11,"rolls":[4,4],"modifier":3}',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        home: Scaffold(
          body: Center(child: ChatToolResults(run: run)),
        ),
      ),
    );

    expect(find.text('Tool calls completed'), findsOneWidget);
    expect(find.text('Roll Dice'), findsOneWidget);
    expect(find.text('11'), findsOneWidget);

    await tester.tap(find.text('Roll Dice'));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(find.textContaining('"formula"'), findsOneWidget);
    expect(find.textContaining('"total"'), findsOneWidget);
  });

  testWidgets('shows actual tracker effects as labelled values', (
    tester,
  ) async {
    final run = ChatToolRun(
      id: 'run-2',
      status: 'completed',
      history: [AgentMessage(role: AgentRole.assistant)],
      effects: [
        const ChatToolEffect(
          key: 'tracker:health',
          before: {'value': 80},
          after: {'label': 'Health', 'value': 72, 'unit': '%'},
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        home: Scaffold(
          body: Center(child: ChatToolResults(run: run)),
        ),
      ),
    );

    expect(find.text('Health  72%'), findsOneWidget);
    expect(find.text('No tool calls were recorded.'), findsNothing);
  });

  testWidgets('stale runs are marked historical without hiding the data', (
    tester,
  ) async {
    final run = ChatToolRun(
      id: 'run-3',
      status: 'completed',
      effects: [
        const ChatToolEffect(
          key: 'tracker:energy',
          before: {'value': 10},
          after: {'label': 'Energy', 'value': 8, 'unit': '%'},
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        home: Scaffold(
          body: Center(
            child: ChatToolResults(run: run, stale: true, showTrackers: true),
          ),
        ),
      ),
    );

    final tooltip = find.byType(Tooltip).first;
    expect(find.text('Stale'), findsOneWidget);
    expect(tooltip, findsOneWidget);
    expect(
      ((tester.widget(tooltip) as Tooltip).message as String).contains(
        'Regenerate this reply',
      ),
      isTrue,
    );
  });

  testWidgets('runs with no recorded data render nothing', (tester) async {
    const run = ChatToolRun(id: 'run-4', status: 'completed');
    Widget? rendered;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              rendered = ChatToolResults(run: run);
              return rendered!;
            },
          ),
        ),
      ),
    );

    // No status header or placeholder is rendered when there is no data.
    expect(find.text('Tool calls completed'), findsNothing);
    expect(find.text('No tool calls were recorded.'), findsNothing);
    expect(tester.getSize(find.byType(Scaffold)).height, greaterThan(0));
  });

  testWidgets('notes generated images without decoding their refs', (
    tester,
  ) async {
    final run = ChatToolRun(
      id: 'run-5',
      status: 'completed',
      images: [const MessageImage(ref: 'local:do-not-decode.png')],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        home: Scaffold(
          body: Center(child: ChatToolResults(run: run)),
        ),
      ),
    );

    expect(
      find.text('1 generated picture attached to this reply'),
      findsOneWidget,
    );
    expect(find.text('local:do-not-decode.png'), findsNothing);
  });
}
