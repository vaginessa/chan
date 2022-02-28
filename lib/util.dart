import 'dart:async';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:mutex/mutex.dart';
import 'package:share_extend/share_extend.dart';
import 'package:share_plus/share_plus.dart';

extension SafeWhere<T> on Iterable<T> {
	T? tryFirstWhere(bool Function(T v) f) => cast<T?>().firstWhere((v) => f(v!), orElse: () => null);
	T? tryLastWhere(bool Function(T v) f) => cast<T?>().lastWhere((v) => f(v!), orElse: () => null);
}

extension BinarySafeWhere<T> on List<T> {
	int binarySearchTryFirstIndexWhere(bool Function(T v) f) {
		int min = 0;
		int max = length - 1;
		while (min < max) {
			final int mid = min + ((max - min) >> 1);
			final T element = this[mid];
			final T next = this[mid + 1];
			final bool elementPasses = f(element);
			final bool nextElementPasses = f(next);
			if (!elementPasses && nextElementPasses) {
				return mid + 1;
			}
			else if (elementPasses) {
				max = mid;
			}
			else {
				min = mid + 1;
			}
		}
		print(first);
		print(f(first));
		if (f(first)) {
			return 0;
		}
		else if (f(last)) {
			return length - 1;
		}
		return -1;
	}
	T? binarySearchTryFirstWhere(bool Function(T v) f) {
		final index = binarySearchTryFirstIndexWhere(f);
		if (index == -1) {
			return null;
		}
		return this[index];
	}
	int binarySearchTryLastIndexWhere(bool Function(T v) f) {
		int min = 0;
		int max = length - 1;
		while (min < max) {
			final int mid = min + ((max - min) >> 1);
			final T element = this[mid];
			final T next = this[mid + 1];
			final bool elementPasses = f(element);
			final bool nextElementPasses = f(next);
			if (elementPasses && !nextElementPasses) {
				return mid;
			}
			else if (elementPasses) {
				min = mid + 1;
			}
			else {
				max = mid;
			}
		}
		if (f(last)) {
			return length - 1;
		}
		else if (f(first)) {
			return 0;
		}
		return -1;
	}
	T? binarySearchTryLastWhere(bool Function(T v) f) {
		final index = binarySearchTryLastIndexWhere(f);
		if (index == -1) {
			return null;
		}
		return this[index];
	}
}

class ExpiringMutexResource<T> {
	final Future<T> Function() _initializer;
	final Future Function(T resource) _deinitializer;
	final Duration _interval;
	ExpiringMutexResource(this._initializer, this._deinitializer, {
		Duration? interval
	}) : _interval = interval ?? const Duration(minutes: 1);
	final _mutex = Mutex();
	T? _resource;
	Timer? _timer;
	Future<T> _getInitialized() async {
		_resource ??= await _initializer();
		return _resource!;
	}
	void _deinitialize() {
		_mutex.protect(() async {
			if (_timer == null) {
				return;
			}
			if (_resource != null) {
				_deinitializer(_resource!);
				_resource = null;
			}
		});
	}
	Future<void> runWithResource(Future Function(T resource) work) {
		return _mutex.protect(() async {
			_timer?.cancel();
			_timer = null;
			await work(await _getInitialized());
			_timer = Timer(_interval, _deinitialize);
		});
	}
}

extension ToStringDio on Object {
	String toStringDio() {
		if (this is DioError) {
			return (this as DioError).message;
		}
		else {
			return toString();
		}
	}
}

Future<void> shareOne({
	required String text,
	required String type,
	String? subject,
	required Rect? sharePositionOrigin
}) async {
	if (type == 'file') {
		try {
			await ShareExtend.share(
				text,
				type,
				subject: subject ?? '',
				sharePositionOrigin: sharePositionOrigin
			);
		}
		on MissingPluginException {
			await Share.shareFiles(
				[text],
				subject: subject,
				sharePositionOrigin: sharePositionOrigin
			);
		}
	}
	else {
		await Share.share(
			text,
			subject: subject,
			sharePositionOrigin: sharePositionOrigin
		);
	}
}