

import 'package:path_provider/path_provider.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:path/path.dart' as p;
import 'dart:async';

import 'model/cache_exceptions.dart';
import 'model/cache_entry.dart';

// 注册 L3HiveEntry 的适配器至关重要
// 您可以使用 build_runner 和 hive_generator 生成它
// 或者手动实现。这里为了简单起见，我们假设它已在其他地方注册。
// 示例：Hive.registerAdapter(L3HiveEntryAdapter())；

class DiskCacheManager {
  final String _boxName;
  // 使用 L3HiveEntry 来一起存储数据和元数据
  Box<Map>? _box;
  bool _isInitialized = false;
  // 使用一个 Completer 来指示初始化何时完成。
  final Completer<void> _initCompleter = Completer<void>();

  DiskCacheManager({required String boxName}) : _boxName = boxName;

  Future<void> initialize() async {
    if (_isInitialized) return;
    if (_initCompleter.isCompleted) return _initCompleter.future; // Already initializing or done

    try {
      if (!kIsWeb) { // Hive needs path_provider on mobile/desktop
        final dir = await getApplicationDocumentsDirectory();
        Hive.init(p.join(dir.path, 'hive_cache')); // Initialize Hive in a subfolder
      } else {
        // Hive web initialization (doesn't need a path)
        Hive.initFlutter(); // Recommended for Flutter web
      }

      _box = await Hive.openBox<Map>(_boxName);
      _isInitialized = true;
      _initCompleter.complete();
      debugPrint("DiskCacheManager initialized. Box '$_boxName' opened.");
      // Optionally run pruneExpired on init
      await pruneExpired();
    } catch (e, s) {
      _initCompleter.completeError(
          DiskCacheException("Failed to initialize Hive box '$_boxName'", originalException: e, stackTrace: s),
          s
      );
      // Rethrow or handle initialization failure appropriately
      rethrow;
    }
    return _initCompleter.future;
  }

  Future<void> _ensureInitialized() async {
    if (!_isInitialized) {
      await _initCompleter.future; // Wait if initialization is in progress
      // If it completed with an error, the await will throw it.
    }
    if (_box == null || !_box!.isOpen) {
      throw DiskCacheException("Hive box '$_boxName' is not open or initialization failed.");
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
        originalType: originalType.toString(), // Store type name as string
        expiryTime: expiryTime);
    final entry = L3HiveEntry(compressedData: compressedData, metaData: metaData);

    try {
      await _box!.put(key, entry.toMap());
      debugPrint("DiskCache: Put key '$key'. Expires: $expiryTime");
    } catch (e, s) {
      throw DiskCacheException("Failed to put key '$key' into Hive box '$_boxName'", originalException: e, stackTrace: s);
    }
  }

  /// 从磁盘缓存中获取数据和元数据。如果未找到或过期，则返回null。
  /// 返回一个元组：（compressedData, originalType）
  Future<L3HiveEntry?> get(String key) async {
    await _ensureInitialized();
    try {
      L3HiveEntry? entry;
      final Map? entryMap = _box!.get(key);
      if (entryMap != null) {
        entry = L3HiveEntry.fromMap(entryMap);
      }

      if (entry == null) {
        debugPrint("DiskCache: Get key '$key' - Not found.");
        return null;
      }

      final metaData = entry.metaData;

      // Check expiry
      if (metaData.isExpired) {
        debugPrint("DiskCache: Get key '$key' - Found but expired (${metaData.expiryTime}). Removing.");
        await remove(key); // Clean up expired entry
        return null;
      }

      debugPrint("DiskCache: Get key '$key' - Found and valid.");
      return entry;

    } catch (e, s) {
      // Handle potential Hive errors during get
      throw DiskCacheException("Failed to get key '$key' from Hive box '$_boxName'", originalException: e, stackTrace: s);
    }
  }

  /// 从磁盘缓存中删除条目
  Future<void> remove(String key) async {
    await _ensureInitialized();
    try {
      await _box!.delete(key);
      debugPrint("DiskCache: Removed key '$key'.");
    } catch (e, s) {
      // Log error, but might not need to throw, removal failure is less critical
      debugPrint("DiskCache: Failed to remove key '$key' from Hive box '$_boxName'. Error: $e \n StackTrace: $s");
      // Optionally rethrow:
      // throw DiskCacheException("Failed to remove key '$key' from Hive box '$_boxName'", originalException: e, stackTrace: s);
    }
  }

  /// 清除整个磁盘缓存
  Future<void> clear() async {
    await _ensureInitialized();
    try {
      final count = await _box!.clear();
      debugPrint("DiskCache: Cleared box '$_boxName'. $count entries removed.");
    } catch (e, s) {
      throw DiskCacheException("Failed to clear Hive box '$_boxName'", originalException: e, stackTrace: s);
    }
  }

  /// 从框中删除所有过期条目
  Future<void> pruneExpired() async {
    await _ensureInitialized();
    int removedCount = 0;
    // Iterating over keys and checking expiry is safer than iterating over values directly if modifying
    final List<String> keys = _box!.keys.cast<String>().toList(); // Get a snapshot of keys

    for (final key in keys) {
      final L3HiveEntry? entry = await get(key); // Get entry again to be safe
      if (entry != null && entry.metaData.isExpired) {
        try {
          await _box!.delete(key);
          removedCount++;
        } catch (e) {
          debugPrint("DiskCache: Error removing expired key '$key' during prune. Error: $e");
        }
      }
    }
    if (removedCount > 0) {
      debugPrint("DiskCache: Pruned $removedCount expired entries from '$_boxName'.");
    } else {
      debugPrint("DiskCache: Prune check complete. No expired entries found in '$_boxName'.");
    }
  }

  /// 关闭 Hive。当应用程序关闭或缓存被处理时调用这个
  Future<void> dispose() async {
    if (_box != null && _box!.isOpen) {
      await _box!.compact(); // Compact before closing
      await _box!.close();
      _isInitialized = false;
      debugPrint("DiskCacheManager: Box '$_boxName' closed.");
    }
  }
}