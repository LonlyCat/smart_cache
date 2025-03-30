

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'dart:collection';
import 'dart:convert';

import 'dart:async';

import 'model/cache_exceptions.dart';
import 'model/cache_config.dart';
import 'model/cache_entry.dart';
import 'model/cache_stats.dart';

import 'disk_cache_manager.dart';
import 'compression_utils.dart';

typedef FromJsonFactory = dynamic Function(Type type, Map<String, dynamic> json);

class SmartCacheManager {
  // --- Singleton Setup ---
  static SmartCacheManager? _instance;
  static final _lock = Lock(); // Simple lock for thread safety during init

  static SmartCacheManager get instance {
    if (_instance == null) {
      throw StateError(
          "SmartCacheManager not initialized. Call SmartCacheManager.initialize() first.");
    }
    return _instance!;
  }

  /// Initializes the singleton instance. Must be called once before use.
  static Future<void> initialize({
    required SmartCacheConfig config,
    FromJsonFactory? fromJsonFactory, // Optional initial factories
    Logger? logger, // Optional external logger
  }) async {
    if (_instance != null) {
      debugPrint("SmartCacheManager already initialized.");
      return;
    }
    // Use a lock to prevent race conditions if initialize is called concurrently
    await _lock.synchronized(() async {
      if (_instance == null) {
        config.validate(); // Validate config early
        final manager = SmartCacheManager._internal(config, logger);
        await manager._initializeDependencies(); // Initialize disk cache etc.
        if (fromJsonFactory != null) {
          manager.registerFromJsonFactorFactory(fromJsonFactory);
        }
        _instance = manager;
        manager._logInfo("SmartCacheManager initialized successfully.");
      }
    });
  }

  // --- Internal State ---
  final SmartCacheConfig _config;
  final Logger _logger; // Use provided logger or default

  // L1 Cache: Fast access, original objects. Use LinkedHashMap to maintain insertion order (for potential LRU later if needed)
  final LinkedHashMap<String, L1CacheEntry> _l1Cache = LinkedHashMap();

  // L2 Cache: Compressed objects in memory.
  final LinkedHashMap<String, L2CacheEntry> _l2Cache = LinkedHashMap();

  // L3 Cache: Disk cache manager
  late final DiskCacheManager _diskCacheManager;

  // Compression Utility
  late final CompressionUtils _compressionUtils;

  // Type Registry for Deserialization: Type -> Function(Map<String, dynamic>)
  FromJsonFactory? _fromJsonFactory;

  // Reverse lookup for disk cache type resolution
  final Map<String, Type> _typeNameToTypeRegistry = {};

  // Timer for periodic maintenance (downgrades, cleanup)
  Timer? _maintenanceTimer;

  // Flag to prevent concurrent maintenance runs
  bool _isMaintenanceRunning = false;
  final _maintenanceLock = Lock(); // Lock for maintenance cycle

  // Log level for the logger
  Level get _logLevel => _config.enableLogs ? Level.debug : Level.off;

  // --- Private Constructor ---
  SmartCacheManager._internal(this._config, Logger? logger) :
        _logger = logger ?? Logger( // Default logger config
          level: _config.enableLogs ? Level.debug : Level.off,
          printer: PrettyPrinter(
              methodCount: 1,
              errorMethodCount: 5,
              lineLength: 80,
              colors: true,
              printEmojis: true,
              dateTimeFormat: DateTimeFormat.dateAndTime), // Control log level via config
        );


  // --- Initialization Helper ---
  Future<void> _initializeDependencies() async {
    _diskCacheManager = DiskCacheManager(boxName: _config.diskCacheBoxName);
    _compressionUtils = CompressionUtils(useIsolate: _config.useIsolateForCompression);

    // Initialize Disk Cache (this also registers Hive adapters if done correctly)
    try {
      await _diskCacheManager.initialize();
    } catch (e) {
      _logError("Failed to initialize Disk Cache. L3 cache will be unavailable.", e);
      // Decide how to proceed: maybe throw, or operate without L3?
      // For robustness, let's log and continue without L3 functionality guaranteed.
      // However, get() calls trying L3 will fail if _ensureInitialized throws.
    }
  }

  // --- Logging Helpers ---
  void _logInfo(String message) {
    if (_config.enableLogs) _logger.i("[SmartCache] $message");
  }

