import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:csv/csv.dart';
import 'package:paged_datatable/paged_datatable.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';

import '../const/constant.dart';

class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({Key? key}) : super(key: key);

  @override
  _MaintenanceScreenState createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  final _tableController =
      PagedDataTableController<String, Map<String, dynamic>>();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<Map<String, dynamic>> _data = [];
  List<String> _errors = [];
  double _uploadProgress = 0;
  bool _isProcessing = false;
  bool _isTableLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDataFromFirestore();
  }

  @override
  void dispose() {
    _tableController.dispose();
    super.dispose();
  }

  Future<void> _loadDataFromFirestore() async {
    setState(() => _isTableLoading = true);
    try {
      final snapshot = await _firestore.collection('materials').get();
      if (mounted) {
        setState(() {
          _data = snapshot.docs
              .map((doc) => {
                    ...doc.data(),
                    'id': doc.id,
                  })
              .toList();
          _isTableLoading = false;
        });
        _tableController.refresh();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isTableLoading = false);
        _showErrorDialog('Failed to load data from Firestore: ${e.toString()}');
      }
    }
  }

  Future<void> _handleFileUpload(PlatformFile file) async {
    setState(() {
      _isProcessing = true;
      _uploadProgress = 0;
      _errors.clear();
    });

    try {
      final reader = html.FileReader();
      final blob = html.Blob([file.bytes!]);
      reader.readAsText(blob, 'Shift-JIS');
      await reader.onLoadEnd.first;

      if (reader.result == null) throw Exception("Failed to read file");

      String csvString;
      if (reader.result is String) {
        csvString = reader.result as String;
      } else {
        final bytes = (reader.result as html.Blob).slice(0).toString();
        csvString = bytes;
      }

      List<List<dynamic>> csvData =
          const CsvToListConverter().convert(csvString);
      if (csvData.isEmpty) throw Exception("CSV file is empty");

      final headers = csvData[0].map((e) => e.toString()).toList();
      final requiredColumns = {
        "material_name": "品目名1",
        "item_name_2": "品目名2",
        "standard_unit": "標準単位",
        "standard_unit_cost": "標準単価",
      };

      final indices = requiredColumns.map((key, value) {
        final index = headers.indexOf(value);
        return MapEntry(key, index);
      });

      if (indices.values.any((index) => index == -1)) {
        throw Exception("Required columns are missing in the CSV file");
      }

      Set<String> materialNames = {};

      List<Map<String, dynamic>> newData = [];
      for (var i = 1; i < csvData.length; i++) {
        final row = csvData[i];
        if (row.length < headers.length) continue;

        final dataRow = {
          "material_name": row[indices["material_name"]!].toString(),
          "item_name_2": row[indices["item_name_2"]!].toString(),
          "standard_unit": row[indices["standard_unit"]!].toString(),
          "standard_unit_cost": row[indices["standard_unit_cost"]!].toString(),
          "created_at": Timestamp.now(),
          "created_by": "csv",
          "updated_at": Timestamp.now(),
          "updated_by": "csv",
        };

        if (_validateRow(
          dataRow,
          i,
          indices,
          materialNames,
        )) {
          newData.add(dataRow);
          materialNames.add(
              "${dataRow["material_name"]?.toString() ?? ''}-${dataRow["item_name_2"]?.toString() ?? ''}");
        }
      }

      if (_errors.isNotEmpty) {
        _showErrorDialog('Validation errors found in CSV file');
        setState(() {
          _isProcessing = false;
        });
        return;
      }

      await _updateFirestore(newData);
    } catch (e) {
      _showErrorDialog('Failed to process CSV file: ${e.toString()}');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  bool _validateRow(
    Map<String, dynamic> row,
    int rowIndex,
    Map<String, int> columnIndices,
    Set<String> existingMaterialNames,
  ) {
    var isValid = true;

    String createErrorMessage(
        String columnKey, String japaneseColumnName, String error) {
      final columnIndex = columnIndices[columnKey]! + 1;
      return "Row ${rowIndex}: Column $columnIndex ($japaneseColumnName/$columnKey) $error";
    }

    final materialName = row["material_name"].toString().trim();
    final itemName2 = row["item_name_2"].toString().trim();
    final combinedName = "$materialName-$itemName2";

    if (materialName.isEmpty) {
      _errors.add(createErrorMessage(
        "material_name",
        "品目名1",
        "is empty",
      ));
      isValid = false;
    } else if (existingMaterialNames.contains(combinedName)) {
      _errors.add(createErrorMessage(
        "material_name",
        "品目名1",
        "is duplicate. Material names must be unique",
      ));
      isValid = false;
    }

    if (row["standard_unit"].toString().trim().isEmpty) {
      _errors.add(createErrorMessage(
        "standard_unit",
        "標準単位",
        "is empty",
      ));
      isValid = false;
    }

    final cost = double.tryParse(row["standard_unit_cost"].toString());
    if (cost == null) {
      _errors.add(createErrorMessage(
        "standard_unit_cost",
        "標準単価",
        "is not a valid decimal",
      ));
      isValid = false;
    }

    return isValid;
  }

  Future<void> _updateFirestore(List<Map<String, dynamic>> newData) async {
    try {
      setState(() {
        _uploadProgress = 0;
      });

      final existingDocs = await _firestore.collection('materials').get();
      final totalOperations = existingDocs.docs.length + newData.length;
      int completedOperations = 0;

      for (var i = 0; i < existingDocs.docs.length; i += 500) {
        final batch = _firestore.batch();
        final end = (i + 500 < existingDocs.docs.length)
            ? i + 500
            : existingDocs.docs.length;
        final batchDocs = existingDocs.docs.sublist(i, end);

        for (var doc in batchDocs) {
          batch.delete(doc.reference);
        }

        await batch.commit();
        completedOperations += batchDocs.length;

        if (mounted) {
          setState(() {
            _uploadProgress = (completedOperations / totalOperations) * 100;
          });
        }
      }

      for (var i = 0; i < newData.length; i += 500) {
        final batch = _firestore.batch();
        final end = (i + 500 < newData.length) ? i + 500 : newData.length;
        final batchData = newData.sublist(i, end);

        for (var data in batchData) {
          final docRef = _firestore.collection('materials').doc();
          batch.set(docRef, data);
        }

        await batch.commit();
        completedOperations += batchData.length;

        if (mounted) {
          setState(() {
            _uploadProgress = (completedOperations / totalOperations) * 100;
          });
        }
      }

      if (mounted) {
        setState(() {
          _uploadProgress = 100;
        });
      }

      await _loadDataFromFirestore();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('CSV data successfully uploaded to Firestore')),
        );

        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            setState(() {
              _isProcessing = false;
              _uploadProgress = 0;
            });
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _uploadProgress = 0;
        });
        _showErrorDialog('Failed to update Firestore: ${e.toString()}');
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red),
            const SizedBox(width: 8),
            const Text(
              "Error",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message,
                style: const TextStyle(fontSize: 16, color: Colors.black87),
              ),
              if (_errors.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  "Validation Errors:",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 150,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    itemCount: _errors.length,
                    itemBuilder: (context, index) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.warning, color: Colors.amber),
                      title: Text(
                        _errors[index],
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              "OK",
              style: TextStyle(color: tBlue2),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Test 3 Master Maintenance Screen"),
        backgroundColor: tBlue2,
        foregroundColor: tWhite,
      ),
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          physics: const BouncingScrollPhysics(),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  foregroundColor: tWhite,
                  backgroundColor: tBlue2,
                ),
                onPressed: _isProcessing ? null : _pickFile,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.upload_file),
                    const SizedBox(width: 8),
                    Text(_isProcessing ? "Processing..." : "Load CSV"),
                  ],
                ),
              ),
              if (_isProcessing) ...[
                const SizedBox(height: 16),
                _buildProgressIndicator(),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: _isTableLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildDataTable(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      await _handleFileUpload(file);
    }
  }

  Widget _buildProgressIndicator() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 100,
              height: 100,
              child: CircularProgressIndicator(
                value: _uploadProgress / 100,
                strokeWidth: 8.0,
                backgroundColor: Colors.grey[300],
                valueColor: AlwaysStoppedAnimation<Color>(tBlue2),
              ),
            ),
            Text(
              '${_uploadProgress.toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: tBlue2,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Processing...',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: Colors.grey[600],
              ),
        ),
      ],
    );
  }

  Widget _buildDataTable() {
    return PagedDataTable<String, Map<String, dynamic>>(
      controller: _tableController,
      fetcher: _fetchData,
      initialPageSize: 10,
      columns: [
        TableColumn(
          title: const Text("品目名1"),
          cellBuilder: (context, item, index) =>
              Text(item["material_name"] ?? ''),
          size: const RemainingColumnSize(),
        ),
        TableColumn(
          title: const Text("品目名2"),
          cellBuilder: (context, item, index) =>
              Text(item["item_name_2"] ?? ''),
          size: const RemainingColumnSize(),
        ),
        TableColumn(
          title: const Text("標準単位"),
          cellBuilder: (context, item, index) =>
              Text(item["standard_unit"] ?? ''),
          size: const RemainingColumnSize(),
        ),
        TableColumn(
          title: const Text("標準単価"),
          cellBuilder: (context, item, index) =>
              Text(item["standard_unit_cost"]?.toString() ?? ''),
          size: const RemainingColumnSize(),
        ),
        TableColumn(
          title: const Text("作成日"),
          cellBuilder: (context, item, index) =>
              Text(_formatTimestamp(item["created_at"])),
          size: const RemainingColumnSize(),
        ),
        TableColumn(
          title: const Text("作成者"),
          cellBuilder: (context, item, index) => Text(item["created_by"] ?? ''),
          size: const RemainingColumnSize(),
        ),
        TableColumn(
          title: const Text("更新日"),
          cellBuilder: (context, item, index) =>
              Text(_formatTimestamp(item["updated_at"])),
          size: const RemainingColumnSize(),
        ),
        TableColumn(
          title: const Text("更新者"),
          cellBuilder: (context, item, index) => Text(item["updated_by"] ?? ''),
          size: const RemainingColumnSize(),
        ),
      ],
    );
  }

  String _formatTimestamp(Timestamp timestamp) {
    return DateTime.fromMillisecondsSinceEpoch(
      timestamp.millisecondsSinceEpoch,
    ).toString();
  }

  Future<(List<Map<String, dynamic>>, String?)> _fetchData(
    int pageSize,
    SortModel? sortModel,
    Map<String, dynamic> filters,
    String? pageToken,
  ) async {
    final startIndex = pageToken != null ? int.parse(pageToken) : 0;
    final endIndex = (startIndex + pageSize).clamp(0, _data.length);
    final items = _data.sublist(startIndex, endIndex);
    final nextPageToken = endIndex >= _data.length ? null : endIndex.toString();
    return (items, nextPageToken);
  }
}
