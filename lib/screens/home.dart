import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:csv/csv.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:open_file/open_file.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:device_info_plus/device_info_plus.dart';

class VitalSyncPage extends StatefulWidget {
  const VitalSyncPage({super.key});

  @override
  State<VitalSyncPage> createState() => _VitalSyncPageState();
}

class _VitalSyncPageState extends State<VitalSyncPage> {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  StreamSubscription<ConnectionStateUpdate>? _connection;
  QualifiedCharacteristic? _heartRateCharacteristic;
  QualifiedCharacteristic? _batteryCharacteristic;
  QualifiedCharacteristic? _stepsCharacteristic;

  bool _isConnected = false;
  bool _isCollecting = false;
  String _deviceStatus = 'Disconnected';
  int _heartRate = 0;
  int _batteryLevel = 0;
  int _steps = 0;
  int _distance = 0; // in meters
  int _calories = 0;
  final List<int> _rrIntervals = [];

  List<String> _csvFiles = [];
  File? _currentCsvFile;
  Timer? _dataCollectionTimer;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _stopwatchTimer;

  int _lastHeartRateUpdate = 0;
  Timer? _heartRateTimer;

  @override
  void initState() {
    super.initState();
    _loadCsvFiles();
    _startHeartRateTimer();
  }

  @override
  void dispose() {
    _connection?.cancel();
    _dataCollectionTimer?.cancel();
    _stopwatchTimer?.cancel();
    _heartRateTimer?.cancel();
    super.dispose();
  }

