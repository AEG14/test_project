import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:paged_datatable/l10n/generated/l10n.dart';
import 'package:test_project/const/constant.dart';
import 'package:test_project/screens/maintenance_screen.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Master Maintenance Screen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: backgroundColor,
        useMaterial3: true,
      ),
      localizationsDelegates: const [
        PagedDataTableLocalization.delegate,
      ],
      supportedLocales: const [
        Locale('ja'),
        Locale('en', ''), // English
      ],
      home: const MaintenanceScreen(),
    );
  }
}
