

import 'package:flutter/foundation.dart'; // For compute
import 'dart:convert';
import 'dart:io';

import 'model/cache_exceptions.dart';

// --- Isolate Payload Structures ---

class _CompressionPayload {
  final String jsonData; // 将对象预先转为 JSON String 传递
  _CompressionPayload(this.jsonData);
}

class _DecompressionPayload {
  final Uint8List compressedData;
  _DecompressionPayload(this.compressedData);
}

class _BatchCompressionPayload {
  // Map where Key is the original cache key, Value is the JSON string to compress
  final Map<String, String> dataToCompress;
  _BatchCompressionPayload(this.dataToCompress);
}

// --- Top-Level Functions for Isolate Execution ---

// 注意：Isolate 不能直接访问主 Isolate 的内存或函数闭包
// 它们需要是顶级函数或静态方法

/// 隔离兼容压缩函数
Future<Uint8List> _compressIsolate(_CompressionPayload payload) async {
  try {
    // 1. Encode String to UTF8 bytes
    final List<int> utf8Bytes = utf8.encode(payload.jsonData);
    // 2. Compress using GZip
    final List<int> compressedBytes = gzip.encode(utf8Bytes);
    // 3. Return as Uint8List
    return Uint8List.fromList(compressedBytes);
  } catch (e, s) {
    // Isolate 内无法直接抛出复杂异常给主 Isolate，通常返回错误标记或 null
    // 这里我们选择重新抛出，由 compute 的 Future 捕获
    // 或者可以返回一个包含错误信息的特定对象
    debugPrint("Compression error in isolate: $e\n$s");
    throw CompressionException("Failed to compress data in isolate", originalException: e, stackTrace: s);
    // return Uint8List(0); // Indicate error with empty list? Needs handling in caller
  }
}

/// 与隔离兼容的解压缩功能
Future<String> _decompressIsolate(_DecompressionPayload payload) async {
  try {
    // 1. Decompress using GZip
    final List<int> decompressedBytes = gzip.decode(payload.compressedData);
    // 2. Decode UTF8 bytes to String
    final String jsonData = utf8.decode(decompressedBytes);
    return jsonData;
  } catch (e, s) {
    debugPrint("Decompression error in isolate: $e\n$s");
    throw CompressionException("Failed to decompress data in isolate", originalException: e, stackTrace: s);
    // return ""; // Indicate error with empty string? Needs handling in caller
  }
}

/// 在单个隔离区内压缩多个 JSON 字符串
/// 返回一个映射，其中键与输入键匹配，值为压缩后的数据
/// 单个项目的压缩失败会被记录下来并跳过（结果中不包含该键）
Future<Map<String, Uint8List>> _compressBatchIsolate(_BatchCompressionPayload payload) async {
  final Map<String, Uint8List> results = {};
  for (final entry in payload.dataToCompress.entries) {
    final key = entry.key;
    final jsonData = entry.value;
    try {
      final List<int> utf8Bytes = utf8.encode(jsonData);
      final List<int> compressedBytes = gzip.encode(utf8Bytes);
      results[key] = Uint8List.fromList(compressedBytes);
    } catch (e, s) {
      debugPrint("Compression error in isolate for batch item key '$key': $e\n$s");
    }
  }
  return results;
}

// --- Compression Utility Class ---

class CompressionUtils {
  final bool _useIsolate;

  CompressionUtils({required bool useIsolate}) : _useIsolate = useIsolate;

