import 'dart:convert';

const String protectedExportKeyBase64 = 'WkhBTkdMT05H';

String encodeProtectedExportText(String rawValue) {
  final rawBase64 = base64Encode(utf8.encode(rawValue));
  return base64Encode(utf8.encode('$protectedExportKeyBase64$rawBase64'));
}

String decodeProtectedExportText(String value) {
  final trimmed = value.trim();
  final decoded = utf8.decode(base64Decode(trimmed));
  if (!decoded.startsWith(protectedExportKeyBase64)) {
    throw const FormatException('导入内容不是 Zmusic 加密格式。');
  }

  final rawBase64 = decoded.substring(protectedExportKeyBase64.length);
  return utf8.decode(base64Decode(rawBase64));
}
