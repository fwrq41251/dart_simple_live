import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/desktop_window_service.dart';

void main() {
  test('窗口边界可无损序列化', () {
    const bounds = Rect.fromLTWH(123.5, -20, 1280, 720);

    expect(
      DesktopWindowService.decodeRect(
        DesktopWindowService.encodeRect(bounds),
      ),
      bounds,
    );
  });

  test('拒绝损坏或小于最小尺寸的窗口边界', () {
    expect(DesktopWindowService.decodeRect(const []), isNull);
    expect(
      DesktopWindowService.decodeRect(const [0, 0, 200, 720]),
      isNull,
    );
    expect(
      DesktopWindowService.decodeRect(const [0, 0, double.nan, 720]),
      isNull,
    );
  });

  test('小窗位置可无损序列化并拒绝非有限值', () {
    const position = Offset(-40, 88.5);

    expect(
      DesktopWindowService.decodeOffset(
        DesktopWindowService.encodeOffset(position),
      ),
      position,
    );
    expect(
      DesktopWindowService.decodeOffset(const [double.infinity, 0]),
      isNull,
    );
  });
}
