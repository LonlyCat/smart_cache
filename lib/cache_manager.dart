import 'dart:math';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:smart_cache/background_processor.dart';
import 'package:smart_cache/model/access_stats.dart';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:smart_cache/model/cache_stats.dart';

/// 日志输出
void Function(String? message, {int? wrapWidth}) cacheLogger = debugPrint;

/// 智能缓存管理器
/// 支持内存缓存、压缩缓存和磁盘缓存
/// 自动管理活跃和非活跃数据
class SmartCacheManager {
  static SmartCacheManager standard = SmartCacheManager();

  // 配置参数
  final bool _enableDiskCache; // 是否启用磁盘缓存
  final int _maxActiveItems; // 活跃缓存最大项数
  final Duration _inactiveTimeout; // 不活跃判定时间
  final Duration _shallowCleanInterval; // 浅清理间隔：内存压缩但不存储到磁盘
  final Duration _deepCleanInterval; // 深清理间隔：压缩后的内存存储到磁盘，并释放内存
  final Duration _diskCacheMaxAge; // 磁盘缓存最大保存时间

  SmartCacheManager({
    bool enableDiskCache = true,
    int maxActiveItems = 100,
    Duration inactiveTimeout = const Duration(seconds: 20),
    Duration shallowCleanInterval = const Duration(seconds: 30),
    Duration deepCleanInterval = const Duration(minutes: 1),
    Duration diskCacheMaxAge = const Duration(days: 3),
  })  : _enableDiskCache = enableDiskCache,
        _maxActiveItems = maxActiveItems,
        _inactiveTimeout = inactiveTimeout,
        _shallowCleanInterval = shallowCleanInterval,
        _deepCleanInterval = deepCleanInterval,
        _diskCacheMaxAge = diskCacheMaxAge;

  // 活跃缓存 - 保持在内存中的数据
  final Map<String, dynamic> _activeCache = {};

  // 访问记录
  final Map<String, AccessStats> _accessStats = {};

  // 压缩数据的临时存储
  final Map<String, Uint8List> _compressedCache = {};

  // 缓存清理定时器
  Timer? _shallowCleanTimer;
  Timer? _deepCleanTimer;

  // 磁盘缓存管理器
  late DefaultCacheManager _diskCacheManager = DefaultCacheManager();

  // 模型注册表 - 用于反序列化
  final Map<String, Function(Map<String, dynamic>)> _modelRegistry = {};
  dynamic Function(String type, Map<String, dynamic>)? _modelGenerator;

  // 用于异步解压缩数据的后台处理器
  final _backgroundProcessor = BackgroundProcessor(poolSize: 2);

  /// 注册模型转换器
  ///
  /// 用于将JSON转换回特定类型的对象
  /// [fromJson] 是将JSON Map转换为T类型对象的函数
  void registerModel<T>(T Function(Map<String, dynamic> json) fromJson) {
    _modelRegistry[T.toString()] = fromJson;
    cacheLogger('已注册模型转换器: ${T.toString()}');
  }

  /// 注册模型生成器
  ///
  /// 用于生成特定类型的对象
  /// [generator] 是生成T类型对象的函数
  void registerModelGenerator(
      dynamic Function(String type, Map<String, dynamic> json) generator) {
    _modelGenerator = generator;
  }

  /// 存储基本数据
  ///
  /// [key] 缓存键
  /// [data] 要存储的数据
  void put(String key, dynamic data) {
    final String hashedKey = _generateKey(key);

    // 存入活跃缓存
    _activeCache[hashedKey] = data;

    // 更新访问记录
    _updateAccessRecord(hashedKey);
  }

  /// 存储对象
  ///
  /// [key] 缓存键
  /// [data] 要存储的对象
  void putObject<T>(String key, T data) {
    assert(
        (_modelRegistry.containsKey(T.toString()) || _modelGenerator != null),
        '未注册模型转换器，请通过 `registerModel<T>` 注册: ${T.toString()}');
    final String hashedKey = _generateKey(key);

    // 存储对象及其类型信息
    _activeCache[hashedKey] = {
      'isModel': true,
      'data': data,
      'type': T.toString()
    };

    _updateAccessRecord(hashedKey);
  }

