/// SmartCacheManager Stats
class CacheStats {
  CacheStats({
    this.l2Count = 0,
    this.l1Cache = const {},
  });

  int l2Count;

  Map<String, dynamic> l1Cache;

  int get totalCount => l1Count + l2Count;
  int get l1Count => l1Cache.length;
}
