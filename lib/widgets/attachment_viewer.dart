import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/search.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/pages/search_query.dart';
import 'package:chan/services/media.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/storage.dart';
import 'package:chan/services/rotating_image_provider.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/attachment_thumbnail.dart';
import 'package:chan/widgets/circular_loading_indicator.dart';
import 'package:chan/widgets/rx_stream_builder.dart';
import 'package:chan/widgets/util.dart';
import 'package:dio/dio.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:video_player/video_player.dart';

const deviceGalleryAlbumName = 'Chance';

class AttachmentNotFoundException {
	final Attachment attachment;
	AttachmentNotFoundException(this.attachment);
	@override
	String toString() => 'Attachment not found: $attachment';
}

class AttachmentViewerController extends ChangeNotifier {
	// Parameters
	final BuildContext context;
	final Attachment attachment;
	final Stream<void>? redrawGestureStream;
	final ImageboardSite site;
	final Uri? overrideSource;

	// Private usage
	Completer<void>? _rotationCompleter;
	bool _isFullResolution = false;
	String? _errorMessage;
	VideoPlayerController? _videoPlayerController;
	bool _hasAudio = false;
	Uri? _goodImageSource;
	File? _cachedFile;
	bool _isPrimary = false;
	MediaConversion? _ongoingConversion;
	int _quarterTurns = 0;
	bool _checkArchives = false;
	bool _showLoadingProgress = false;
	final _longPressFactorStream = BehaviorSubject<double>();
	int _millisecondsBeforeLongPress = 0;
	bool _currentlyWithinLongPress = false;
	bool _playingBeforeLongPress = false;
	bool _seeking = false;
	String? _overlayText;
	bool _isDisposed = false;
	bool _isDownloaded = false;

	// Public API
	/// Whether loading of the full quality attachment has begun
	bool get isFullResolution => _isFullResolution;
	/// Error that occured while loading the full quality attachment
	String? get errorMessage => _errorMessage;
	/// Whether the loading spinner should be displayed
	bool get showLoadingProgress => _showLoadingProgress;
	/// Conversion process of a video attachment
	final videoLoadingProgress = ValueNotifier<double?>(null);
	/// A VideoPlayerController to enable playing back video attachments
	VideoPlayerController? get videoPlayerController => _videoPlayerController;
	/// Whether the attachment is a video that has an audio track
	bool get hasAudio => _hasAudio;
	/// The Uri to use to load the image, if needed
	Uri? get goodImageSource => _goodImageSource;
	/// Whether the attachment has been cached locally
	bool get cacheCompleted => _cachedFile != null;
	/// Whether this attachment is currently the primary one being displayed to the user
	bool get isPrimary => _isPrimary;
	/// How many turns to rotate the image by
	int get quarterTurns => _quarterTurns;
	/// A key to use to with ExtendedImage (to help maintain gestures when the image widget is replaced)
	final gestureKey = GlobalKey<ExtendedImageGestureState>();
	/// A key to use with CupertinoContextMenu share button
	final contextMenuShareButtonKey = GlobalKey();
	/// Whether archive checking for this attachment is enabled
	bool get checkArchives => _checkArchives;
	/// Modal text which should be overlayed on the attachment
	String? get overlayText => _overlayText;
	/// Whether the image has already been downloaded
	bool get isDownloaded => _isDownloaded;


	AttachmentViewerController({
		required this.context,
		required this.attachment,
		this.redrawGestureStream,
		required this.site,
		this.overrideSource,
		bool isPrimary = false
	}) : _isPrimary = isPrimary {
		_longPressFactorStream.bufferTime(const Duration(milliseconds: 50)).listen((x) {
			if (x.isNotEmpty) {
				_onCoalescedLongPressUpdate(x.last);
			}
		});
	}

	set isPrimary(bool val) {
		if (val) {
			videoPlayerController?.play();
		}
		else {
			videoPlayerController?.pause();
		}
		_isPrimary = val;
	}

