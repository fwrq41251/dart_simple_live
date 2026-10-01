import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/widgets/desktop_player_shortcuts.dart';

void main() {
  testWidgets('桌面播放器快捷键映射到对应动作', (tester) async {
    var actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopPlayerShortcuts(
          onTogglePlay: () => actions.add('play'),
          onToggleFullScreen: () => actions.add('fullscreen'),
          onToggleMute: () {
            actions.add('mute');
            return 0;
          },
          onVolumeUp: () {
            actions.add('volumeUp');
            return 55;
          },
          onVolumeDown: () {
            actions.add('volumeDown');
            return 45;
          },
          onSeekBackward: () => actions.add('backward'),
          onSeekForward: () => actions.add('forward'),
          onEscape: () => actions.add('escape'),
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    for (var key in const [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.escape,
    ]) {
      await tester.sendKeyEvent(key);
    }

    expect(actions, [
      'play',
      'fullscreen',
      'mute',
      'volumeUp',
      'volumeDown',
      'backward',
      'forward',
      'escape',
    ]);
  });

  testWidgets('输入框获得焦点时不触发播放器快捷键', (tester) async {
    var playCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopPlayerShortcuts(
          onTogglePlay: () => playCount++,
          onToggleFullScreen: () {},
          onToggleMute: () => 0,
          onVolumeUp: () => 55,
          onVolumeDown: () => 45,
          onEscape: () {},
          child: const Scaffold(body: TextField()),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);

    expect(playCount, 0);
  });

  testWidgets('直播未提供 seek 动作时左右键保持未处理', (tester) async {
    var actionCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopPlayerShortcuts(
          onTogglePlay: () => actionCount++,
          onToggleFullScreen: () => actionCount++,
          onToggleMute: () {
            actionCount++;
            return 0;
          },
          onVolumeUp: () {
            actionCount++;
            return 55;
          },
          onVolumeDown: () {
            actionCount++;
            return 45;
          },
          onEscape: () => actionCount++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);

    expect(actionCount, 0);
  });

  testWidgets('音量和静音快捷键显示短暂反馈', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopPlayerShortcuts(
          onTogglePlay: () {},
          onToggleFullScreen: () {},
          onToggleMute: () => 0,
          onVolumeUp: () => 65,
          onVolumeDown: () => 55,
          onEscape: () {},
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(find.text('音量 65%'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(find.text('已静音'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('已静音'), findsNothing);
  });
}
