import 'package:flutter/material.dart';
import 'package:sensor_human/screens/home.dart';

void main() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint(details.toString());
  };
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VitalSync',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const VitalSyncPage(),
    );
  }
}