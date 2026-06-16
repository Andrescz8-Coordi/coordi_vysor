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
    return MaterialApp(
      title: 'Coordi Vysor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF003C82), // primary
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFF003C82), // primary
          secondary: const Color(0xFFFF5722), // secondary
        ),
      ),
      home: HomeScreen(controller: controller),
    );
  }
}
