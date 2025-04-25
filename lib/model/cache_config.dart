class SmartCacheConfig {
  /// L1 缓存项在最后一次访问后，多久降级到 L3
  final Duration l1DowngradeDuration;

  /// L3 磁盘缓存的默认有效期 (从写入磁盘开始计算)
  final Duration l3DefaultExpiryDuration;

  /// 执行缓存清理和降级检查的频率
  final Duration maintenanceInterval;

  /// 磁盘缓存使用的 Box 名称 (Hive)
  final String diskCacheBoxName;

  /// 是否启用日志记录
  final bool enableLogs;

  /// 是否在后台线程(Isolate)执行压缩/解压缩
  /// 注意: 解压缩目前仍需要在主 Isolate 完成 JSON -> Object 的转换
  final bool useIsolateForCompression;

  SmartCacheConfig({
    this.l1DowngradeDuration = const Duration(seconds: 30),
    this.l3DefaultExpiryDuration = const Duration(days: 7),
    this.maintenanceInterval = const Duration(seconds: 15),
    this.diskCacheBoxName = 'smart_cache_l3',
    this.useIsolateForCompression = true,
    this.enableLogs = true, // 生产环境建议关闭或使用更精细的日志级别
  });

  // 添加一些验证逻辑
  void validate() {
    if (l1DowngradeDuration <= Duration.zero || l3DefaultExpiryDuration <= Duration.zero || maintenanceInterval <= Duration.zero) {
      throw ArgumentError("缓存持续时间和间隔必须为正数");
    }
  }
}
