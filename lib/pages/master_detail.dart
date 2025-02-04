import 'dart:math';

import 'package:chan/services/settings.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/injecting_navigator.dart';
import 'package:chan/widgets/util.dart';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:chan/widgets/cupertino_page_route.dart';
import 'package:provider/provider.dart';

PageRoute fullWidthCupertinoPageRouteBuilder(WidgetBuilder builder, {required bool showAnimations, required bool? showAnimationsForward}) => FullWidthCupertinoPageRoute(builder: builder, showAnimations: showAnimations, showAnimationsForward: showAnimationsForward);
PageRoute transparentPageRouteBuilder(WidgetBuilder builder, {required bool showAnimations, required bool? showAnimationsForward}) => TransparentRoute(builder: builder, showAnimations: showAnimations, showAnimationsForward: showAnimationsForward);

class MasterDetailHint {
	final bool twoPane;
	final GlobalKey<PrimaryScrollControllerInjectingNavigatorState> primaryInterceptorKey;
	final dynamic currentValue;

	const MasterDetailHint({
		required this.twoPane,
		required this.primaryInterceptorKey,
		required this.currentValue
	});
}

const dontAutoPopSettings = RouteSettings(
	name: 'dontautoclose'
);

class WillPopZone {
	WillPopCallback? callback;
}

class BuiltDetailPane {
	final Widget widget;
	final PageRoute Function(WidgetBuilder builder, {required bool showAnimations, required bool? showAnimationsForward}) pageRouteBuilder;

	BuiltDetailPane({
		required this.widget,
		required this.pageRouteBuilder
	});

	PageRoute pageRoute({required bool showAnimations, required bool? showAnimationsForward}) => pageRouteBuilder((context) => widget, showAnimations: showAnimations, showAnimationsForward: showAnimationsForward);
}

class MasterDetailPage<T> extends StatelessWidget {
	final Object? id;
	final Widget Function(BuildContext context, bool Function(BuildContext, T) isSelected, ValueChanged<T?> valueSetter) masterBuilder;
	final BuiltDetailPane Function(T? selectedValue, bool poppedOut) detailBuilder;
	final T? initialValue;
	final ValueChanged<T?>? onValueChanged;
	const MasterDetailPage({
		required this.id,
		required this.masterBuilder,
		required this.detailBuilder,
		this.initialValue,
		this.onValueChanged,
		Key? key
	}) : super(key: key);
	@override
	Widget build(BuildContext context) {
		return MultiMasterDetailPage(
			showChrome: false,
			id: id,
			paneCreator: () => [
				MultiMasterPane<T>(
					masterBuilder: masterBuilder,
					detailBuilder: detailBuilder,
					initialValue: initialValue,
					onValueChanged: onValueChanged
				)
			]
		);
	}
}

class MultiMasterPane<T> {
	final Widget? title;
	final ObstructingPreferredSizeWidget? navigationBar;
	final IconData? icon;
	final Widget Function(BuildContext context, bool Function(BuildContext, T) isSelected, ValueChanged<T?> valueSetter) masterBuilder;
	final BuiltDetailPane Function(T? selectedValue, bool poppedOut) detailBuilder;
	ValueNotifier<T?> currentValue;
	final ValueChanged<T?>? onValueChanged;

	MultiMasterPane({
		required this.masterBuilder,
		required this.detailBuilder,
		this.title,
		this.navigationBar,
		this.icon,
		T? initialValue,
		this.onValueChanged
	}) : currentValue = ValueNotifier<T?>(initialValue);

	Widget buildMaster(BuildContext context, VoidCallback onNewValue, bool provideCurrentValue) {
		return masterBuilder(context, (context, thisValue) => context.select<MasterDetailHint?, bool>((h) {
			if (!provideCurrentValue) return false;
			return h?.currentValue == thisValue;
		}), (newValue) {
			currentValue.value = newValue;
			onValueChanged?.call(newValue);
			onNewValue();
		});
	}

	void onPushReturn(dynamic value) {
		if (value != false) {
			// it was a user-initiated pop
			currentValue.value = null;
			onValueChanged?.call(null);
		}
	}

	Widget buildDetail() {
		return ValueListenableBuilder(
			valueListenable: currentValue,
			builder: (context, T? v, child) => detailBuilder(v, false).widget
		);
	}

	PageRoute buildDetailRoute({required bool showAnimations, required bool? showAnimationsForward}) {
		return detailBuilder(currentValue.value, true).pageRoute(showAnimations: showAnimations, showAnimationsForward: showAnimationsForward);
	}

