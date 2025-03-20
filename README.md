
# Smart Cache

Smart Cache is a comprehensive caching solution that supports memory caching, compressed caching, and disk caching. It automatically manages active and inactive data to optimize performance.

## Features

- **Memory Caching**: Keeps frequently accessed data in memory for quick retrieval.
- **Compressed Caching**: Compresses inactive data to save memory.
- **Disk Caching**: Stores data on disk to persist across sessions.
- **Automatic Management**: Automatically manages active and inactive data based on access patterns.

## Installation

Add the following dependency to your `pubspec.yaml` file:

```yaml
dependencies:
  smart_cache: ^1.0.0
```

## Usage

### Initialization

Initialize the `SmartCacheManager` singleton:

```dart
import 'package:smart_cache/smart_cache.dart';

void main() {
  SmartCacheManager.standard.init();
}
```

### Storing Data

#### Basic Data

``` dart
SmartCacheManager.standard.put('key', 'value');
```

#### Objects

``` dart
SmartCacheManager.standard.putObject<Product>('product_key', product, fromJson: Product.fromJson);
```

#### Serializable Objects

``` dart
class MySerializableObject implements Serializable {
  // Implement the Serializable interface
  @override
  Map<String, dynamic> serialize() {
    // Serialization logic
  }
}

SmartCacheManager.standard.putSerializable('serializable_key', mySerializableObject);
```

#### Dynamic Objects

``` dart
SmartCacheManager.standard.putDynamicObject('dynamic_key', complexObject);
```

### Retrieving Data

#### Basic Data

``` dart
var value = SmartCacheManager.standard.get('key');
```

#### Objects

``` dart
Product? product = SmartCacheManager.standard.getObject<Product>('product_key');
```

#### Serializable Objects

``` dart
MySerializableObject? obj = SmartCacheManager.standard.getSerializable<MySerializableObject>('serializable_key', MySerializableObject.fromJson);
```

#### Dynamic Objects

``` dart
var complexObject = SmartCacheManager.standard.getDynamicObject('dynamic_key');
```

### Cache Management

#### Check if Key Exists

``` dart
bool exists = SmartCacheManager.standard.containsKey('key');
```

#### Remove Data

``` dart
SmartCacheManager.standard.remove('key');
```

#### Clear All Cache

``` dart
SmartCacheManager.standard.clear();
```

### Cache Statistics

Retrieve cache statistics:

```dart
CacheStats stats = SmartCacheManager.standard.getStats();
```

## License

This project is licensed under the MIT License.
