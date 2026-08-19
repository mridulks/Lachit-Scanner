// GENERATED CODE (hand-written stand-in) — see document.dart.
// Same note as page.g.dart: regenerate with build_runner once you have
// network access to pub.dev, or keep hand-maintaining this small file.

part of 'document.dart';

class ScanDocumentAdapter extends TypeAdapter<ScanDocument> {
  @override
  final int typeId = 0;

  @override
  ScanDocument read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ScanDocument(
      id: fields[0] as String,
      name: fields[1] as String,
      createdAt: fields[2] as DateTime,
      updatedAt: fields[3] as DateTime,
      pageIds: (fields[4] as List).cast<String>(),
    );
  }

  @override
  void write(BinaryWriter writer, ScanDocument obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.createdAt)
      ..writeByte(3)
      ..write(obj.updatedAt)
      ..writeByte(4)
      ..write(obj.pageIds);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScanDocumentAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