  void _logWarning(String message) {
    if (_config.enableLogs) _logger.w("[SmartCache] $message");
  }

  void _logError(String message, [dynamic error, StackTrace? stackTrace]) {
    if (_config.enableLogs) _logger.e("[SmartCache] $message", error: error, stackTrace: stackTrace);
  }

  void _logDebug(String message) {
    if (_config.enableLogs && _logLevel == Level.debug) {
      _logger.d("[SmartCache] $message");
    }
  }


  // --- Type Factory Registration ---

  /// Registers a `fromJson` factory function for a given Type `T`.
  /// This is crucial for deserializing objects retrieved from L2/L3 cache.
  void registerFromJsonFactorFactory(FromJsonFactory factory) {
    if (_fromJsonFactory != null) {
      _logWarning("Replacing existing fromJson factory.");
    }
    _fromJsonFactory = factory;
    _logInfo("Registered fromJson factory.");
  }


  // --- Core Cache Operations ---

  /// Retrieves a cached item by key.
  /// Checks L1, L2, then L3 (Disk). Handles decompression and deserialization.
  /// Returns null if the item is not found or has expired in L3.
  /// Promotes items found in L2/L3 back to L1.
  Future<T?> get<T>(String key) async {
    _logDebug("Get request for key '$key', type $T");

    // 1. Check L1 (Memory Cache)
    L1CacheEntry? l1Entry = _l1Cache[key];
    if (l1Entry != null) {
      // Check type compatibility (important!)
      if (l1Entry.value is T) {
        _logDebug("L1 Hit for key '$key'. Updating access time.");
        l1Entry.touch();
        // Optional: Move to end if using LRU strategy with LinkedHashMap
        // _l1Cache.remove(key);
        // _l1Cache[key] = l1Entry;
        return l1Entry.value as T;
      } else {
        _logWarning("L1 Hit for key '$key', but type mismatch. "
            "Expected $T, found ${l1Entry.originalType}. Discarding entry.");
        await remove(key); // Remove inconsistent entry
        return null;
      }
    }

    // 2. Check L2 (Compressed Memory Cache)
    L2CacheEntry? l2Entry = _l2Cache[key];
    if (l2Entry != null) {
      // Check type compatibility *before* decompression
      if (l2Entry.originalType == T) {
        _logDebug("L2 Hit for key '$key'. Decompressing and promoting to L1.");
        try {
          // Decompress (potentially in Isolate)
          final String jsonData = await _compressionUtils.decompress(l2Entry.compressedData);

          // Deserialize (on main isolate)
          final T? value = _deserialize<T>(jsonData);

          if (value != null) {
            // Promote to L1
            final newL1Entry = L1CacheEntry<T>(
              key: key,
              value: value,
              originalType: T, // Use the requested type T
            );
            _l1Cache[key] = newL1Entry;
            _l2Cache.remove(key); // Remove from L2 after successful promotion
            _logDebug("L2 -> L1 Promotion successful for key '$key'.");
            return value;
          } else {
            // Deserialization failed (e.g., factory missing or JSON invalid)
            _logError("L2 Hit for key '$key', but deserialization failed. Removing entry.");
            await remove(key); // Remove corrupted/unusable entry
            return null;
          }
        } catch (e, s) {
          _logError("Error processing L2 entry for key '$key'. Removing entry.", e, s);
          await remove(key); // Remove on error
          return null;
        }
      } else {
        _logWarning("L2 Hit for key '$key', but type mismatch. "
            "Expected $T, found ${l2Entry.originalType}. Discarding entry.");
        await remove(key);
        return null;
      }
    }

    // 3. Check L3 (Disk Cache)
    try {
      final l3Result = await _diskCacheManager.get(key);
      if (l3Result != null) {
        // Check type compatibility
        if (l3Result.metaData.originalType == T.toString()) {
          _logDebug("L3 Hit for key '$key'. Decompressing and promoting to L1.");
          try {
            // Decompress
            final String jsonData = await _compressionUtils.decompress(l3Result.compressedData);
            // Deserialize
            final T? value = _deserialize<T>(jsonData);

            if (value != null) {
              // Promote to L1
              final newL1Entry = L1CacheEntry<T>(
                key: key,
                value: value,
                originalType: T,
              );
              _l1Cache[key] = newL1Entry;
              // Optional: Remove from L3 immediately after promotion?
              // Or let expiry handle it? Let expiry handle for simplicity.
              // await _diskCacheManager.remove(key);
              _logDebug("L3 -> L1 Promotion successful for key '$key'.");
              // 如果定时器当前没有运行，则启动它
              _ensureMaintenanceTimerRunning();
              return value;
            } else {
              _logError("L3 Hit for key '$key', but deserialization failed. Removing entry.");
              await remove(key); // Remove corrupted entry from disk
              return null;
            }
          } catch (e, s) {
            _logError("Error processing L3 entry for key '$key'. Removing entry.", e, s);
            await remove(key); // Remove on error
            return null;
          }

        } else {
          _logWarning("L3 Hit for key '$key', but type mismatch. "
              "Expected $T, found $T. Discarding entry.");
          await remove(key); // Remove inconsistent type from disk
          return null;
        }
      }
    } catch (e, s) {
      _logError("Error accessing L3 disk cache for key '$key'.", e, s);
      // Don't remove key here, the disk cache might be temporarily unavailable
      return null; // Return null if disk access fails
    }


    // 4. Not found in any cache
    _logDebug("Cache Miss for key '$key'.");
    return null;
  }


