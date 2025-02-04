import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/flag.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/search.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/filtering.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/incognito.dart';
import 'package:chan/services/pick_attachment.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/thread_watcher.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/widgets/refreshable_list.dart';
import 'package:chan/widgets/util.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:extended_image_library/extended_image_library.dart';
import 'package:flutter/widgets.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tuple/tuple.dart';
import 'package:uuid/uuid.dart';
import 'package:chan/util.dart';
import 'package:chan/main.dart' as main;
part 'persistence.g.dart';

const _knownCacheDirs = {
	cacheImageFolderName: 'Images',
	'webmcache': 'Converted WEBM files',
	'sharecache': 'Media exported for sharing',
	'webpickercache': 'Images picked from web'
};

const _boxPrefix = '';
const _backupBoxPrefix = 'backup_';
const _backupUpdateDuration = Duration(minutes: 10);

class UriAdapter extends TypeAdapter<Uri> {
	@override
	final typeId = 12;

	@override
	Uri read(BinaryReader reader) {
		var str = reader.readString();
		return Uri.parse(str);
	}

	@override
	void write(BinaryWriter writer, Uri obj) {
		writer.writeString(obj.toString());
	}
}

const _savedAttachmentThumbnailsDir = 'saved_attachments_thumbs';
const _savedAttachmentsDir = 'saved_attachments';
const _maxAutosavedIdsPerBoard = 250;
const _maxHiddenIdsPerBoard = 1000;

abstract class EphemeralThreadStateOwner {
	Future<void> ephemeralThreadStateDidUpdate(PersistentThreadState state);
}

class Persistence extends ChangeNotifier implements EphemeralThreadStateOwner {
	final String id;
	Persistence(this.id);
	late final Box<PersistentThreadState> _threadStateBox;
	Box<PersistentThreadState> get threadStateBox => _threadStateBox;
	Map<String, ImageboardBoard> get boards => settings.boardsBySite[id]!;
	Map<String, SavedAttachment> get savedAttachments => settings.savedAttachmentsBySite[id]!;
	Map<String, SavedPost> get savedPosts => settings.savedPostsBySite[id]!;
	static PersistentRecentSearches get recentSearches => settings.recentSearches;
	PersistentBrowserState get browserState => settings.browserStateBySite[id]!;
	static List<PersistentBrowserTab> get tabs => settings.tabs;
	static int get currentTabIndex => settings.currentTabIndex;
	static set currentTabIndex(int setting) {
		settings.currentTabIndex = setting;
	}
	final savedAttachmentsListenable = EasyListenable();
	final savedPostsListenable = EasyListenable();
	final hiddenMD5sListenable = EasyListenable();
	static late final SavedSettings settings;
	static late final Directory temporaryDirectory;
	static late final Directory documentsDirectory;
	static late final PersistCookieJar wifiCookies;
	static late final PersistCookieJar cellularCookies;
	static PersistCookieJar get currentCookies {
		if (main.settings.connectivity == ConnectivityResult.mobile) {
			return cellularCookies;
		}
		return wifiCookies;
	}
	// Do not persist
	static bool enableHistory = true;
	static final browserHistoryStatusListenable = EasyListenable();
	static final tabsListenable = EasyListenable();
	static final recentSearchesListenable = EasyListenable();
	static String get _settingsBoxName => '${_boxPrefix}settings';
	static String get _settingsBoxPath => '${documentsDirectory.path}/$_settingsBoxName.hive';
	static String get _settingsBackupBoxName => '${_backupBoxPrefix}settings';
	static String get _settingsBackupBoxPath => '${documentsDirectory.path}/$_settingsBackupBoxName.hive';