	Future<Uri> _getGoodSource() async {
		if (overrideSource != null) {
			return overrideSource!;
		}
		Response result = await site.client.head(attachment.url.toString(), options: Options(
			validateStatus: (_) => true,
			headers: context.read<ImageboardSite>().getHeaders(attachment.url),
		));
		if (result.statusCode == 200) {
			return attachment.url;
		}
		else {
			if (_checkArchives && attachment.threadId != null) {
				final archivedThread = await site.getThreadFromArchive(ThreadIdentifier(
					board: attachment.board,
					id: attachment.threadId!
				));
				for (final reply in archivedThread.posts) {
					if (reply.attachment?.id == attachment.id) {
						result = await site.client.head(reply.attachment!.url.toString(), options: Options(
							validateStatus: (_) => true,
							headers: context.read<ImageboardSite>().getHeaders(reply.attachment!.url)
						));
						if (result.statusCode == 200) {
							return reply.attachment!.url;
						}
					}
				}
			}
		}
		if (result.statusCode == 404) {
			throw AttachmentNotFoundException(attachment);
		}
		throw HTTPStatusException(result.statusCode!);
	}

	void _onConversionProgressUpdate() {
		videoLoadingProgress.value = _ongoingConversion!.progress.value;
		notifyListeners();
	}

