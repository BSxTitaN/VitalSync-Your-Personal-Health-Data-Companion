import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

class CsvUtils {
  static final List<List<dynamic>> _data = [];

  static void addDataPoint(String heartRate, String steps, String batteryLevel, String sleepData) {
    _data.add([
      DateTime.now().toIso8601String(),
      heartRate,
      steps,
      batteryLevel,
      sleepData,
    ]);
  }

  static Future<String> saveRecordingToFile() async {
    String csv = const ListToCsvConverter().convert(_data);

    Directory tempDir = await getTemporaryDirectory();
    String directoryPath = '${tempDir.path}/vitalsync';
    await Directory(directoryPath).create(recursive: true);

    String fileName = 'recording_${DateTime.now().millisecondsSinceEpoch}.csv';
    String filePath = '$directoryPath/$fileName';

    File file = File(filePath);
    await file.writeAsString(csv);

    _data.clear();
    return filePath;
  }
}