import 'package:smart_cache/smart_cache_manager.dart';
import 'package:flutter/foundation.dart';

/// 缓存加载状态枚举
///
/// [fromCache] 数据从缓存加载
/// [fromLoader] 数据从加载器加载
/// [noneCache] 仅当 cacheOnly 为 true 且缓存为空时返回
/// [failed] 加载失败
enum CacheableLoadStatus {
  fromCache,
  fromLoader,
  noneCache,
  failed,
}

/// 缓存加载结果类
/// 用于封装加载的数据状态和错误信息
class CacheableLoadResult<T> {
  /// 从缓存加载成功的构造函数
  CacheableLoadResult.fromCache(this.data)
      : status = data != null
            ? CacheableLoadStatus.fromCache
            : CacheableLoadStatus.noneCache,
        error = null;

  /// 从加载器加载成功的构造函数
  CacheableLoadResult.fromLoader(this.data)
      : status = CacheableLoadStatus.fromLoader,
        error = null;

  /// 加载失败的构造函数
  CacheableLoadResult.failed(this.error)
      : status = CacheableLoadStatus.failed,
        data = null;

  /// 加载状态
  final CacheableLoadStatus status;

  /// 加载的数据，加载失败时为null
  final T? data;

  /// 错误信息，加载成功时为null
  final dynamic error;
}

/// 可缓存加载器类
/// 提供从缓存或加载器获取数据的功能
class CacheableLoader {
  /// 以 Stream 形式加载数据
  ///
  /// [key] 缓存的键
  /// [cacheOnly] 是否只从缓存加载，默认为false
  /// [loaderOnly] 是否只从加载器加载，默认为false
  /// [flushWhenSuccess] 是否在加载成功后刷新缓存，默认为 false
  /// [cacheManager] 缓存管理器，不指定时使用标准缓存管理器
  /// [loader] 实际加载数据的函数
  /// [loaderValidator] 加载数据验证器，用于处理是否应该缓存加载器返回的数据
  ///
  /// 返回数据加载过程的流
  static Stream<CacheableLoadResult<T>> loadAsStream<T>(
    String key, {
    bool cacheOnly = false,
    bool loaderOnly = false,
    bool flushWhenSuccess = false,
    SmartCacheManager? cacheManager,
    required Future<T?> Function() loader,
    bool Function(T? data)? loaderValidator,
  }) async* {
    // 确保 cacheOnly 和 loaderOnly 不同时为 true
    assert(!cacheOnly || !loaderOnly, 'cacheOnly 和 loaderOnly 不能同时为 true');
    // 使用提供的缓存管理器或标准缓存管理器
    cacheManager ??= SmartCacheManager.instance;

    // 如果不是只从加载器加载，尝试从缓存获取数据
    if (!loaderOnly) {
      try {
        final cachedData = await cacheManager.get<T>(key);
        if (cachedData != null || cacheOnly) {
          // 缓存中有数据，返回缓存数据
          yield CacheableLoadResult.fromCache(cachedData);
        }
      } catch (e) {
        debugPrint('缓存加载失败: $e');
      }
    }
    // 如果只从缓存加，直接返回
    if (cacheOnly) return;

    // 尝试从加载器获取数据
    try {
      final loadedData = await loader();
      bool willCache = loadedData != null;
      if (loaderValidator != null) {
        willCache = loaderValidator(loadedData);
      }
      // 将数据存入缓存
      if (willCache && loadedData != null) {
        cacheManager.put<T>(key, loadedData, flushNow: flushWhenSuccess);
      }
      // 返回加载器数据
      yield CacheableLoadResult.fromLoader(loadedData);
    } catch (e) {
      // 加载器加载失败，返回错误信息
      yield CacheableLoadResult.failed(e);
    }
  }

  /// 以 Future 的形式加载数据
  ///
  /// [key] 缓存的键
  /// [loader] 实际加载数据的函数
  /// [cacheOnly] 是否只从缓存加载，默认为false
  /// [loaderOnly] 是否只从加载器加载，默认为false
  /// [flushWhenSuccess] 是否在加载成功后刷新缓存，默认为 false
  /// [refreshAfterCache] 是否在返回缓存后刷新缓存，默认为 false
  /// [cacheManager] 缓存管理器，不指定时使用标准缓存管理器
  /// [loaderValidator] 加载数据验证器，用于处理是否应该缓存加载器返回的数据
  ///
  /// 返回数据加载过程的流
  static Future<CacheableLoadResult<T>> load<T>(
    String key, {
    bool cacheOnly = false,
    bool loaderOnly = false,
    bool flushWhenSuccess = false,
    bool refreshAfterCache = false,
    SmartCacheManager? cacheManager,
    required Future<T?> Function() loader,
    bool Function(T? data)? loaderValidator,
  }) async {
    // 确保 cacheOnly 和 loaderOnly 不同时为 true
    assert(!cacheOnly || !loaderOnly, 'cacheOnly 和 loaderOnly 不能同时为 true');
    // 使用提供的缓存管理器或标准缓存管理器
    cacheManager ??= SmartCacheManager.instance;

    // 如果不是只从加载器加载，尝试从缓存获取数据
    if (!loaderOnly) {
      try {
        final cachedData = await cacheManager.get<T>(key);
        if (cachedData != null || cacheOnly) {
          // 如果需要在返回缓存后刷新，且不是仅缓存模式
          if (refreshAfterCache && !cacheOnly) {
            // 在后台执行加载和缓存更新
            _refreshCache(
              key,
              loader: loader,
              cacheManager: cacheManager,
              loaderValidator: loaderValidator,
              flushWhenSuccess: flushWhenSuccess,
            );
          }
          // 返回缓存数据
          return CacheableLoadResult.fromCache(cachedData);
        }
      } catch (e) {
        debugPrint('缓存加载失败: $e');
      }
    }

    // 尝试从加载器获取数据
    try {
      final loadedData = await loader();
      bool willCache = loadedData != null;
      if (loaderValidator != null) {
        willCache = loaderValidator(loadedData);
      }
      // 将数据存入缓存
      if (willCache && loadedData != null) {
        // 返回加载器数据
        cacheManager.put<T>(key, loadedData, flushNow: flushWhenSuccess);
      }
      return CacheableLoadResult.fromLoader(loadedData);
    } catch (e) {
      // 加载器加载失败，返回错误信息
      return CacheableLoadResult.failed(e);
    }
  }

  // 新增一个私有方法用于后台刷新缓存
  static Future<void> _refreshCache<T>(
    String key, {
    required Future<T?> Function() loader,
    required SmartCacheManager cacheManager,
    bool Function(T? data)? loaderValidator,
    bool flushWhenSuccess = false,
  }) async {
    try {
      final loadedData = await loader();
      bool willCache = loadedData != null;
      if (loaderValidator != null) {
        willCache = loaderValidator(loadedData);
      }
      if (willCache && loadedData != null) {
        cacheManager.put<T>(key, loadedData, flushNow: flushWhenSuccess);
      }
    } catch (e) {
      debugPrint('后台刷新缓存失败: $e');
    }
  }
}
