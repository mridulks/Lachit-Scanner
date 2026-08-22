import 'package:hive/hive.dart';


part 'document.g.dart';

@HiveType(typeId: 0)
class ScanDocument extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  DateTime createdAt;

  @HiveField(3)
  DateTime updatedAt;

  @HiveField(4)
  List<String> pageIds; // ordered list of ScanPage keys in the pages box

  ScanDocument({
    required this.id,
    required this.name,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? pageIds,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       pageIds = pageIds ?? [];
}
