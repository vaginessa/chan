import 'package:chan/models/flag.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/attachment.dart';
import 'package:chan/services/filtering.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

part 'thread.g.dart';

class Thread implements Filterable {
	final List<Post> posts_;
	final bool isArchived;
	final bool isDeleted;
	final int replyCount;
	final int imageCount;
	@override
	final int id;
	@override
	final String board;
	Attachment? deprecatedAttachment;
	final String? title;
	bool isSticky;
	final DateTime time;
	final ImageboardFlag? flag;
	int? currentPage;
	int? uniqueIPCount;
	int? customSpoilerId;
	bool attachmentDeleted;
	final List<Attachment> attachments;
	ThreadVariant? suggestedVariant;
	Thread({
		required this.posts_,
		this.isArchived = false,
		this.isDeleted = false,
		required this.replyCount,
		required this.imageCount,
		required this.id,
		this.deprecatedAttachment,
		this.attachmentDeleted = false,
		required this.board,
		required this.title,
		required this.isSticky,
		required this.time,
		this.flag,
		this.currentPage,
		this.uniqueIPCount,
		this.customSpoilerId,
		required this.attachments,
		this.suggestedVariant
	}) {
		if (deprecatedAttachment != null) {
			attachments.insert(0, deprecatedAttachment!);
			deprecatedAttachment = null;
		}
	}
	
	bool _initialized = false;
	List<Post> get posts {
		if (!_initialized) {
			Map<int, Post> postsById = {};
			for (final post in posts_) {
				postsById[post.id] = post;
				post.replyIds = [];
			}
			for (final post in posts_) {
				for (final referencedPostId in post.repliedToIds) {
					if (!(postsById[referencedPostId]?.replyIds.contains(post.id) ?? true)) {
						postsById[referencedPostId]?.replyIds.add(post.id);
					}
				}
			}
			_initialized = true;
		}
		return posts_;
	}

	Future<void> preinit({bool catalog = false}) async {
		if (catalog) {
			await posts_.first.preinit();
		}
		else {
			for (final post in posts_) {
				await post.preinit();
			}
		}
	}

	@override
	bool operator == (dynamic other) {
		return (other is Thread)
			&& (other.id == id)
			&& (other.posts_.length == posts_.length)
			&& other.posts_.last == posts_.last
			&& other.currentPage == currentPage
			&& other.isArchived == isArchived
			&& other.isDeleted == isDeleted
			&& other.isSticky == isSticky
			&& listEquals(other.attachments, attachments);
	}
	@override
	int get hashCode => id;

	@override
	String toString() {
		return 'Thread /$board/$id';
	}

	@override
	String? getFilterFieldText(String fieldName) {
		switch (fieldName) {
			case 'subject':
				return title;
			case 'name':
				return posts_.first.name;
			case 'filename':
				return attachments.map((a) => a.filename).join(' ');
			case 'text':
				return posts_.first.span.buildText();
			case 'postID':
				return id.toString();
			case 'posterID':
				return posts_.first.posterId;
			case 'flag':
				return posts_.first.flag?.name;
			case 'md5':
				return attachments.map((a) => a.md5).join(' ');
			default:
				return null;
		}
	}
	@override
	bool get hasFile => attachments.isNotEmpty;
	@override
	bool get isThread => true;
	@override
	List<int> get repliedToIds => [];
	@override
	Iterable<String> get md5s => attachments.map((a) => a.md5);

	ThreadIdentifier get identifier => ThreadIdentifier(board, id);
}

@HiveType(typeId: 23)
class ThreadIdentifier {
	@HiveField(0)
	final String board;
	@HiveField(1)
	final int id;
	ThreadIdentifier(this.board, this.id);

	@override
	String toString() => 'ThreadIdentifier: /$board/$id';

	@override
	bool operator == (dynamic other) => (other is ThreadIdentifier) && (other.board == board) && (other.id == id);
	@override
	int get hashCode => board.hashCode * 31 + id.hashCode;
}

class BoardThreadOrPostIdentifier {
	final String board;
	final int? threadId;
	final int? postId;
	BoardThreadOrPostIdentifier(this.board, [this.threadId, this.postId]);
	@override
	String toString() => '/$board/$threadId/$postId';
	ThreadIdentifier? get threadIdentifier => threadId == null ? null : ThreadIdentifier(board, threadId!);

	@override
	bool operator == (Object other) => (other is BoardThreadOrPostIdentifier) && (other.board == board) && (other.threadId == threadId) && (other.postId == postId);
	@override
	int get hashCode => Object.hash(board, threadId, postId);
}

class ThreadAdapter extends TypeAdapter<Thread> {
  @override
  final int typeId = 15;

  @override
  Thread read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final Map<int, dynamic> fields;
		if (numOfFields == 255) {
			// New version (terminated with zero)
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
			// Previous versions (last field is 16, numOfFields is untrustworthy)
			fields = {
				for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
			};
		}
    return Thread(
      posts_: (fields[0] as List).cast<Post>(),
      isArchived: fields[1] as bool,
      isDeleted: fields[2] as bool,
      replyCount: fields[3] as int,
      imageCount: fields[4] as int,
      id: fields[5] as int,
      deprecatedAttachment: fields[7] as Attachment?,
      attachmentDeleted: fields[15] == null ? false : fields[15] as bool,
      board: fields[6] as String,
      title: fields[8] as String?,
      isSticky: fields[9] as bool,
      time: fields[10] as DateTime,
      flag: fields[11] as ImageboardFlag?,
      currentPage: fields[12] as int?,
      uniqueIPCount: fields[13] as int?,
      customSpoilerId: fields[14] as int?,
      attachments:
          fields[16] == null ? [] : (fields[16] as List).cast<Attachment>(),
			suggestedVariant: fields[17] as ThreadVariant?
    );
  }

  @override
  void write(BinaryWriter writer, Thread obj) {
    writer
      ..writeByte(255)
      ..writeByte(1)
      ..write(obj.isArchived)
      ..writeByte(2)
      ..write(obj.isDeleted)
      ..writeByte(3)
      ..write(obj.replyCount)
      ..writeByte(4)
      ..write(obj.imageCount)
      ..writeByte(5)
      ..write(obj.id)
      ..writeByte(6)
      ..write(obj.board)
      ..writeByte(8)
      ..write(obj.title)
      ..writeByte(9)
      ..write(obj.isSticky)
      ..writeByte(10)
      ..write(obj.time)
      ..writeByte(15)
      ..write(obj.attachmentDeleted)
      ..writeByte(16)
      ..write(obj.attachments);
		if (obj.flag != null) {
      writer..writeByte(11)..write(obj.flag);
		}
		if (obj.currentPage != null) {
			writer..writeByte(12)..write(obj.currentPage);
		}
		if (obj.uniqueIPCount != null) {
			writer..writeByte(13)..write(obj.uniqueIPCount);
		}
		if (obj.customSpoilerId != null) {
			writer..writeByte(14)..write(obj.customSpoilerId);
		}
		if (obj.suggestedVariant != null) {
			writer..writeByte(17)..write(obj.suggestedVariant);
		}
		writer
      ..writeByte(0)
      ..write(obj.posts_);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThreadAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
