// GENERATED CODE (hand-written stand-in) — see page.dart.
//
// This sandbox has no network access to pub.dev, so `build_runner` could
// not be run here. This file was written to match exactly what
// `dart run build_runner build` would produce for the @HiveType/@HiveField
// annotations in page.dart. Once you have the project on your own machine,
// you can safely delete this and regenerate with:
//   dart run build_runner build --delete-conflicting-outputs
// or just keep hand-maintaining it — it's small and stable.

part of 'page.dart';

class ScanPageAdapter extends TypeAdapter<ScanPage> {
  @override
  final int typeId = 1;

  @override
  ScanPage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ScanPage(
      id: fields[0] as String,
      order: fields[1] as int,
      imagePath: fields[2] as String,
      sourceModeIndex: fields[3] as int,
      rotation: fields[4] as int,
      colorModeIndex: fields[5] as int,
      createdAt: fields[6] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, ScanPage obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.order)
      ..writeByte(2)
      ..write(obj.imagePath)
      ..writeByte(3)
      ..write(obj.sourceModeIndex)
      ..writeByte(4)
      ..write(obj.rotation)
      ..writeByte(5)
      ..write(obj.colorModeIndex)
      ..writeByte(6)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScanPageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