  /// 存储动态结构的复杂对象
  ///
  /// 通过JSON序列化后存储
  /// [key] 缓存键
  /// [data] 复杂对象
  void putDynamicObject(String key, dynamic data) {
    try {
      // 尝试JSON序列化
      final String jsonString = jsonEncode(data);
      put(key, {
        'isDynamicObject': true,
        'data': jsonString,
      });
    } catch (e) {
      cacheLogger('无法序列化对象: $e');
      // 如果无法序列化，直接存储
      put(key, data);
    }
  }

  /// 获取基本数据, 此方法会忽略磁盘缓存
  ///
  /// [key] 缓存键
  dynamic get(String key, {bool isHashedKey = false}) {
    final String hashedKey = isHashedKey ? key : _generateKey(key);

    // 检查活跃缓存
    if (_activeCache.containsKey(hashedKey)) {
      _updateAccessRecord(hashedKey);
      return _activeCache[hashedKey];
    }

    // 检查压缩缓存
    if (_compressedCache.containsKey(hashedKey)) {
      // 解压数据并移回活跃缓存
      final dynamic decompressedData = _decompressData(hashedKey);
      _activeCache[hashedKey] = decompressedData;
      _updateAccessRecord(hashedKey);
      return decompressedData;
    }

    return null;
  }

  /// 异步获取基本数据，包括磁盘缓存
  ///
  /// [key] 缓存键
  Future<dynamic> getAsync(String key, {bool isHashedKey = false}) async {
    final String hashedKey = isHashedKey ? key : _generateKey(key);

    if (!_activeCache.containsKey(hashedKey) &&
        !_compressedCache.containsKey(hashedKey)) {
      // 尝试从磁盘加载
      await _tryLoadFromDiskCache(hashedKey);
    }

    // 检查活跃缓存
    if (_activeCache.containsKey(hashedKey)) {
      _updateAccessRecord(hashedKey);
      return _activeCache[hashedKey];
    }

    // 检查压缩缓存
    if (_compressedCache.containsKey(hashedKey)) {
      // 解压数据并移回活跃缓存
      final dynamic decompressedData = await _decompressDataAsync(hashedKey);
      _activeCache[hashedKey] = decompressedData;
      _updateAccessRecord(hashedKey);
      return decompressedData;
    }

    return null;
  }

  /// 获取对象, 此方法会忽略磁盘缓存
  ///
  /// [key] 缓存键
  /// 返回T类型的对象，或null
  T? getObject<T>(String key, {bool isHashedKey = false}) {
    final dynamic cachedData = get(key, isHashedKey: isHashedKey);

    if (cachedData == null) return null;

    return _mapObject<T>(cachedData);
  }

  /// 异步获取对象，包括磁盘缓存
  ///
  /// [key] 缓存键
  /// 返回T类型的对象，或null
  Future<T?> getObjectAsync<T>(String key) async {
    final String hashedKey = _generateKey(key);

    if (!_activeCache.containsKey(hashedKey) &&
        !_compressedCache.containsKey(hashedKey)) {
      // 尝试从磁盘加载
      await _tryLoadFromDiskCache(hashedKey);
    }

    final dynamic cachedData = await getAsync(hashedKey, isHashedKey: true);
    if (cachedData == null) return null;

    return _mapObject<T>(cachedData);
  }

  T? _mapObject<T>(dynamic cachedData) {
    try {
      // 检查是否是模型对象
      if (cachedData is Map &&
          cachedData['isModel'] == true &&
          cachedData['type'] == T.toString()) {
        return cachedData['data'] as T;
      }

      // 如果是已经从压缩缓存还原的对象
      if (cachedData is Map &&
          cachedData.containsKey('data') &&
          cachedData.containsKey('type') &&
          cachedData['type'] == T.toString()) {
        final dynamic data = cachedData['data'];
        if (data is T) return data;

        // 尝试使用注册的转换器
        final converter = _modelRegistry[T.toString()];
        if (converter != null && data is Map<String, dynamic>) {
          return converter(data) as T;
        }
      }
    } catch (e) {
      cacheLogger('获取对象时出错: $e');
    }

    return null;
  }