  /// Adds or updates an item in the L1 cache.
  /// Checks if the object has a `toJson` method.
  /// Removes the key from L2 and L3 if it exists there.
  Future<void> put<T>(String key, T value) async {
    _logDebug("Put request for key '$key', type $T");

    // --- toJson Method Check ---
    if (!(value is String || value is num || value is bool ||
        value is List || value is Map<String, dynamic>)) {
      if ((value as dynamic).toJson is! Function) {
        throw SerializationException(
            "Failed to cache object of type $T for key '$key'. "
                "It must have a 'toJson()' method returning 'Map<String, dynamic>' "
                "or be a JSON-encodable primitive/collection."
        );
      }
    }
    _logDebug("toJson check passed for key '$key'.");
    // --- End toJson Check ---


    // Remove from lower caches to prevent stale data
    if (_l2Cache.containsKey(key)) {
      _logDebug("Removing key '$key' from L2 due to new put.");
      _l2Cache.remove(key);
    }


    // 添加到 L1
    final entry = L1CacheEntry<T>(key: key, value: value, originalType: T);
    _l1Cache[key] = entry;
    _logInfo("Put successful for key '$key' into L1.");

    // 如果定时器当前没有运行，则启动它
    _ensureMaintenanceTimerRunning();
  }


  /// Synchronously retrieves an item ONLY from the L1 cache.
  /// Returns null if not found in L1 or if type doesn't match.
  /// Useful for immediate access where disk latency is unacceptable.
  T? getSync<T>(String key) {
    _logDebug("GetSync request for key '$key', type $T");
    L1CacheEntry? l1Entry = _l1Cache[key];
    if (l1Entry != null) {
      if (l1Entry.value is T) {
        _logDebug("L1 Sync Hit for key '$key'.");
        l1Entry.touch(); // Still update access time
        return l1Entry.value as T;
      } else {
        _logWarning("L1 Sync Hit for key '$key', but type mismatch. Expected $T, found ${l1Entry.originalType}.");
        // Don't remove here, let async `get` or maintenance handle it
        return null;
      }
    }
    _logDebug("L1 Sync Miss for key '$key'.");
    return null;
  }


  /// Removes an item from all cache levels (L1, L2, L3).
  Future<void> remove(String key) async {
    _logInfo("Remove request for key '$key'.");
    bool removed = false;
    // Remove from L1
    if (_l1Cache.remove(key) != null) {
      _logDebug("Removed key '$key' from L1.");
      removed = true;
    }
    // Remove from L2
    if (_l2Cache.remove(key) != null) {
      _logDebug("Removed key '$key' from L2.");
      removed = true;
    }
    // Remove from L3
    try {
      // Assuming DiskCacheManager.remove handles non-existent keys gracefully
      await _diskCacheManager.remove(key);
      _logDebug("Removed key '$key' from L3 (if exists).");
      // Consider L3 remove failure? Logged in disk manager.
    } catch (e, s) {
      _logError("Failed to remove key '$key' from L3 disk cache during explicit remove.", e, s);
      // Propagate? Or just log? Let's just log for now.
    }
    if (!removed) {
      _logDebug("Key '$key' not found in L1 or L2 during remove request.");
    }
  }

