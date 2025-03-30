
import 'dart:typed_data';

/// SmartCacheManager Stats
class CacheStats {

  CacheStats({
    this.l3Count = 0,
    this.l1Cache = const {},
    this.l2Cache = const {},
  });

  int l3Count;

  Map<String, dynamic> l1Cache;
  Map<String, Uint8List> l2Cache;

  int get totalCount => l1Count + l2Count + l3Count;
  int get l1Count => l1Cache.length;
  int get l2Count => l2Cache.length;

  /// L2 Cache Size in KB
  double get l2CacheBytes {
    double totalBytes = l2Cache.values.fold(0, (prev, element) => prev + element.lengthInBytes);
    return totalBytes / 1024;
  }
}