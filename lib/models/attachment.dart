import 'package:flutter/rendering.dart';
import 'package:hive/hive.dart';

part 'attachment.g.dart';

@HiveType(typeId: 10)
enum AttachmentType {
	@HiveField(0)
	image,
	@HiveField(1)
	webm,
	@HiveField(2)
	mp4,
	@HiveField(3)
	mp3,
	@HiveField(4)
	pdf
}

extension IsVideo on AttachmentType {
	bool get isVideo => this == AttachmentType.webm || this == AttachmentType.mp4;
}

class Attachment {
	final String board;
	final String ext;
	final String filename;
	final AttachmentType type;
	final Uri url;
	Uri thumbnailUrl;
	final String md5;
	final bool spoiler;
	final int? width;
	final int? height;
	final int? threadId;
	final int? sizeInBytes;
	String id;
	final bool useRandomUseragent;
	Attachment({
		required this.type,
		required this.board,
		required this.id,
		required this.ext,
		required this.filename,
		required this.url,
		required this.thumbnailUrl,
		required this.md5,
		bool? spoiler,
		required this.width,
		required this.height,
		required this.threadId,
		required this.sizeInBytes,
		this.useRandomUseragent = false
	}) : spoiler = spoiler ?? false;

	bool? get isLandscape => (width == null || height == null) ? null : width! > height!;

	double get aspectRatio {
		if (width == null || height == null) {
			return 1;
		}
		return width! / height!;
	}

	Size estimateFittedSize({
		required Size size,
		BoxFit fit = BoxFit.contain,
	}) {
		if (width == null || height == null) {
			return size;
		}
		return applyBoxFit(
			fit,
			Size(width!.toDouble(), height!.toDouble()),
			size
		).destination;
	}

	String get globalId => '${board}_$id';

	@override
	String toString() => 'Attachment(board: $board, id: $id, ext: $ext, filename: $filename, type: $type, url: $url, thumbnailUrl: $thumbnailUrl, md5: $md5, spoiler: $spoiler, width: $width, height: $height, threadId: $threadId)';

	@override
	bool operator==(Object other) => (other is Attachment) && (other.url == url) && (other.thumbnailUrl == thumbnailUrl);

	@override
	int get hashCode => Object.hash(url, thumbnailUrl);
}

class AttachmentAdapter extends TypeAdapter<Attachment> {
  @override
  final int typeId = 9;

  @override
  Attachment read(BinaryReader reader) {
    final numOfFields = reader.readByte();
		final Map<int, dynamic> fields;
		if (numOfFields == 255) {
			// Dynamic number of fields
			fields = {};
			while (true) {
				final int fieldId = reader.readByte();
				fields[fieldId] = reader.read();
				if (fieldId == 0) {
					break;
				}
			}
		}
		else {
			fields = <int, dynamic>{
				for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
			};
		}
    return Attachment(
      type: fields[4] as AttachmentType,
      board: fields[0] as String,
      id: fields[13] == null ? '${fields[1]}' : fields[13] as String,
      ext: fields[2] as String,
      filename: fields[3] as String,
      url: fields[5] as Uri,
      thumbnailUrl: fields[6] as Uri,
      md5: fields[7] as String,
      spoiler: fields[8] as bool?,
      width: fields[9] as int?,
      height: fields[10] as int?,
      threadId: fields[11] as int?,
      sizeInBytes: fields[12] as int?,
			useRandomUseragent: fields[14] as bool? ?? false
    );
  }

  @override
  void write(BinaryWriter writer, Attachment obj) {
    writer
      ..writeByte(255)
      ..writeByte(2)
      ..write(obj.ext)
      ..writeByte(3)
      ..write(obj.filename)
      ..writeByte(4)
      ..write(obj.type)
      ..writeByte(5)
      ..write(obj.url)
      ..writeByte(6)
      ..write(obj.thumbnailUrl)
      ..writeByte(7)
      ..write(obj.md5);
		if (obj.spoiler) {
			writer..writeByte(8)..write(obj.spoiler);
		}
		if (obj.width != null) {
      writer..writeByte(9)..write(obj.width);
		}
		if (obj.height != null) {
      writer..writeByte(10)..write(obj.height);
		}
		if (obj.threadId != null) {
      writer..writeByte(11)..write(obj.threadId);
		}
		if (obj.sizeInBytes != null) {
      writer..writeByte(12)..write(obj.sizeInBytes);
		}
		writer
      ..writeByte(13)
      ..write(obj.id);
		writer
      ..writeByte(0)
      ..write(obj.board);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AttachmentAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}