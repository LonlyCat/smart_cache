
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:smart_cache/background_processor.dart';
import 'package:smart_cache/model/access_stats.dart';
import 'package:smart_cache/model/cache_stats.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';

import 'dart:io';

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
  final Duration _compressInterval; // 控制每次压缩间隔避免占用过多CPU
  final Duration _inactiveTimeout; // 不活跃判定时间
  final Duration _shallowCleanInterval; // 浅清理间隔：内存压缩但不存储到磁盘
  final Duration _deepCleanInterval; // 深清理间隔：压缩后的内存存储到磁盘，并释放内存
  final Duration _diskCacheMaxAge; // 磁盘缓存最大保存时间

  SmartCacheManager({
    bool enableDiskCache = true,
    int maxActiveItems = 100,
    Duration compressInterval = const Duration(seconds: 3),
    Duration inactiveTimeout = const Duration(seconds: 20),
    Duration shallowCleanInterval = const Duration(seconds: 30),
    Duration deepCleanInterval = const Duration(minutes: 1),
    Duration diskCacheMaxAge = const Duration(days: 3),
  })  : _enableDiskCache = enableDiskCache,
        _compressInterval = compressInterval,
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

  // 用于异步压缩数据的后台处理器
  final _compressProcessor = BackgroundProcessor(poolSize: 2);
  // 用于异步解压缩数据的后台处理器
  final _decompressProcessor = BackgroundProcessor(poolSize: 1);

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
  void put(String key, dynamic data, {bool stayInMemory = false}) {
    // 存入活跃缓存
    _activeCache[key] = data;
    if (_compressedCache.containsKey(key)) {
      // 如果已经压缩，移除压缩数据
      _compressedCache.remove(key);
    }

    // 更新访问记录
    _updateAccessRecord(key, stayInMemory: stayInMemory);
  }

  /// 存储对象
  ///
  /// [key] 缓存键
  /// [data] 要存储的对象
  void putObject<T>(String key, T data, {bool stayInMemory = false}) {
    assert(
        (_modelRegistry.containsKey(T.toString()) || _modelGenerator != null),
        '未注册模型转换器，请通过 `registerModel<T>` 注册: ${T.toString()}');

    // 存储对象及其类型信息
    put(key, {
      'isModel': true,
      'data': data,
      'type': T.toString()
    }, stayInMemory: stayInMemory);
  }

  /// 存储动态结构的复杂对象
  ///
  /// 通过JSON序列化后存储
  /// [key] 缓存键
  /// [data] 复杂对象
  void putDynamicObject(String key, dynamic data, {bool stayInMemory = false}) {
    try {
      // 尝试JSON序列化
      final String jsonString = jsonEncode(data);
      put(key, {
        'isDynamicObject': true,
        'data': jsonString,
      }, stayInMemory: stayInMemory);
    } catch (e) {
      cacheLogger('无法序列化对象: $e');
      // 如果无法序列化，直接存储
      put(key, data, stayInMemory: stayInMemory);
    }
  }

  /// 获取基本数据, 此方法会忽略磁盘缓存
  ///
  /// [key] 缓存键
  dynamic get(String key) {

    // 检查活跃缓存
    if (_activeCache.containsKey(key)) {
      _updateAccessRecord(key);
      return _activeCache[key];
    }

    // 检查压缩缓存
    if (_compressedCache.containsKey(key)) {
      // 解压数据并移回活跃缓存
      final dynamic decompressedData = _decompressData(key);
      _activeCache[key] = decompressedData;
      _updateAccessRecord(key);
      return decompressedData;
    }

    return null;
  }

  /// 异步获取基本数据，包括磁盘缓存
  ///
  /// [key] 缓存键
  Future<dynamic> getAsync(String key) async {

    if (!_activeCache.containsKey(key) &&
        !_compressedCache.containsKey(key)) {
      // 尝试从磁盘加载
      await _tryLoadFromDiskCache(key);
    }

    // 检查活跃缓存
    if (_activeCache.containsKey(key)) {
      _updateAccessRecord(key);
      return _activeCache[key];
    }

    // 检查压缩缓存
    if (_compressedCache.containsKey(key)) {
      // 解压数据并移回活跃缓存
      final dynamic decompressedData = await _decompressDataAsync(key);
      _activeCache[key] = decompressedData;
      _updateAccessRecord(key);
      return decompressedData;
    }

    return null;
  }

  /// 获取对象, 此方法会忽略磁盘缓存
  ///
  /// [key] 缓存键
  /// 返回T类型的对象，或null
  T? getObject<T>(String key) {
    final dynamic cachedData = get(key);

    if (cachedData == null) return null;

    return _mapObject<T>(cachedData);
  }

  /// 异步获取对象，包括磁盘缓存
  ///
  /// [key] 缓存键
  /// 返回T类型的对象，或null
  Future<T?> getObjectAsync<T>(String key) async {

    if (!_activeCache.containsKey(key) &&
        !_compressedCache.containsKey(key)) {
      // 尝试从磁盘加载
      await _tryLoadFromDiskCache(key);
    }

    final dynamic cachedData = await getAsync(key);
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
  dynamic getDynamicObject(String key) {
    final dynamic cachedData = get(key);

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

    if (!_activeCache.containsKey(key) &&
        !_compressedCache.containsKey(key)) {
      // 尝试从磁盘加载
      await _tryLoadFromDiskCache(key);
    }

    final dynamic cachedData = await getAsync(key);
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
  bool containsKey(String key) {
    return _activeCache.containsKey(key) ||
        _compressedCache.containsKey(key);
  }

  /// 异步检查键是否存在，包括磁盘缓存
  ///
  /// [key] 缓存键
  Future<bool> containsKeyAsync(String key) async {
    if (!_activeCache.containsKey(key) &&
        !_compressedCache.containsKey(key)) {
      // 尝试从磁盘加载
      await _tryLoadFromDiskCache(key);
    }
    return containsKey(key);
  }

  /// 移除缓存
  ///
  /// [key] 缓存键
  void remove(String key) {
    _activeCache.remove(key);
    _compressedCache.remove(key);
    _accessStats.remove(key);
    // 从磁盘缓存中移除
    if (_enableDiskCache) _diskCacheManager.removeFile(key);
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

  bool _compressCoolingDown = false;
  /// 将不活跃数据压缩
  ///
  /// [forced] 强制压缩所有数据
  void compressInactiveData({bool forced = false}) async {
    if (_compressCoolingDown) return;
    _compressCoolingDown = true;

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
            return _accessStats[a]!.lastAccessTime.compareTo(_accessStats[b]!.lastAccessTime);
          });
        // 每次压缩多20项
        final keysToRemove = sortedKeys.take(_activeCache.length - _maxActiveItems + 20);
        for (final key in keysToRemove) {
          if (_activeCache.containsKey(key) && !_accessStats[key]!.isCompressed) {
            keysToCompress.add(key);
            _accessStats[key]!.isCompressed = true;
          }
        }
        sortedKeys.clear();
      }

      // 查找超过指定时间未访问的数据
      for (final key in accessKeys) {
        final lastAccess = _accessStats[key]?.lastAccessTime;
        if (lastAccess == null) continue;
        if (now.difference(lastAccess) > _inactiveTimeout &&
            !_accessStats[key]!.isCompressed &&
            _activeCache.containsKey(key) &&
            !keysToCompress.contains(key)) {
          keysToCompress.add(key);
          _accessStats[key]!.isCompressed = true;
        }
      }
    }

    if (keysToCompress.isEmpty) {
      _compressCoolingDown = false;
      return;
    }
    // 压缩数据
    _batchCompressDataByKeysAsync(keysToCompress).then((_) {
      cacheLogger('SmartCacheManage'
          '\n压缩了 ${keysToCompress.length} 项数据'
          '\n当前还有 ${_activeCache.length} 项活跃数据'
          '\n当前还有 ${_compressedCache.length} 项压缩数据');
      return Future.delayed(_compressInterval);
    }).then((_) {
      _compressCoolingDown = false;
    }).catchError((e) {
      cacheLogger('压缩数据时出错: $e');
      _compressCoolingDown = false;
    });
  }

  /// 将所有压缩数据存储到磁盘
  void storedAllCompressedData() {
    final keys = _compressedCache.keys;
    for (final key in keys) {
      if (_compressedCache[key] != null) {
        _saveToDiskCache(key, _compressedCache[key]!);
        if (_accessStats[key]?.stayInMemory == false) {
          _compressedCache.remove(key);
        } else {
          _accessStats[key]?.count = 0;
        }
      }
      else {
        _compressedCache.remove(key);
      }
    }
  }

  void _startCleanupTimer() {
    _shallowCleanTimer ??= Timer.periodic(_shallowCleanInterval, (timer) {
      compressInactiveData();
    });

    if (_enableDiskCache) {
      _deepCleanTimer ??= Timer.periodic(_deepCleanInterval, (timer) {
        // 深清理：将压缩数据存储到磁盘
        storedAllCompressedData();
      });
    }
  }

  void _stopCleanupTimer() {
    _shallowCleanTimer?.cancel();
    _shallowCleanTimer = null;

    storedAllCompressedData();

    if (_enableDiskCache) {
      _deepCleanTimer?.cancel();
      _deepCleanTimer = null;
    }
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

      if (_accessStats[key]?.stayInMemory == false) {
        _accessStats.remove(key);
      } else {
        _accessStats[key]?.count = 0;
      }

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
  Future<void> _batchCompressDataByKeysAsync(List<String> keys) async {

    Map<String, String> oriCompressMap = {};
    for (final key in keys) {
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
        oriCompressMap[key] = jsonData;
      } catch (e, s) {
        cacheLogger('异步压缩缓存时出错: $e\n$s');
      }
    }

    try {

      // 在独立线程中执行压缩
      Map<String, List<int>> compressedMap =
        await _compressProcessor.execute<Map<String, String>, Map<String, List<int>>>(
            _batchZip, oriCompressMap);

      for (final entry in compressedMap.entries) {
        // 存储压缩数据
        _compressedCache[entry.key] = Uint8List.fromList(entry.value);
        _activeCache.remove(entry.key);
        if (_accessStats[entry.key]?.stayInMemory == false) {
          _accessStats.remove(entry.key);
        } else {
          _accessStats[entry.key]?.count = 0;
        }
      }

      if (_activeCache.isEmpty) {
        _stopCleanupTimer();
      }
    } catch (e, s) {
      cacheLogger('异步压缩缓存时出错: $e\n$s');
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
          await _decompressProcessor.execute<List<int>, String>(_unzipString, compressedData);

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
  void _updateAccessRecord(String key, {bool stayInMemory = false}) {
    AccessStats? oldStats = _accessStats[key];
    if (oldStats == null) {
      _accessStats[key] = AccessStats(
        count: 0,
        stayInMemory: stayInMemory,
        lastAccessTime: DateTime.now(),
      );
    } else {
      oldStats.lastAccessTime = DateTime.now();
      oldStats.isCompressed = false;
      oldStats.count++;
    }

    // 有更新时启动清理定时器
    _startCleanupTimer();
    // 如果活跃缓存超过最大项数，压缩一部分数据
    if (_activeCache.length > _maxActiveItems) {
      compressInactiveData();
    }
  }

  /// 将缓存项预加载到活跃缓存
  ///
  /// 用于提前加载可能需要的数据
  Future<void> preload(String key) async {

    if (_activeCache.containsKey(key)) {
      // 已在活跃缓存中
      return;
    }

    if (_compressedCache.containsKey(key)) {
      // 解压到活跃缓存
      final decompressedData = _decompressData(key);
      if (decompressedData != null) {
        _activeCache[key] = decompressedData;
        _updateAccessRecord(key);
      }
      return;
    }

    if (!_enableDiskCache) return;
    // 尝试从磁盘加载至压缩内存
    try {
      final fileInfo = await _diskCacheManager.getFileFromCache(key);
      if (fileInfo != null) {
        final file = fileInfo.file;
        final bytes = await file.readAsBytes();
        _compressedCache[key] = bytes;

        // // 解压到活跃缓存
        // final decompressedData = _decompressData(key);
        // if (decompressedData != null) {
        //   _activeCache[key] = decompressedData;
        //   _compressedCache.remove(key);
        //   _updateAccessRecord(key);
        // }
      }
    } catch (e) {
      cacheLogger('预加载缓存时出错: $e');
    }
  }

  /// 析构函数
  void dispose() {
    _decompressProcessor.dispose();
    _compressProcessor.dispose();
    _shallowCleanTimer?.cancel();
    _shallowCleanTimer = null;
    _compressedCache.clear();
    _activeCache.clear();
  }
}


List<int> _zipString(String string) {
  return gzip.encode(utf8.encode(string));
}

Map<String, List<int>> _batchZip(Map<String, String> datas) {
  return datas.map((key, value) {
    return MapEntry(key, _zipString(value));
  });
}

String _unzipString(List<int> bytes) {
  return utf8.decode(gzip.decode(bytes));
}