	static Future<void> initializeStatic() async {
		await Hive.initFlutter();
		Hive.registerAdapter(ColorAdapter());
		Hive.registerAdapter(SavedThemeAdapter());
		Hive.registerAdapter(TristateSystemSettingAdapter());
		Hive.registerAdapter(AutoloadAttachmentsSettingAdapter());
		Hive.registerAdapter(ThreadSortingMethodAdapter());
		Hive.registerAdapter(CatalogVariantAdapter());
		Hive.registerAdapter(ThreadVariantAdapter());
		Hive.registerAdapter(ContentSettingsAdapter());
		Hive.registerAdapter(PostDisplayFieldAdapter());
		Hive.registerAdapter(SettingsQuickActionAdapter());
		Hive.registerAdapter(WebmTranscodingSettingAdapter());
		Hive.registerAdapter(SavedSettingsAdapter());
		Hive.registerAdapter(UriAdapter());
		Hive.registerAdapter(AttachmentTypeAdapter());
		Hive.registerAdapter(AttachmentAdapter());
		Hive.registerAdapter(ImageboardFlagAdapter());
		Hive.registerAdapter(PostSpanFormatAdapter());
		Hive.registerAdapter(PostAdapter());
		Hive.registerAdapter(ThreadAdapter());
		Hive.registerAdapter(ImageboardBoardAdapter());
		Hive.registerAdapter(PostReceiptAdapter());
		Hive.registerAdapter(PersistentThreadStateAdapter());
		Hive.registerAdapter(ImageboardArchiveSearchQueryAdapter());
		Hive.registerAdapter(PostTypeFilterAdapter());
		Hive.registerAdapter(MediaFilterAdapter());
		Hive.registerAdapter(PostDeletionStatusFilterAdapter());
		Hive.registerAdapter(PersistentRecentSearchesAdapter());
		Hive.registerAdapter(SavedAttachmentAdapter());
		Hive.registerAdapter(SavedPostAdapter());
		Hive.registerAdapter(ThreadIdentifierAdapter());
		Hive.registerAdapter(PersistentBrowserTabAdapter());
		Hive.registerAdapter(ThreadWatchAdapter());
		Hive.registerAdapter(BoardWatchAdapter());
		Hive.registerAdapter(PersistentBrowserStateAdapter());
		temporaryDirectory = await getTemporaryDirectory();
		documentsDirectory = await getApplicationDocumentsDirectory();
		wifiCookies = PersistCookieJar(
			storage: FileStorage(temporaryDirectory.path)
		);
		cellularCookies = PersistCookieJar(
			storage: FileStorage('${temporaryDirectory.path}/cellular')
		);
		await Directory('${documentsDirectory.path}/$_savedAttachmentsDir').create(recursive: true);
		await Directory('${documentsDirectory.path}/$_savedAttachmentThumbnailsDir').create(recursive: true);
		Box<SavedSettings> settingsBox;
		try {
			settingsBox = await Hive.openBox<SavedSettings>(_settingsBoxName,
				compactionStrategy: (int entries, int deletedEntries) {
					return deletedEntries > 5;
				},
				crashRecovery: false
			);
			await File(_settingsBoxPath).copy(_settingsBackupBoxPath);
		}
		catch (e, st) {
			if (await File(_settingsBackupBoxPath).exists()) {
				print('Attempting to handle $e opening settings by restoring backup');
				print(st);
				final backupTime = (await File(_settingsBackupBoxPath).stat()).modified;
				await File(_settingsBoxPath).copy('${documentsDirectory.path}/$_settingsBoxName.broken.hive');
				await File(_settingsBackupBoxPath).copy(_settingsBoxPath);
				settingsBox = await Hive.openBox<SavedSettings>(_settingsBoxName,
					compactionStrategy: (int entries, int deletedEntries) {
						return deletedEntries > 5;
					}
				);
				Future.delayed(const Duration(seconds: 5), () {
					alertError(ImageboardRegistry.instance.context!, 'Settings corruption\nSettings database was restored to backup from $backupTime (${formatRelativeTime(backupTime)} ago)');
				});
			}
			else {
				rethrow;
			}
		}
		settings = settingsBox.get('settings', defaultValue: SavedSettings(
			useInternalBrowser: true
		))!;
		if (settings.automaticCacheClearDays < 100000) {
			// Don't await
			clearFilesystemCaches(Duration(days: settings.automaticCacheClearDays));
		}
		Timer.periodic(_backupUpdateDuration, (_) {
			File(_settingsBoxPath).copy(_settingsBackupBoxPath);
		});
	}

	static Future<Map<String, int>> getFilesystemCacheSizes() async {
		final folderSizes = <String, int>{};
		final systemTempDirectory = Persistence.temporaryDirectory;
		await for (final directory in systemTempDirectory.list()) {
			int size = 0;
			final stat = await directory.stat();
			if (stat.type == FileSystemEntityType.directory) {
				await for (final subentry in Directory(directory.path).list(recursive: true)) {
					size += (await subentry.stat()).size;
				}
			}
			else {
				size = stat.size;
			}
			folderSizes.update(_knownCacheDirs[directory.path.split('/').last] ?? 'Other', (total) => total + size, ifAbsent: () => size);
		}
		return folderSizes;
	}