  /// 获取动态结构的复杂对象(List, Map等), 此方法会忽略磁盘缓存
  ///
  /// [key] 缓存键
  dynamic getDynamicObject(String key, {bool isHashedKey = false}) {
    final dynamic cachedData = get(key, isHashedKey: isHashedKey);

    if (cachedData == null) return null;

    try {
      return _mapDynamicObject(cachedData);
    } catch (e) {
      cacheLogger('获取动态对象时出错: $e');
    }
    return cachedData;
  }

  /// 异步获取动态结构的复杂对象(List, Map等)，包括磁盘缓存
  ///
  /// [key] 缓存键
  Future<dynamic> getDynamicObjectAsync(String key) async {
    final String hashedKey = _generateKey(key);

    if (!_activeCache.containsKey(hashedKey) &&
        !_compressedCache.containsKey(hashedKey)) {
      // 尝试从磁盘加载
      await _tryLoadFromDiskCache(hashedKey);
    }

    final dynamic cachedData = await getAsync(hashedKey, isHashedKey: true);
    if (cachedData == null) return null;

    try {
      return _mapDynamicObject(cachedData);
    } catch (e) {
      cacheLogger('获取动态对象时出错: $e');
    }
    return cachedData;
  }

  dynamic _mapDynamicObject(dynamic cachedData) {
    if (cachedData is Map && cachedData['isDynamicObject'] == true) {
      final jsonString = cachedData['data'];
      if (jsonString is String) {
        return jsonDecode(jsonString);
      }
    }
    return cachedData;
  }

  /// 检查键是否存在(不包括磁盘缓存)
  ///
  /// [key] 缓存键
  bool containsKey(String key, {bool isHashedKey = false}) {
    final String hashedKey = isHashedKey ? key : _generateKey(key);
    return _activeCache.containsKey(hashedKey) ||
        _compressedCache.containsKey(hashedKey);
  }

  /// 异步检查键是否存在，包括磁盘缓存
  ///
  /// [key] 缓存键
  Future<bool> containsKeyAsync(String key) async {
    final String hashedKey = _generateKey(key);
    if (!_activeCache.containsKey(hashedKey) &&
        !_compressedCache.containsKey(hashedKey)) {
      // 尝试从磁盘加载
      await _tryLoadFromDiskCache(hashedKey);
    }
    return containsKey(key);
  }

  /// 移除缓存
  ///
  /// [key] 缓存键
  void remove(String key) {
    final String hashedKey = _generateKey(key);
    _activeCache.remove(hashedKey);
    _compressedCache.remove(hashedKey);
    _accessStats.remove(hashedKey);
    // 从磁盘缓存中移除
    if (_enableDiskCache) _diskCacheManager.removeFile(hashedKey);
  }

  /// 清空所有缓存
  void clear() {
    _stopCleanupTimer();
    _accessStats.clear();
    _activeCache.clear();
    _compressedCache.clear();
    if (_enableDiskCache) _diskCacheManager.emptyCache();
  }

  /// 获取缓存统计信息
  CacheStats getStats() {
    double compressedCache = _compressedCache.values.fold(0, (size, item) {
      return size + item.lengthInBytes / 1024;
    });
    return CacheStats(
      memoryUsage: CacheMemoryUsage(
        activeCache: _activeCache.length * 100.0, // 100 bytes per item
        compressedCache: compressedCache, // 100 bytes per item
      ),
      activeItemsCount: _activeCache.length,
      compressedItemsCount: _compressedCache.length,
      totalItemsCount: _activeCache.length + _compressedCache.length,
      registeredModels: _modelRegistry.keys.toList(),
    );
  }

