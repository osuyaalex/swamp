import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Custom palette for "SWAMP_"
  static const primary = Color(0xFF00FF88); // Neon Emerald
  static const accent = Color(0xFF7000FF);  // Cyber Grape
  static const background = Color(0xFF0A0C10); // Deep Space
  static const surface = Color(0xFF161B22);    // Dark Surface
  static const card = Color(0xFF1C2128);       // Card Surface
  static const textPrimary = Color(0xFFF0F6FC);
  static const textSecondary = Color(0xFF8B949E);

  static ThemeData dark() {
    final scheme = ColorScheme.dark(
      primary: primary,
      onPrimary: Colors.black,
      secondary: accent,
      onSecondary: Colors.white,
      surface: surface,
      onSurface: textPrimary,
      error: const Color(0xFFFF453A),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: 'Inter', // Note: User might not have this, falls back to system
      
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w900,
          color: textPrimary,
          letterSpacing: -0.5,
        ),
      ),

      textTheme: TextTheme(
        displayLarge: const TextStyle(fontWeight: FontWeight.w900, color: textPrimary, letterSpacing: -1),
        displayMedium: const TextStyle(fontWeight: FontWeight.w800, color: textPrimary, letterSpacing: -0.5),
        titleLarge: const TextStyle(fontWeight: FontWeight.w700, color: textPrimary),
        titleMedium: const TextStyle(fontWeight: FontWeight.w600, color: textPrimary),
        bodyLarge: const TextStyle(color: textPrimary, fontSize: 16),
        bodyMedium: const TextStyle(color: textSecondary, fontSize: 14),
        labelLarge: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.2),
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        color: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.05), width: 1),
        ),
        margin: EdgeInsets.zero,
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 8,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
      ),
      
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: primary.withValues(alpha: 0.2),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(color: primary, fontWeight: FontWeight.bold);
          }
          return const TextStyle(color: textSecondary);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: primary);
          }
          return const IconThemeData(color: textSecondary);
        }),
      ),
    );
  }

  // Keep light for compatibility if needed, but make it better
  static ThemeData light() => dark(); // For now, let's just use dark for both to "go wild"
}