	static Future<void> clearFilesystemCaches(Duration? olderThan) async {
		if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
			// The temporary directory is shared between applications, it's not safe to clear it. 
			return;
		}
		DateTime? deadline;
		if (olderThan != null) {
			deadline = DateTime.now().subtract(olderThan);
		}
		int deletedSize = 0;
		int deletedCount = 0;
		await for (final child in temporaryDirectory.list(recursive: true)) {
			final stat = child.statSync();
			if (stat.type == FileSystemEntityType.file) {
				// Probably something from file_pickers
				if (deadline == null || stat.accessed.compareTo(deadline) < 0) {
					deletedSize += stat.size;
					deletedCount++;
					try {
						await child.delete();
					}
					catch (e) {
						print('Error deleting file: $e');
					}
				}
			}
		}
		if (deletedCount > 0) {
			print('Deleted $deletedCount files totalling ${(deletedSize / 1000000).toStringAsFixed(1)} MB');
		}
	}

	Future<void> _cleanupThreads(Duration olderThan) async {
		final deadline = DateTime.now().subtract(olderThan);
		final toPreserve = savedPosts.values.map((v) => '${v.post.board}/${v.post.threadId}').toSet();
		final toDelete = threadStateBox.keys.where((key) {
			return (threadStateBox.get(key)?.youIds.isEmpty ?? false) // no replies
				&& (threadStateBox.get(key)?.lastOpenedTime.isBefore(deadline) ?? false) // not opened recently
				&& (!toPreserve.contains(key)); // connect to a saved post
		});
		if (toDelete.isNotEmpty) {
			print('Deleting ${toDelete.length} threads');
		}
		await threadStateBox.deleteAll(toDelete);
	}

	Future<void> deleteAllData() async {
		settings.boardsBySite.remove(id);
		settings.savedPostsBySite.remove(id);
		settings.browserStateBySite.remove(id);
		await threadStateBox.deleteFromDisk();
	}

	String get _threadStatesBoxName => '${_boxPrefix}threadStates_$id';
	String get _threadStatesBackupBoxName => '${_backupBoxPrefix}threadStates_$id';
	String get _threadStatesBoxPath => '${documentsDirectory.path}/$_threadStatesBoxName.hive';
	String get _threadStatesBackupBoxPath => '${documentsDirectory.path}/$_threadStatesBackupBoxName.hive';

	Future<void> initialize() async {
		try {
			_threadStateBox = await Hive.openBox<PersistentThreadState>(_threadStatesBoxName, crashRecovery: false);
			if (await File(_threadStatesBoxPath).exists()) {
				await File(_threadStatesBoxPath).copy(_threadStatesBackupBoxPath);
			}
			else if (await File(_threadStatesBoxPath.toLowerCase()).exists()) {
				await File(_threadStatesBoxPath.toLowerCase()).copy(_threadStatesBackupBoxPath);
			}
		}
		catch (e, st) {
			if (await File(_threadStatesBackupBoxPath).exists()) {
				print('Attempting to handle $e opening $id by restoring backup');
				print(st);
				final backupTime = (await File(_threadStatesBackupBoxPath).stat()).modified;
				if (await File(_threadStatesBoxPath).exists()) {
					await File(_threadStatesBoxPath).copy('${documentsDirectory.path}/$_threadStatesBoxName.broken.hive');
					await File(_threadStatesBackupBoxPath).copy(_threadStatesBoxPath);
				}
				else if (await File(_threadStatesBoxPath.toLowerCase()).exists()) {
					await File(_threadStatesBoxPath.toLowerCase()).copy('${documentsDirectory.path}/$_threadStatesBoxName.broken.hive');
					await File(_threadStatesBackupBoxPath).copy(_threadStatesBoxPath.toLowerCase());
				}
				_threadStateBox = await Hive.openBox<PersistentThreadState>(_threadStatesBoxName);
				Future.delayed(const Duration(seconds: 5), () {
					alertError(ImageboardRegistry.instance.context!, 'Database corruption\n$id database was restored to backup from $backupTime (${formatRelativeTime(backupTime)} ago)');
				});
			}
			else {
				rethrow;
			}
		}
		if (await Hive.boxExists('searches_$id')) {
			print('Migrating searches box');
			final searchesBox = await Hive.openBox<PersistentRecentSearches>('${_boxPrefix}searches_$id');
			final existingRecentSearches = searchesBox.get('recentSearches');
			if (existingRecentSearches != null) {
				settings.deprecatedRecentSearchesBySite[id] = existingRecentSearches;
			}
			await searchesBox.deleteFromDisk();
		}
		if (settings.deprecatedRecentSearchesBySite[id]?.entries.isNotEmpty == true) {
			print('Migrating recent searches');
			for (final search in settings.deprecatedRecentSearchesBySite[id]!.entries) {
				Persistence.recentSearches.add(search..imageboardKey = id);
			}
		}
		settings.deprecatedRecentSearchesBySite.remove(id);
		if (await Hive.boxExists('browserStates_$id')) {
			print('Migrating browser states box');
			final browserStateBox = await Hive.openBox<PersistentBrowserState>('${_boxPrefix}browserStates_$id');
			final existingBrowserState = browserStateBox.get('browserState');
			if (existingBrowserState != null) {
				settings.browserStateBySite[id] = existingBrowserState;
			}
			await browserStateBox.deleteFromDisk();
		}
		settings.browserStateBySite.putIfAbsent(id, () => PersistentBrowserState(
			hiddenIds: {},
			favouriteBoards: [],
			autosavedIds: {},
			hiddenImageMD5s: [],
			loginFields: {},
			threadWatches: [],
			boardWatches: [],
			notificationsMigrated: true,
			deprecatedBoardSortingMethods: {},
			deprecatedBoardReverseSortings: {},
			catalogVariants: {},
			postingNames: {}
		));
		if (browserState.deprecatedTabs.isNotEmpty && ImageboardRegistry.instance.getImageboardUnsafe(id) != null) {
			print('Migrating tabs');
			for (final deprecatedTab in browserState.deprecatedTabs) {
				if (Persistence.tabs.length == 1 && Persistence.tabs.first.imageboardKey == null) {
					// It's the dummy tab
					Persistence.tabs.clear();
				}
				Persistence.tabs.add(deprecatedTab..imageboardKey = id);
			}
			browserState.deprecatedTabs.clear();
			didUpdateBrowserState();
			Persistence.didUpdateTabs();
		}
		if (await Hive.boxExists('boards_$id')) {
			print('Migrating boards box');
			final boardBox = await Hive.openBox<ImageboardBoard>('${_boxPrefix}boards_$id');
			settings.boardsBySite[id] = {
				for (final key in boardBox.keys) key.toString(): boardBox.get(key)!
			};
			await boardBox.deleteFromDisk();
		}
		settings.boardsBySite.putIfAbsent(id, () => {});
		if (await Hive.boxExists('savedAttachments_$id')) {
			print('Migrating saved attachments box');
			final savedAttachmentsBox = await Hive.openBox<SavedAttachment>('${_boxPrefix}savedAttachments_$id');
			settings.savedAttachmentsBySite[id] = {
				for (final key in savedAttachmentsBox.keys) key.toString(): savedAttachmentsBox.get(key)!
			};
			await savedAttachmentsBox.deleteFromDisk();
		}
		settings.savedAttachmentsBySite.putIfAbsent(id, () => {});
		if (await Hive.boxExists('savedPosts_$id')) {
			print('Migrating saved posts box');
			final savedPostsBox = await Hive.openBox<SavedPost>('${_boxPrefix}savedPosts_$id');
			settings.savedPostsBySite[id] = {
				for (final key in savedPostsBox.keys) key.toString(): savedPostsBox.get(key)!
			};
			await savedPostsBox.deleteFromDisk();
		}
		settings.savedPostsBySite.putIfAbsent(id, () => {});
		// Cleanup expanding lists
		for (final list in browserState.autosavedIds.values) {
			list.removeRange(0, max(0, list.length - _maxAutosavedIdsPerBoard));
		}
		for (final list in browserState.hiddenIds.values) {
			list.removeRange(0, max(0, list.length - _maxHiddenIdsPerBoard));
		}
		if (!browserState.notificationsMigrated) {
			browserState.threadWatches.clear();
			for (final threadState in threadStateBox.values) {
				if (threadState.savedTime != null && threadState.thread?.isArchived == false) {
					browserState.threadWatches.add(ThreadWatch(
						board: threadState.board,
						threadId: threadState.id,
						youIds: threadState.youIds,
						localYousOnly: true,
						pushYousOnly: true,
						lastSeenId: threadState.thread?.posts.last.id ?? threadState.id
					));
				}
			}
			browserState.notificationsMigrated = true;
		}
		for (final savedPost in savedPosts.values) {
			if (savedPost.deprecatedThread != null) {
				print('Migrating saved ${savedPost.post} to ${savedPost.post.threadIdentifier}');
				getThreadState(savedPost.post.threadIdentifier).thread ??= savedPost.deprecatedThread;
				savedPost.deprecatedThread = null;
			}
		}
		if (settings.automaticCacheClearDays < 100000) {
			await _cleanupThreads(Duration(days: settings.automaticCacheClearDays));
		}
		settings.save();
		Timer.periodic(_backupUpdateDuration, (_) async {
			if (await File(_threadStatesBoxPath).exists()) {
				await File(_threadStatesBoxPath).copy(_threadStatesBackupBoxPath);
			}
			else if (await File(_threadStatesBoxPath.toLowerCase()).exists()) {
				await File(_threadStatesBoxPath.toLowerCase()).copy(_threadStatesBackupBoxPath);
			}
		});
	}

	PersistentThreadState? getThreadStateIfExists(ThreadIdentifier thread) {
		return _cachedEphemeralThreadStates[thread]?.item1 ?? threadStateBox.get('${thread.board}/${thread.id}');
	}

	static final Map<String, Map<ThreadIdentifier, Tuple2<PersistentThreadState, EasyListenable>>> _cachedEphemeralThreadStatesById = {};
	Map<ThreadIdentifier, Tuple2<PersistentThreadState, EasyListenable>> get _cachedEphemeralThreadStates => _cachedEphemeralThreadStatesById.putIfAbsent(id, () => {});
	PersistentThreadState getThreadState(ThreadIdentifier thread, {bool updateOpenedTime = false}) {
		final existingState = threadStateBox.get('${thread.board}/${thread.id}');
		if (existingState != null) {
			if (updateOpenedTime) {
				existingState.lastOpenedTime = DateTime.now();
				existingState.save();
			}
			return existingState;
		}
		else if (enableHistory) {
			final newState = PersistentThreadState();
			threadStateBox.put('${thread.board}/${thread.id}', newState);
			return newState;
		}
		else {
			return _cachedEphemeralThreadStates.putIfAbsent(thread, () => Tuple2(PersistentThreadState(ephemeralOwner: this), EasyListenable())).item1;
		}
	}

	@override
	Future<void> ephemeralThreadStateDidUpdate(PersistentThreadState state) async {
		await Future.microtask(() => _cachedEphemeralThreadStates[state.identifier]?.item2.didUpdate());
	}

	ImageboardBoard getBoard(String boardName) {
		final board = boards[boardName];
		if (board != null) {
			return board;
		}
		else {
			return ImageboardBoard(
				title: boardName,
				name: boardName,
				webmAudioAllowed: false,
				isWorksafe: true,
				maxImageSizeBytes: 4000000,
				maxWebmSizeBytes: 4000000
			);
		}
	}

	SavedAttachment? getSavedAttachment(Attachment attachment) {
		return savedAttachments[attachment.globalId];
	}

	void saveAttachment(Attachment attachment, File fullResolutionFile) {
		final newSavedAttachment = SavedAttachment(attachment: attachment, savedTime: DateTime.now());
		savedAttachments[attachment.globalId] = newSavedAttachment;
		fullResolutionFile.copy(newSavedAttachment.file.path);
		getCachedImageFile(attachment.thumbnailUrl.toString()).then((file) {
			if (file != null) {
				file.copy(newSavedAttachment.thumbnailFile.path);
			}
			else {
				print('Failed to find cached copy of ${attachment.thumbnailUrl.toString()}');
			}
		});
		settings.save();
		savedAttachmentsListenable.didUpdate();
		if (savedAttachments.length == 1) {
			attachmentSourceNotifier.didUpdate();
		}
	}

	void deleteSavedAttachment(Attachment attachment) {
		final removed = savedAttachments.remove(attachment.globalId);
		if (removed != null) {
			removed.deleteFiles();
		}
		if (savedAttachments.isEmpty) {
			attachmentSourceNotifier.didUpdate();
		}
		settings.save();
		savedAttachmentsListenable.didUpdate();
	}

	SavedPost? getSavedPost(Post post) {
		return savedPosts[post.globalId];
	}

	void savePost(Post post, Thread thread) {
		savedPosts[post.globalId] = SavedPost(post: post, savedTime: DateTime.now());
		settings.save();
		// Likely will force the widget to rebuild
		getThreadState(post.threadIdentifier).save();
		savedPostsListenable.didUpdate();
	}

	void unsavePost(Post post) {
		savedPosts.remove(post.globalId);
		settings.save();
		// Likely will force the widget to rebuild
		getThreadStateIfExists(post.threadIdentifier)?.save();
		savedPostsListenable.didUpdate();
	}

	Listenable listenForPersistentThreadStateChanges(ThreadIdentifier thread) {
		return _cachedEphemeralThreadStates[thread]?.item2 ?? threadStateBox.listenable(keys: ['${thread.board}/${thread.id}']);
	}

	Future<void> storeBoards(List<ImageboardBoard> newBoards) async {
		final deadline = DateTime.now().subtract(const Duration(days: 3));
		boards.removeWhere((k, v) => (v.additionalDataTime == null || v.additionalDataTime!.isBefore(deadline)) && !browserState.favouriteBoards.contains(v.name));
		for (final newBoard in newBoards) {
			if (boards[newBoard.name] == null || newBoard.additionalDataTime != null) {
				boards[newBoard.name] = newBoard;
			}
		}
	}

	static Future<void> didUpdateTabs() async {
		settings.save();
		tabsListenable.didUpdate();
	}

	Future<void> didUpdateBrowserState() async {
		settings.save();
		notifyListeners();
	}

	Future<void> didUpdateHiddenMD5s() async {
		hiddenMD5sListenable.didUpdate();
		didUpdateBrowserState();
	}

	static Future<void> didUpdateRecentSearches() async {
		settings.save();
		recentSearchesListenable.didUpdate();
	}

	Future<void> didUpdateSavedPost() async {
		settings.save();
		savedPostsListenable.didUpdate();
	}

	static void didChangeBrowserHistoryStatus() {
		for (final x in _cachedEphemeralThreadStatesById.values) {
			for (final y in x.values) {
				y.item2.dispose();
			}
		}
		_cachedEphemeralThreadStatesById.clear();
		browserHistoryStatusListenable.didUpdate();
	}

	@override
	String toString() => 'Persistence($id)';
}

