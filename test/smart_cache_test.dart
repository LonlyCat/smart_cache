import 'package:flutter_test/flutter_test.dart';
import 'package:smart_cache/smart_cache.dart';

import 'test_model.dart';

void main() {
  group('CacheableLoader', () {
    late SmartCacheManager cacheManager;

    setUp(() {
      cacheManager = SmartCacheManager(enableDiskCache: false);
      cacheManager.registerModel<TestModel>(TestModel.fromJson);
    });

    test('loads data from cache', () async {
      final key = 'test_key';
      final cachedData = TestModel(
        id: 'cached_id',
        name: 'cached_name',
      );
      cacheManager.putObject(key, cachedData);

      final stream = CacheableLoader.load<TestModel>(
        key,
        cacheManager: cacheManager,
        loader: () async => Future.value(cachedData),
      );
      final result = await stream.first;

      expect(result.status, CacheableLoadStatus.fromCache);
      expect(result.data, cachedData);
    });

    test('loads data from loader when cache is empty', () async {
      final key = 'test_key';

      final loadedData = TestModel(
        id: 'loaded_id',
        name: 'loaded_name',
      );

      final stream = CacheableLoader.load<TestModel>(
        key,
        cacheManager: cacheManager,
        loader: () async => Future.value(loadedData),
      );
      final result = await stream.first;

      expect(result.status, CacheableLoadStatus.fromLoader);
      expect(result.data, loadedData);
    });

    test('returns failed result when loader fails', () async {
      final key = 'test_key_loader';

      final stream = CacheableLoader.load<String>(
        key,
        cacheManager: cacheManager,
        loader: () async => Future.error('加载失败'),
      );
      final result = await stream.first;

      expect(result.status, CacheableLoadStatus.failed);
      expect(result.error, isNotNull);
    });

    test('loads data from cache only', () async {
      final key = 'test_key';
      final cachedData = TestModel(
        id: 'cached_id',
        name: 'cached_name',
      );
      cacheManager.putObject(key, cachedData);

      final stream = CacheableLoader.load<TestModel>(
        key,
        cacheOnly: true,
        cacheManager: cacheManager,
        loader: () async => Future.value(cachedData),
      );
      final result = await stream.first;

      expect(result.status, CacheableLoadStatus.fromCache);
      expect(result.data, cachedData);
    });

    test('loads data from loader only', () async {
      final key = 'test_key';
      final cachedData = TestModel(
        id: 'cached_id',
        name: 'cached_name',
      );
      final loadedData = TestModel(
        id: 'loaded_id',
        name: 'loaded_name',
      );
      cacheManager.putObject(key, cachedData);

      final stream = CacheableLoader.load<TestModel>(
        key,
        loaderOnly: true,
        cacheManager: cacheManager,
        loader: () async => Future.value(loadedData),
      );
      final result = await stream.first;

      expect(result.status, CacheableLoadStatus.fromLoader);
      expect(result.data, loadedData);
    });
  });
}