	Future<void> _loadFullAttachment(bool startImageDownload, {bool force = false}) async {
		if (attachment.type == AttachmentType.image && goodImageSource != null && !force) {
			return;
		}
		if (attachment.type == AttachmentType.webm && ((videoPlayerController != null && !force) || _ongoingConversion != null)) {
			return;
		}
		_errorMessage = null;
		videoLoadingProgress.value = null;
		_goodImageSource = null;
		_videoPlayerController?.dispose();
		_videoPlayerController = null;
		_cachedFile = null;
		_isFullResolution = true;
		_showLoadingProgress = false;
		notifyListeners();
		Future.delayed(const Duration(milliseconds: 500), () {
			_showLoadingProgress = true;
			if (_isDisposed) return;
			notifyListeners();
		});
		try {
			if (attachment.type == AttachmentType.image) {
				_goodImageSource = await _getGoodSource();
				if (_goodImageSource?.scheme == 'file') {
					_cachedFile = File(_goodImageSource!.path);
				}
				if (_isDisposed) return;
				notifyListeners();
				if (startImageDownload) {
					await ExtendedNetworkImageProvider(
						goodImageSource.toString(),
						cache: true,
						headers: context.read<ImageboardSite>().getHeaders(goodImageSource!)
					).getNetworkImageData();
					final file = await getCachedImageFile(goodImageSource.toString());
					if (file != null && _cachedFile?.path != file.path) {
						_cachedFile = file;
					}
				}
			}
			else if (attachment.type == AttachmentType.webm) {
				final url = await _getGoodSource();
				if (Platform.isAndroid) {
					final scan = await MediaScan.scan(url);
					_hasAudio = scan.hasAudio;
					if (_isDisposed) {
						return;
					}
					_videoPlayerController = VideoPlayerController.network(url.toString());
					await _videoPlayerController!.initialize();
					if (_isDisposed) {
						return;
					}
					await videoPlayerController!.setLooping(true);
					if (_isDisposed) {
						return;
					}
					if (isPrimary) {
						await videoPlayerController!.play();
					}
					if (_isDisposed) {
						return;
					}
					notifyListeners();
				}
				else {
					_ongoingConversion = MediaConversion.toMp4(url);
					_ongoingConversion!.progress.addListener(_onConversionProgressUpdate);
					_ongoingConversion!.start();
					final result = await _ongoingConversion!.result;
					_ongoingConversion = null;
					_videoPlayerController = VideoPlayerController.file(result.file, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
					if (_isDisposed) {
						return;
					}
					await _videoPlayerController!.initialize();
					if (_isDisposed) {
						return;
					}
					await _videoPlayerController!.setLooping(true);
					if (_isDisposed) {
						return;
					}
					if (isPrimary) {
						await _videoPlayerController!.play();
					}
					if (_isDisposed) {
						return;
					}
					_cachedFile = result.file;
					_hasAudio = result.hasAudio;
				}
				if (_isDisposed) return;
				notifyListeners();
			}
		}
		catch (e, st) {
			_errorMessage = e.toStringDio();
			print(e);
			print(st);
			notifyListeners();
		}
		finally {
			_ongoingConversion = null;
		}
	}

	Future<void> loadFullAttachment() => _loadFullAttachment(false);

	Future<void> reloadFullAttachment() => _loadFullAttachment(false, force: true);

	Future<void> preloadFullAttachment() => _loadFullAttachment(true);

	Future<void> rotate() async {
		_quarterTurns = 1;
		notifyListeners();
		if (attachment.type == AttachmentType.image) {
			_rotationCompleter ??= Completer<void>();
			await _rotationCompleter!.future;
		}
	}

	void unrotate() {
		_quarterTurns = 0;
		notifyListeners();
	}

	void onRotationCompleted() {
		if (!(_rotationCompleter?.isCompleted ?? false)) {
			_rotationCompleter?.complete();
		}
	}

	void onCacheCompleted(File file) {
		_cachedFile = file;
		if (_isDisposed) return;
		notifyListeners();
	}

	void tryArchives() {
		_checkArchives = true;
		loadFullAttachment();
	}

	String _formatPosition(Duration position, Duration duration) {
		return '${position.inMinutes.toString()}:${(position.inSeconds % 60).toString().padLeft(2, '0')} / ${duration.inMinutes.toString()}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
	}

	void _onLongPressStart() {
		_playingBeforeLongPress = videoPlayerController!.value.isPlaying;
		_millisecondsBeforeLongPress = videoPlayerController!.value.position.inMilliseconds;
		_currentlyWithinLongPress = true;
		_overlayText = _formatPosition(videoPlayerController!.value.position, videoPlayerController!.value.duration);
		notifyListeners();
		videoPlayerController!.pause();
	}

	void _onLongPressUpdate(double factor) {
		_longPressFactorStream.add(factor);
	}

	void _onCoalescedLongPressUpdate(double factor) async {
		if (_currentlyWithinLongPress) {
			final duration = videoPlayerController!.value.duration.inMilliseconds;
			final newPosition = Duration(milliseconds: ((_millisecondsBeforeLongPress + (duration * factor)).clamp(0, duration)).round());
			_overlayText = _formatPosition(newPosition, videoPlayerController!.value.duration);
			notifyListeners();
			if (!_seeking) {
				_seeking = true;
				await videoPlayerController!.seekTo(newPosition);
				await videoPlayerController!.play();
				await videoPlayerController!.pause();
				_seeking = false;
			}
		}
	}

	void _onLongPressEnd() {
		if (_playingBeforeLongPress) {
			videoPlayerController!.play();
		}
		_currentlyWithinLongPress = false;
		_overlayText = null;
		notifyListeners();
	}

	bool get canShare => (attachment.type == AttachmentType.webm && Platform.isAndroid) || (overrideSource ?? _cachedFile) != null;

	Future<File> getFile() async {
		if (overrideSource != null) {
			return File(overrideSource!.path);
		}
		else if (_cachedFile != null) {
			return _cachedFile!;
		}
		else if (attachment.type == AttachmentType.webm && Platform.isAndroid) {
			final response = await site.client.get((await _getGoodSource()).toString(), options: Options(
				responseType: ResponseType.bytes
			));
			final systemTempDirectory = Persistence.temporaryDirectory;
			final directory = await (Directory(systemTempDirectory.path + '/webmcache')).create(recursive: true);
			return await File(directory.path + attachment.id.toString() + '.webm').writeAsBytes(response.data);
		}
		else {
			throw Exception('No file available');
		}
	}

	Future<File> _moveToShareCache() async {
		final systemTempDirectory = Persistence.temporaryDirectory;
		final shareDirectory = await (Directory(systemTempDirectory.path + '/sharecache')).create(recursive: true);
		final newFilename = attachment.id.toString() + attachment.ext.replaceFirst('webm', Platform.isAndroid ? 'webm' : 'mp4');
		File? originalFile = await getFile();
		return await originalFile.copy(shareDirectory.path.toString() + '/' + newFilename);
	}

	Future<void> share(Rect? sharePosition) async {
		await shareOne(
			text: (await _moveToShareCache()).path,
			subject: attachment.filename,
			type: "file",
			sharePositionOrigin: sharePosition
		);
	}

	Future<void> download() async {
		if (_isDownloaded) return;
		try {
			if (Platform.isIOS) {
				final existingAlbums = await PhotoManager.getAssetPathList(type: RequestType.common, filterOption: FilterOptionGroup(containsEmptyAlbum: true));
				AssetPathEntity? album = existingAlbums.tryFirstWhere((album) => album.name == deviceGalleryAlbumName);
				album ??= await PhotoManager.editor.iOS.createAlbum('Chance');
				final shareCachedFile = await _moveToShareCache();
				final asAsset = attachment.type == AttachmentType.image ? 
					await PhotoManager.editor.saveImageWithPath(shareCachedFile.path, title: attachment.filename) :
					await PhotoManager.editor.saveVideo(shareCachedFile, title: attachment.filename);
				await PhotoManager.editor.copyAssetToPath(asset: asAsset!, pathEntity: album!);
				_isDownloaded = true;
			}
			else if (Platform.isAndroid) {
				if (context.read<EffectiveSettings>().androidGallerySavePath == null) {
					// pick the path
					context.read<EffectiveSettings>().androidGallerySavePath = await pickDirectory();
				}
				if (context.read<EffectiveSettings>().androidGallerySavePath != null) {
					File source = (await getFile());
					await saveFile(
						sourcePath: source.path,
						destinationDir: context.read<EffectiveSettings>().androidGallerySavePath!,
						destinationName: attachment.id.toString() + attachment.ext
					);
					_isDownloaded = true;
				}
			}
			else {
				throw UnsupportedError("Downloading not supported on this platform");
			}
		}
		catch (e) {
			alertError(context, e.toStringDio());
			rethrow;
		}
		notifyListeners();
	}

	@override
	void dispose() {
		_isDisposed = true;
		super.dispose();
		_ongoingConversion?.progress.removeListener(_onConversionProgressUpdate);
		_ongoingConversion?.cancel();
		videoPlayerController?.pause().then((_) => videoPlayerController?.dispose());
		_longPressFactorStream.close();
	}

	@override
	String toString() => 'AttachmentViewerController(attachment: $attachment)';
}

class AttachmentViewer extends StatelessWidget {
	final AttachmentViewerController controller;
	final Iterable<int> semanticParentIds;
	final ValueChanged<double>? onScaleChanged;
	final bool fill;

