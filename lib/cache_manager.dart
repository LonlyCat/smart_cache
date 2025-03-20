import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:smart_cache/lru/lru.dart';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:smart_cache/model/CacheStats.dart';

/// 可序列化接口，用于不能直接JSON序列化的对象
abstract class Serializable {
  Map<String, dynamic> serialize();
  static T? deserialize<T extends Serializable>(
      Map<String, dynamic> data, T Function(Map<String, dynamic>) factory) {
    return factory(data);
  }
}

/// 智能缓存管理器
/// 支持内存缓存、压缩缓存和磁盘缓存
/// 自动管理活跃和非活跃数据
class SmartCacheManager {
  // 单例模式
  static final SmartCacheManager _instance = SmartCacheManager();
  static SmartCacheManager get standard => _instance;

  // 配置参数
  final int _maxActiveItems;            // 活跃缓存最大项数
  final Duration _inactiveTimeout;      // 不活跃判定时间
  final Duration _cleanupInterval;      // 清理间隔
  final Duration _diskCacheMaxAge;      // 磁盘缓存最大保存时间

  SmartCacheManager({
    int maxActiveItems = 50,
    Duration inactiveTimeout = const Duration(seconds: 30),
    Duration cleanupInterval = const Duration(seconds: 10),
    Duration diskCacheMaxAge = const Duration(days: 3),
  })  : _maxActiveItems = maxActiveItems,
        _inactiveTimeout = inactiveTimeout,
        _cleanupInterval = cleanupInterval,
        _diskCacheMaxAge = diskCacheMaxAge;

  // 活跃缓存 - 保持在内存中的数据
  late final LruCache<String, dynamic> _activeCache = LruCache(_maxActiveItems);

  // 访问频率记录
  final Map<String, int> _accessCount = {};

  // 最后访问时间记录
  final Map<String, DateTime> _lastAccessTime = {};

  // 压缩数据的临时存储
  final Map<String, Uint8List> _compressedCache = {};

  // 缓存清理定时器
  Timer? _cleanupTimer;

  // 磁盘缓存管理器
  final DefaultCacheManager _diskCacheManager = DefaultCacheManager();

  // 模型注册表 - 用于反序列化
  final Map<String, Function(Map<String, dynamic>)> _modelRegistry = {};

  // 初始化标志
  bool _isInitialized = false;

  /// 初始化缓存管理器
  void init() {
    if (_isInitialized) return;

    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(_cleanupInterval, (_) {
      _compressInactiveData();
    });

    _activeCache.willEvictEntry = _willEvictActiveEntry;

    _isInitialized = true;
    debugPrint('SmartCacheManager 初始化完成');
  }

