import 'dart:math';
import 'dart:ui';

import 'package:chan/widgets/weak_navigator.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class OverscrollModalPage extends StatefulWidget {
	final Widget child;
	final double heightEstimate;
	final Color backgroundColor;
	final Widget? background;

	OverscrollModalPage({
		required this.child,
		this.background,
		this.heightEstimate = 0,
		this.backgroundColor = Colors.black38
	});

	@override
	createState() => _OverscrollModalPageState();
}

class _OverscrollModalPageState extends State<OverscrollModalPage> {
	late final ScrollController _controller;
	final GlobalKey _scrollKey = GlobalKey();
	final GlobalKey _childKey = GlobalKey();
	late double _scrollStopPosition;
	Offset? _pointerDownPosition;
	bool _pointerInSpacer = false;
	double _opacity = 1;
	bool _popping = false;
	bool _finishedPopIn = false;

	@override
	void initState() {
		super.initState();
		_scrollStopPosition = -150.0 - widget.heightEstimate;
		_controller = ScrollController(initialScrollOffset: _scrollStopPosition);
		_controller.addListener(_onScrollUpdate);
	}

	// To fix behavior when stopping the scroll-in with tap event
	void _onScrollUpdate() {
		if (!_popping) {
			final overscrollTop = _controller.position.minScrollExtent - _controller.position.pixels;
			final overscrollBottom = _controller.position.pixels - _controller.position.maxScrollExtent;
			final double desiredOpacity = 1 - (((max(overscrollTop, overscrollBottom) + _scrollStopPosition) - 40) / 100).clamp(0, 1);
			if (desiredOpacity != _opacity) {
				setState(() {
					_opacity = desiredOpacity;
				});
			}
		}
		if (_scrollStopPosition != 0 && _controller.position.pixels > _scrollStopPosition) {
			_scrollStopPosition = _controller.position.pixels;
			// Stop when coming to intial rest (since start position is largely negative)
			if (_scrollStopPosition > -0.2) {
				_scrollStopPosition = 0;
				setState(() {
					_finishedPopIn = true;
				});
			}
		}
	}

	void _onPointerUp() {
		if (_popping || _controller.positions.isEmpty) {
			return;
		}
		final overscrollTop = _controller.position.minScrollExtent - _controller.position.pixels;
		final overscrollBottom = _controller.position.pixels - _controller.position.maxScrollExtent;
		if (max(overscrollTop, overscrollBottom) > 50 - _scrollStopPosition) {
			_popping = true;
			WeakNavigator.pop(context);
		}
		else if (_pointerInSpacer) {
			_popping = true;
			// Simulate onTap for the Spacers which fill the transparent space
			// It's done here rather than using GestureDetector so it works during scroll-in
			if (WeakNavigator.of(context) != null) {
				WeakNavigator.of(context)!.popAllExceptFirst(animated: true);
			}
			else {
				Navigator.of(context).pop();
			}
		}
	}

	@override
	Widget build(BuildContext context) {
		return LayoutBuilder(
			builder: (context, constraints) => Stack(
				fit: StackFit.expand,
				children: [
					if (widget.background != null) Container(
						color: widget.backgroundColor,
						child: SafeArea(
							child: AnimatedBuilder(
								animation: _controller,
								child: widget.background,
								builder: (context, child) {
									final RenderBox? scrollBox = _scrollKey.currentContext?.findRenderObject() as RenderBox?;
									final RenderBox? childBox = _childKey.currentContext?.findRenderObject() as RenderBox?;
									final double scrollBoxTop = scrollBox?.localToGlobal(scrollBox.semanticBounds.topCenter).dy ?? 0;
									final double scrollBoxBottom = scrollBox?.localToGlobal(scrollBox.semanticBounds.bottomCenter).dy ?? 0;
									final double childBoxTopDiff = (childBox?.localToGlobal(childBox.semanticBounds.topCenter).dy ?? scrollBoxTop) - scrollBoxTop;
									final double childBoxBottomDiff = scrollBoxBottom - (childBox?.localToGlobal(childBox.semanticBounds.bottomCenter).dy ?? scrollBoxBottom);
									if (_finishedPopIn && _controller.positions.isNotEmpty && _controller.position.isScrollingNotifier.value) {
										return Stack(
											fit: StackFit.expand,
											children: [
												Positioned(
													top: childBoxTopDiff + (0 * max(0, _controller.position.pixels -	_controller.position.maxScrollExtent)) - (-1 * min(0, _controller.position.pixels)),
													bottom: childBoxBottomDiff + (-0 * min(0, _controller.position.pixels)) - max(0, _controller.position.pixels -	_controller.position.maxScrollExtent),
													left: 0,
													right: 0,
													child: Center(
														child: child!
													)
												)
											]
										);
									}
									return Container();
								}
							)
						)
					),
					NotificationListener<ScrollNotification>(
						onNotification: (notification) {
							if ((notification is ScrollEndNotification) || (notification is ScrollUpdateNotification && notification.dragDetails == null)) {
								_onPointerUp();
							}
							return false;
						},
						child: Listener(
							onPointerDown: (event) {
								final RenderBox childBox = _childKey.currentContext!.findRenderObject()! as RenderBox;
								_pointerDownPosition = event.position;
								_pointerInSpacer = event.position.dy < childBox.localToGlobal(childBox.semanticBounds.topCenter).dy || event.position.dy > childBox.localToGlobal(childBox.semanticBounds.bottomCenter).dy;
							},
							onPointerMove: (event) {
								if (_pointerInSpacer) {
									if ((event.position - _pointerDownPosition!).distance > kTouchSlop) {
										_pointerInSpacer = false;
									}
								}
							},
							onPointerUp: (event) => _onPointerUp(),
							child: Actions(
								actions: {
									DismissIntent: CallbackAction<DismissIntent>(
										onInvoke: (i) => WeakNavigator.pop(context)
									)
								},
								child: Focus(
									autofocus: true,
									child: CustomScrollView(
										controller: _controller,
										physics: AlwaysScrollableScrollPhysics(),
										slivers: [
											SliverToBoxAdapter(
												child: ConstrainedBox(
													constraints: BoxConstraints(
														minHeight: constraints.maxHeight
													),
													child: SafeArea(
														child: Center(
															key: _scrollKey,
															child: Opacity(
																key: _childKey,
																opacity: _opacity,
																child: widget.child
															)
														)
													)
												)
											)
										]
									)
								)
							)
						)
					)
				]
			)
		);
	}

	@override
	void dispose() {
		super.dispose();
		_controller.dispose();
	}
}