  void _startHeartRateTimer() {
    _heartRateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (DateTime.now().millisecondsSinceEpoch - _lastHeartRateUpdate > 10000) {
        // If we haven't received an update in 10 seconds, set heart rate to 0
        setState(() {
          _heartRate = 0;
        });
      }
    });
  }

  Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      if (await _isAndroidOverSdk31()) {
        // For Android 12 (SDK 31) and above
        Map<Permission, PermissionStatus> statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.location,
        ].request();
        return statuses.values.every((status) => status.isGranted);
      } else {
        // For Android 11 and below
        Map<Permission, PermissionStatus> statuses = await [
          Permission.bluetooth,
          Permission.location,
        ].request();
        return statuses.values.every((status) => status.isGranted);
      }
    } else {
      // For iOS
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetooth,
        Permission.location,
      ].request();
      return statuses.values.every((status) => status.isGranted);
    }
  }

  Future<bool> _isAndroidOverSdk31() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return androidInfo.version.sdkInt > 30;
    }
    return false;
  }

  Future<void> _connect() async {
    bool permissionsGranted = await _requestPermissions();
    if (!permissionsGranted) {
      print('Not all permissions were granted');
      return;
    }

    await for (final device in _ble.scanForDevices(
      withServices: [],
      scanMode: ScanMode.lowLatency,
    )) {
      if (device.name == 'Mi Smart Band 5') {
        _ble.deinitialize();

        _connection = _ble.connectToDevice(
          id: device.id,
          connectionTimeout: const Duration(seconds: 10),
        ).listen((connectionState) {
          if (connectionState.connectionState == DeviceConnectionState.connected) {
            setState(() {
              _isConnected = true;
              _deviceStatus = 'Connected';
            });
            _discoverServices(device.id);
          } else {
            setState(() {
              _isConnected = false;
              _deviceStatus = 'Disconnected';
            });
          }
        }, onError: (Object error) {
          print('Connection error: $error');
        });

        break;
      }
    }
  }

  void _discoverServices(String deviceId) async {
    try {
      var services = await _ble.discoverServices(deviceId);
      for (var service in services) {
        for (var characteristic in service.characteristicIds) {
          if (characteristic.toString() == '00002a37-0000-1000-8000-00805f9b34fb') {
            _heartRateCharacteristic = QualifiedCharacteristic(
              serviceId: service.serviceId,
              characteristicId: characteristic,
              deviceId: deviceId,
            );
            _subscribeToHeartRateCharacteristic();
          } else if (characteristic.toString() == '00002a19-0000-1000-8000-00805f9b34fb') {
            _batteryCharacteristic = QualifiedCharacteristic(
              serviceId: service.serviceId,
              characteristicId: characteristic,
              deviceId: deviceId,
            );
            _subscribeToBatteryCharacteristic();
          } else if (characteristic.toString() == '00000007-0000-3512-2118-0009af100700') {
            _stepsCharacteristic = QualifiedCharacteristic(
              serviceId: service.serviceId,
              characteristicId: characteristic,
              deviceId: deviceId,
            );
            _subscribeToStepsCharacteristic();
          }
        }
      }
      print('Services discovered and subscriptions set up');

      // We're not attempting to read the heart rate characteristic anymore
      _readStepsCharacteristic();
      // Battery is already being read in _subscribeToBatteryCharacteristic()
    } catch (e) {
      print('Error discovering services: $e');
    }
  }

  void _subscribeToHeartRateCharacteristic() {
    if (_heartRateCharacteristic != null) {
      _ble.subscribeToCharacteristic(_heartRateCharacteristic!).listen(
            (data) {
          _parseHeartRateData(data);
          _lastHeartRateUpdate = DateTime.now().millisecondsSinceEpoch;
        },
        onError: (dynamic error) {
          print('Error subscribing to heart rate: $error');
          // Don't attempt to read the characteristic
        },
      );
    }
  }

  void _parseHeartRateData(List<int> data) {
    if (data.isNotEmpty) {
      int flags = data[0];
      bool isUint16 = flags & 0x01 == 1;
      int offset = 1;

      if (isUint16 && data.length >= 3) {
        setState(() {
          _heartRate = data[offset] + (data[offset + 1] << 8);
        });
      } else if (data.length >= 2) {
        setState(() {
          _heartRate = data[offset];
        });
      }
      print('Heart rate updated: $_heartRate bpm');
    }
  }

  void _subscribeToBatteryCharacteristic() {
    if (_batteryCharacteristic != null) {
      _ble.readCharacteristic(_batteryCharacteristic!).then((data) {
        if (data.isNotEmpty) {
          setState(() {
            _batteryLevel = data[0];
          });
          print('Battery level read: $_batteryLevel%');
        }
      }).catchError((error) {
        print('Error reading battery level: $error');
      });

      _ble.subscribeToCharacteristic(_batteryCharacteristic!).listen(
            (data) {
          if (data.isNotEmpty) {
            setState(() {
              _batteryLevel = data[0];
            });
            print('Battery level updated: $_batteryLevel%');
          }
        },
        onError: (dynamic error) {
          print('Error subscribing to battery level: $error');
        },
      );
    }
  }

  void _subscribeToStepsCharacteristic() {
    if (_stepsCharacteristic != null) {
      _ble.subscribeToCharacteristic(_stepsCharacteristic!).listen(
            (data) {
          _parseStepsData(data);
        },
        onError: (dynamic error) {
          print('Error subscribing to steps: $error');
          // Attempt to read the characteristic if subscription fails
          _readStepsCharacteristic();
        },
      );
    }
  }

  void _readStepsCharacteristic() {
    if (_stepsCharacteristic != null) {
      _ble.readCharacteristic(_stepsCharacteristic!).then(
            (data) {
          _parseStepsData(data);
        },
        onError: (error) {
          print('Error reading steps: $error');
        },
      );
    }
  }

  void _parseStepsData(List<int> data) {
    if (data.length >= 10) {
      setState(() {
        _steps = data[1] + (data[2] << 8);
        _distance = data[5] + (data[6] << 8);
        _calories = data[9];
      });
      print('Steps: $_steps, Distance: $_distance m, Calories: $_calories kcal');
    }
  }

  void _toggleDataCollection() {
    setState(() {
      _isCollecting = !_isCollecting;
    });

    if (_isCollecting) {
      _startDataCollection();
    } else {
      _stopDataCollection();
    }
  }

  void _startDataCollection() async {
    final directory = await getTemporaryDirectory();
    _currentCsvFile = File('${directory.path}/vital_sync_${DateTime.now().millisecondsSinceEpoch}.csv');

    // Write headers to the new file
    List<List<dynamic>> headers = [
      ['Timestamp', 'Heart Rate', 'RR Intervals', 'Battery Level', 'Steps', 'Distance', 'Calories']
    ];
    String csv = const ListToCsvConverter().convert(headers);
    await _currentCsvFile!.writeAsString('$csv\n');

    _dataCollectionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _saveDataToCsv();
    });

    _stopwatch.start();
    _stopwatchTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      setState(() {});
    });
  }

  void _stopDataCollection() {
    _dataCollectionTimer?.cancel();
    _stopwatch.stop();
    _stopwatchTimer?.cancel();
    _loadCsvFiles();
  }

  Future<void> _saveDataToCsv() async {
    if (_currentCsvFile == null) return;

    bool fileExists = await _currentCsvFile!.exists();

    List<List<dynamic>> rows = [];

    if (!fileExists) {
      // If file doesn't exist, add headers
      rows.add(['Timestamp', 'Heart Rate', 'RR Intervals', 'Battery Level', 'Steps', 'Distance', 'Calories']);
    }

    // Add data row
    rows.add([
      DateTime.now().toIso8601String(),
      _heartRate,
      _rrIntervals.isEmpty ? '' : _rrIntervals.join(';'),
      _batteryLevel,
      _steps,
      _distance,
      _calories
    ]);

    String csv = const ListToCsvConverter().convert(rows);

    if (fileExists) {
      // Append to existing file
      await _currentCsvFile!.writeAsString('$csv\n', mode: FileMode.append);
    } else {
      // Write new file
      await _currentCsvFile!.writeAsString('$csv\n');
    }
  }

  Future<void> _loadCsvFiles() async {
    final directory = await getTemporaryDirectory();
    final files = directory.listSync();
    setState(() {
      _csvFiles = files
          .where((file) => file.path.endsWith('.csv'))
          .map((file) => file.path.split('/').last)
          .toList();
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  void _openFile(String fileName) async {
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/$fileName';
    OpenFile.open(path, type: 'text/csv');
  }

  Future<void> _deleteFile(String fileName) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$fileName');
    await file.delete();
    _loadCsvFiles();
  }

  @override
  Widget build(BuildContext context) {
    print('Building UI - Heart Rate: $_heartRate, Steps: $_steps, Distance: $_distance, Calories: $_calories');

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: false,
              pinned: true,
              backgroundColor: const Color(0xFF2D3748),
              title: Text('VitalSync', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, color: Colors.white)),
              centerTitle: true,
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStatusCard(),
                    const SizedBox(height: 16),
                    _buildDataSummary(),
                    const SizedBox(height: 16),
                    _buildActivitySection(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isConnected ? _toggleDataCollection : _connect,
        backgroundColor: _isCollecting ? Colors.red : const Color(0xFF48BB78),
        child: Icon(_isCollecting ? Icons.stop : Icons.play_arrow),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device Status',
              style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: _isConnected ? const Color(0xFF48BB78) : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(
                  _deviceStatus,
                  style: GoogleFonts.poppins(fontSize: 16),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataSummary() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Activity Summary',
              style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildDataItem(Icons.favorite, 'Heart Rate', '$_heartRate bpm'),
                _buildDataItem(Icons.battery_full, 'Battery', '$_batteryLevel%'),
                _buildDataItem(Icons.directions_walk, 'Steps', '$_steps'),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildDataItem(Icons.straighten, 'Distance', '${(_distance / 1000).toStringAsFixed(2)} km'),
                _buildDataItem(Icons.local_fire_department, 'Calories', '$_calories kcal'),
              ],
            ),
            if (_rrIntervals.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'RR Intervals: ${_rrIntervals.map((interval) => '${(interval / 1024).toStringAsFixed(2)}s').join(', ')}',
                style: GoogleFonts.poppins(fontSize: 14),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Duration: ${_formatDuration(_stopwatch.elapsed)}',
              style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, size: 24, color: const Color(0xFF2D3748)),
        const SizedBox(height: 4),
        Text(label, style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey)),
        Text(value, style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildActivitySection() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recorded Sessions',
              style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _csvFiles.length,
              itemBuilder: (context, index) {
                return Slidable(
                  endActionPane: ActionPane(
                    motion: const ScrollMotion(),
                    children: [
                      SlidableAction(
                        onPressed: (_) => _deleteFile(_csvFiles[index]),
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        icon: Icons.delete,
                        label: 'Delete',
                      ),
                    ],
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.insert_drive_file, color: Color(0xFF2D3748)),
                    title: Text(_csvFiles[index], style: GoogleFonts.poppins()),
                    onTap: () => _openFile(_csvFiles[index]),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}