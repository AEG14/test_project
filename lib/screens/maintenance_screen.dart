import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:csv/csv.dart';
import 'package:paged_datatable/paged_datatable.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:universal_html/html.dart' as universal_html;

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
  bool _isTableLoading = true; // Add loading state for table

  // Add platform detection
  bool get isMacOS =>
      html.window.navigator.platform?.toLowerCase().contains('mac') ?? false;
  final html.FileUploadInputElement uploadInput = html.FileUploadInputElement()
    ..accept = '.csv'
    ..style.display = 'none';
  @override
  void initState() {
    super.initState();

    uploadInput.onChange.listen((e) {
      final files = uploadInput.files;
      if (files?.isNotEmpty ?? false) {
        _handleFileUpload(files!.first);
      }
    });
    html.document.body!.children.add(uploadInput);
    _loadDataFromFirestore();
    _configureForPlatform();
  }

  @override
  void dispose() {
    uploadInput.remove();
    _tableController.dispose(); // Properly dispose of the controller
    super.dispose();
  }

  void _configureForPlatform() {
    // Apply platform-specific configurations
    if (isMacOS) {
      // Add MacOS-specific meta tags
      final head = html.document.head;
      if (head != null) {
        // Add MacOS-specific viewport meta tag
        var meta = html.MetaElement()
          ..name = 'viewport'
          ..content =
              'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
        head.children.add(meta);

        // Add CSS for MacOS font rendering
        var style = html.StyleElement()
          ..text = '''
            body {
              -webkit-font-smoothing: antialiased;
              -moz-osx-font-smoothing: grayscale;
            }
            
            /* Fix for MacOS Chrome table rendering */
            table {
              -webkit-border-horizontal-spacing: 0;
              -webkit-border-vertical-spacing: 0;
            }
          ''';
        head.children.add(style);
      }
    }
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

  Future<void> _handleFileUpload(html.File file) async {
    setState(() {
      _isProcessing = true;
      _uploadProgress = 0;
      _errors.clear();
    });

    final reader = html.FileReader();

    reader.onLoadEnd.listen((e) async {
      try {
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

        // Validate CSV structure
        final headers = csvData[0].map((e) => e.toString()).toList();
        final requiredColumns = {
          "material_name": "品目名1",
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

        // Prepare data for validation
        List<Map<String, dynamic>> newData = [];
        for (var i = 1; i < csvData.length; i++) {
          final row = csvData[i];
          if (row.length < headers.length) continue;

          final dataRow = {
            "material_name": row[indices["material_name"]!].toString(),
            "standard_unit": row[indices["standard_unit"]!].toString(),
            "standard_unit_cost":
                row[indices["standard_unit_cost"]!].toString(),
            "created_at": Timestamp.now(),
            "created_by": "csv",
            "updated_at": Timestamp.now(),
            "updated_by": "csv",
          };

          if (_validateRow(dataRow, i)) {
            newData.add(dataRow);
          }
        }

        // If there are validation errors, show them immediately
        if (_errors.isNotEmpty) {
          _showErrorDialog('Validation errors found in CSV file');
          setState(() {
            _isProcessing = false;
          });
          return;
        }

        // Proceed with Firestore update
        await _updateFirestore(newData);
      } catch (e) {
        _showErrorDialog('Failed to process CSV file: ${e.toString()}');
      } finally {
        setState(() {
          _isProcessing = false;
        });
      }
    });

    reader.readAsText(file, 'Shift-JIS');
  }

  Future<void> _processCsvData(String csvString) async {
    try {
      List<List<dynamic>> csvData =
          const CsvToListConverter().convert(csvString);
      if (csvData.isEmpty) throw Exception("CSV file is empty");

      // Validate CSV structure
      final headers = csvData[0].map((e) => e.toString().trim()).toList();
      final requiredColumns = {
        "material_name": "品目名1",
        "standard_unit": "標準単位",
        "standard_unit_cost": "標準単価",
      };

      // Validate headers
      for (var entry in requiredColumns.entries) {
        if (!headers.contains(entry.value)) {
          throw Exception("Required column '${entry.value}' is missing");
        }
      }

      final indices = requiredColumns.map((key, value) {
        final index = headers.indexOf(value);
        return MapEntry(key, index);
      });

      // Process data rows with validation
      List<Map<String, dynamic>> newData = [];
      for (var i = 1; i < csvData.length; i++) {
        final row = csvData[i];
        if (row.length < headers.length) continue;

        final dataRow = {
          "material_name": row[indices["material_name"]!].toString().trim(),
          "standard_unit": row[indices["standard_unit"]!].toString().trim(),
          "standard_unit_cost":
              row[indices["standard_unit_cost"]!].toString().trim(),
          "created_at": Timestamp.now(),
          "created_by": "csv",
          "updated_at": Timestamp.now(),
          "updated_by": "csv",
        };

        if (_validateRow(dataRow, i)) {
          newData.add(dataRow);
        }
      }

      if (_errors.isNotEmpty) {
        _showErrorDialog('Validation errors found in CSV file');
        return;
      }

      await _updateFirestore(newData);
    } catch (e) {
      _showErrorDialog(e.toString());
    }
  }

  Future<void> _updateFirestore(List<Map<String, dynamic>> newData) async {
    try {
      setState(() {
        _uploadProgress = 0;
      });

      // Calculate total operations (deletions + additions)
      final existingDocs = await _firestore.collection('materials').get();
      final totalOperations = existingDocs.docs.length + newData.length;
      int completedOperations = 0;

      // Delete existing documents in batches
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

      // Add new documents in batches
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

      // Ensure progress shows 100% when complete
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

        // Reset processing state after small delay to show 100%
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

  bool _validateRow(Map<String, dynamic> row, int rowIndex) {
    var isValid = true;

    if (row["material_name"].toString().trim().isEmpty) {
      _errors.add("Row $rowIndex: 品目名1 (material_name) is empty.");
      isValid = false;
    }

    if (row["standard_unit"].toString().trim().isEmpty) {
      _errors.add("Row $rowIndex: 標準単位 (standard_unit) is empty.");
      isValid = false;
    }

    final cost = double.tryParse(row["standard_unit_cost"].toString());
    if (cost == null) {
      _errors.add(
          "Row $rowIndex: 標準単価 (standard_unit_cost) is not a valid decimal.");
      isValid = false;
    }

    return isValid;
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
        title: const Text("Master Maintenance Screen"),
        backgroundColor: tBlue2,
        foregroundColor: tWhite,
      ),
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          physics: const BouncingScrollPhysics(),
          platform: isMacOS ? TargetPlatform.macOS : Theme.of(context).platform,
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
                onPressed: _isProcessing ? null : () => uploadInput.click(),
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
