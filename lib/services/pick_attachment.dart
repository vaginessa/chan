// ignore_for_file: use_build_context_synchronously

import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:chan/pages/overscroll_modal.dart';
import 'package:chan/pages/web_image_picker.dart';
import 'package:chan/services/apple.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/saved_attachment_thumbnail.dart';
import 'package:chan/widgets/util.dart';
import 'package:chan/services/clipboard_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

final List<String> receivedFilePaths = [];
final attachmentSourceNotifier = EasyListenable();

class AttachmentPickingSource {
	final String name;
	final IconData icon;
	final Future<String?> Function() pick;

	const AttachmentPickingSource({
		required this.name,
		required this.icon,
		required this.pick
	});
}

List<AttachmentPickingSource> getAttachmentSources({
	required BuildContext context,
	required bool includeClipboard
}) {
	final gallery = AttachmentPickingSource(
		name: 'Image Gallery',
		icon: CupertinoIcons.photo,
		pick: () => FilePicker.platform.pickFiles(type: FileType.image).then((x) => x?.files.single.path)
	);
	final videoGallery = AttachmentPickingSource(
		name: 'Video Gallery',
		icon: CupertinoIcons.play_rectangle,
		pick: () => FilePicker.platform.pickFiles(type: FileType.video).then((x) => x?.files.single.path)
	);
	final picker = ImagePicker();
	final camera = AttachmentPickingSource(
		name: 'Camera',
		icon: CupertinoIcons.camera,
		pick: () => picker.pickImage(source: ImageSource.camera).then((x) => x?.path)
	);
	final videoCamera = AttachmentPickingSource(
		name: 'Video Camera',
		icon: CupertinoIcons.videocam,
		pick: () => picker.pickVideo(source: ImageSource.camera).then((x) => x?.path)
	);
	final web = AttachmentPickingSource(
		name: 'Web',
		icon: CupertinoIcons.globe,
		pick: () => Navigator.of(context, rootNavigator: true).push<File>(CupertinoModalPopupRoute(
			builder: (_) => WebImagePickerPage(
				site: context.read<ImageboardSite?>()
			)
		)).then((x) => x?.path)
	);
	final file = AttachmentPickingSource(
		name: 'File',
		icon: CupertinoIcons.folder,
		pick: () => FilePicker.platform.pickFiles(type: FileType.any).then((x) => x?.files.single.path)
	);
	final clipboard = AttachmentPickingSource(
		name: 'Clipboard',
		icon: CupertinoIcons.doc_on_clipboard,
		pick: () => getClipboardImageAsFile().then((x) {
			if (x == null) {
				showToast(
					context: context,
					message: 'No image in clipboard',
					icon: CupertinoIcons.xmark
				);
			}
			return x?.path;
		})
	);
	final anySaved = context.read<Persistence?>()?.savedAttachments.isNotEmpty ?? false;
	final saved = AttachmentPickingSource(
		name: 'Saved Attachments',
		icon: CupertinoIcons.bookmark,
		pick: () {
			final savedAttachments = context.read<Persistence>().savedAttachments.values.toList();
			savedAttachments.sort((a, b) => b.savedTime.compareTo(a.savedTime));
			return Navigator.of(context).push<String>(TransparentRoute(
				builder: (context) => OverscrollModalPage(
					child: Container(
						width: double.infinity,
						padding: const EdgeInsets.all(16),
						color: CupertinoTheme.of(context).scaffoldBackgroundColor,
						child: GridView.builder(
							gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
								maxCrossAxisExtent: 100,
								mainAxisSpacing: 16,
								crossAxisSpacing: 16,
								childAspectRatio: 1
							),
							addAutomaticKeepAlives: false,
							addRepaintBoundaries: false,
							shrinkWrap: true,
							physics: const NeverScrollableScrollPhysics(),
							itemCount: savedAttachments.length,
							itemBuilder: (context, i) {
								final attachment = savedAttachments[i];
								return GestureDetector(
									onTap: () {
										Navigator.of(context).pop(attachment.file.path);
									},
									child: ClipRRect(
										borderRadius: BorderRadius.circular(8),
										child: SavedAttachmentThumbnail(file: attachment.file, fit: BoxFit.cover)
									)
								);
							}
						)
					)
				),
				showAnimations: context.read<EffectiveSettings>().showAnimations
			));
		}
	);
	if (Platform.isIOS) {
		return [
			if (anySaved) saved,
			gallery,
			videoGallery,
			file,
			web,
			if (!isOnMac) ...[
				camera,
				videoCamera,
			],
			if (includeClipboard) clipboard,
		];
	}
	else if (Platform.isAndroid) {
		return [
			if (anySaved) saved,
			file,
			if (includeClipboard) clipboard,
			web,
			camera,
			videoCamera,
		];
	}
	else {
		return [
			file
		];
	}
}