  /// Clears all cache levels.
  Future<void> clear() async {
    _logInfo("Clear request received. Clearing all caches.");
    // Clear L1
    final l1Count = _l1Cache.length;
    _l1Cache.clear();
    _logDebug("Cleared L1 cache ($l1Count items).");

    // Clear L2
    final l2Count = _l2Cache.length;
    _l2Cache.clear();
    _logDebug("Cleared L2 cache ($l2Count items).");

    // Clear L3
    try {
      await _diskCacheManager.clear();
      _logDebug("Cleared L3 disk cache.");
    } catch (e, s) {
      _logError("Failed to clear L3 disk cache.", e, s);
      // Should this be thrown? Maybe not critical for app function.
    }
    _logInfo("All caches cleared.");
  }

  /// Returns the items currently in each cache level.
  CacheStats getStats() {
    return CacheStats(
      l3Count: _diskCacheManager.length(),
      l1Cache: _l1Cache.map((key, entry) => MapEntry(key, entry.value)),
      l2Cache: _l2Cache.map((key, entry) => MapEntry(key, entry.compressedData)),
    );
  }

  // --- Deserialization Helper ---
  T? _deserialize<T>(String jsonData) {
    if (_fromJsonFactory == null) {
      _logError("Cannot deserialize key: No fromJson factory registered for type $T.");
      throw DeserializationException("No fromJson factory registered for type $T.");
      // return null; // Or throw? Throwing is better for identifying setup errors
    }

    try {
      dynamic data = jsonDecode(jsonData);
      if (T is String || T is num || T is bool ||
          T is List || T is Map<String, dynamic>) {
        // Directly return the primitive or collection
        return data as T;
      }
      final Map<String, dynamic> jsonMap = data as Map<String, dynamic>;
      T? object = _fromJsonFactory!(T, jsonMap);
      return object;
    } catch (e, s) {
      _logError("Error during JSON decoding or factory execution for type $T.", e, s);
      // Don't remove cache entry here, let the caller handle failure.
      // Re-throw a specific exception?
      throw DeserializationException(
          "Failed to deserialize JSON for type $T.",
          originalException: e, stackTrace: s
      );
      // return null;
    }
  }

  // --- Serialization Helper ---
  String? _serialize<T>(T value) {
    try {
      // Handle primitives/basic types directly
      if (value is String || value is num || value is bool) {
        return jsonEncode(value); // Direct encoding
      }
      if (value is List || value is Map) {
        // Assume Lists/Maps contain JSON-encodable types or objects with toJson
        return jsonEncode(value);
      }

      // For custom objects, rely on the checked toJson method
      final dynamic jsonMap = (value as dynamic).toJson();
      if (jsonMap is! Map<String, dynamic>) {
        // This check should ideally happen in `put`, but double-check here
        _logError("Serialization error: toJson() for ${value.runtimeType} did not return Map<String, dynamic>.");
        return null;
      }
      return jsonEncode(jsonMap);
    } catch (e, s) {
      _logError("Serialization failed for object of type ${value.runtimeType}.", e, s);
      // This typically indicates a bad toJson implementation or un-encodable data within the object
      return null; // Return null to indicate failure
    }
  }


  // --- Background Maintenance ---

