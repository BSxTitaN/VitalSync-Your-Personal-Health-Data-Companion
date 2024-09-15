import 'dart:async';
import 'dart:io';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

class DataCollector {
  final FlutterReactiveBle ble;
  final String deviceId;
  List<List<dynamic>> collectedData = [];
  Timer? timer;

  // UUIDs for Mi Band 5 services and characteristics
  final Uuid heartRateServiceUuid = Uuid.parse("0000180d-0000-1000-8000-00805f9b34fb");
  final Uuid heartRateCharUuid = Uuid.parse("00002a37-0000-1000-8000-00805f9b34fb");
  final Uuid stepsServiceUuid = Uuid.parse("0000fee0-0000-1000-8000-00805f9b34fb");
  final Uuid stepsCharUuid = Uuid.parse("00000007-0000-3512-2118-0009af100700");
  final Uuid batteryServiceUuid = Uuid.parse("0000180f-0000-1000-8000-00805f9b34fb");
  final Uuid batteryCharUuid = Uuid.parse("00002a19-0000-1000-8000-00805f9b34fb");

  DataCollector({required this.ble, required this.deviceId});

  void startCollecting() {
    timer = Timer.periodic(const Duration(seconds: 5), (Timer t) async {
      await _collectData();
    });
  }

  Future<void> _collectData() async {
    try {
      int? heartRate = await _readHeartRate();
      int? steps = await _readSteps();
      int? batteryLevel = await _readBatteryLevel();
      // Sleep data might require more complex logic and might not be available in real-time

      DateTime now = DateTime.now();
      collectedData.add([now.toIso8601String(), heartRate, steps, batteryLevel]);
    } catch (e) {
      print('Error collecting data: $e');
    }
  }

  Future<int?> _readHeartRate() async {
    final characteristic = QualifiedCharacteristic(
        serviceId: heartRateServiceUuid,
        characteristicId: heartRateCharUuid,
        deviceId: deviceId);
    final result = await ble.readCharacteristic(characteristic);
    if (result.isNotEmpty) {
      return result[1]; // Assuming the heart rate value is at index 1
    }
    return null;
  }

  Future<int?> _readSteps() async {
    final characteristic = QualifiedCharacteristic(
        serviceId: stepsServiceUuid,
        characteristicId: stepsCharUuid,
        deviceId: deviceId);
    final result = await ble.readCharacteristic(characteristic);
    if (result.length >= 3) {
      return result[1] + (result[2] << 8); // Combine two bytes for steps
    }
    return null;
  }

  Future<int?> _readBatteryLevel() async {
    final characteristic = QualifiedCharacteristic(
        serviceId: batteryServiceUuid,
        characteristicId: batteryCharUuid,
        deviceId: deviceId);
    final result = await ble.readCharacteristic(characteristic);
    if (result.isNotEmpty) {
      return result[0]; // Battery level is usually a single byte
    }
    return null;
  }

  Future<void> stopCollecting() async {
    timer?.cancel();
  }

  Future<String> saveDataToCSV() async {
    List<List<dynamic>> rows = [
      ['Timestamp', 'Heart Rate', 'Steps', 'Battery Level'],
      ...collectedData
    ];

    String csv = const ListToCsvConverter().convert(rows);
    final directory = await getApplicationDocumentsDirectory();
    final path = directory.path;
    final fileName = 'fitness_data_${DateTime.now().toIso8601String()}.csv';
    final file = File('$path/$fileName');
    await file.writeAsString(csv);
    return file.path;
  }
}