  /// 注册模型转换器
  ///
  /// 用于将JSON转换回特定类型的对象
  /// [fromJson] 是将JSON Map转换为T类型对象的函数
  void registerModel<T>(T Function(Map<String, dynamic> json) fromJson) {
    _modelRegistry[T.toString()] = fromJson;
    debugPrint('已注册模型转换器: ${T.toString()}');
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
  /// [fromJson] 从JSON转换为对象的函数
  void putObject<T>(String key, T data, {required T Function(Map<String, dynamic> json) fromJson}) {
    final String hashedKey = _generateKey(key);

    // 注册模型转换器(如果尚未注册)
    if (!_modelRegistry.containsKey(T.toString())) {
      registerModel<T>(fromJson);
    }

    // 存储对象及其类型信息
    _activeCache[hashedKey] = {
      'isModel': true,
      'data': data,
      'type': T.toString()
    };

    _updateAccessRecord(hashedKey);
  }

  /// 存储可序列化对象
  ///
  /// [key] 缓存键
  /// [object] 实现了Serializable接口的对象
  void putSerializable<T extends Serializable>(String key, T object) {
    final String hashedKey = _generateKey(key);

    // 序列化对象并存储
    _activeCache[hashedKey] = {
      'isSerializable': true,
      'data': object.serialize(),
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
        'data': jsonString
      });
    } catch (e) {
      debugPrint('无法序列化对象: $e');
      // 如果无法序列化，直接存储
      put(key, data);
    }
  }

  /// 获取基本数据
  ///
  /// [key] 缓存键
  dynamic get(String key) {
    final String hashedKey = _generateKey(key);

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
      _compressedCache.remove(hashedKey);
      _updateAccessRecord(hashedKey);
      return decompressedData;
    }

    // 尝试从磁盘缓存获取
    _tryLoadFromDiskCache(hashedKey);

    return null;
  }

  /// 获取对象
  ///
  /// [key] 缓存键
  /// 返回T类型的对象，或null
  T? getObject<T>(String key) {
    final String hashedKey = _generateKey(key);
    final dynamic cachedData = get(hashedKey);

    if (cachedData == null) return null;

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
      debugPrint('获取对象时出错: $e');
    }

    return null;
  }

  /// 获取可序列化对象
  ///
  /// [key] 缓存键
  /// [factory] 从序列化数据创建对象的工厂函数
  T? getSerializable<T extends Serializable>(String key, T Function(Map<String, dynamic>) factory) {
    final String hashedKey = _generateKey(key);
    final dynamic cachedData = get(hashedKey);

    if (cachedData == null) return null;

    try {
      if (cachedData is Map &&
          cachedData['isSerializable'] == true &&
          cachedData['type'] == T.toString()) {
        final data = cachedData['data'];
        if (data is Map<String, dynamic>) {
          return factory(data);
        }
      }
    } catch (e) {
      debugPrint('获取可序列化对象时出错: $e');
    }

    return null;
  }

  /// 获取动态结构的复杂对象
  ///
  /// [key] 缓存键
  dynamic getDynamicObject(String key) {
    final String hashedKey = _generateKey(key);
    final dynamic cachedData = get(hashedKey);

    if (cachedData == null) return null;

    try {
      if (cachedData is Map && cachedData['isDynamicObject'] == true) {
        final jsonString = cachedData['data'];
        if (jsonString is String) {
          return jsonDecode(jsonString);
        }
      }
    } catch (e) {
      debugPrint('获取动态对象时出错: $e');
    }

    return cachedData;
  }

  /// 检查键是否存在
  ///
  /// [key] 缓存键
  bool containsKey(String key) {
    final String hashedKey = _generateKey(key);
    return _activeCache.containsKey(hashedKey) ||
        _compressedCache.containsKey(hashedKey);
  }

  /// 移除缓存
  ///
  /// [key] 缓存键
  void remove(String key) {
    final String hashedKey = _generateKey(key);
    _activeCache.remove(hashedKey);
    _compressedCache.remove(hashedKey);
    _accessCount.remove(hashedKey);
    _lastAccessTime.remove(hashedKey);
    // 从磁盘缓存中移除
    _diskCacheManager.removeFile(hashedKey);
  }

  /// 清空所有缓存
  void clear() {
    _activeCache.clear();
    _compressedCache.clear();
    _accessCount.clear();
    _lastAccessTime.clear();
    _diskCacheManager.emptyCache();
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

  void _willEvictActiveEntry(LruCacheEntry<String, dynamic> entry) {
    final key = entry.key;
    if (_activeCache.containsKey(key)) {
      _compressDataToStorage(key);
    }
  }

  /// 将不活跃数据压缩
  void _compressInactiveData() {
    final now = DateTime.now();
    final List<String> keysToCompress = [];

    // 查找超过指定时间未访问的数据
    for (final key in _lastAccessTime.keys) {
      final lastAccess = _lastAccessTime[key]!;
      if (now.difference(lastAccess) > _inactiveTimeout && _activeCache.containsKey(key)) {
        keysToCompress.add(key);
      }
    }

    // 压缩数据
    for (final key in keysToCompress) {
      if (_activeCache.containsKey(key)) {
        _compressDataToStorage(key);
      }
    }

    debugPrint('SmartCacheManager 压缩了 ${keysToCompress.length} 项数据');
  }

  /// 压缩数据并存储
  void _compressDataToStorage(String key) {
    try {
      final data = _activeCache[key];
      if (data != null) {
        String jsonData;

        if (data is String) {
          // 如果已经是字符串，直接使用
          jsonData = data;
        } else if (data is Map && data.containsKey('isDynamicObject') && data['isDynamicObject'] == true) {
          // 如果是动态对象，已经JSON序列化
          jsonData = jsonEncode(data);
        } else if (data is Map && data.containsKey('isModel') && data['isModel'] == true) {
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

            jsonData = jsonEncode({
              'isModel': true,
              'type': type,
              'data': jsonObject
            });
          } else {
            throw Exception('无法序列化模型对象');
          }
        } else if (data is Map && data.containsKey('isSerializable') && data['isSerializable'] == true) {
          // 处理可序列化对象
          jsonData = jsonEncode(data);
        } else {
          // 尝试直接序列化
          jsonData = jsonEncode(data);
        }

        // 压缩数据
        final compressedData = gzip.encode(utf8.encode(jsonData));
        // 存储压缩数据
        _compressedCache[key] = Uint8List.fromList(compressedData);
        // 从活跃缓存中移除
        _activeCache.remove(key);

        // 同时存储到磁盘缓存中以防内存清理
        _saveToDiskCache(key, compressedData);
      }
    } catch (e) {
      debugPrint('压缩缓存时出错: $e');
      // 压缩失败时保留在活跃缓存中
    }
  }

  /// 解压缩数据
  dynamic _decompressData(String key) {
    try {
      final compressedData = _compressedCache[key];
      if (compressedData != null) {
        // 解压数据
        final decompressedBytes = gzip.decode(compressedData);
        // 将字节转换回JSON字符串
        final jsonString = utf8.decode(decompressedBytes);
        // 解析JSON
        final dynamic decodedData = jsonDecode(jsonString);

        // 处理模型对象
        if (decodedData is Map && decodedData.containsKey('isModel') && decodedData['isModel'] == true) {
          final type = decodedData['type'];
          final data = decodedData['data'];

          // 通过注册的工厂函数恢复对象
          final modelFactory = _modelRegistry[type];
          if (modelFactory != null && data is Map<String, dynamic>) {
            try {
              final restoredObject = modelFactory(data);
              return {
                'isModel': true,
                'type': type,
                'data': restoredObject
              };
            } catch (e) {
              debugPrint('恢复模型对象时出错: $e');
              // 如果恢复失败，返回原始数据
              return decodedData;
            }
          }
          return decodedData;
        }
        // 处理可序列化对象
        else if (decodedData is Map && decodedData.containsKey('isSerializable') && decodedData['isSerializable'] == true) {
          return decodedData;
        }
        // 处理动态对象
        else if (decodedData is Map && decodedData.containsKey('isDynamicObject') && decodedData['isDynamicObject'] == true) {
          return decodedData;
        }

        return decodedData;
      }
    } catch (e) {
      debugPrint('解压缩数据时出错: $e');
    }
    return null;
  }

  /// 保存到磁盘缓存
  Future<void> _saveToDiskCache(String key, List<int> compressedData) async {
    try {
      await _diskCacheManager.putFile(
        key,
        Uint8List.fromList(compressedData),
        key: key,
        maxAge: _diskCacheMaxAge,
      );
    } catch (e) {
      debugPrint('保存到磁盘缓存时出错: $e');
    }
  }

  /// 尝试从磁盘缓存加载
  Future<void> _tryLoadFromDiskCache(String key) async {
    try {
      final fileInfo = await _diskCacheManager.getFileFromCache(key);
      if (fileInfo != null) {
        final file = fileInfo.file;
        final bytes = await file.readAsBytes();
        _compressedCache[key] = bytes;
      }
    } catch (e) {
      debugPrint('从磁盘缓存加载时出错: $e');
    }
  }

  /// 更新访问记录
  void _updateAccessRecord(String key) {
    _accessCount[key] = (_accessCount[key] ?? 0) + 1;
    _lastAccessTime[key] = DateTime.now();
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
        _compressedCache.remove(hashedKey);
        _updateAccessRecord(hashedKey);
      }
      return;
    }

    // 尝试从磁盘加载
    try {
      final fileInfo = await _diskCacheManager.getFileFromCache(hashedKey);
      if (fileInfo != null) {
        final file = fileInfo.file;
        final bytes = await file.readAsBytes();
        _compressedCache[hashedKey] = bytes;

        // 解压到活跃缓存
        final decompressedData = _decompressData(hashedKey);
        if (decompressedData != null) {
          _activeCache[hashedKey] = decompressedData;
          _compressedCache.remove(hashedKey);
          _updateAccessRecord(hashedKey);
        }
      }
    } catch (e) {
      debugPrint('预加载缓存时出错: $e');
    }
  }

  /// 析构函数
  void dispose() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _activeCache.clear();
    _compressedCache.clear();
    _isInitialized = false;
  }
}