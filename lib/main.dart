import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_data.dart';
import 'home_page.dart';

// 💡 MODIFIED: main is now async
void main() async {
  // 💡 Ensure Flutter is ready
  WidgetsFlutterBinding.ensureInitialized();

  // 💡 Create and load the data *before* running the app
  final appData = AppData();
  await appData.loadData(); // This waits for all data to load

  runApp(
    // 💡 MODIFIED: Use .value to provide the *existing* instance
    ChangeNotifierProvider.value(value: appData, child: const MyApp()),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Data Collector',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            // All platforms will use a fade transition
            TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          },
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F5F5),
          foregroundColor: Colors.black87,
          elevation: 0,
          scrolledUnderElevation: 1,
        ),
      ),
      home: const HomePage(),
    );
  }
}
