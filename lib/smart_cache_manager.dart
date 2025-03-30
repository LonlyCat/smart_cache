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
  // --- 单例模式设置 ---
  static SmartCacheManager? _instance;
  // 用于线程安全的简单锁，在初始化时使用
  static final _lock = Lock();

  static SmartCacheManager get instance {
    if (_instance == null) {
      throw StateError(
          "SmartCacheManager 未初始化。请先调用 SmartCacheManager.initialize()。");
    }
    return _instance!;
  }

  /// 初始化单例实例。必须在使用前调用一次。
  static Future<void> initialize({
    required SmartCacheConfig config,
    FromJsonFactory? fromJsonFactory, // 可选的初始工厂函数
    Logger? logger, // 可选的外部日志记录器
  }) async {
    if (_instance != null) {
      debugPrint("SmartCacheManager 已初始化。");
      return;
    }
    // 使用锁来防止并发调用 initialize 时的竞争条件
    await _lock.synchronized(() async {
      if (_instance == null) {
        config.validate(); // 尽早验证配置
        final manager = SmartCacheManager._internal(config, logger);
        await manager._initializeDependencies(); // 初始化磁盘缓存等依赖
        if (fromJsonFactory != null) {
          manager.registerFromJsonFactorFactory(fromJsonFactory);
        }
        _instance = manager;
        manager._logInfo("SmartCacheManager 初始化成功。");
      }
    });
  }

  // --- 内部状态 ---
  final SmartCacheConfig _config;
  final Logger _logger;

  // L1 缓存：快速访问，原始对象。使用 LinkedHashMap 维护插入顺序（如果以后需要 LRU 策略）
  final LinkedHashMap<String, L1CacheEntry> _l1Cache = LinkedHashMap();

  // L2 缓存：内存中的压缩对象。
  final LinkedHashMap<String, L2CacheEntry> _l2Cache = LinkedHashMap();

  // L3 缓存：磁盘缓存管理器
  late final DiskCacheManager _diskCacheManager;

  // 压缩工具
  late final CompressionUtils _compressionUtils;

  // 用于反序列化的类型注册表：Type -> Function(Map<String, dynamic>)
  FromJsonFactory? _fromJsonFactory;

  // 用于磁盘缓存类型解析的反向查找
  final Map<String, Type> _typeNameToTypeRegistry = {};

  // 定时器，用于定期维护（降级、清理）
  Timer? _maintenanceTimer;

  // 标志，防止维护任务并发运行
  bool _isMaintenanceRunning = false;
  final _maintenanceLock = Lock(); // 维护周期的锁

  // 日志记录器的日志级别
  Level get _logLevel => _config.enableLogs ? Level.debug : Level.off;

  // --- 私有构造函数 ---
  SmartCacheManager._internal(this._config, Logger? logger) :
        _logger = logger ?? Logger( // 默认日志记录器配置
          level: _config.enableLogs ? Level.debug : Level.off,
          printer: PrettyPrinter(
              methodCount: 1,
              errorMethodCount: 5,
              lineLength: 80,
              colors: true,
              printEmojis: true,
              printTime: true), // 通过配置控制日志级别
        );

  // --- 初始化辅助方法 ---
  Future<void> _initializeDependencies() async {
    _diskCacheManager = DiskCacheManager(boxName: _config.diskCacheBoxName);
    _compressionUtils = CompressionUtils(useIsolate: _config.useIsolateForCompression);

    // 初始化磁盘缓存（如果正确完成，也会注册 Hive 适配器）
    try {
      await _diskCacheManager.initialize();
    } catch (e) {
      // 为了健壮性，记录日志并继续运行，但不保证 L3 功能。
      // 如果 _ensureInitialized 抛出异常，get() 调用尝试 L3 时会失败。
      _logError("初始化磁盘缓存失败。L3 缓存将不可用。", e);
    }
  }

  // --- 类型工厂注册 ---

  /// 为给定的类型 `T` 注册一个 `fromJson` 工厂函数。
  /// 这对于从 L2/L3 缓存中检索对象时的反序列化至关重要。
  void registerFromJsonFactorFactory(FromJsonFactory factory) {
    if (_fromJsonFactory != null) {
      _logWarning("正在替换现有的 fromJson 工厂函数。");
    }
    _fromJsonFactory = factory;
    _logInfo("已注册 fromJson 工厂函数。");
  }

  // --- 核心缓存操作 ---

  /// 通过键检索缓存项。
  /// 按顺序检查 L1、L2、L3（磁盘）。处理解压缩和反序列化。
  /// 如果项未找到或在 L3 中已过期，则返回 null。
  /// 将在 L2/L3 中找到的项提升回 L1。
  Future<T?> get<T>(String key) async {
    _logDebug("获取请求：键 '$key'，类型 $T");

    // 1. 检查 L1（内存缓存）
    L1CacheEntry? l1Entry = _l1Cache[key];
    if (l1Entry != null) {
      // 检查类型兼容性（重要！）
      if (l1Entry.value is T) {
        _logDebug("L1 命中：键 '$key'。更新访问时间。");
        l1Entry.touch();
        // 可选：如果使用 LRU 策略，可以将键移到末尾
        // _l1Cache.remove(key);
        // _l1Cache[key] = l1Entry;
        return l1Entry.value as T;
      } else {
        _logWarning("L1 命中：键 '$key'，但类型不匹配。预期 $T，实际 ${l1Entry.originalType}。丢弃条目。");
        await remove(key); // 移除不一致的条目
        return null;
      }
    }

    // 2. 检查 L2（压缩内存缓存）
    L2CacheEntry? l2Entry = _l2Cache[key];
    if (l2Entry != null) {
      // 在解压缩前检查类型兼容性
      if (l2Entry.originalType == T) {
        _logDebug("L2 命中：键 '$key'。正在解压缩并提升到 L1。");
        try {
          // 解压缩（可能在隔离线程中进行）
          final String jsonData = await _compressionUtils.decompress(l2Entry.compressedData);

          // 反序列化（在主隔离线程上）
          final T? value = _deserialize<T>(jsonData);

          if (value != null) {
            // 提升到 L1
            final newL1Entry = L1CacheEntry<T>(
              key: key,
              value: value,
              originalType: T, // 使用请求的类型 T
            );
            _l1Cache[key] = newL1Entry;
            _l2Cache.remove(key); // 成功提升后从 L2 移除
            _logDebug("L2 -> L1 提升成功：键 '$key'。");
            return value;
          } else {
            // 反序列化失败（例如，缺少工厂或 JSON 无效）
            _logError("L2 命中：键 '$key'，但反序列化失败。移除条目。");
            await remove(key); // 移除损坏/不可用的条目
            return null;
          }
        } catch (e, s) {
          _logError("处理 L2 条目时出错：键 '$key'。移除条目。", e, s);
          await remove(key); // 出错时移除
          return null;
        }
      } else {
        _logWarning("L2 命中：键 '$key'，但类型不匹配。预期 $T，实际 ${l2Entry.originalType}。丢弃条目。");
        await remove(key);
        return null;
      }
    }

    // 3. 检查 L3（磁盘缓存）
    try {
      final l3Result = await _diskCacheManager.get(key);
      if (l3Result != null) {
        // 检查类型兼容性
        if (l3Result.metaData.originalType == T.toString()) {
          _logDebug("L3 命中：键 '$key'。正在解压缩并提升到 L1。");
          try {
            // 解压缩
            final String jsonData = await _compressionUtils.decompress(l3Result.compressedData);
            // 反序列化
            final T? value = _deserialize<T>(jsonData);

            if (value != null) {
              // 提升到 L1
              final newL1Entry = L1CacheEntry<T>(
                key: key,
                value: value,
                originalType: T,
              );
              _l1Cache[key] = newL1Entry;
              // 可选：在提升后立即从 L3 移除？
              // 或者让过期机制处理？为简单起见，交给过期处理。
              // await _diskCacheManager.remove(key);
              _logDebug("L3 -> L1 提升成功：键 '$key'。");
              // 如果定时器当前未运行，则启动它
              _ensureMaintenanceTimerRunning();
              return value;
            } else {
              _logError("L3 命中：键 '$key'，但反序列化失败。移除条目。");
              await remove(key); // 从磁盘移除损坏的条目
              return null;
            }
          } catch (e, s) {
            _logError("处理 L3 条目时出错：键 '$key'。移除条目。", e, s);
            await remove(key); // 出错时移除
            return null;
          }
        } else {
          _logWarning("L3 命中：键 '$key'，但类型不匹配。预期 $T，实际 $T。丢弃条目。");
          await remove(key); // 从磁盘移除不一致的类型
          return null;
        }
      }
    } catch (e, s) {
      _logError("访问 L3 磁盘缓存时出错：键 '$key'。", e, s);
      // 这里不移除键，因为磁盘缓存可能只是暂时不可用
      return null; // 如果磁盘访问失败，返回 null
    }

    // 4. 在任何缓存中都未找到
    _logDebug("缓存未命中：键 '$key'。");
    return null;
  }

  /// 通过键检索缓存项。
  /// 注意: 当 [deepSearch] 为 true 时，L2 和 L3 将使用同步 API 搜索，可能会阻塞 UI 线程。
  T? getSync<T>(String key, { bool deepSearch = false }) {
    _logDebug("同步获取请求：键 '$key'，类型 $T");
    L1CacheEntry? l1Entry = _l1Cache[key];
    if (l1Entry != null) {
      if (l1Entry.value is T) {
        _logDebug("L1 同步命中：键 '$key'。");
        l1Entry.touch(); // 仍然更新访问时间
        return l1Entry.value as T;
      } else {
        _logWarning("L1 同步命中：键 '$key'，但类型不匹配。预期 $T，实际 ${l1Entry.originalType}。");
        remove(key); // 移除不一致的条目
        return null;
      }
    }
    _logDebug("L1 同步未命中：键 '$key'。");
    if (!deepSearch) {
      return null; // 如果不深度搜索，直接返回 null
    }

    // 2. 检查 L2（压缩内存缓存）
    L2CacheEntry? l2Entry = _l2Cache[key];
    if (l2Entry != null) {
      // 在解压缩前检查类型兼容性
      if (l2Entry.originalType == T) {
        _logDebug("L2 命中：键 '$key'。正在解压缩并提升到 L1。");
        try {
          // 在主线程解压缩
          final String jsonData = _compressionUtils.decompressSync(l2Entry.compressedData);

          // 反序列化
          final T? value = _deserialize<T>(jsonData);

          if (value != null) {
            // 提升到 L1
            final newL1Entry = L1CacheEntry<T>(
              key: key,
              value: value,
              originalType: T, // 使用请求的类型 T
            );
            _l1Cache[key] = newL1Entry;
            _l2Cache.remove(key); // 成功提升后从 L2 移除
            _logDebug("L2 -> L1 提升成功：键 '$key'。");
            return value;
          } else {
            // 反序列化失败（例如，缺少工厂或 JSON 无效）
            _logError("L2 命中：键 '$key'，但反序列化失败。移除条目。");
            remove(key); // 移除损坏/不可用的条目
            return null;
          }
        } catch (e, s) {
          _logError("处理 L2 条目时出错：键 '$key'。移除条目。", e, s);
          remove(key); // 出错时移除
          return null;
        }
      } else {
        _logWarning("L2 命中：键 '$key'，但类型不匹配。预期 $T，实际 ${l2Entry.originalType}。丢弃条目。");
        remove(key);
        return null;
      }
    }

    // 3. 检查 L3（磁盘缓存）
    try {
      final l3Result = _diskCacheManager.getSync(key);
      if (l3Result != null) {
        // 检查类型兼容性
        if (l3Result.metaData.originalType == T.toString()) {
          _logDebug("L3 命中：键 '$key'。正在解压缩并提升到 L1。");
          try {
            // 解压缩
            final String jsonData = _compressionUtils.decompressSync(l3Result.compressedData);
            // 反序列化
            final T? value = _deserialize<T>(jsonData);

            if (value != null) {
              // 提升到 L1
              final newL1Entry = L1CacheEntry<T>(
                key: key,
                value: value,
                originalType: T,
              );
              _l1Cache[key] = newL1Entry;
              // 可选：在提升后立即从 L3 移除？
              // 或者让过期机制处理？为简单起见，交给过期处理。
              // await _diskCacheManager.remove(key);
              _logDebug("L3 -> L1 提升成功：键 '$key'。");
              // 如果定时器当前未运行，则启动它
              _ensureMaintenanceTimerRunning();
              return value;
            } else {
              _logError("L3 命中：键 '$key'，但反序列化失败。移除条目。");
              remove(key); // 从磁盘移除损坏的条目
              return null;
            }
          } catch (e, s) {
            _logError("处理 L3 条目时出错：键 '$key'。移除条目。", e, s);
            remove(key); // 出错时移除
            return null;
          }
        } else {
          _logWarning("L3 命中：键 '$key'，但类型不匹配。预期 $T，实际 $T。丢弃条目。");
          remove(key); // 从磁盘移除不一致的类型
          return null;
        }
      }
    } catch (e, s) {
      _logError("访问 L3 磁盘缓存时出错：键 '$key'。", e, s);
      // 这里不移除键，因为磁盘缓存可能只是暂时不可用
      return null; // 如果磁盘访问失败，返回 null
    }

    // 4. 在任何缓存中都未找到
    _logDebug("缓存未命中：键 '$key'。");
    return null;
  }

  /// 在 L1 缓存中添加或更新项。
  /// 检查对象是否具有 `toJson` 方法。
  /// 如果键存在于 L2 中，则从中移除。
  Future<void> put<T>(String key, T value) async {
    _logDebug("放入请求：键 '$key'，类型 $T");

    // --- 检查 toJson 方法 ---
    if (!(value is String || value is num || value is bool ||
        value is List || value is Map<String, dynamic>)) {
      if ((value as dynamic).toJson is! Function) {
        throw SerializationException(
            "无法缓存键 '$key' 的类型 $T 对象。它必须具有返回 'Map<String, dynamic>' 的 'toJson()' 方法，或是 JSON 可编码的原始类型/集合。");
      }
    }
    _logDebug("键 '$key' 的 toJson 检查通过。");
    // --- 结束 toJson 检查 ---

    // 从较低层缓存中移除，以防止数据过时
    if (_l2Cache.containsKey(key)) {
      _logDebug("由于新的放入操作，从 L2 移除键 '$key'。");
      _l2Cache.remove(key);
    }

    // 添加到 L1
    final entry = L1CacheEntry<T>(key: key, value: value, originalType: T);
    _l1Cache[key] = entry;
    _logInfo("放入成功：键 '$key' 已存入 L1。");

    // 如果定时器当前未运行，则启动它
    _ensureMaintenanceTimerRunning();
  }

  /// 从所有缓存层（L1、L2、L3）中移除项。
  Future<void> remove(String key) async {
    _logInfo("移除请求：键 '$key'。");
    bool removed = false;
    // 从 L1 移除
    if (_l1Cache.remove(key) != null) {
      _logDebug("从 L1 移除键 '$key'。");
      removed = true;
    }
    // 从 L2 移除
    if (_l2Cache.remove(key) != null) {
      _logDebug("从 L2 移除键 '$key'。");
      removed = true;
    }
    // 从 L3 移除
    try {
      // 假设 DiskCacheManager.remove 能优雅处理不存在的键
      await _diskCacheManager.remove(key);
      _logDebug("从 L3 移除键 '$key'（如果存在）。");
      // 考虑 L3 移除失败的情况？在磁盘管理器中记录。
    } catch (e, s) {
      _logError("显式移除期间，从 L3 磁盘缓存移除键 '$key' 失败。", e, s);
      // 抛出异常还是仅记录？暂时仅记录。
    }
    if (!removed) {
      _logDebug("移除请求期间，键 '$key' 在 L1 或 L2 中未找到。");
    }
  }

  /// 清除所有缓存层。
  Future<void> clear() async {
    _logInfo("收到清除请求。正在清除所有缓存。");
    // 清除 L1
    final l1Count = _l1Cache.length;
    _l1Cache.clear();
    _logDebug("已清除 L1 缓存（$l1Count 项）。");

    // 清除 L2
    final l2Count = _l2Cache.length;
    _l2Cache.clear();
    _logDebug("已清除 L2 缓存（$l2Count 项）。");

    // 清除 L3
    try {
      await _diskCacheManager.clear();
      _logDebug("已清除 L3 磁盘缓存。");
    } catch (e, s) {
      _logError("清除 L3 磁盘缓存失败。", e, s);
      // 是否应抛出异常？可能对应用功能不关键。
    }
    _logInfo("所有缓存已清除。");
  }

  /// 返回当前每个缓存层中的项。
  CacheStats getStats() {
    return CacheStats(
      l3Count: _diskCacheManager.length(),
      l1Cache: _l1Cache.map((key, entry) => MapEntry(key, entry.value)),
      l2Cache: _l2Cache.map((key, entry) => MapEntry(key, entry.compressedData)),
    );
  }

  // --- 反序列化辅助方法 ---
  T? _deserialize<T>(String jsonData) {
    if (_fromJsonFactory == null) {
      _logError("无法反序列化键：未为类型 $T 注册 fromJson 工厂函数。");
      throw DeserializationException("未为类型 $T 注册 fromJson 工厂函数。");
      // return null; // 或者抛出异常？抛出更好，以便识别设置错误
    }

    try {
      dynamic data = jsonDecode(jsonData);
      if (T is String || T is num || T is bool ||
          T is List || T is Map<String, dynamic>) {
        // 直接返回原始类型或集合
        return data as T;
      }
      final Map<String, dynamic> jsonMap = data as Map<String, dynamic>;
      T? object = _fromJsonFactory!(T, jsonMap);
      return object;
    } catch (e, s) {
      _logError("JSON 解码或工厂执行期间出错：类型 $T。", e, s);
      // 这里不移除缓存条目，让调用者处理失败。
      // 重新抛出特定异常？
      throw DeserializationException(
          "为类型 $T 反序列化 JSON 失败。",
          originalException: e, stackTrace: s
      );
      // return null;
    }
  }

  // --- 序列化辅助方法 ---
  String? _serialize<T>(T value) {
    try {
      // 直接处理原始类型/基本类型
      if (value is String || value is num || value is bool) {
        return jsonEncode(value); // 直接编码
      }
      if (value is List || value is Map) {
        // 假设列表/映射包含 JSON 可编码类型或具有 toJson 的对象
        return jsonEncode(value);
      }

      // 对于自定义对象，依赖已检查的 toJson 方法
      final dynamic jsonMap = (value as dynamic).toJson();
      if (jsonMap is! Map<String, dynamic>) {
        // 此检查应在 `put` 中进行，但这里再次确认
        _logError("序列化错误：${value.runtimeType} 的 toJson() 未返回 Map<String, dynamic>。");
        return null;
      }
      return jsonEncode(jsonMap);
    } catch (e, s) {
      _logError("对象类型 ${value.runtimeType} 的序列化失败。", e, s);
      // 这通常表明 toJson 实现有问题或对象中包含不可编码的数据
      return null; // 返回 null 表示失败
    }
  }

  // --- 后台维护 ---

  /// 确保后台维护定时器正在运行。如果未运行，则启动它。
  /// 此方法是幂等的，如果定时器已激活，则不执行任何操作。
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

  /// 将符合条件的项从 L1 降级到 L2，使用批量压缩。
  Future<void> _runDowngradeL1ToL2() async {
    final now = DateTime.now();
    // 用于保存 {键: jsonDataString} 的映射，包含准备压缩的项
    final Map<String, String> itemsToCompress = {};
    // 用于保存 {键: 原始L1条目} 的映射，序列化成功后需要类型信息
    final Map<String, L1CacheEntry> successfullySerializedEntries = {};
    // 序列化失败的键列表
    final List<String> serializationFailedKeys = [];

    _logDebug("L1->L2：检查需要降级的项...");

    // --- 步骤 1：识别并序列化符合条件的项（主线程） ---
    final currentKeys = _l1Cache.keys.toList(); // 安全迭代
    for (final key in currentKeys) {
      final entry = _l1Cache[key];
      if (entry == null) continue; // 安全检查

      if (now.difference(entry.lastAccessTime) > _config.l1DowngradeDuration) {
        _logDebug("L1->L2：键 '$key' 符合降级条件。");
        // 在加入批量前序列化
        final String? jsonData = _serialize(entry.value);
        if (jsonData == null) {
          // 序列化失败（例如，toJson 错误）- 记录错误并标记移除
          _logError("L1->L2：键 '$key'，类型 ${entry.originalType} 的序列化失败。从 L1 标记移除。");
          serializationFailedKeys.add(key);
        } else {
          // 序列化成功 - 添加到批量并存储条目信息
          itemsToCompress[key] = jsonData;
          successfullySerializedEntries[key] = entry;
          _logDebug("L1->L2：键 '$key' 序列化成功，已添加到压缩批次。");
        }
      }
    }

    // 立即从 L1 移除序列化失败的项
    if (serializationFailedKeys.isNotEmpty) {
      _logWarning("L1->L2：因序列化失败，从 L1 移除 ${serializationFailedKeys.length} 个项。");
      for (final key in serializationFailedKeys) {
        _l1Cache.remove(key);
      }
    }

    if (itemsToCompress.isEmpty) {
      _logDebug("L1->L2：没有符合条件或成功序列化的项可用于降级压缩。");
      return;
    }
    _logInfo("L1->L2：尝试压缩 ${itemsToCompress.length} 个项的批次。");

    // --- 步骤 2：批量压缩（可能在隔离线程中） ---
    Map<String, Uint8List> compressedResults = {};
    try {
      compressedResults = await _compressionUtils.compressBatch(itemsToCompress);
      _logInfo("L1->L2：批次压缩完成。成功压缩 ${compressedResults.length} 个项。");
    } catch (e, s) {
      _logError("L1->L2：批次压缩执行期间发生严重错误。本周期内没有项被降级。", e, s);
      // 如果整个批量操作失败，不修改 L1 或 L2 缓存。项保留在 L1。
      return; // 退出本周期的 L1->L2 降级过程
    }

    // --- 步骤 3：处理成功压缩的结果（更新 L1/L2） ---
    int downgradeSuccessCount = 0;
    for (final key in compressedResults.keys) {
      final compressedData = compressedResults[key];
      final originalEntry = successfullySerializedEntries[key]; // 获取原始类型信息

      if (compressedData != null && originalEntry != null) {
        // 创建 L2 条目
        final l2Entry = L2CacheEntry(
          key: key,
          compressedData: compressedData,
          originalType: originalEntry.originalType, // 使用存储的类型
        );

        // 添加到 L2 并从 L1 移除（对该键类似原子的操作）
        _l2Cache[key] = l2Entry;
        _l1Cache.remove(key);
        downgradeSuccessCount++;
        _logDebug("L1->L2：成功降级键 '$key'。");
      } else {
        // 如果键在 compressedResults 中，这种情况不应发生，但进行防御性检查
        _logWarning("L1->L2：在批次压缩后发现键 '$key' 不一致。跳过。");
      }
    }

    // 记录概要并识别失败项（结果中缺少的项）
    final int failureCount = itemsToCompress.length - downgradeSuccessCount;
    if (failureCount > 0) {
      _logWarning("L1->L2：$failureCount 个项在压缩阶段失败（详情请查看隔离线程日志）。它们保留在 L1。");
      // 可选：如果需要调试，可以列出失败的键：
      // final failedKeys = itemsToCompress.keys.where((k) => !compressedResults.containsKey(k)).toList();
      // _logDebug("L1->L2：压缩失败的键：$failedKeys");
    } else if (downgradeSuccessCount > 0) {
      _logInfo("L1->L2：成功降级 $downgradeSuccessCount 个项。");
    } else {
      _logInfo("L1->L2：本次压缩尝试后没有项成功降级。");
    }
  }

  /// 将符合条件的项从 L2 降级到 L3（磁盘）。
  Future<void> _runDowngradeL2ToL3() async {
    final now = DateTime.now();
    final List<String> keysToDowngrade = [];
    final Map<String, L2CacheEntry> entriesToProcess = {};

    final currentKeys = _l2Cache.keys.toList();
    for (final key in currentKeys) {
      final entry = _l2Cache[key];
      if (entry == null) continue;

      if (now.difference(entry.lastAccessTime) > _config.l2DowngradeDuration) {
        _logDebug("L2->L3：键 '$key' 符合降级条件（空闲 > ${_config.l2DowngradeDuration}）。");
        keysToDowngrade.add(key);
        entriesToProcess[key] = entry;
      }
    }

    if (keysToDowngrade.isEmpty) {
      _logDebug("L2->L3：没有符合降级的项。");
      return;
    }
    _logInfo("L2->L3：找到 ${keysToDowngrade.length} 个项需要降级。");

    // 处理降级（写入磁盘）
    for (final key in keysToDowngrade) {
      final entry = entriesToProcess[key];
      if (entry == null) continue;

      try {
        // 将 L2 的压缩数据直接写入 L3 磁盘缓存
        await _diskCacheManager.put(
          key,
          entry.compressedData,
          entry.originalType,
          _config.l3DefaultExpiryDuration, // 使用 L3 的默认过期时间
        );

        // 成功写入 L3 后从 L2 移除
        _l2Cache.remove(key);
        _logDebug("L2->L3：成功将键 '$key' 降级到磁盘。");

      } catch (e, s) {
        _logError("L2->L3：降级键 '$key' 到磁盘时出错。暂时保留在 L2。", e, s);
        // 如果磁盘写入失败，不从 L2 移除，或许下个周期重试？
      }
    }
  }

  /// 释放资源，关闭 Hive box，停止定时器。
  Future<void> dispose() async {
    _logInfo("正在释放 SmartCacheManager...");
    _stopMaintenanceTimer();
    await _diskCacheManager.dispose();
    _l1Cache.clear();
    _l2Cache.clear();
    _typeNameToTypeRegistry.clear();
    _fromJsonFactory = null;
    _instance = null; // 允许重新初始化
    _logInfo("SmartCacheManager 已释放。");
  }

  // --- 日志记录辅助方法 ---
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
}

// 简单的异步锁类（如果需要，可以替换为更健壮的实现）
class Lock {
  Completer<void>? _completer;

  Future<void> synchronized(FutureOr<void> Function() action) async {
    // 如果锁当前被占用，则等待
    while (_completer != null) {
      await _completer!.future;
    }

    // 获取锁
    _completer = Completer<void>();

    try {
      await action();
    } finally {
      // 释放锁
      final completer = _completer;
      _completer = null;
      completer?.complete(); // 通知等待的 Future
    }
  }
}