  /// 将不活跃数据压缩
  ///
  /// [forced] 强制压缩所有数据
  void compressInactiveData({bool forced = false}) async {
    final now = DateTime.now();
    List<String> keysToCompress = [];

    // 检查活跃缓存是否超过最大项数
    List<String> accessKeys = _accessStats.keys.toList();
    if (forced) {
      keysToCompress = accessKeys;
    } else {
      if (_activeCache.length > _maxActiveItems) {
        // 按访问时间升序排序
        final sortedKeys = accessKeys
          ..sort((a, b) {
            return _accessStats[a]!
                .lastAccessTime
                .compareTo(_accessStats[b]!.lastAccessTime);
          });
        // 每次压缩多20项
        final keysToRemove =
            sortedKeys.take(_activeCache.length - _maxActiveItems + 20);
        for (final key in keysToRemove) {
          keysToCompress.add(key);
        }
        sortedKeys.clear();
      }

      // 查找超过指定时间未访问的数据
      for (final key in accessKeys) {
        final lastAccess = _accessStats[key]?.lastAccessTime;
        if (lastAccess == null) continue;
        if (now.difference(lastAccess) > _inactiveTimeout &&
            _activeCache.containsKey(key) &&
            !keysToCompress.contains(key)) {
          keysToCompress.add(key);
        }
      }
    }

    // 压缩数据
    Future.wait(keysToCompress.where((e) => keysToCompress.contains(e)).map((key) {
      return _compressDataByKeyAsync(key);
    })).then((_) {
      cacheLogger('SmartCacheManage'
          '\n压缩了 ${keysToCompress.length} 项数据'
          '\n当前还有 ${_activeCache.length} 项活跃数据'
          '\n当前还有 ${_compressedCache.length} 项压缩数据');
    });
  }

  /// 将所有压缩数据存储到磁盘
  void storedAllCompressedData() {
    final keys = _compressedCache.keys.toList();
    for (final key in keys) {
      _saveToDiskCache(key, _compressedCache[key]!);
      _compressedCache.remove(key);
    }
  }

  void _startCleanupTimer() {
    _shallowCleanTimer ??= Timer.periodic(_shallowCleanInterval, (timer) {
      compressInactiveData();
    });

    _deepCleanTimer ??= Timer.periodic(_deepCleanInterval, (timer) {
      // 深清理：将压缩数据存储到磁盘
      storedAllCompressedData();
    });
  }

  void _stopCleanupTimer() {
    _shallowCleanTimer?.cancel();
    _shallowCleanTimer = null;

    storedAllCompressedData();

    _deepCleanTimer?.cancel();
    _deepCleanTimer = null;
  }

  /// 压缩数据并存储
  void _compressDataByKey(String key) {
    final data = _activeCache.remove(key);
    if (data == null) return;
    try {
      String jsonData;

      if (data is String) {
        // 如果已经是字符串，直接使用
        jsonData = data;
      } else if (data is Map &&
          data.containsKey('isDynamicObject') &&
          data['isDynamicObject'] == true) {
        // 如果是动态对象，已经JSON序列化
        jsonData = jsonEncode(data);
      } else if (data is Map &&
          data.containsKey('isModel') &&
          data['isModel'] == true) {
        // 处理模型对象
        final type = data['type'];
        final modelData = data['data'];

        // 检查对象是否可以序列化为JSON
        if (modelData != null) {
          dynamic jsonObject;

          if (modelData is Map<String, dynamic>) {
            jsonObject = modelData;
          } else if (modelData.toJson is Function) {
            // 调用对象的toJson方法
            jsonObject = modelData.toJson();
          }

          jsonData =
              jsonEncode({'isModel': true, 'type': type, 'data': jsonObject});
        } else {
          throw Exception('无法序列化模型对象');
        }
      } else {
        // 尝试直接序列化
        jsonData = jsonEncode(data);
      }

      // 压缩数据
      final compressedData = _zipString(jsonData);
      // 存储压缩数据
      _compressedCache[key] = Uint8List.fromList(compressedData);

      _accessStats.remove(key);

      // 如果活跃缓存中已经没有数据，停止循环
      if (_activeCache.isEmpty) {
        _stopCleanupTimer();
      }
    } catch (e) {
      cacheLogger('压缩缓存时出错: $e');
      // 压缩失败时保留在活跃缓存中
      _activeCache[key] = data;
    }
  }

