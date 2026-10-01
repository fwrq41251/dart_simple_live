import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  test('脱敏 URL 用户信息和全部签名查询参数', () {
    var result = DiagnosticRedactor.redact(
      'url=https://user:pass@example.com/live.flv?token=abc&wsSecret=def, next',
    );

    expect(result, contains('https://%3Credacted%3E@example.com/live.flv'));
    expect(result, contains('token=<redacted>'));
    expect(result, contains('wsSecret=<redacted>'));
    expect(result, isNot(contains('abc')));
    expect(result, isNot(contains('pass')));
  });

  test('脱敏 cookie token 密码和授权头', () {
    var result = DiagnosticRedactor.redact('''
Cookie: bili_jct=secret-value
Authorization=Bearer-token
WebDAVPassword: hunter2
token=plain-token
''');

    expect(result, isNot(contains('secret-value')));
    expect(result, isNot(contains('Bearer-token')));
    expect(result, isNot(contains('hunter2')));
    expect(result, isNot(contains('plain-token')));
    expect(result.split('<redacted>').length - 1, 4);
  });

  test('脱敏包含空格的授权头完整值', () {
    var credential = ['access', 'value', 'with', 'spaces'].join('-');
    var result = DiagnosticRedactor.redact(
      'Authorization: Bearer $credential extra-part',
    );

    expect(result, 'Authorization: <redacted>');
    expect(result, isNot(contains(credential)));
    expect(result, isNot(contains('extra-part')));
  });

  test('脱敏包含空格的密码值但保留后续字段', () {
    var value = ['two', 'word', 'value'].join(' ');
    var result = DiagnosticRedactor.redact('password=$value, mode=webdav');

    expect(result, 'password=<redacted>, mode=webdav');
    expect(result, isNot(contains(value)));
  });
}
