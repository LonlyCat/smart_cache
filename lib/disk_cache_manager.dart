import 'package:path_provider/path_provider.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:flutter/foundation.dart'; // 用于 kIsWeb
import 'package:path/path.dart' as p;
import 'dart:async';

import 'model/cache_exceptions.dart';
import 'model/cache_entry.dart';


class DiskCacheManager {
  final String _boxName;
  // 使用 L3HiveEntry 同时存储数据和元数据
  Box<Map>? _box;
  bool _isInitialized = false;
  // 使用一个 Completer 来指示初始化何时完成。
  final Completer<void> _initCompleter = Completer<void>();

  DiskCacheManager({required String boxName}) : _boxName = boxName;

  Future<void> initialize() async {
    if (_isInitialized) return;
    if (_initCompleter.isCompleted) return _initCompleter.future; // 已在初始化或已完成

    try {
      if (!kIsWeb) { // 在移动端/桌面端 Hive 需要 path_provider
        final dir = await getApplicationDocumentsDirectory();
        Hive.init(p.join(dir.path, 'hive_cache')); // 在子文件夹中初始化 Hive
      } else {
        // Hive 网页初始化（不需要路径）
        Hive.initFlutter(); // 推荐用于 Flutter 网页端
      }

      _box = await Hive.openBox<Map>(_boxName);
      _isInitialized = true;
      _initCompleter.complete();
      debugPrint("DiskCacheManager 初始化完成。Box '$_boxName' 已打开。");
      // 可选：在初始化时运行 pruneExpired
      await pruneExpired();
    } catch (e, s) {
      _initCompleter.completeError(
          DiskCacheException("初始化 Hive box '$_boxName' 失败", originalException: e, stackTrace: s),
          s
      );
      // 重新抛出或适当地处理初始化失败
      rethrow;
    }
    return _initCompleter.future;
  }

  Future<void> _ensureInitialized() async {
    if (!_isInitialized) {
      await _initCompleter.future; // 如果初始化正在进行，则等待
    }
    if (_box == null || !_box!.isOpen) {
      throw DiskCacheException("Hive box '$_boxName' 未打开或初始化失败。");
    }
  }

  /// 获取当前缓存数目
  int length() {
    return _box?.length ?? 0;
  }

  /// 将压缩数据连同元数据一起放入磁盘缓存
  Future<void> put(String key, Uint8List compressedData, Type originalType, Duration expiryDuration) async {
    await _ensureInitialized();
    final now = DateTime.now();
    final expiryTime = now.add(expiryDuration);
    final metaData = L3MetaData(
        key: key,
        originalType: originalType.toString(), // 将类型名称存储为字符串
        expiryTime: expiryTime);
    final entry = L3HiveEntry(compressedData: compressedData, metaData: metaData);

    try {
      await _box!.put(key, entry.toMap());
      debugPrint("磁盘缓存：放入键 '$key'。过期时间：$expiryTime");
    } catch (e, s) {
      throw DiskCacheException("将键 '$key' 放入 Hive box '$_boxName' 失败", originalException: e, stackTrace: s);
    }
  }

  /// 从磁盘缓存中获取数据和元数据。如果未找到或过期，则返回 null。
  /// 返回一个 L3HiveEntry 对象，包含压缩数据和元数据。
  Future<L3HiveEntry?> get(String key) async {
    await _ensureInitialized();
    try {
      L3HiveEntry? entry;
      final Map? entryMap = _box!.get(key);
      if (entryMap != null) {
        entry = L3HiveEntry.fromMap(entryMap);
      }

      if (entry == null) {
        debugPrint("磁盘缓存：获取键 '$key' - 未找到。");
        return null;
      }

      final metaData = entry.metaData;

      // 检查过期时间
      if (metaData.isExpired) {
        debugPrint("磁盘缓存：获取键 '$key' - 已找到但已过期（${metaData.expiryTime}）。正在移除。");
        await remove(key); // 清理过期条目
        return null;
      }

      debugPrint("磁盘缓存：获取键 '$key' - 已找到且有效。");
      return entry;

    } catch (e, s) {
      // 处理获取期间可能出现的 Hive 错误
      throw DiskCacheException("从 Hive box '$_boxName' 获取键 '$key' 失败", originalException: e, stackTrace: s);
    }
  }

  /// 从磁盘缓存中删除条目
  Future<void> remove(String key) async {
    await _ensureInitialized();
    try {
      await _box!.delete(key);
      debugPrint("磁盘缓存：已移除键 '$key'。");
    } catch (e, s) {
      // 记录错误，但可能无需抛出，移除失败的严重性较低
      debugPrint("磁盘缓存：从 Hive box '$_boxName' 移除键 '$key' 失败。错误：$e \n 堆栈跟踪：$s");
    }
  }

  /// 清除整个磁盘缓存
  Future<void> clear() async {
    await _ensureInitialized();
    try {
      final count = await _box!.clear();
      debugPrint("磁盘缓存：已清除 box '$_boxName'。移除 $count 个条目。");
    } catch (e, s) {
      throw DiskCacheException("清除 Hive box '$_boxName' 失败", originalException: e, stackTrace: s);
    }
  }

  /// 从 box 中删除所有过期条目
  Future<void> pruneExpired() async {
    await _ensureInitialized();
    int removedCount = 0;
    // 迭代键并检查过期时间比直接迭代值更安全，尤其是在修改时
    final List<String> keys = _box!.keys.cast<String>().toList(); // 获取键的快照

    for (final key in keys) {
      final L3HiveEntry? entry = await get(key); // 再次获取条目以确保安全
      if (entry != null && entry.metaData.isExpired) {
        try {
          await _box!.delete(key);
          removedCount++;
        } catch (e) {
          debugPrint("磁盘缓存：在清理期间移除过期键 '$key' 时出错。错误：$e");
        }
      }
    }
    if (removedCount > 0) {
      debugPrint("磁盘缓存：从 '$_boxName' 中清理了 $removedCount 个过期条目。");
    } else {
      debugPrint("磁盘缓存：清理检查完成。在 '$_boxName' 中未找到过期条目。");
    }
  }

  /// 关闭 Hive。当应用程序关闭或缓存被处理时调用此方法
  Future<void> dispose() async {
    if (_box != null && _box!.isOpen) {
      await _box!.compact(); // 在关闭前压缩
      await _box!.close();
      _isInitialized = false;
      debugPrint("DiskCacheManager：Box '$_boxName' 已关闭。");
    }
  }
}