	void dispose() {
		currentValue.dispose();
	}
}

class MultiMasterDetailPage extends StatefulWidget {
	final Object? id;
	final List<MultiMasterPane> Function() paneCreator;
	final bool showChrome;

	const MultiMasterDetailPage({
		required this.paneCreator,
		this.id,
		this.showChrome = true,
		Key? key
	}) : super(key: key);

	@override
	createState() => MultiMasterDetailPageState();
}

class MultiMasterDetailPageState extends State<MultiMasterDetailPage> with TickerProviderStateMixin {
	late TabController _tabController;
	late GlobalKey<NavigatorState> masterKey;
	late GlobalKey<PrimaryScrollControllerInjectingNavigatorState> _masterInterceptorKey;
	late GlobalKey _masterContentKey;
	late GlobalKey<NavigatorState> detailKey;
	late GlobalKey<PrimaryScrollControllerInjectingNavigatorState> _detailInterceptorKey;
	late GlobalKey _detailContentKey;
	List<MultiMasterPane> panes = [];
 	bool? lastOnePane;
	late bool onePane;
	late final EasyListenable _rebuild;

	void _onPaneChanged() {
		setState(() {});
		_rebuild.didUpdate();
	}

	void _initGlobalKeys() {
		masterKey = GlobalKey<NavigatorState>(debugLabel: '${widget.id} masterKey');
		_masterInterceptorKey = GlobalKey(debugLabel: '${widget.id} _masterInterceptorKey');
		_masterContentKey = GlobalKey(debugLabel: '${widget.id} _masterContentKey');
		detailKey = GlobalKey<NavigatorState>(debugLabel: '${widget.id} detailKey}');
		_detailInterceptorKey = GlobalKey(debugLabel: '${widget.id} _detailInterceptorKey');
		_detailContentKey = GlobalKey(debugLabel: '${widget.id} _detailContentKey');
	}

