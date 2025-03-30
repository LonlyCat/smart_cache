
import 'dart:typed_data';

/// L1 缓存条目
class L1CacheEntry<T> {
  final String key;
  T value; // 值是可变的，因为访问时会更新
  DateTime lastAccessTime;
  final Type originalType; // 保存原始类型，用于降级时序列化

  L1CacheEntry({
    required this.key,
    required this.value,
    required this.originalType,
  }) : lastAccessTime = DateTime.now();

  void touch() {
    lastAccessTime = DateTime.now();
  }
}

/// L2 缓存条目 (压缩后的数据)
class L2CacheEntry {
  final String key;
  final Uint8List compressedData; // 压缩后的二进制数据
  final Type originalType; // 用于解压后反序列化
  DateTime lastAccessTime;

  L2CacheEntry({
    required this.key,
    required this.compressedData,
    required this.originalType,
  }) : lastAccessTime = DateTime.now();

  void touch() {
    lastAccessTime = DateTime.now();
  }
}

/// L3 磁盘缓存条目元数据 (存储在 Hive 中)
/// Hive Box 可以存储复杂对象，但为了清晰，我们定义一个类
/// 实际存储时，会存储 compressedData 和 L3MetaData
class L3MetaData {
  final String key;
  // 存储 Type 的字符串表示
  final String originalType;
  // 绝对过期时间
  final DateTime expiryTime;
  // 创建时间 (写入磁盘的时间)
  final DateTime createdAt;

  L3MetaData({
    required this.key,
    required this.originalType,
    required this.expiryTime,
  }) : createdAt = DateTime.now();

  L3MetaData.fromMap(Map<dynamic, dynamic> map)
      : key = map['key'] as String,
        originalType = map['originalType'] as String,
        expiryTime = DateTime.fromMillisecondsSinceEpoch(map['expiryTime'] as int),
        createdAt = DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int);

  Map<String, dynamic> toMap() => {
    'key': key,
    'originalType': originalType,
    'expiryTime': expiryTime.millisecondsSinceEpoch,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  bool get isExpired => DateTime.now().isAfter(expiryTime);
}

// 为了方便 Hive 存储，我们可以创建一个包含数据和元数据的 Wrapper
class L3HiveEntry {
  final Uint8List compressedData;
  final L3MetaData metaData;

  L3HiveEntry({required this.compressedData, required this.metaData});

  L3HiveEntry.fromMap(Map<dynamic, dynamic> map)
      : compressedData = map['compressedData'] as Uint8List,
        metaData = L3MetaData.fromMap(map['metaData'] as Map<dynamic, dynamic>);


  Map<String, dynamic> toMap() => {
    'compressedData': compressedData,
    'metaData': metaData.toMap(),
  };
}