const _maxRecentItems = 50;
@HiveType(typeId: 8)
class PersistentRecentSearches {
	@HiveField(0)
	List<ImageboardArchiveSearchQuery> entries = [];

	void handleSearch(ImageboardArchiveSearchQuery entry) {
		if (entries.contains(entry)) {
			bump(entry);
		}
		else {
			add(entry);
		}
	}

	void add(ImageboardArchiveSearchQuery entry) {
		entries = [entry, ...entries.take(_maxRecentItems)];
	}

	void bump(ImageboardArchiveSearchQuery entry) {
		entries = [entry, ...entries.where((e) => e != entry)];
	}

	void remove(ImageboardArchiveSearchQuery entry) {
		entries = [...entries.where((e) => e != entry)];
	}

	PersistentRecentSearches();
}

@HiveType(typeId: 3)
class PersistentThreadState extends HiveObject implements Filterable {
	@HiveField(0)
	int? lastSeenPostId;
	@HiveField(1)
	DateTime lastOpenedTime;
	@HiveField(6)
	DateTime? savedTime;
	@HiveField(3)
	List<PostReceipt> receipts = [];
	@HiveField(4)
	Thread? _thread;
	@HiveField(5)
	bool useArchive = false;
	@HiveField(7, defaultValue: [])
	List<int> postsMarkedAsYou = [];
	@HiveField(8, defaultValue: [])
	List<int> hiddenPostIds = [];
	@HiveField(9, defaultValue: '')
	String draftReply = '';
	// Don't persist this
	final lastSeenPostIdNotifier = ValueNotifier<int?>(null);
	// Don't persist this
	EphemeralThreadStateOwner? ephemeralOwner;
	@HiveField(10, defaultValue: [])
	List<int> treeHiddenPostIds = [];
	@HiveField(11, defaultValue: [])
	List<String> hiddenPosterIds = [];
	@HiveField(12, defaultValue: {})
	Map<int, Post> translatedPosts = {};
	@HiveField(13, defaultValue: false)
	bool autoTranslate = false;
	@HiveField(14)
	bool? useTree;
	@HiveField(15)
	ThreadVariant? variant;
	@HiveField(16, defaultValue: [])
	List<List<int>> collapsedItems = [];

