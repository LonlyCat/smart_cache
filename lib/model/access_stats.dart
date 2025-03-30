class AccessStats {
  AccessStats({
    this.stayInMemory = false,
    required this.count,
    required this.lastAccessTime,
  });

  int count;
  DateTime lastAccessTime;
  // 是否正在压缩
  bool isCompressed = false;
  // (写入磁盘后)是否保留在压缩内存中
  bool stayInMemory = false;
}