	const AttachmentViewer({
		required this.controller,
		required this.semanticParentIds,
		this.onScaleChanged,
		this.fill = true,
		Key? key
	}) : super(key: key);

	Attachment get attachment => controller.attachment;

	Object get _tag => AttachmentSemanticLocation(
		attachment: attachment,
		semanticParents: semanticParentIds
	);

	Widget _centeredLoader({
		required bool active,
		required double? value
	}) => Builder(
		builder: (context) => Center(
			child: AnimatedSwitcher(
				duration: const Duration(milliseconds: 300),
				child: active ? CircularLoadingIndicator(
					value: value
				) : Icon(
					CupertinoIcons.arrow_down_circle,
					size: 60,
					color: CupertinoTheme.of(context).primaryColor
				)
			)
		)
	);

	Widget _buildImage(BuildContext context, Size? size, bool passedFirstBuild) {
		Uri source = attachment.thumbnailUrl;
		if (controller.goodImageSource != null && passedFirstBuild) {
			source = controller.goodImageSource!;
		}
		ImageProvider image = ExtendedNetworkImageProvider(
			source.toString(),
			cache: true,
			headers: context.read<ImageboardSite>().getHeaders(source)
		);
		if (source.scheme == 'file') {
			image = ExtendedFileImageProvider(
				File(source.path),
				imageCacheName: 'asdf'
			);
		}
		if (controller.quarterTurns != 0) {
			image = RotatingImageProvider(
				parent: image,
				quarterTurns: controller.quarterTurns,
				onLoaded: controller.onRotationCompleted
			);
			image.obtainCacheStatus(configuration: createLocalImageConfiguration(context)).then((status) {
				if (status?.keepAlive == true) {
					controller.onRotationCompleted();
				}
			});
		}
		_buildChild(bool useRealGestureKey) => ExtendedImage(
			image: image,
			extendedImageGestureKey: useRealGestureKey ? controller.gestureKey : null,
			color: const Color.fromRGBO(238, 242, 255, 1),
			colorBlendMode: BlendMode.dstOver,
			enableSlideOutPage: true,
			gaplessPlayback: true,
			fit: BoxFit.contain,
			mode: ExtendedImageMode.gesture,
			width: size?.width ?? double.infinity,
			height: size?.height ?? double.infinity,
			enableLoadState: true,
			handleLoadingProgress: true,
			onDoubleTap: (state) {
				final old = state.gestureDetails!;
				if ((old.totalScale ?? 1) > 1) {
					state.gestureDetails = GestureDetails(
						offset: Offset.zero,
						totalScale: 1,
						actionType: ActionType.zoom
					);
				}
				else {
					double autozoomScale = 2.0;
					if (attachment.width != null && attachment.height != null) {
						double screenAspectRatio = MediaQuery.of(context, MediaQueryAspect.width).size.width / MediaQuery.of(context, MediaQueryAspect.height).size.height;
						double attachmentAspectRatio = attachment.width! / attachment.height!;
						double fillZoomScale = screenAspectRatio / attachmentAspectRatio;
						autozoomScale = max(autozoomScale, max(fillZoomScale, 1 / fillZoomScale));
					}
					autozoomScale = min(autozoomScale, 5);
					final center = Offset(MediaQuery.of(context, MediaQueryAspect.width).size.width / 2, MediaQuery.of(context, MediaQueryAspect.height).size.height / 2);
					state.gestureDetails = GestureDetails(
						offset: (state.pointerDownPosition! * autozoomScale - center).scale(-1, -1),
						totalScale: autozoomScale,
						actionType: ActionType.zoom
					);
				}
			},
			loadStateChanged: (loadstate) {
				// We can't rely on loadstate.extendedImageLoadState because of using gaplessPlayback
				if (!controller.cacheCompleted) {
					double? loadingValue;
					if (loadstate.loadingProgress?.cumulativeBytesLoaded != null && loadstate.loadingProgress?.expectedTotalBytes != null) {
						// If we got image download completion, we can check if it's cached
						loadingValue = loadstate.loadingProgress!.cumulativeBytesLoaded / loadstate.loadingProgress!.expectedTotalBytes!;
						if ((source != attachment.thumbnailUrl) && loadingValue == 1) {
							getCachedImageFile(source.toString()).then((file) {
								if (file != null) {
									controller.onCacheCompleted(file);
								}
							});
						}
					}
					else if (loadstate.extendedImageInfo?.image.width == attachment.width && (source != attachment.thumbnailUrl)) {
						// If the displayed image looks like the full image, we can check cache
						getCachedImageFile(source.toString()).then((file) {
							if (file != null) {
								controller.onCacheCompleted(file);
							}
						});
					}
					loadstate.returnLoadStateChangedWidget = true;
					buildContent(context, _) {
						Widget _child = Container();
						if (controller.errorMessage != null) {
							_child = Center(
								child: ErrorMessageCard(controller.errorMessage!, remedies: {
										'Retry': () => controller.loadFullAttachment(),
										if (!controller.checkArchives) 'Try archives': () => controller.tryArchives()
									}
								)
							);
						}
						else if (controller.showLoadingProgress) {
							_child = _centeredLoader(
								active: controller.isFullResolution,
								value: loadingValue
							);
						}
						final Rect? rect = controller.gestureKey.currentState?.gestureDetails?.destinationRect;
						final Widget __child = Transform.scale(
							scale: (controller.gestureKey.currentState?.extendedImageSlidePageState?.scale ?? 1) * (controller.gestureKey.currentState?.gestureDetails?.totalScale ?? 1),
							child: _child
						);
						if (rect == null) {
							return Positioned.fill(
								child: __child
							);
						}
						else {
							return Positioned.fromRect(
								rect: rect,
								child: __child
							);
						}
					}
					return Stack(
						children: [
							loadstate.completedWidget,
							if (controller.redrawGestureStream != null) RxStreamBuilder(
								stream: controller.redrawGestureStream!,
								builder: buildContent
							)
							else buildContent(context, null)
						]
					);
				}
				return null;
			},
			initGestureConfigHandler: (state) {
				return GestureConfig(
					inPageView: true,
					gestureDetailsIsChanged: (details) {
						if (details?.totalScale != null) {
							onScaleChanged?.call(details!.totalScale!);
						}
					}
				);
			},
			heroBuilderForSlidingPage: (Widget result) {
				return Hero(
					tag: _tag,
					child: result,
					flightShuttleBuilder: (ctx, animation, direction, from, to) => from.widget
				);
			}
		);
		return CupertinoContextMenu(
			actions: [
					CupertinoContextMenuAction(
						child: const Text('Download'),
						trailingIcon: CupertinoIcons.cloud_download,
						onPressed: () async {
							Navigator.of(context, rootNavigator: true).pop();
							await controller.download();
							showToast(context: context, message: 'Downloaded ${controller.attachment.filename}', icon: CupertinoIcons.cloud_download);
						}
					),
					CupertinoContextMenuAction(
						child: const Text('Share'),
						trailingIcon: CupertinoIcons.share,
						onPressed: () async {
							final offset = (controller.contextMenuShareButtonKey.currentContext?.findRenderObject() as RenderBox?)?.localToGlobal(Offset.zero);
							final size = controller.contextMenuShareButtonKey.currentContext?.findRenderObject()?.semanticBounds.size;
							await controller.share((offset != null && size != null) ? offset & size : null);
							Navigator.of(context, rootNavigator: true).pop();
						},
						key: controller.contextMenuShareButtonKey
					),
					CupertinoContextMenuAction(
						child: const Text('Search archives'),
						trailingIcon: Icons.image_search,
						onPressed: () {
							openSearch(context: context, query: ImageboardArchiveSearchQuery(boards: [attachment.board], md5: attachment.md5));
						}
					),
					CupertinoContextMenuAction(
						child: const Text('Search Google'),
						trailingIcon: Icons.image_search,
						onPressed: () => openBrowser(context, Uri.https('www.google.com', '/searchbyimage', {
							'image_url': attachment.url.toString(),
							'safe': 'off'
						}))
					),
					CupertinoContextMenuAction(
						child: const Text('Search Yandex'),
						trailingIcon: Icons.image_search,
						onPressed: () => openBrowser(context, Uri.https('yandex.com', '/images/search', {
							'rpt': 'imageview',
							'url': attachment.url.toString()
						}))
					)
			],
			child: _buildChild(true),
			previewBuilder: (context, animation, child) => IgnorePointer(
				child: AspectRatio(
					aspectRatio: (attachment.width != null && attachment.height != null) ? (attachment.width! / attachment.height!) : 1,
					child: _buildChild(false)
				)
			)
		);
	}

