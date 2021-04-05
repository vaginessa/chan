import 'package:chan/pages/history.dart';
import 'package:chan/pages/search.dart';
import 'package:chan/pages/settings.dart';
import 'package:chan/pages/saved.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/foolfuuka.dart';
import 'package:cupertino_back_gesture/cupertino_back_gesture.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'sites/imageboard_site.dart';
import 'sites/4chan.dart';
import 'pages/tab.dart';
import 'package:provider/provider.dart';

void main() async {
	await Persistence.initialize();
	runApp(ChanApp());
}

class ChanApp extends StatelessWidget {
	@override
	Widget build(BuildContext context) {
		return BackGestureWidthTheme(
			backGestureWidth: BackGestureWidth.fraction(1),
			child: MultiProvider(
				providers: [
					ChangeNotifierProvider<EffectiveSettings>(create: (_) => EffectiveSettings()),
					Provider<ImageboardSite>(create: (_) => Site4Chan(
						baseUrl: 'boards.4chan.org',
						staticUrl: 's.4cdn.org',
						sysUrl: 'sys.4chan.org',
						apiUrl: 'a.4cdn.org',
						imageUrl: 'i.4cdn.org',
						name: '4chan',
						captchaKey: '6Ldp2bsSAAAAAAJ5uyx_lx34lJeEpTLVkP5k04qc',
						archives: [
							FoolFuukaArchive(baseUrl: 'archive.4plebs.org', staticUrl: 's.4cdn.org', name: '4plebs'),
							FoolFuukaArchive(baseUrl: 'archive.rebeccablacktech.com', staticUrl: 's.4cdn.org', name: 'RebeccaBlackTech'),
							FoolFuukaArchive(baseUrl: 'archive.nyafuu.org', staticUrl: 's.4cdn.org', name: 'Nyafuu'),
							FoolFuukaArchive(baseUrl: 'desuarchive.org', staticUrl: 's.4cdn.org', name: 'Desuarchive'),
							FoolFuukaArchive(baseUrl: 'archived.moe', staticUrl: 's.4cdn.org', name: 'Archived.Moe')
						]
					))
				],
				child: SettingsSystemListener(
					child: Builder(
						builder: (BuildContext context) {
							final brightness = context.watch<EffectiveSettings>().theme;
							CupertinoThemeData theme = CupertinoThemeData(brightness: Brightness.light, primaryColor: Colors.black);
							if (brightness == Brightness.dark) {
								theme = CupertinoThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: Color.fromRGBO(20, 20, 20, 1), primaryColor: Colors.white);
							}
							return CupertinoApp(
								title: 'Chan',
								theme: theme,
								home: Builder(
									builder: (BuildContext context) {
										return DefaultTextStyle(
											style: CupertinoTheme.of(context).textTheme.textStyle,
											child: ChanHomePage()
										);
									}
								)
							);
						}
					)
				)
			)
		);
	}
}

class ChanHomePage extends StatelessWidget {
	@override
	Widget build(BuildContext context) {
		return CupertinoTabScaffold(
			tabBar: CupertinoTabBar(
				items: [
					BottomNavigationBarItem(
						icon: Icon(Icons.list),
						label: 'Browse'
					),
					BottomNavigationBarItem(
						icon: Icon(Icons.save_alt),
						label: 'Saved'
					),
					BottomNavigationBarItem(
						icon: Icon(Icons.history),
						label: 'History'
					),
					BottomNavigationBarItem(
						icon: Icon(Icons.search),
						label: 'Search'
					),
					BottomNavigationBarItem(
						icon: Icon(Icons.settings),
						label: 'Settings'
					)
				]
			),
			tabBuilder: (context, index) {
				if (index == 0) {
					return CupertinoTabView(
						builder: (context) => ImageboardTab(
							initialBoardName: 'tv',
							isInTabletLayout: MediaQuery.of(context).size.width > 700
						)
					);
				}
				else if (index == 1) {
					return CupertinoTabView(
						builder: (context) => SavedPage()
					);
				}
				else if (index == 2) {
					return CupertinoTabView(
						builder: (context) => HistoryPage()
					);
				}
				else if (index == 3) {
					return CupertinoTabView(
						builder: (context) => SearchPage()
					);
				}
				else {
					return CupertinoTabView(
						builder: (context) => SettingsPage()
					);
				}
			}
		);
	}
}