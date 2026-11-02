
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SanadApp());
}

class SanadApp extends StatelessWidget {
  const SanadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'سند',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF092D55),
        ),
      ),
      home: const SanadHome(),
    );
  }
}

class SanadHome extends StatelessWidget {
  const SanadHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('سند'),
        centerTitle: true,
      ),
      body: const Center(
        child: Text(
          'مرحبًا بك في تطبيق سند',
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}
