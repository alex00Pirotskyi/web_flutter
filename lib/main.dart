import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_data.dart'; // We will create this file
import 'home_page.dart'; // We will create this file

void main() {
  runApp(
    // Wrap your app in a ChangeNotifierProvider.
    // This makes your 'AppData' available to all widgets.
    ChangeNotifierProvider(
      create: (context) => AppData(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JSON Counter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // We start on the HomePage
      home: const HomePage(),
    );
  }
}