	@override
	void initState() {
		super.initState();
		_rebuild = EasyListenable();
		panes = widget.paneCreator();
		_tabController = TabController(length: panes.length, vsync: this);
		_tabController.addListener(_onPaneChanged);
		_initGlobalKeys();
		WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
			if (panes[_tabController.index].currentValue.value != null) {
				_onNewValue(panes[_tabController.index], showAnimationsForward: false);
			}
		});
	}

	@override
	void didUpdateWidget(MultiMasterDetailPage oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.id != widget.id) {
			int newIndex = _tabController.index;
			panes = widget.paneCreator();
			if (_tabController.index >= panes.length) {
				newIndex = max(0, panes.length - 1);
			}
			_tabController.removeListener(_onPaneChanged);
			_tabController = TabController(
				initialIndex: newIndex,
				length: panes.length,
				vsync: this
			);
			_tabController.addListener(_onPaneChanged);
		  _initGlobalKeys();
		}
	}

	void setValue(int index, dynamic value) {
		if (panes[index].currentValue.value == value) {
			return;
		}
		panes[index].currentValue.value = value;
		panes[index].onValueChanged?.call(value);
		_onNewValue(panes[index]);
	}

	T? getValue<T>(int index) {
		dynamic value = panes[index].currentValue.value;
		if (value is T) {
			return value;
		}
		else if (value != null) {
			print('Tried to getValue<$T>($index) but found ${value.runtimeType}');
		}
		return null;
	}

	void _popMasterValueRoutes() {
		bool continuePopping = true;
		while ((masterKey.currentState?.canPop() ?? false) && continuePopping) {
			// Hack to peek at top route
			// Need to pop with value=false so can't just use popUntil
			masterKey.currentState?.popUntil((route) {
				continuePopping = route.settings != dontAutoPopSettings;
				if (continuePopping) {
					masterKey.currentState?.pop(false);
				}
				return true;
			});
		}
	}

	void _onNewValue<T> (MultiMasterPane<T> pane, {bool? showAnimationsForward}) {
		if (onePane) {
			if (pane.currentValue.value != null) {
				_popMasterValueRoutes();
				masterKey.currentState!.push(pane.buildDetailRoute(
					showAnimations: context.read<EffectiveSettings>().showAnimations,
					showAnimationsForward: showAnimationsForward
				)).then(pane.onPushReturn);
			}
		}
		else {
			detailKey.currentState?.popUntil((route) => route.isFirst);
		}
		setState(() {});
	}

	Future<bool> _onWillPop() async {
		if (onePane) {
			return !(await masterKey.currentState?.maybePop() ?? false);
		}
		else {
			if (await detailKey.currentState?.maybePop() ?? false) {
				return false;
			}
			return !(await masterKey.currentState?.maybePop() ?? false);
		}
	}

	@override
	Widget build(BuildContext context) {
		final settings = context.watch<EffectiveSettings>();
		onePane = MediaQuery.sizeOf(context).width < settings.twoPaneBreakpoint;
		final masterNavigator = Provider.value(
			value: masterKey,
			child: ClipRect(
				child: PrimaryScrollControllerInjectingNavigator(
					key: _masterInterceptorKey,
					navigatorKey: masterKey,
					observers: [HeroController()],
					buildRoot: (context) => AnimatedBuilder(
						animation: _rebuild,
						builder: (context, _) {
							Widget child = TabBarView(
								controller: _tabController,
								physics: panes.length > 1 ? const AlwaysScrollableScrollPhysics() : const NeverScrollableScrollPhysics(),
								children: panes.asMap().entries.map((entry) => AnimatedBuilder(
									animation: _tabController,
									builder: (context, child) => entry.key == _tabController.index ? child! : PrimaryScrollController.none(
										child: child!
									),
									child: Builder(
										builder: (context) => entry.value.buildMaster(context, () => _onNewValue(entry.value), !onePane)
									)
								)).toList()
							);
							if (widget.showChrome) {
								child = CupertinoPageScaffold(
									resizeToAvoidBottomInset: false,
									navigationBar: panes[_tabController.index].navigationBar ?? CupertinoNavigationBar(
										transitionBetweenRoutes: false,
										middle: panes[_tabController.index].title
									),
									child: Column(
										children: [
											SafeArea(
												bottom: false,
												child: Material(
													color: CupertinoTheme.of(context).scaffoldBackgroundColor,
													child: TabBar(
														controller: _tabController,
														indicatorColor: CupertinoTheme.of(context).primaryColor,
														tabs: panes.map((pane) => Tab(
															icon: Icon(
																pane.icon,
																color: CupertinoTheme.of(context).primaryColor
															)
														)).toList()
													)
												)
											),
											TransformedMediaQuery(
												transformation: (mq) => mq.removePadding(removeTop: true),
												child: Expanded(
													child: child
												)
											)
										]
									)
								);
							}
							child = KeyedSubtree(
								key: _masterContentKey,
								child: child
							);
							return child;
						}
					)
				)
			)
		);
		final detailNavigator = Provider.value(
			value: detailKey,
			child: ClipRect(
				child: PrimaryScrollControllerInjectingNavigator(
					key: _detailInterceptorKey,
					navigatorKey: detailKey,
					buildRoot: (context) => AnimatedBuilder(
						animation: _rebuild,
						builder: (context, _) => KeyedSubtree(
							key: _detailContentKey,
							child: panes[_tabController.index].buildDetail()
						)
					)
				)
			)
		);
		if (lastOnePane != null && lastOnePane != onePane) {
			final pane = panes[_tabController.index];
			if (onePane && pane.currentValue.value != null) {
				masterKey.currentState!.push(pane.buildDetailRoute(
					showAnimations: context.read<EffectiveSettings>().showAnimations,
					showAnimationsForward: null
				)).then(pane.onPushReturn);
			}
			else {
				_popMasterValueRoutes();
				while (detailKey.currentState?.canPop() ?? false) {
					detailKey.currentState?.pop(false);
				}
			}
		}
		lastOnePane = onePane;
		context.watch<WillPopZone?>()?.callback = _onWillPop;
		return Provider.value(
			value: MasterDetailHint(
				twoPane: !onePane,
				primaryInterceptorKey: onePane ? _masterInterceptorKey : _detailInterceptorKey,
				currentValue: panes[_tabController.index].currentValue.value
			),
			child: WillPopScope(
				onWillPop: _onWillPop,
				child: onePane ? masterNavigator : Row(
					children: [
						Flexible(
							flex: settings.twoPaneSplit,
							child: PrimaryScrollController.none(
								child: masterNavigator
							)
						),
						VerticalDivider(
							width: 0,
							color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2)
						),
						Flexible(
							flex: twoPaneSplitDenominator - settings.twoPaneSplit,
							child: detailNavigator
						)
					]
				)
			)
		);
	}

	@override
	void dispose() {
		super.dispose();
		_tabController.dispose();
		for (final pane in panes) {
			pane.dispose();
		}
		_rebuild.dispose();
	}
}