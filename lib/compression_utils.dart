import 'package:flutter/foundation.dart'; // 用于 compute
import 'dart:convert';
import 'dart:io';

import 'model/cache_exceptions.dart';

// --- 隔离线程负载结构 ---

class _CompressionPayload {
  final String jsonData; // 将对象预先转为 JSON 字符串传递
  _CompressionPayload(this.jsonData);
}

class _DecompressionPayload {
  final Uint8List compressedData;
  _DecompressionPayload(this.compressedData);
}

class _BatchCompressionPayload {
  // 映射，其中键是原始缓存键，值是待压缩的 JSON 字符串
  final Map<String, String> dataToCompress;
  _BatchCompressionPayload(this.dataToCompress);
}

// --- 用于隔离线程执行的顶级函数 ---

// 注意：隔离线程无法直接访问主隔离线程的内存或函数闭包
// 它们需要是顶级函数或静态方法

/// 隔离线程兼容的压缩函数
Future<Uint8List> _compressIsolate(_CompressionPayload payload) async {
  try {
    // 1. 将字符串编码为 UTF8 字节
    final List<int> utf8Bytes = utf8.encode(payload.jsonData);
    // 2. 使用 GZip 压缩
    final List<int> compressedBytes = gzip.encode(utf8Bytes);
    // 3. 返回 Uint8List
    return Uint8List.fromList(compressedBytes);
  } catch (e, s) {
    // 隔离线程内无法直接抛出复杂异常给主隔离线程，通常返回错误标记或 null
    // 这里选择重新抛出，由 compute 的 Future 捕获
    // 或者可以返回一个包含错误信息的特定对象
    debugPrint("隔离线程中的压缩错误: $e\n$s");
    throw CompressionException("在隔离线程中压缩数据失败", originalException: e, stackTrace: s);
  }
}

/// 与隔离线程兼容的解压缩函数
Future<String> _decompressIsolate(_DecompressionPayload payload) async {
  try {
    // 1. 使用 GZip 解压缩
    final List<int> decompressedBytes = gzip.decode(payload.compressedData);
    // 2. 将 UTF8 字节解码为字符串
    final String jsonData = utf8.decode(decompressedBytes);
    return jsonData;
  } catch (e, s) {
    debugPrint("隔离线程中的解压缩错误: $e\n$s");
    throw CompressionException("在隔离线程中解压缩数据失败", originalException: e, stackTrace: s);
  }
}

/// 在单个隔离线程中压缩多个 JSON 字符串
/// 返回一个映射，其中键与输入键匹配，值为压缩后的数据
/// 单个项目的压缩失败会被记录并跳过（结果中不包含该键）
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
      debugPrint("隔离线程中批量项键 '$key' 的压缩错误: $e\n$s");
    }
  }
  return results;
}

// --- 压缩工具类 ---

class CompressionUtils {
  final bool _useIsolate;

  CompressionUtils({required bool useIsolate}) : _useIsolate = useIsolate;

  /// 将 JSON 字符串压缩为 GZipped Uint8List。
  /// 如果配置了隔离线程，则通过 compute() 在隔离线程中运行。
  Future<Uint8List> compress(String jsonData) async {
    if (_useIsolate) {
      try {
        // compute 会自动处理隔离线程的创建、通信和销毁
        return await compute(_compressIsolate, _CompressionPayload(jsonData));
      } catch (e, s) {
        if (e is CompressionException) rethrow; // 传播特定异常
        // 包装其他 compute 错误
        throw CompressionException("隔离线程压缩期间出错", originalException: e, stackTrace: s);
      }
    } else {
      // 在当前线程上同步执行
      try {
        final List<int> utf8Bytes = utf8.encode(jsonData);
        final List<int> compressedBytes = gzip.encode(utf8Bytes);
        return Uint8List.fromList(compressedBytes);
      } catch (e, s) {
        throw CompressionException("同步压缩期间出错", originalException: e, stackTrace: s);
      }
    }
  }

  /// 将 GZipped Uint8List 解压缩回 JSON 字符串。
  /// 如果配置了隔离线程，则通过 compute() 在隔离线程中运行。
  /// 注意：JSON 解析和对象反序列化在此之后进行。
  Future<String> decompress(Uint8List compressedData) async {
    if (compressedData.isEmpty) {
      throw CompressionException("无法解压缩空数据。");
    }
    if (_useIsolate) {
      try {
        return await compute(_decompressIsolate, _DecompressionPayload(compressedData));
      } catch (e, s) {
        if (e is CompressionException) rethrow;
        throw CompressionException("隔离线程解压缩期间出错", originalException: e, stackTrace: s);
      }
    } else {
      // 同步执行
      try {
        final List<int> decompressedBytes = gzip.decode(compressedData);
        return utf8.decode(decompressedBytes);
      } catch (e, s) {
        throw CompressionException("同步解压缩期间出错", originalException: e, stackTrace: s);
      }
    }
  }

  /// 如果启用了隔离线程，则使用单个 `compute` 调用以提高效率。
  /// 接收 {cacheKey: jsonData} 映射，返回 {cacheKey: compressedData} 映射。
  /// 在隔离线程中压缩失败的键将从结果映射中缺失。
  Future<Map<String, Uint8List>> compressBatch(Map<String, String> jsonDataMap) async {
    if (jsonDataMap.isEmpty) {
      return {}; // 无需操作
    }

    if (_useIsolate) {
      try {
        // 将整个映射传递给批量隔离函数
        return await compute(_compressBatchIsolate, _BatchCompressionPayload(jsonDataMap));
      } catch (e, s) {
        // 如果 compute 调用本身失败（例如隔离线程崩溃），则捕获错误
        // 隔离线程内单个项的错误通过从结果映射中省略来处理。
        throw CompressionException("隔离线程批量压缩执行期间出错", originalException: e, stackTrace: s);
      }
    } else {
      // 在当前线程上同步执行
      final Map<String, Uint8List> results = {};
      for (final entry in jsonDataMap.entries) {
        final key = entry.key;
        final jsonData = entry.value;
        try {
          final List<int> utf8Bytes = utf8.encode(jsonData);
          final List<int> compressedBytes = gzip.encode(utf8Bytes);
          results[key] = Uint8List.fromList(compressedBytes);
        } catch (e, s) {
          // 记录同步错误并跳过该项
          debugPrint("同步压缩批量项键 '$key' 的错误: $e\n$s");
        }
      }
      return results;
    }
  }

  // --- 同步版本（如果数据量大或 CPU 慢，可能会阻塞 UI） ---
  Uint8List compressSync(String jsonData) {
    try {
      final List<int> utf8Bytes = utf8.encode(jsonData);
      final List<int> compressedBytes = gzip.encode(utf8Bytes);
      return Uint8List.fromList(compressedBytes);
    } catch (e, s) {
      throw CompressionException("同步压缩期间出错", originalException: e, stackTrace: s);
    }
  }

  String decompressSync(Uint8List compressedData) {
    if (compressedData.isEmpty) {
      throw CompressionException("无法解压缩空数据。");
    }
    try {
      final List<int> decompressedBytes = gzip.decode(compressedData);
      return utf8.decode(decompressedBytes);
    } catch (e, s) {
      throw CompressionException("同步解压缩期间出错", originalException: e, stackTrace: s);
    }
  }
}