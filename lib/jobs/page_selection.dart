/// 与后端 `PageSelection::parse` 同一套语法：`3`、`1-10`、`1..10`、`5-`，
/// 以逗号（中英文）、分号或空白分隔。返回错误提示，合法时返回空串。
/// 移植自 webapp/app.js 的 `validatePageSelection`。
String validatePageSelection(String rawValue, String label) {
  final value = rawValue.trim();
  if (value.isEmpty) {
    return '';
  }
  final parts = value
      .split(RegExp(r'[,，;；\s]+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) {
    return '$label需要页码，例如 1-10,11,13 或 3。';
  }
  final pattern = RegExp(r'^(\d+)(?:(?:-|\.\.)(\d*))?$');
  for (final part in parts) {
    final matched = pattern.firstMatch(part);
    if (matched == null) {
      return '$label格式不正确: $part（例如 1-10,11,13）。';
    }
    final start = int.parse(matched.group(1)!);
    if (start < 1) {
      return '$label必须是大于 0 的整数: $part。';
    }
    final endText = matched.group(2);
    if (endText != null && endText.isNotEmpty) {
      final end = int.parse(endText);
      if (end < 1) {
        return '$label必须是大于 0 的整数: $part。';
      }
      if (start > end) {
        return '$label起始页不能大于结束页: $part。';
      }
    }
  }
  return '';
}
