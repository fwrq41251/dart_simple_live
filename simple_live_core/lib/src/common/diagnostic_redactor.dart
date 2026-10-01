class DiagnosticRedactor {
  static const _redacted = '<redacted>';

  static String redact(String input) {
    var output = input.replaceAllMapped(
      RegExp(r'https?://[^\s]+', caseSensitive: false),
      (match) => _redactUrl(match.group(0)!),
    );
    output = output.replaceAllMapped(
      RegExp(
        r'((?:cookie|authorization)\s*[=:]\s*)[^\r\n]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}$_redacted',
    );
    output = output.replaceAllMapped(
      RegExp(
        r'((?:token|password|passwd|secret|signature|sign|webdav(?:user|password)?)\s*[=:]\s*)([^,&\r\n}\]]+)',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}$_redacted',
    );
    return output;
  }

  static String _redactUrl(String value) {
    var trailing = '';
    while (value.isNotEmpty && '.,;)]}'.contains(value[value.length - 1])) {
      trailing = value[value.length - 1] + trailing;
      value = value.substring(0, value.length - 1);
    }
    try {
      var uri = Uri.parse(value);
      var query = <String, String>{};
      for (var key in uri.queryParameters.keys) {
        query[key] = _redacted;
      }
      var sanitized = uri.replace(
        userInfo: uri.userInfo.isEmpty ? null : _redacted,
        queryParameters: query.isEmpty ? null : query,
      );
      return '$sanitized$trailing';
    } catch (_) {
      return value.replaceAll(RegExp(r'(?<=\?).*'), _redacted) + trailing;
    }
  }
}