	bool get incognito => ephemeralOwner != null;

	PersistentThreadState({this.ephemeralOwner}) : lastOpenedTime = DateTime.now();

	void _invalidate() {
		_replyIdsToYou.clear();
		_filteredPosts.clear();
	}

	Thread? get thread => _thread;
	set thread(Thread? newThread) {
		if (newThread != _thread) {
			_thread = newThread;
			_youIds = null;
			_invalidate();
		}
	}

	void didUpdatePostsMarkedAsYou() {
		_youIds = null;
		_invalidate();
	}

	List<int> freshYouIds() {
		return receipts.map((receipt) => receipt.id).followedBy(postsMarkedAsYou).toList();
	}
	List<int>? _youIds;
	List<int> get youIds {
		_youIds ??= freshYouIds();
		return _youIds!;
	}
	final Map<Filter, List<int>?> _replyIdsToYou = {};
	List<int>? replyIdsToYou(Filter additionalFilter) => _replyIdsToYou.putIfAbsent(additionalFilter, () {
		return filteredPosts(additionalFilter)?.where((p) {
			return p.repliedToIds.any((id) => youIds.contains(id));
		}).map((p) => p.id).toList();
	});

	int? unseenReplyIdsToYouCount(Filter additionalFilter) => replyIdsToYou(additionalFilter)?.binarySearchCountAfter((id) => id > lastSeenPostId!);
	final Map<Filter, List<Post>?> _filteredPosts = {};
	List<Post>? filteredPosts(Filter additionalFilter) {
		_filteredPosts[additionalFilter] ??= () {
			if (lastSeenPostId == null) {
				return null;
			}
			return thread?.posts.where((p) {
				return threadFilter.filter(p)?.type.hide != true
					&& additionalFilter.filter(p)?.type.hide != true;
			}).toList();
		}();
		return _filteredPosts[additionalFilter];
	}
	int? unseenReplyCount(Filter additionalFilter) => filteredPosts(additionalFilter)?.binarySearchCountAfter((p) => p.id > lastSeenPostId!);
	int? unseenImageCount(Filter additionalFilter) => filteredPosts(additionalFilter)?.map((p) {
		if (p.id <= lastSeenPostId!) {
			return 0;
		}
		return p.attachments.length;
	}).fold<int>(0, (a, b) => a + b);

