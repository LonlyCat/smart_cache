
# Smart Cache

Smart Cache 是一个综合的缓存解决方案，支持内存缓存、压缩缓存和磁盘缓存。它会根访问模式自动管理活跃和非活跃数据，以优化性能。

## 功能

- **内存缓存**：将频繁访问的数据保存在内存中以便快速检索。
- **压缩缓存**：压缩非活跃数据以节省内存。
- **磁盘缓存**：将数据存储在磁盘上以便在会话之间持久化。
- **自动管理**：根据访问模式自动管理活跃和非活跃数据。

## 安装

在你的 `pubspec.yaml` 文件中添加以下依赖项：

```yaml
dependencies:
  smart_cache: ^1.0.0
```

## 使用方法

### 初始化

初始化 `SmartCacheManager` 单例：

``` dart
import 'package:smart_cache/smart_cache.dart';

void main() {
  SmartCacheManager.standard.init();
}
```

### 存储数据

#### 基本数据

``` dart
SmartCacheManager.standard.put('key', 'value');
```

#### 对象

``` dart
SmartCacheManager.standard.putObject<Product>('product_key', product, fromJson: Product.fromJson);
```

#### 可序列化对象

``` dart
class MySerializableObject implements Serializable {
  // 实现 Serializable 接口
  @override
  Map<String, dynamic> serialize() {
    // 序列化逻辑
  }
}

SmartCacheManager.standard.putSerializable('serializable_key', mySerializableObject);
```

#### 动态对象

``` dart
SmartCacheManager.standard.putDynamicObject('dynamic_key', complexObject);
```

### 获取数据

#### 基本数据

``` dart
var value = SmartCacheManager.standard.get('key');
```

#### 对象

``` dart
Product? product = SmartCacheManager.standard.getObject<Product>('product_key');
```

#### 可序列化对象

``` dart
MySerializableObject? obj = SmartCacheManager.standard.getSerializable<MySerializableObject>('serializable_key', MySerializableObject.fromJson);
```

#### 动态对象

``` dart
var complexObject = SmartCacheManager.standard.getDynamicObject('dynamic_key');
```

### 缓存管理

#### 检查键是否存在

``` dart
bool exists = SmartCacheManager.standard.containsKey('key');
```

#### 移除数据

``` dart
SmartCacheManager.standard.remove('key');
```

#### 清空所有缓存

``` dart
SmartCacheManager.standard.clear();
```

### 缓存统计

获取缓存统计信息：

``` dart
CacheStats stats = SmartCacheManager.standard.getStats();
```

## 许可证

此项目使用 MIT 许可证。