  /// 异步压缩数据并存储
  Future<void> _compressDataByKeyAsync(String key) async {
    final data = _activeCache[key];
    if (data == null) return;

    try {
      String jsonData;

      if (data is String) {
        jsonData = data;
      } else if (data is Map &&
          data.containsKey('isDynamicObject') &&
          data['isDynamicObject'] == true) {
        jsonData = jsonEncode(data);
      } else if (data is Map &&
          data.containsKey('isModel') &&
          data['isModel'] == true) {
        final type = data['type'];
        final modelData = data['data'];

        if (modelData != null) {
          dynamic jsonObject;

          if (modelData is Map<String, dynamic>) {
            jsonObject = modelData;
          } else if (modelData.toJson is Function) {
            jsonObject = modelData.toJson();
          }

          jsonData =
              jsonEncode({'isModel': true, 'type': type, 'data': jsonObject});
        } else {
          throw Exception('无法序列化模型对象');
        }
      } else {
        jsonData = jsonEncode(data);
      }

      // 在独立线程中执行压缩
      List<int> compressedData =
        await _backgroundProcessor.execute<String, List<int>>(_zipString, jsonData);

      // 存储压缩数据
      _compressedCache[key] = Uint8List.fromList(compressedData);
      _activeCache.remove(key);
      _accessStats.remove(key);

      if (_activeCache.isEmpty) {
        _stopCleanupTimer();
      }
    } catch (e) {
      cacheLogger('异步压缩缓存时出错: $e');
      _activeCache[key] = data;
    }
  }

  /// 解压缩数据
  dynamic _decompressData(String key) {
    Stopwatch? stopwatch = Stopwatch()..start();
    final compressedData = _compressedCache.remove(key);
    try {
      if (compressedData != null) {
        // 解压数据,将字节转换回JSON字符串
        final jsonString = _unzipString(compressedData);
        // 解析JSON
        final dynamic decodedData = jsonDecode(jsonString);

        // 处理模型对象
        if (decodedData is Map &&
            decodedData.containsKey('isModel') &&
            decodedData['isModel'] == true) {
          final type = decodedData['type'];
          final data = decodedData['data'];

          // 通过注册的工厂函数恢复对象
          final modelFactory = _modelRegistry[type];
          if (modelFactory != null && data is Map<String, dynamic>) {
            try {
              final restoredObject = modelFactory(data);
              return {'isModel': true, 'type': type, 'data': restoredObject};
            } catch (e) {
              cacheLogger('恢复模型对象时出错: $e');
              // 如果恢复失败，返回原始数据
              return decodedData;
            }
          }

          // 如果没有注册的工厂函数，尝试使用注册的生成器
          if (_modelGenerator != null && data is Map<String, dynamic>) {
            try {
              final restoredObject = _modelGenerator!(type, data);
              if (restoredObject != null) {
                return {'isModel': true, 'type': type, 'data': restoredObject};
              }
            } catch (e) {
              cacheLogger('恢复模型对象时出错: $e');
              // 如果恢复失败，返回原始数据
              return decodedData;
            }
          }
          return decodedData;
        } else if (decodedData is Map &&
            decodedData.containsKey('isDynamicObject') &&
            decodedData['isDynamicObject'] == true) {
          return decodedData;
        }
        return decodedData;
      }
    } catch (e) {
      cacheLogger('解压缩数据时出错: $e');
    } finally {
      if (compressedData != null) {
        cacheLogger('解压缩数据 ${stopwatch.elapsedMilliseconds} ms');
      }
      stopwatch.stop();
      stopwatch = null;
    }
    return null;
  }

  /// 异步解压缩数据
  Future<dynamic> _decompressDataAsync(String key) async {
    Stopwatch? stopwatch = Stopwatch()..start();
    final compressedData = _compressedCache.remove(key);

    try {
      if (compressedData != null) {
        // 在独立线程中执行解压缩
        String jsonString =
          await _backgroundProcessor.execute<List<int>, String>(_unzipString, compressedData);

        // 解析JSON
        final dynamic decodedData = jsonDecode(jsonString);

        // 处理模型对象
        if (decodedData is Map &&
            decodedData.containsKey('isModel') &&
            decodedData['isModel'] == true) {
          final type = decodedData['type'];
          final data = decodedData['data'];

          // 通过注册的工厂函数恢复对象
          final modelFactory = _modelRegistry[type];
          if (modelFactory != null && data is Map<String, dynamic>) {
            try {
              final restoredObject = modelFactory(data);
              return {'isModel': true, 'type': type, 'data': restoredObject};
            } catch (e) {
              cacheLogger('恢复模型对象时出错: $e');
              return decodedData;
            }
          }

          // 如果没有注册的工厂函数，尝试使用注册的生成器
          if (_modelGenerator != null && data is Map<String, dynamic>) {
            try {
              final restoredObject = _modelGenerator!(type, data);
              if (restoredObject != null) {
                return {'isModel': true, 'type': type, 'data': restoredObject};
              }
            } catch (e) {
              cacheLogger('恢复模型对象时出错: $e');
              return decodedData;
            }
          }
          return decodedData;
        } else if (decodedData is Map &&
            decodedData.containsKey('isDynamicObject') &&
            decodedData['isDynamicObject'] == true) {
          return decodedData;
        }
        return decodedData;
      }
    } catch (e) {
      cacheLogger('异步解压缩数据时出错: $e');
    } finally {
      if (compressedData != null) {
        cacheLogger('异步解压缩数据 ${stopwatch.elapsedMilliseconds} ms');
      }
      stopwatch.stop();
      stopwatch = null;
    }
    return null;
  }

