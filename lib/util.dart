import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';
import 'package:tuple/tuple.dart';

extension SafeWhere<T> on Iterable<T> {
	T? tryFirstWhere(bool Function(T v) f) => cast<T?>().firstWhere((v) => f(v as T), orElse: () => null);
	T? tryLastWhere(bool Function(T v) f) => cast<T?>().lastWhere((v) => f(v as T), orElse: () => null);
	T? get tryFirst => isNotEmpty ? first : null;
	T? get tryLast => isNotEmpty ? last : null;
}

extension BinarySafeWhere<T> on List<T> {
	int binarySearchFirstIndexWhere(bool Function(T v) f) {
		if (isEmpty) {
			return -1;
		}
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
		if (f(first)) {
			return 0;
		}
		else if (f(last)) {
			return length - 1;
		}
		return -1;
	}
	T? binarySearchTryFirstWhere(bool Function(T v) f) {
		final index = binarySearchFirstIndexWhere(f);
		if (index == -1) {
			return null;
		}
		return this[index];
	}
	int binarySearchLastIndexWhere(bool Function(T v) f) {
		if (isEmpty) {
			return -1;
		}
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
		final index = binarySearchLastIndexWhere(f);
		if (index == -1) {
			return null;
		}
		return this[index];
	}
	int binarySearchCountBefore(bool Function(T v) f) {
		final index = binarySearchFirstIndexWhere(f);
		if (index == -1) {
			return length;
		}
		else {
			return length - index;
		}
	}
	int binarySearchCountAfter(bool Function(T v) f) {
		final index = binarySearchFirstIndexWhere(f);
		if (index == -1) {
			return 0;
		}
		else {
			return length - index;
		}
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
				_deinitializer(_resource as T);
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
			return '${(this as DioError).message}\nURL: ${(this as DioError).requestOptions.uri}';
		}
		else {
			return toString();
		}
	}
}

extension Filtering on Listenable {
	Listenable filter(bool Function() filter) {
		return FilteringListenable(this, filter);
	}
}

class FilteringListenable extends ChangeNotifier {
  FilteringListenable(this._child, this._filter) {
		_child.addListener(_listen);
	}

  final Listenable _child;
	final bool Function() _filter;

	void _listen() {
		if (_filter()) {
			notifyListeners();
		}
	}

	@override
	void dispose() {
		super.dispose();
		_child.removeListener(_listen);
	}

  @override
  String toString() {
    return 'FilteringListenable(child: $_child, filter: $_filter)';
  }
}

class CombiningValueListenable<T> extends ChangeNotifier implements ValueListenable<T> {
	final List<ValueListenable<T>> children;
	final T Function(T, T) combine;
	final T noChildrenValue;
	CombiningValueListenable({
		required this.children,
		required this.combine,
		required this.noChildrenValue
	}) {
		for (final child in children) {
			child.addListener(_listen);
		}
	}

	void _listen() {
		notifyListeners();
	}

	@override
	void dispose() {
		super.dispose();
		for (final child in children) {
			child.removeListener(_listen);
		}
	}

	@override
	T get value => children.isEmpty ? noChildrenValue : children.map((c) => c.value).reduce(combine);
}

final Map<Function, Tuple2<Timer, Completer<void>>> _functionIdleTimers = {};
Future<void> runWhenIdle(Duration duration, FutureOr Function() function) {
	final completer = _functionIdleTimers[function]?.item2 ?? Completer();
	_functionIdleTimers[function]?.item1.cancel();
	_functionIdleTimers[function] = Tuple2(Timer(duration, () async {
		_functionIdleTimers.remove(function);
		await function();
		completer.complete();
	}), completer);
	return completer.future;
}

enum NullSafeOptional {
	null_,
	false_,
	true_
}

extension ToBool on NullSafeOptional {
	bool? get value {
		switch (this) {
			case NullSafeOptional.null_: return null;
			case NullSafeOptional.false_: return false;
			case NullSafeOptional.true_: return true;
		}
	}
}

extension ToNullSafeOptional on bool? {
	NullSafeOptional get value {
		switch (this) {
			case true: return NullSafeOptional.true_;
			case false: return NullSafeOptional.false_;
			default: return NullSafeOptional.null_;
		}
	}
}

class EasyListenable extends ChangeNotifier {
	void didUpdate() {
		notifyListeners();
	}
}
