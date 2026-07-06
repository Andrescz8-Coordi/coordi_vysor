import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScrcpyGuiApp());
}

class ScrcpyGuiApp extends StatefulWidget {
  const ScrcpyGuiApp({super.key});

  @override
  State<ScrcpyGuiApp> createState() => _ScrcpyGuiAppState();
}

class _ScrcpyGuiAppState extends State<ScrcpyGuiApp> {
  late final AppController controller;

  @override
  void initState() {
    super.initState();
    controller = AppController();
    controller.init();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'Coordi Tools',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFF05A28),
              brightness: Brightness.light,
            ).copyWith(
              primary: const Color(0xFFF05A28),
              surface: const Color(0xFFFFFFFF),
              onSurface: const Color(0xFF263238),
              surfaceContainerLow: const Color(0xFFF1F5F9),
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFF1F5F9),
              foregroundColor: Color(0xFF263238),
            ),
            scaffoldBackgroundColor: const Color(0xFFFFFFFF),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFF05A28),
              brightness: Brightness.dark,
            ).copyWith(
              primary: const Color(0xFFF05A28),
              surface: const Color(0xFF263238),
              onSurface: const Color(0xFFFFFFFF),
              onSurfaceVariant: const Color(0xFF94A3B8),
              surfaceContainerLow: const Color(0xFF37474F),
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF37474F),
              foregroundColor: Color(0xFFFFFFFF),
            ),
            scaffoldBackgroundColor: const Color(0xFF263238),
          ),
          themeMode: controller.themeMode,
          home: HomeScreen(controller: controller),
        );
      },
    );
  }
}
