import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'background_service.dart';
import 'data_collector.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fitness Tracker',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _scanStream;
  StreamSubscription<ConnectionStateUpdate>? _connectionStream;
  bool isScanning = false;
  bool isConnected = false;
  bool isRecording = false;
  String? connectedDeviceId;
  String deviceName = 'No device connected';
  String connectionStatus = 'Disconnected';
  DataCollector? dataCollector;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _loadSavedDevice();
  }

  void _checkPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    if (statuses[Permission.bluetooth] != PermissionStatus.granted ||
        statuses[Permission.bluetoothScan] != PermissionStatus.granted ||
        statuses[Permission.bluetoothConnect] != PermissionStatus.granted ||
        statuses[Permission.location] != PermissionStatus.granted) {
      // Handle the case where permissions are not granted
      print("Necessary permissions are not granted");
      // You might want to show a dialog to the user explaining why these permissions are necessary
    }
  }

  void _loadSavedDevice() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      connectedDeviceId = prefs.getString('connectedDeviceId');
      if (connectedDeviceId != null) {
        _connectToDevice(connectedDeviceId!);
      }
    });
  }

  void _startScan() async {
    bool permissionsGranted = await _checkAndRequestPermissions();
    if (!permissionsGranted) {
      print("Cannot start scan. Permissions not granted.");
      // Show a dialog to inform the user about the importance of permissions
      return;
    }

    setState(() {
      isScanning = true;
    });

    _scanStream = _ble.scanForDevices(
      withServices: [], // Add MiBand 5 service UUID if known
      scanMode: ScanMode.lowLatency,
    ).listen((device) {
      // Filter for Mi Band 5 devices
      if (device.name.contains('Mi Band 5')) {
        _connectToDevice(device.id);
      }
    }, onError: (Object error) {
      print('Scanning failed: $error');
      setState(() {
        isScanning = false;
      });
    });
  }

  Future<bool> _checkAndRequestPermissions() async {
    if (Platform.isAndroid) {
      if (await Permission.bluetooth.status.isDenied) {
        await Permission.bluetooth.request();
      }
      if (await Permission.bluetoothScan.status.isDenied) {
        await Permission.bluetoothScan.request();
      }
      if (await Permission.bluetoothConnect.status.isDenied) {
        await Permission.bluetoothConnect.request();
      }
      if (await Permission.bluetoothAdvertise.status.isDenied) {
        await Permission.bluetoothAdvertise.request();
      }
      if (await Permission.location.status.isDenied) {
        await Permission.location.request();
      }
    }

    if (await Permission.scheduleExactAlarm.status.isDenied) {
      await Permission.scheduleExactAlarm.request();
    }

    // For Android 13 and above, check if USE_EXACT_ALARM is available
    if (int.parse(await _getAndroidVersion()) >= 33) {
      const platform = MethodChannel('com.example.sensor_human/permissions');
      try {
        await platform.invokeMethod('requestExactAlarmPermission');
      } on PlatformException catch (e) {
        print("Failed to request USE_EXACT_ALARM permission: ${e.message}");
      }
    }

    // Check if all permissions are granted
    bool allGranted = true;
    var statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.location,
    ].request();

    statuses.forEach((permission, status) {
      if (status != PermissionStatus.granted) {
        allGranted = false;
      }
    });

    return allGranted;
  }

Future<String> _getAndroidVersion() async {
  if (Platform.isAndroid) {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    return androidInfo.version.release;
  }
  return '0';
}

  void _connectToDevice(String deviceId) async {
    setState(() {
      connectionStatus = 'Connecting...';
    });
    _connectionStream = _ble.connectToDevice(id: deviceId).listen((update) {
      setState(() {
        connectionStatus = update.connectionState.toString();
        if (update.connectionState == DeviceConnectionState.connected) {
          isConnected = true;
          connectedDeviceId = deviceId;
          deviceName = 'Mi Band 5';
          _saveBleDevice(deviceId);
        } else {
          isConnected = false;
        }
      });
    }, onError: (Object error) {
      print('Connection failed: $error');
      setState(() {
        isConnected = false;
        connectionStatus = 'Connection failed';
      });
    });
  }

  void _saveBleDevice(String deviceId) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('connectedDeviceId', deviceId);
  }

  void _disconnectDevice() {
    _connectionStream?.cancel();
    setState(() {
      isConnected = false;
      connectedDeviceId = null;
      deviceName = 'No device connected';
      connectionStatus = 'Disconnected';
    });
    _removeSavedDevice();
  }

  void _removeSavedDevice() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('connectedDeviceId');
  }

  void _toggleRecording() async {
    if (!isRecording) {
      final service = FlutterBackgroundService();
      bool isRunning = await service.isRunning();
      if (!isRunning) {
        service.startService();
      }

      setState(() {
        isRecording = true;
      });

      // Initialize DataCollector
      dataCollector = DataCollector(ble: _ble, deviceId: connectedDeviceId!);
      dataCollector!.startCollecting();
    } else {
      final service = FlutterBackgroundService();
      service.invoke("stopService");

      setState(() {
        isRecording = false;
      });

      // Stop data collection and save CSV
      if (dataCollector != null) {
        await dataCollector!.stopCollecting();
        String csvPath = await dataCollector!.saveDataToCSV();
        print('CSV saved at: $csvPath');
        // You can show this path to the user or use it to access the file later
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fitness Tracker')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text('Device: $deviceName'),
            Text('Status: $connectionStatus'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: isConnected ? _disconnectDevice : _startScan,
              child: Text(isConnected ? 'Disconnect' : 'Scan and Connect'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: isConnected ? _toggleRecording : null,
              child: Text(isRecording ? 'Stop Recording' : 'Start Recording'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scanStream?.cancel();
    _connectionStream?.cancel();
    super.dispose();
  }
}