  /// 确保后台维护定时器正在运行。如果未运行，则启动它。
  /// 这是幂等的，如果定时器已激活，则不执行任何操作。
  void _ensureMaintenanceTimerRunning() {
    // 检查定时器是否已经是活动的
    if (_maintenanceTimer?.isActive ?? false) {
      return; // 如果已经在运行，则无需操作
    }

    _logInfo("检测到缓存活动，启动后台维护定时器 (间隔: ${_config.maintenanceInterval})...");
    _maintenanceTimer = Timer.periodic(_config.maintenanceInterval, (_) async {
      // 使用锁防止重叠执行
      if (_isMaintenanceRunning) {
        _logDebug("跳过维护周期，因为上一个周期仍在运行。");
        return;
      }
      await _maintenanceLock.synchronized(() async {
        _isMaintenanceRunning = true;
        _logDebug("开始维护周期...");
        try {
          await _runDowngradeL1ToL2();
          await _runDowngradeL2ToL3();
          await _diskCacheManager.pruneExpired(); // 清理 L3 过期项
        } catch (e, s) {
          _logError("维护周期中发生错误。", e, s);
        } finally {
          _isMaintenanceRunning = false;
          _logDebug("维护周期结束。");

          // 如果 L1 和 L2 都为空，说明没有需要维护的内存缓存了
          if (_l1Cache.isEmpty && _l2Cache.isEmpty) {
            _logInfo("缓存处于空闲状态 (L1 和 L2 为空)，停止维护定时器。");
            _stopMaintenanceTimer(); // 停止定时器
          }
        }
      });
    });
  }

  /// 停止并取消当前的后台维护定时器。
  void _stopMaintenanceTimer() {
    // 检查定时器是否存在并且是活动的
    if (_maintenanceTimer != null) {
      _maintenanceTimer!.cancel();
      _maintenanceTimer = null;
      _logInfo("已停止后台维护定时器。");
    }
  }

  /// Downgrades eligible items from L1 to L2 using batch compression.
  Future<void> _runDowngradeL1ToL2() async {
    final now = DateTime.now();
    // Map to hold {key: jsonDataString} for items ready for compression
    final Map<String, String> itemsToCompress = {};
    // Map to hold {key: originalL1Entry} for successful serialization, needed for type info later
    final Map<String, L1CacheEntry> successfullySerializedEntries = {};
    // List of keys that failed serialization
    final List<String> serializationFailedKeys = [];


    _logDebug("L1->L2: Checking for items to downgrade...");

    // --- Step 1: Identify and Serialize Eligible Items (Main Thread) ---
    final currentKeys = _l1Cache.keys.toList(); // Iterate safely
    for (final key in currentKeys) {
      final entry = _l1Cache[key];
      if (entry == null) continue; // Safety check

      if (now.difference(entry.lastAccessTime) > _config.l1DowngradeDuration) {
        _logDebug("L1->L2: Key '$key' eligible for downgrade attempt.");
        // Serialize *before* adding to the batch
        final String? jsonData = _serialize(entry.value);
        if (jsonData == null) {
          // Serialization failed (e.g., bad toJson) - Log error and mark for removal
          _logError("L1->L2: Serialization failed for key '$key', type ${entry.originalType}. Marking for removal from L1.");
          serializationFailedKeys.add(key);
        } else {
          // Serialization successful - add to batch and store entry info
          itemsToCompress[key] = jsonData;
          successfullySerializedEntries[key] = entry;
          _logDebug("L1->L2: Key '$key' serialized successfully, added to compression batch.");
        }
      }
    }

    // Remove items that failed serialization immediately from L1
    if (serializationFailedKeys.isNotEmpty) {
      _logWarning("L1->L2: Removing ${serializationFailedKeys.length} items from L1 due to serialization failure.");
      for (final key in serializationFailedKeys) {
        _l1Cache.remove(key);
      }
    }

    if (itemsToCompress.isEmpty) {
      _logDebug("L1->L2: No items eligible or successfully serialized for downgrade compression.");
      return;
    }
    _logInfo("L1->L2: Attempting to compress batch of ${itemsToCompress.length} items.");


    // --- Step 2: Compress Batch (Potentially in Isolate) ---
    Map<String, Uint8List> compressedResults = {};
    try {
      compressedResults = await _compressionUtils.compressBatch(itemsToCompress);
      _logInfo("L1->L2: Batch compression finished. ${compressedResults.length} items successfully compressed.");
    } catch (e, s) {
      _logError("L1->L2: Critical error during batch compression execution. No items downgraded in this cycle.", e, s);
      // Don't modify L1 or L2 cache if the whole batch operation failed. Items remain in L1.
      return; // Exit the downgrade process for L1->L2 this cycle
    }


    // --- Step 3: Process Successful Compressions (Update L1/L2) ---
    int downgradeSuccessCount = 0;
    for (final key in compressedResults.keys) {
      final compressedData = compressedResults[key];
      final originalEntry = successfullySerializedEntries[key]; // Get original type info

      if (compressedData != null && originalEntry != null) {
        // Create L2 Entry
        final l2Entry = L2CacheEntry(
          key: key,
          compressedData: compressedData,
          originalType: originalEntry.originalType, // Use stored type
        );

        // Add to L2 and remove from L1 (atomic-like operation for this key)
        _l2Cache[key] = l2Entry;
        _l1Cache.remove(key);
        downgradeSuccessCount++;
        _logDebug("L1->L2: Successfully downgraded key '$key'.");
      } else {
        // This case shouldn't happen if key is in compressedResults, but defensive check
        _logWarning("L1->L2: Inconsistency found for key '$key' after batch compression. Skipping.");
      }
    }

    // Log summary and identify failures (items missing from results)
    final int failureCount = itemsToCompress.length - downgradeSuccessCount;
    if (failureCount > 0) {
      _logWarning("L1->L2: $failureCount items failed during the compression stage within the batch (check isolate logs for details). They remain in L1.");
      // Optionally list the keys that failed if needed for debugging:
      // final failedKeys = itemsToCompress.keys.where((k) => !compressedResults.containsKey(k)).toList();
      // _logDebug("L1->L2: Failed compression keys: $failedKeys");
    } else if (downgradeSuccessCount > 0) {
      _logInfo("L1->L2: Successfully downgraded $downgradeSuccessCount items.");
    } else {
      _logInfo("L1->L2: No items were successfully downgraded in this cycle after compression attempt.");
    }
  }

