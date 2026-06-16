import 'package:flutter/material.dart';

ThemeData buildAppTheme() {
  const background = Color(0xFF05080B);
  const surface = Color(0xFF101820);
  const surfaceHigh = Color(0xFF17232D);
  const textPrimary = Color(0xFFE7F0F0);
  const textMuted = Color(0xFF91A3AD);
  const accent = Color(0xFF43D17A);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    surface: surface,
    primary: accent,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: colorScheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      foregroundColor: textPrimary,
      centerTitle: false,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: background,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: textPrimary,
        side: const BorderSide(color: Color(0xFF29404D)),
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      labelStyle: const TextStyle(color: textMuted),
      hintStyle: const TextStyle(color: textMuted),
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        color: textPrimary,
        fontSize: 30,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
      ),
      titleLarge: TextStyle(
        color: textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      bodyLarge: TextStyle(color: textPrimary, height: 1.45),
      bodyMedium: TextStyle(color: textMuted, height: 1.45),
      labelLarge: TextStyle(fontWeight: FontWeight.w700),
    ),
  );
}