	@override
	String toString() => 'PersistentThreadState(lastSeenPostId: $lastSeenPostId, receipts: $receipts, lastOpenedTime: $lastOpenedTime, savedTime: $savedTime, useArchive: $useArchive)';

	@override
	String get board => thread?.board ?? '';
	@override
	int get id => thread?.id ?? 0;
	@override
	String? getFilterFieldText(String fieldName) => thread?.getFilterFieldText(fieldName);
	@override
	bool get hasFile => thread?.hasFile ?? false;
	@override
	bool get isThread => true;
	@override
	List<int> get repliedToIds => [];
	@override
	Iterable<String> get md5s => thread?.md5s ?? [];

	late Filter threadFilter = FilterCache(ThreadFilter(hiddenPostIds, treeHiddenPostIds, hiddenPosterIds));
	void hidePost(int id, {bool tree = false}) {
		hiddenPostIds.add(id);
		if (tree) {
			treeHiddenPostIds.add(id);
		}
		// invalidate cache
		threadFilter = FilterCache(ThreadFilter(hiddenPostIds, treeHiddenPostIds, hiddenPosterIds));
		_invalidate();
	}
	void unHidePost(int id) {
		hiddenPostIds.remove(id);
		treeHiddenPostIds.remove(id);
		// invalidate cache
		threadFilter = FilterCache(ThreadFilter(hiddenPostIds, treeHiddenPostIds, hiddenPosterIds));
		_invalidate();
	}