	Widget _buildVideo(BuildContext context, Size? size) {
		return ExtendedImageSlidePageHandler(
			heroBuilderForSlidingPage: (Widget result) {
				return Hero(
					tag: _tag,
					child: result,
					flightShuttleBuilder: (ctx, animation, direction, from, to) => from.widget
				);
			},
			child: SizedBox.fromSize(
				size: size,
				child: Stack(
					children: [
						AttachmentThumbnail(
							attachment: attachment,
							width: double.infinity,
							height: double.infinity,
							quarterTurns: controller.quarterTurns,
							gaplessPlayback: true
						),
						if (controller.errorMessage != null) Center(
							child: ErrorMessageCard(controller.errorMessage!, remedies: {
								'Retry': () => controller.reloadFullAttachment()
							})
						)
						else if (controller.videoPlayerController != null) GestureDetector(
							behavior: HitTestBehavior.translucent,
							onLongPressStart: (x) => controller._onLongPressStart(),
							onLongPressMoveUpdate: (x) => controller._onLongPressUpdate(x.offsetFromOrigin.dx / (MediaQuery.of(context, MediaQueryAspect.width).size.width / 2)),
							onLongPressEnd: (x) => controller._onLongPressEnd(),
							child: Center(
								child: RotatedBox(
									quarterTurns: controller.quarterTurns,
									child: AspectRatio(
										aspectRatio: controller.videoPlayerController!.value.aspectRatio,
										child: VideoPlayer(controller.videoPlayerController!)
									)
								)
							)
						)
						else if (controller.showLoadingProgress) ValueListenableBuilder(
							valueListenable: controller.videoLoadingProgress,
							builder: (context, double? loadingProgress, child) => _centeredLoader(
								active: controller.isFullResolution,
								value: loadingProgress
							)
						),
						AnimatedSwitcher(
							duration: const Duration(milliseconds: 250),
							child: (controller.overlayText != null) ? Center(
								child: RotatedBox(
									quarterTurns: controller.quarterTurns,
									child: Container(
										padding: const EdgeInsets.all(8),
										decoration: const BoxDecoration(
											color: Colors.black54,
											borderRadius: BorderRadius.all(Radius.circular(8))
										),
										child: Text(
											controller.overlayText!,
											style: const TextStyle(
												fontSize: 32,
												color: Colors.white
											)
										)
									)
								)
							) : Container()
						)
					]
				)
			)
		);
	}

	@override
	Widget build(BuildContext context) {
		return FirstBuildDetector(
			identifier: _tag,
			builder: (context, passedFirstBuild) {
				return LayoutBuilder(
					builder: (context, constraints) {
						Size? targetSize;
						if (!fill && attachment.width != null && attachment.height != null && constraints.hasBoundedHeight && constraints.hasBoundedWidth) {
							targetSize = applyBoxFit(BoxFit.scaleDown, Size(attachment.width!.toDouble(), attachment.height!.toDouble()), constraints.biggest).destination;
						}
						if (attachment.type == AttachmentType.image) {
							return _buildImage(context, targetSize, passedFirstBuild);
						}
						else {
							return _buildVideo(context, targetSize);
						}
					}
				);
			}
		);
	}
}