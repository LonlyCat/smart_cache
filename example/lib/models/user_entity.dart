import 'package:json_annotation/json_annotation.dart';
import 'package:smart_cache/smart_cache.dart';

part 'user_entity.g.dart';

@JsonSerializable(explicitToJson: true)
class User {
  String id;
  String name;
  List<Address> addresses;
  final Map<String, dynamic> preferences;

  User({
    required this.id,
    required this.name,
    required this.addresses,
    required this.preferences,
  });

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  Map<String, dynamic> toJson() => _$UserToJson(this);
}

@JsonSerializable()
class Address {
  String street;
  String city;
  String country;

  Address({
    required this.street,
    required this.city,
    required this.country,
  });

  factory Address.fromJson(Map<String, dynamic> json) => _$AddressFromJson(json);

  Map<String, dynamic> toJson() => _$AddressToJson(this);
}


// 不使用json_serializable的示例 - 手动实现序列化
class CustomObject implements Serializable {
  final int id;
  final String name;
  final List<int> values;

  CustomObject({
    required this.id,
    required this.name,
    required this.values,
  });

  @override
  Map<String, dynamic> serialize() {
    return {
      'id': id,
      'name': name,
      'values': values,
    };
  }

  factory CustomObject.deserialize(Map<String, dynamic> data) {
    return CustomObject(
      id: data['id'],
      name: data['name'],
      values: List<int>.from(data['values']),
    );
  }
}