	void hidePosterId(String id) {
		hiddenPosterIds.add(id);
		// invalidate cache
		threadFilter = FilterCache(ThreadFilter(hiddenPostIds, treeHiddenPostIds, hiddenPosterIds));
		_invalidate();
	}
	void unHidePosterId(String id) {
		hiddenPosterIds.remove(id);
		// invalidate cache
		threadFilter = FilterCache(ThreadFilter(hiddenPostIds, treeHiddenPostIds, hiddenPosterIds));
		_invalidate();
	}

	@override
	Future<void> save() async {
		if (ephemeralOwner != null) {
			await ephemeralOwner!.ephemeralThreadStateDidUpdate(this);
		}
		else {
			await super.save();
		}
	}

	ThreadIdentifier get identifier => ThreadIdentifier(board, id);
}

@HiveType(typeId: 4)
class PostReceipt {
	@HiveField(0)
	final String password;
	@HiveField(1)
	final int id;
	PostReceipt({
		required this.password,
		required this.id
	});
	@override
	String toString() => 'PostReceipt(id: $id, password: $password)';
}

@HiveType(typeId: 18)
class SavedAttachment {
	@HiveField(0)
	final Attachment attachment;
	@HiveField(1)
	final DateTime savedTime;
	@HiveField(2)
	final List<int> tags;
	SavedAttachment({
		required this.attachment,
		required this.savedTime,
		List<int>? tags
	}) : tags = tags ?? [];

	Future<void> deleteFiles() async {
		await thumbnailFile.delete();
		await file.delete();
	}

	File get thumbnailFile => File('${Persistence.documentsDirectory.path}/$_savedAttachmentThumbnailsDir/${attachment.globalId}.jpg');
	File get file => File('${Persistence.documentsDirectory.path}/$_savedAttachmentsDir/${attachment.globalId}${attachment.ext == '.webm' ? '.mp4' : attachment.ext}');
}

class SavedPost {
	Post post;
	final DateTime savedTime;
	Thread? deprecatedThread;

	SavedPost({
		required this.post,
		required this.savedTime
	});
}

@HiveType(typeId: 21)
class PersistentBrowserTab extends EasyListenable {
	@HiveField(0)
	ImageboardBoard? board;
	@HiveField(1)
	ThreadIdentifier? thread;
	@HiveField(2, defaultValue: '')
	String draftThread;
	@HiveField(3, defaultValue: '')
	String draftSubject;
	@HiveField(4)
	String? imageboardKey;
	Imageboard? get imageboard => imageboardKey == null ? null : ImageboardRegistry.instance.getImageboard(imageboardKey!);
	// Do not persist
	RefreshableListController<Post>? threadController;
	// Do not persist
	final Map<ThreadIdentifier, int> initialPostId = {};
	// Do not persist
	final tabKey = GlobalKey();
	// Do not persist
	final boardKey = GlobalKey();
	// Do not persist
	final incognitoProviderKey = GlobalKey();
	// Do not persist
	final unseen = ValueNotifier(0);
	@HiveField(5, defaultValue: '')
	String draftOptions;
	@HiveField(6)
	String? draftFilePath;
	@HiveField(7)
	String? initialSearch;
	@HiveField(8)
	CatalogVariant? catalogVariant;
	@HiveField(9, defaultValue: false)
	bool incognito;

	PersistentBrowserTab({
		this.board,
		this.thread,
		this.draftThread = '',
		this.draftSubject = '',
		this.imageboardKey,
		this.draftOptions = '',
		this.draftFilePath,
		this.initialSearch,
		this.catalogVariant,
		this.incognito = false
	});

	IncognitoPersistence? incognitoPersistence;
	Persistence? get persistence => incognitoPersistence ?? imageboard?.persistence;

	void initialize() {
		if (incognito && imageboardKey != null) {
			final persistence = ImageboardRegistry.instance.getImageboardUnsafe(imageboardKey!)?.persistence;
			if (persistence != null) {
				incognitoPersistence = IncognitoPersistence(persistence);
				if (thread != null) {
					// ensure state created before accessing
					incognitoPersistence!.getThreadState(thread!);
				}
			}
		}
	}

