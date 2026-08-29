import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 强调色（Claude 风格暖橙色）
const _accent = Color(0xFFD97757);

const _cjkFallbacks = [
  'PingFang SC',
  'Hiragino Sans GB',
  'Microsoft YaHei',
  'Noto Sans SC',
  'sans-serif',
];

class AppTheme {
  static ThemeData get light {
    final colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: _accent,
      onPrimary: Colors.white,
      secondary: const Color(0xFFF3EDE4),
      onSecondary: const Color(0xFF2D2B26),
      surface: const Color(0xFFFAF9F5),
      onSurface: const Color(0xFF2D2B26),
      surfaceContainer: const Color(0xFFFFFFFF),
      onSurfaceVariant: const Color(0xFF6E6659),
      outline: const Color(0xFFE2DDD5),
      outlineVariant: const Color(0x1A3D3929),
      error: const Color(0xFFC4342D),
      onError: Colors.white,
    );

    return _buildTheme(colorScheme);
  }

  static ThemeData get dark {
    final colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: _accent,
      onPrimary: const Color(0xFF1F1E1D),
      secondary: const Color(0xFF35342F),
      onSecondary: const Color(0xFFF5F4EF),
      surface: const Color(0xFF262624),
      onSurface: const Color(0xFFF5F4EF),
      surfaceContainer: const Color(0xFF30302E),
      onSurfaceVariant: const Color(0xFFA8A197),
      outline: const Color(0xFF45433E),
      outlineVariant: const Color(0x1FFFFFFF),
      error: const Color(0xFFE06B63),
      onError: const Color(0xFF1F1E1D),
    );

    return _buildTheme(colorScheme);
  }

  static ThemeData _buildTheme(ColorScheme colorScheme) {
    final isDark = colorScheme.brightness == Brightness.dark;
    final baseTextTheme =
        Typography.material2021(platform: TargetPlatform.macOS).black.apply(
          fontFamilyFallback: _cjkFallbacks,
          bodyColor: colorScheme.onSurface,
          displayColor: colorScheme.onSurface,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      dividerColor: colorScheme.outlineVariant,
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surfaceContainer,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            fontFamilyFallback: _cjkFallbacks,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            fontFamilyFallback: _cjkFallbacks,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
          side: BorderSide(color: colorScheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            fontFamilyFallback: _cjkFallbacks,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            fontFamilyFallback: _cjkFallbacks,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: colorScheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colorScheme.error),
        ),
        hintStyle: TextStyle(
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          fontSize: 13,
        ),
        helperStyle: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimary;
          }
          return colorScheme.onSurfaceVariant;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return colorScheme.secondary;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: colorScheme.secondary,
        linearMinHeight: 6,
      ),
      textTheme: baseTextTheme,
    );
  }
}

/// 语义颜色辅助扩展类
class AppColors {
  const AppColors({
    required this.accentSubtle,
    required this.accentBorder,
    required this.accentText,
    required this.success,
    required this.successSubtle,
    required this.dangerSubtle,
  });

  final Color accentSubtle;
  final Color accentBorder;
  final Color accentText;
  final Color success;
  final Color successSubtle;
  final Color dangerSubtle;

  static const _light = AppColors(
    accentSubtle: Color(0x0DD97757),
    accentBorder: Color(0x59D97757),
    accentText: Color(0xFFB8532F),
    success: Color(0xFF2F8132),
    successSubtle: Color(0x1A2F8132),
    dangerSubtle: Color(0x14C4342D),
  );

  static const _dark = AppColors(
    accentSubtle: Color(0x1FD97757),
    accentBorder: Color(0x66D97757),
    accentText: Color(0xFFE08A63),
    success: Color(0xFF6FBF73),
    successSubtle: Color(0x266FBF73),
    dangerSubtle: Color(0x26E06B63),
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light ? _light : _dark;
}