  /// Compresses a JSON string into GZipped Uint8List.
  /// Handles running in an isolate via compute() if configured.
  Future<Uint8List> compress(String jsonData) async {
    if (_useIsolate) {
      try {
        // compute 会自动处理 Isolate 的创建、通信和销毁
        return await compute(_compressIsolate, _CompressionPayload(jsonData));
      } catch (e, s) {
        if (e is CompressionException) rethrow; // Propagate specific exception
        // Wrap other compute errors
        throw CompressionException("Error during isolated compression", originalException: e, stackTrace: s);
      }
    } else {
      // Synchronous execution on the current thread
      try {
        final List<int> utf8Bytes = utf8.encode(jsonData);
        final List<int> compressedBytes = gzip.encode(utf8Bytes);
        return Uint8List.fromList(compressedBytes);
      } catch (e, s) {
        throw CompressionException("Error during synchronous compression", originalException: e, stackTrace: s);
      }
    }
  }

  /// Decompresses GZipped Uint8List back into a JSON string.
  /// Handles running in an isolate via compute() if configured.
  /// Note: JSON parsing and object deserialization happens *after* this.
  Future<String> decompress(Uint8List compressedData) async {
    if (compressedData.isEmpty) {
      throw CompressionException("Cannot decompress empty data.");
    }
    if (_useIsolate) {
      try {
        return await compute(_decompressIsolate, _DecompressionPayload(compressedData));
      } catch (e, s) {
        if (e is CompressionException) rethrow;
        throw CompressionException("Error during isolated decompression", originalException: e, stackTrace: s);
      }
    } else {
      // Synchronous execution
      try {
        final List<int> decompressedBytes = gzip.decode(compressedData);
        return utf8.decode(decompressedBytes);
      } catch (e, s) {
        throw CompressionException("Error during synchronous decompression", originalException: e, stackTrace: s);
      }
    }
  }

  /// Uses a single `compute` call for efficiency if isolates are enabled.
  /// Takes a map of {cacheKey: jsonData} and returns a map of {cacheKey: compressedData}.
  /// Keys for which compression failed in the isolate will be missing from the result map.
  Future<Map<String, Uint8List>> compressBatch(Map<String, String> jsonDataMap) async {
    if (jsonDataMap.isEmpty) {
      return {}; // Nothing to do
    }

    if (_useIsolate) {
      try {
        // Pass the entire map to the batch isolate function
        return await compute(_compressBatchIsolate, _BatchCompressionPayload(jsonDataMap));
      } catch (e, s) {
        // This catches errors if the compute call itself fails (e.g., isolate crash)
        // Individual item errors inside the isolate are handled by omission from the result map.
        throw CompressionException("Error during isolated batch compression execution", originalException: e, stackTrace: s);
      }
    } else {
      // Synchronous execution on the current thread
      final Map<String, Uint8List> results = {};
      for (final entry in jsonDataMap.entries) {
        final key = entry.key;
        final jsonData = entry.value;
        try {
          final List<int> utf8Bytes = utf8.encode(jsonData);
          final List<int> compressedBytes = gzip.encode(utf8Bytes);
          results[key] = Uint8List.fromList(compressedBytes);
        } catch (e, s) {
          // Log synchronous error and skip item
          debugPrint("Synchronous compression error for batch item key '$key': $e\n$s");
          // Optionally rethrow or use a more sophisticated error handling/reporting mechanism
        }
      }
      return results;
    }
  }

  // --- Synchronous versions (might block UI if data is large/CPU is slow) ---
  Uint8List compressSync(String jsonData) {
    try {
      final List<int> utf8Bytes = utf8.encode(jsonData);
      final List<int> compressedBytes = gzip.encode(utf8Bytes);
      return Uint8List.fromList(compressedBytes);
    } catch (e, s) {
      throw CompressionException("Error during synchronous compression", originalException: e, stackTrace: s);
    }
  }

  String decompressSync(Uint8List compressedData) {
    if (compressedData.isEmpty) {
      throw CompressionException("Cannot decompress empty data.");
    }
    try {
      final List<int> decompressedBytes = gzip.decode(compressedData);
      return utf8.decode(decompressedBytes);
    } catch (e, s) {
      throw CompressionException("Error during synchronous decompression", originalException: e, stackTrace: s);
    }
  }
}