Future<File?> pickAttachment({
	required BuildContext context
}) async {
	final sources = getAttachmentSources(context: context, includeClipboard: true);
	bool loadingPick = false;
	return Navigator.of(context).push<File>(TransparentRoute(
		builder: (context) => StatefulBuilder(
			builder: (context, setPickerDialogState) => OverscrollModalPage(
				child: Container(
					width: double.infinity,
					padding: const EdgeInsets.all(16),
					color: CupertinoTheme.of(context).scaffoldBackgroundColor,
					child: Stack(
						children: [
							GridView.builder(
								gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
									maxCrossAxisExtent: 100,
									mainAxisSpacing: 16,
									crossAxisSpacing: 16,
									childAspectRatio: 1
								),
								addAutomaticKeepAlives: false,
								addRepaintBoundaries: false,
								shrinkWrap: true,
								physics: const NeverScrollableScrollPhysics(),
								itemCount: sources.length + receivedFilePaths.length,
								itemBuilder: (context, i) {
									if (i < sources.length) {
										final entry = sources[i];
										return GestureDetector(
											onTap: () async {
												loadingPick = true;
												setPickerDialogState(() {});
												try {
													final path = await entry.pick();
													loadingPick = false;
													setPickerDialogState(() {});
													if (path != null) {
														Navigator.of(context).pop<File>(File(path));
													}
												}
												catch (e) {
													alertError(context, e.toStringDio());
													loadingPick = false;
													setPickerDialogState(() {});
												}
											},
											child: Container(
												decoration: BoxDecoration(
													color: CupertinoTheme.of(context).primaryColor,
													borderRadius: BorderRadius.circular(8)
												),
												padding: const EdgeInsets.all(8),
												child: Column(
													mainAxisAlignment: MainAxisAlignment.center,
													children: [
														Icon(entry.icon, size: 40, color: CupertinoTheme.of(context).scaffoldBackgroundColor),
														Flexible(
															child: AutoSizeText(entry.name, minFontSize: 5, style: TextStyle(color: CupertinoTheme.of(context).scaffoldBackgroundColor), textAlign: TextAlign.center)
														)
													]
												)
											)
										);
									}
									else {
										// Reverse order
										final file = File(receivedFilePaths[(receivedFilePaths.length - 1) - (i - sources.length)]);
										return GestureDetector(
											onTap: () {
												Navigator.of(context).pop(file);
											},
											child: ClipRRect(
												borderRadius: BorderRadius.circular(8),
												child: SavedAttachmentThumbnail(file: file, fit: BoxFit.cover)
											)
										);
									}
								}
							),
							if (loadingPick) Positioned.fill(
								child: Container(
									color: CupertinoTheme.of(context).scaffoldBackgroundColor.withOpacity(0.5),
									child: const CupertinoActivityIndicator()
								)
							)
						]
					)
				)
			)
		),
		showAnimations: context.read<EffectiveSettings>().showAnimations
	));
}