	@override
	void didUpdate() {
		if (incognito && imageboard != null && imageboard!.persistence != incognitoPersistence?.parent) {
			incognitoPersistence?.dispose();
			incognitoPersistence = IncognitoPersistence(imageboard!.persistence);
		}
		else if (!incognito) {
			incognitoPersistence?.dispose();
			incognitoPersistence = null;
		}
		super.didUpdate();
	}
}

@HiveType(typeId: 22)
class PersistentBrowserState {
	@HiveField(0)
	List<PersistentBrowserTab> deprecatedTabs;
	@HiveField(2, defaultValue: {})
	final Map<String, List<int>> hiddenIds;
	@HiveField(3, defaultValue: [])
	final List<String> favouriteBoards;
	@HiveField(5, defaultValue: {})
	final Map<String, List<int>> autosavedIds;
	@HiveField(6, defaultValue: [])
	final Set<String> hiddenImageMD5s;
	@HiveField(7, defaultValue: {})
	Map<String, String> loginFields;
	@HiveField(8)
	String notificationsId;
	@HiveField(10, defaultValue: [])
	List<ThreadWatch> threadWatches;
	@HiveField(11, defaultValue: [])
	List<BoardWatch> boardWatches;
	@HiveField(12, defaultValue: false)
	bool notificationsMigrated;
	@HiveField(13, defaultValue: {})
	final Map<String, ThreadSortingMethod> deprecatedBoardSortingMethods;
	@HiveField(14, defaultValue: {})
	final Map<String, bool> deprecatedBoardReverseSortings;
	@HiveField(16)
	bool? useTree;
	@HiveField(17, defaultValue: {})
	final Map<String, CatalogVariant> catalogVariants;
	@HiveField(18, defaultValue: {})
	final Map<String, String> postingNames;
	
	PersistentBrowserState({
		this.deprecatedTabs = const [],
		required this.hiddenIds,
		required this.favouriteBoards,
		required this.autosavedIds,
		required List<String> hiddenImageMD5s,
		required this.loginFields,
		String? notificationsId,
		required this.threadWatches,
		required this.boardWatches,
		required this.notificationsMigrated,
		required this.deprecatedBoardSortingMethods,
		required this.deprecatedBoardReverseSortings,
		required this.catalogVariants,
		required this.postingNames,
		this.useTree
	}) : hiddenImageMD5s = hiddenImageMD5s.toSet(), notificationsId = notificationsId ?? (const Uuid()).v4();

	final Map<String, Filter> _catalogFilters = {};
	Filter getCatalogFilter(String board) {
		return _catalogFilters.putIfAbsent(board, () => FilterCache(IDFilter(hiddenIds[board] ?? [])));
	}
	
	bool isThreadHidden(String board, int id) {
		return hiddenIds[board]?.contains(id) ?? false;
	}

	void hideThread(String board, int id) {
		_catalogFilters.remove(board);
		hiddenIds.putIfAbsent(board, () => []).add(id);
	}

	void unHideThread(String board, int id) {
		_catalogFilters.remove(board);
		hiddenIds[board]?.remove(id);
	}

	bool areMD5sHidden(Iterable<String> md5s) {
		for (final md5 in md5s) {
			if (hiddenImageMD5s.contains(md5)) {
				return true;
			}
		}
		return false;
	}

	late Filter imageMD5Filter = MD5Filter(hiddenImageMD5s.toSet());
	void hideByMD5(String md5) {
		hiddenImageMD5s.add(md5);
		imageMD5Filter = MD5Filter(hiddenImageMD5s.toSet());
	}

	void unHideByMD5s(Iterable<String> md5s) {
		hiddenImageMD5s.removeAll(md5s);
		imageMD5Filter = MD5Filter(hiddenImageMD5s.toSet());
	}

	void setHiddenImageMD5s(Iterable<String> md5s) {
		hiddenImageMD5s.clear();
		hiddenImageMD5s.addAll(md5s.map((md5) {
			switch (md5.length % 3) {
				case 1:
					return '$md5==';
				case 2:
					return '$md5=';
			}
			return md5;
		}));
		imageMD5Filter = MD5Filter(hiddenImageMD5s.toSet());
	}
}

/// Custom adapter to not write-out deprecatedThread
class SavedPostAdapter extends TypeAdapter<SavedPost> {
  @override
  final int typeId = 19;

  @override
  SavedPost read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SavedPost(
      post: fields[0] as Post,
      savedTime: fields[1] as DateTime,
    )..deprecatedThread = fields[2] as Thread?;
  }

  @override
  void write(BinaryWriter writer, SavedPost obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.post)
      ..writeByte(1)
      ..write(obj.savedTime);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedPostAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
