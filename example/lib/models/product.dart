
import 'dart:convert';
import 'dart:typed_data';

class Product {
  final String id;
  final String name;
  final String description;
  final double price;
  final List<String> categories;
  final Map<String, dynamic> attributes;
  final List<Variant> variants;

  Product({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
    required this.categories,
    required this.attributes,
    required this.variants,
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      price: json['price'],
      categories: List<String>.from(json['categories']),
      attributes: json['attributes'],
      variants: (json['variants'] as List)
          .map((v) => Variant.fromJson(v))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'price': price,
      'categories': categories,
      'attributes': attributes,
      'variants': variants.map((v) => v.toJson()).toList(),
    };
  }

  double? _memorySize;
  double get memorySize => _memorySize ??= _estimateProductMemorySize(this);

  // Estimate memory usage of a Product object in KB
  double _estimateProductMemorySize(Product product) {
    // 将对象转换为 JSON
    final String jsonString = jsonEncode(product.toJson());

    // 将 JSON 字符串转换为 UTF-8 编码的字节
    final Uint8List data = utf8.encode(jsonString);

    // 返回字节数转 KB
    int bytes = data.lengthInBytes;
    return bytes / 1024;
  }
}

class Variant {
  final String id;
  final String name;
  final double price;
  final Map<String, String> options;

  Variant({
    required this.id,
    required this.name,
    required this.price,
    required this.options,
  });

  factory Variant.fromJson(Map<String, dynamic> json) {
    return Variant(
      id: json['id'],
      name: json['name'],
      price: json['price'],
      options: Map<String, String>.from(json['options']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'price': price,
      'options': options,
    };
  }
}