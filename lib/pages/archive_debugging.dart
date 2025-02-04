import 'package:chan/pages/board.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/models/search.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/attachment.dart';
import 'package:chan/services/settings.dart';
import 'dart:io';

import 'package:chan/sites/4chan.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/widgets/cupertino_page_route.dart';
import 'package:dio/dio.dart';
import 'package:extended_image_library/extended_image_library.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

class WrappedArchive extends ImageboardSite {
	final ImageboardSiteArchive archive;
	WrappedArchive(this.archive) : super([]);

  @override
  List<ImageboardSiteArchive> get archives => [];

  @override
  Dio get client => archive.client;

  @override
  Future<PostReceipt> createThread({required String board, String name = '', String options = '', String subject = '', required String text, required CaptchaSolution captchaSolution, File? file, bool? spoiler, String? overrideFilename, ImageboardBoardFlag? flag}) {
    throw UnimplementedError();
  }

  @override
  Future<void> deletePost(String board, PostReceipt receipt) {
    throw UnimplementedError();
  }

  @override
  DateTime? getActionAllowedTime(String board, ImageboardAction action) {
    return null;
  }

  @override
  Future<List<ImageboardBoard>> getBoards() {
    return archive.getBoards();
  }

  @override
  Future<CaptchaRequest> getCaptchaRequest(String board, [int? threadId]) async {
    throw UnimplementedError();
  }

  @override
  Future<List<Thread>> getCatalog(String board, {CatalogVariant? variant}) {
    return archive.getCatalog(board);
  }

  @override
  Future<Post> getPost(String board, int id) {
    return archive.getPost(board, id);
  }

  @override
  Future<Post> getPostFromArchive(String board, int id) {
    return archive.getPost(board, id);
  }

  @override
  Uri getPostReportUrl(String board, int id) {
    throw UnimplementedError();
  }

  @override
  Uri getSpoilerImageUrl(Attachment attachment, {ThreadIdentifier? thread}) {
    throw UnimplementedError();
  }

  @override
  Future<Thread> getThread(ThreadIdentifier thread, {ThreadVariant? variant}) {
    return archive.getThread(thread);
  }

  @override
  Future<Thread> getThreadFromArchive(ThreadIdentifier thread, {Future<void> Function(Thread)? validate}) {
    return archive.getThread(thread);
  }

  @override
  String getWebUrl(String board, [int? threadId, int? postId]) {
    throw UnimplementedError();
  }

  @override
  String get imageUrl => throw UnimplementedError();

  @override
  String get name => archive.name;

  @override
  Future<PostReceipt> postReply({required ThreadIdentifier thread, String name = '', String options = '', required String text, required CaptchaSolution captchaSolution, File? file, bool? spoiler, String? overrideFilename, ImageboardBoardFlag? flag}) {
    throw UnimplementedError();
  }

  @override
  Future<ImageboardArchiveSearchResultPage> search(ImageboardArchiveSearchQuery query, {required int page, ImageboardArchiveSearchResultPage? lastResult}) {
    return archive.search(query, page: page, lastResult: lastResult);
  }

  @override
  List<ImageboardSiteLoginField> getLoginFields() {
    return [];
  }

  @override
  Future<void> clearLoginCookies(bool fromBothWifiAndCellular) async {
    
  }

  @override
  Future<void> login(Map<ImageboardSiteLoginField, String> fields) {
    throw UnimplementedError();
  }

  @override
  String? getLoginSystemName() {
    return null;
  }

  @override
  String get siteType => 'debugging';
  @override
  String get siteData => '';
  
  @override
  BoardThreadOrPostIdentifier? decodeUrl(String url) => null;

  @override
  Uri get iconUrl => Uri.https('google.com', '/favicon.ico');
  
  @override
  String get defaultUsername => '';
  
  @override
  String get baseUrl => 'www.example.com';
}

class ArchiveDebuggingPage extends StatelessWidget {
	const ArchiveDebuggingPage({
		Key? key
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		final site = context.watch<ImageboardSite>() as Site4Chan;
		return CupertinoPageScaffold(
			navigationBar: const CupertinoNavigationBar(
				transitionBetweenRoutes: false,
				middle: Text('Archive debugging')
			),
			child: ListView.builder(
        itemCount: site.archives.length,
        itemBuilder: (context, i) => Container(
          padding: const EdgeInsets.all(16),
          alignment: Alignment.center,
          child: CupertinoButton(
            child: Text(site.archives[i].name),
            onPressed: () {
              final t = ThreadIdentifier('g', 72382464);
              context.read<Persistence>().getThreadStateIfExists(t)?.delete();
              Navigator.of(context).push(CupertinoPageRoute(
                builder: (context) => Provider<ImageboardSite>.value(
                  value: WrappedArchive(site.archives[i]),
                  child: Navigator(
                    initialRoute: '/',
                    onGenerateRoute: (settings) => FullWidthCupertinoPageRoute(
                      builder: (context) => const BoardPage(
                        initialBoard: null,
                        semanticId: -1
                      ),
                      showAnimations: context.read<EffectiveSettings>().showAnimations
                    )
                  )
                )
              ));
            }
          )
        )
      )
    );
	}
}