  /// Downgrades eligible items from L2 to L3 (Disk).
  Future<void> _runDowngradeL2ToL3() async {
    final now = DateTime.now();
    final List<String> keysToDowngrade = [];
    final Map<String, L2CacheEntry> entriesToProcess = {};

    final currentKeys = _l2Cache.keys.toList();
    for (final key in currentKeys) {
      final entry = _l2Cache[key];
      if (entry == null) continue;

      if (now.difference(entry.lastAccessTime) > _config.l2DowngradeDuration) {
        _logDebug("L2->L3: Key '$key' eligible for downgrade (idle > ${_config.l2DowngradeDuration}).");
        keysToDowngrade.add(key);
        entriesToProcess[key] = entry;
      }
    }

    if (keysToDowngrade.isEmpty) {
      _logDebug("L2->L3: No items eligible for downgrade.");
      return;
    }
    _logInfo("L2->L3: Found ${keysToDowngrade.length} items to downgrade.");

    // Process downgrades (write to disk)
    for (final key in keysToDowngrade) {
      final entry = entriesToProcess[key];
      if (entry == null) continue;

      try {
        // Write compressed data from L2 directly to L3 disk cache
        await _diskCacheManager.put(
          key,
          entry.compressedData,
          entry.originalType,
          _config.l3DefaultExpiryDuration, // Use default expiry for L3
        );

        // Remove from L2 after successful write to L3
        _l2Cache.remove(key);
        _logDebug("L2->L3: Successfully downgraded key '$key' to disk.");

      } catch (e, s) {
        _logError("L2->L3: Error downgrading key '$key' to disk. Keeping in L2 for now.", e, s);
        // Don't remove from L2 if disk write fails, maybe retry next cycle?
      }
    }
  }

  /// Dispose resources, close Hive box, stop timer.
  Future<void> dispose() async {
    _logInfo("Disposing SmartCacheManager...");
    _stopMaintenanceTimer();
    await _diskCacheManager.dispose();
    _l1Cache.clear();
    _l2Cache.clear();
    _typeNameToTypeRegistry.clear();
    _fromJsonFactory = null;
    _instance = null; // Allow re-initialization if needed (though usually not)
    _logInfo("SmartCacheManager disposed.");
  }
}

// Simple async lock class (can be replaced with more robust implementations if needed)
class Lock {
  Completer<void>? _completer;

  Future<void> synchronized(FutureOr<void> Function() action) async {
    // Wait if lock is currently held
    while (_completer != null) {
      await _completer!.future;
    }

    // Acquire lock
    _completer = Completer<void>();

    try {
      await action();
    } finally {
      // Release lock
      final completer = _completer;
      _completer = null;
      completer?.complete(); // Signal waiting futures
    }
  }
}