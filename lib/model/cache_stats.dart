
class CacheStats {
  CacheStats({
    required this.memoryUsage,
    required this.activeItemsCount,
    required this.compressedItemsCount,
    required this.totalItemsCount,
    required this.registeredModels,
  });

  int activeItemsCount;
  int compressedItemsCount;
  int totalItemsCount;
  List<String> registeredModels;
  CacheMemoryUsage memoryUsage;
}

class CacheMemoryUsage {
  CacheMemoryUsage({
    required this.activeCache,
    required this.compressedCache,
  });

  /// 活跃内存占用，单位 KB
  double activeCache;
  /// 压缩内存占用，单位 KB
  double compressedCache;
}