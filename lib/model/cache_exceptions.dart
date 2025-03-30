

/// 基础缓存异常类
class CacheException implements Exception {
  final String message;
  final dynamic originalException;
  final StackTrace? stackTrace;

  CacheException(this.message, {this.originalException, this.stackTrace});

  @override
  String toString() {
    return 'CacheException: $message'
        '${originalException != null ? '\nOriginal Exception: $originalException' : ''}'
        '${stackTrace != null ? '\nStack Trace:\n$stackTrace' : ''}';
  }
}

/// 序列化错误 (例如，对象缺少 toJson 方法)
class SerializationException extends CacheException {
  SerializationException(super.message, {super.originalException, super.stackTrace});
}

/// 反序列化错误 (例如，找不到 fromJson 工厂或 JSON 格式错误)
class DeserializationException extends CacheException {
  DeserializationException(super.message, {super.originalException, super.stackTrace});
}

/// 磁盘操作错误
class DiskCacheException extends CacheException {
  DiskCacheException(super.message, {super.originalException, super.stackTrace});
}

/// 压缩/解压缩错误
class CompressionException extends CacheException {
  CompressionException(super.message, {super.originalException, super.stackTrace});
}