  /// 保存到磁盘缓存
  Future<void> _saveToDiskCache(String key, List<int> compressedData) async {
    if (!_enableDiskCache) return;
    try {
      await _diskCacheManager.putFile(
        key,
        Uint8List.fromList(compressedData),
        key: key,
        maxAge: _diskCacheMaxAge,
      );
    } catch (e) {
      cacheLogger('保存到磁盘缓存时出错: $e');
    }
  }

  /// 尝试从磁盘缓存加载
  ///
  /// [key] 缓存键
  Future<void> _tryLoadFromDiskCache(String key) async {
    if (!_enableDiskCache) return;
    try {
      Stopwatch? stopwatch = Stopwatch()..start();
      final fileInfo = await _diskCacheManager.getFileFromCache(key);
      if (fileInfo != null) {
        final file = fileInfo.file;
        final bytes = await file.readAsBytes();
        _compressedCache[key] = bytes;
        cacheLogger('从磁盘缓存加载 ${stopwatch.elapsedMilliseconds} ms');
      }
      stopwatch.stop();
      stopwatch = null;
    } catch (e) {
      cacheLogger('从磁盘缓存加载时出错: $e');
    }
  }

  /// 更新访问记录
  void _updateAccessRecord(String key) {
    AccessStats? oldStats = _accessStats[key];
    if (oldStats == null) {
      _accessStats[key] = AccessStats(count: 0, lastAccessTime: DateTime.now());
    } else {
      oldStats.lastAccessTime = DateTime.now();
      oldStats.count++;
    }

    // 有更新时启动清理定时器
    _startCleanupTimer();
    // 如果活跃缓存超过最大项数，压缩一部分数据
    if (_activeCache.length > _maxActiveItems) {
      compressInactiveData();
    }
  }

  /// 生成键的哈希值
  String _generateKey(String key) {
    return md5.convert(utf8.encode(key)).toString();
  }

  /// 将缓存项预加载到活跃缓存
  ///
  /// 用于提前加载可能需要的数据
  Future<void> preload(String key) async {
    final String hashedKey = _generateKey(key);

    if (_activeCache.containsKey(hashedKey)) {
      // 已在活跃缓存中
      return;
    }

    if (_compressedCache.containsKey(hashedKey)) {
      // 解压到活跃缓存
      final decompressedData = _decompressData(hashedKey);
      if (decompressedData != null) {
        _activeCache[hashedKey] = decompressedData;
        _updateAccessRecord(hashedKey);
      }
      return;
    }

    if (!_enableDiskCache) return;
    // 尝试从磁盘加载至压缩内存
    try {
      final fileInfo = await _diskCacheManager.getFileFromCache(hashedKey);
      if (fileInfo != null) {
        final file = fileInfo.file;
        final bytes = await file.readAsBytes();
        _compressedCache[hashedKey] = bytes;

        // // 解压到活跃缓存
        // final decompressedData = _decompressData(hashedKey);
        // if (decompressedData != null) {
        //   _activeCache[hashedKey] = decompressedData;
        //   _compressedCache.remove(hashedKey);
        //   _updateAccessRecord(hashedKey);
        // }
      }
    } catch (e) {
      cacheLogger('预加载缓存时出错: $e');
    }
  }

  /// 析构函数
  void dispose() {
    _backgroundProcessor.dispose();
    _shallowCleanTimer?.cancel();
    _shallowCleanTimer = null;
    _compressedCache.clear();
    _activeCache.clear();
  }
}


List<int> _zipString(String string) {
  return gzip.encode(utf8.encode(string));
}

String _unzipString(List<int> bytes) {
  return utf8.decode(gzip.decode(bytes));
}
