import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';

// 导入我们的SmartCacheManager
import 'package:smart_cache/smart_cache.dart';
import 'package:smart_cache_example/models/product.dart';

void main() {
  runApp(const MemoryComparisonApp());
}

class MemoryComparisonApp extends StatelessWidget {
  const MemoryComparisonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '内存优化对比',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
      ),
      home: const MemoryComparisonHome(),
    );
  }
}

class MemoryComparisonHome extends StatefulWidget {
  const MemoryComparisonHome({Key? key}) : super(key: key);

  @override
  _MemoryComparisonHomeState createState() => _MemoryComparisonHomeState();
}

class _MemoryComparisonHomeState extends State<MemoryComparisonHome> with WidgetsBindingObserver {
  // 传统方法 - 直接使用Map存储所有产品
  final Map<String, Product> _traditionalCache = {};

  // 使用SmartCacheManager
  final SmartCacheManager _smartCache = SmartCacheManager.standard;

  // 内存使用数据
  List<MemoryUsage> _traditionalMemoryUsage = [];
  List<MemoryUsage> _smartMemoryUsage = [];

  // 控制运行状态
  bool _isRunningTest = false;
  Timer? _memoryMonitorTimer;

  // 每次加载的产品数量
  int _productsPerBatch = 100;

  // 加载的总批次
  int _totalBatches = 10;

  // 当前加载的批次
  int _currentBatch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 初始化SmartCache
    //
    // 可以使用模型表
    // _smartCache.registerModel<Product>(Product.fromJson);
    // _smartCache.registerModel<Variant>(Variant.fromJson);
    // 也可以使用模型生成器
    _smartCache.registerModelGenerator((type, json) {
      if (type == 'Product') {
        return Product.fromJson(json);
      } else if (type == 'Variant') {
        return Variant.fromJson(json);
      }
      return null;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopMemoryMonitoring();
    _smartCache.dispose();
    super.dispose();
  }

  // 开始内存使用监控
  void _startMemoryMonitoring() {
    _traditionalMemoryUsage = [];
    _smartMemoryUsage = [];
    _currentBatch = 0;

    setState(() {
      _isRunningTest = true;
    });

    _memoryMonitorTimer = Timer.periodic(Duration(seconds: 2), (timer) {
      _captureMemoryUsage();
      // 加载下一批产品
      if (_currentBatch < _totalBatches) {
        _loadNextBatch();
      } else if (_currentBatch >= _totalBatches && _currentBatch < _totalBatches + 10) {
        // 最后一批加载完毕后，模拟 10 批随机访问
        _simulateRandomAccess();
      } else if (_currentBatch == _totalBatches + 40) {
        // 模拟访问一段时间后停止测试
        _stopMemoryMonitoring();
      }
      _currentBatch++;
    });
  }

  // 停止内存监控
  void _stopMemoryMonitoring({ bool clearCache = true }) {
    _memoryMonitorTimer?.cancel();
    _memoryMonitorTimer = null;

    // 清空传统缓存
    if (clearCache) {
      _traditionalCache.clear();
      _smartCache.clear();
    }
    setState(() {
      _isRunningTest = false;
    });
  }

  // 模拟随机访问数据
  void _simulateRandomAccess() {
    final random = Random();
    // 随机访问10个产品
    for (int i = 0; i < 10; i++) {
      final productId = 'product-${random.nextInt(_productsPerBatch * _totalBatches)}';

      // 传统方法访问
      final traditional = _traditionalCache[productId];

      // SmartCacheManager访问
      final smart = _smartCache.getObject<Product>(productId);
    }
  }

  // 加载下一批产品
  void _loadNextBatch() {
    final startIndex = _currentBatch * _productsPerBatch;
    for (int i = 0; i < _productsPerBatch; i++) {
      final productId = 'product-${startIndex + i}';
      final product = _generateRandomProduct(productId);

      // 存储到传统缓存
      _traditionalCache[productId] = product;

      // 存储到SmartCache
      _smartCache.putObject<Product>(productId, product);
    }
  }

  // 生成随机产品数据
  Product _generateRandomProduct(String id) {
    final random = Random();
    final variantsCount = 2 + random.nextInt(8); // 2-10个变体

    List<Variant> variants = [];
    for (int i = 0; i < variantsCount; i++) {
      variants.add(Variant(
        id: '$id-variant-$i',
        name: 'Variant ${i + 1}',
        price: 50 + random.nextDouble() * 450, // 50-500价格
        options: {
          'color': ['红色', '蓝色', '黑色', '白色', '绿色'][random.nextInt(5)],
          'size': ['S', 'M', 'L', 'XL', 'XXL'][random.nextInt(5)],
          'material': ['棉', '麻', '丝', '涤纶', '羊毛'][random.nextInt(5)],
        },
      ));
    }

    return Product(
      id: id,
      name: '产品 ${random.nextInt(10000)}',
      description: '这是一个随机生成的产品描述，包含了大量的文本内容。' * 15, // 长文本
      price: 100 + random.nextDouble() * 900, // 100-1000价格
      categories: [
        ['服装', '电子', '家居', '食品', '玩具'][random.nextInt(5)],
        ['新品', '热卖', '限量版', '折扣'][random.nextInt(4)],
      ],
      attributes: {
        'brand': ['品牌A', '品牌B', '品牌C', '品牌D', '品牌E'][random.nextInt(5)],
        'warranty': ['1年', '2年', '3年', '无'][random.nextInt(4)],
        'rating': 1 + random.nextDouble() * 4, // 1-5评分
        'stock': 5 + random.nextInt(95), // 5-100库存
        'specifications': {
          'width': 10 + random.nextDouble() * 90,
          'height': 10 + random.nextDouble() * 90,
          'weight': 0.5 + random.nextDouble() * 9.5,
          'features': [
            '特性1',
            '特性2',
            '特性3',
            '特性4',
            '特性5',
          ].sublist(0, 2 + random.nextInt(4)), // 2-5个特性
        },
      },
      variants: variants,
    );
  }

  // 捕获当前内存使用情况
  Future<void> _captureMemoryUsage() async {
    try {
      // 计算传统缓存的内存使用
      final traditionalUsage = _traditionalCache.values
                .map((product) => product.memorySize)
                .fold(0.0, (previousValue, element) => previousValue + element);

      // SmartCache在加载中内存使用较少，之后会压缩不活跃数据
      double smartUsage = 0;
      if (_currentBatch > 0) {
        final stats = _smartCache.getStats();
        double activeUsage = stats.activeItemsCount * _traditionalCache.values.first.memorySize;
        smartUsage = activeUsage + stats.memoryUsage.compressedCache;
      }

      setState(() {
        _traditionalMemoryUsage.add(MemoryUsage(_currentBatch, traditionalUsage));
        _smartMemoryUsage.add(MemoryUsage(_currentBatch, smartUsage));
      });
    } catch (e) {
      print('捕获内存使用时出错: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('内存优化对比'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '对比传统缓存与SmartCacheManager的内存使用',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 20),

            // 内存使用图表
            if (_traditionalMemoryUsage.isNotEmpty) ...[
              SizedBox(
                height: 300,
                child: MemoryUsageChart(
                  traditionalUsage: _traditionalMemoryUsage,
                  smartUsage: _smartMemoryUsage,
                ),
              ),
              SizedBox(height: 20),

              // 内存使用概要
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('内存使用情况概要',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 8),

                      if (_traditionalMemoryUsage.isNotEmpty &&
                          _smartMemoryUsage.isNotEmpty) ...[
                        Text('传统缓存当前内存: ${_traditionalMemoryUsage.last.usage.toStringAsFixed(2)} KB'),
                        Text('SmartCache当前内存: ${_smartMemoryUsage.last.usage.toStringAsFixed(2)} KB'),
                        SizedBox(height: 8),
                        Text(
                          '内存节省: ${(_traditionalMemoryUsage.last.usage - _smartMemoryUsage.last.usage).toStringAsFixed(2)} KB (${((_traditionalMemoryUsage.last.usage - _smartMemoryUsage.last.usage) / _traditionalMemoryUsage.last.usage * 100).toStringAsFixed(1)}%)',
                          style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SmartCacheManager缓存统计',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 8),

                      // 获取并显示SmartCache的统计信息
                      Text('活跃缓存项: ${_smartCache.getStats().activeItemsCount}'),
                      Text('压缩缓存项: ${_smartCache.getStats().compressedItemsCount}'),
                      Text('总缓存项: ${_smartCache.getStats().totalItemsCount}'),
                    ],
                  ),
                ),
              ),
            ],

            SizedBox(height: 20),

            // 测试控制按钮
            ElevatedButton(
              onPressed: _isRunningTest ? null : _startMemoryMonitoring,
              child: Text('开始测试'),
            ),

            SizedBox(height: 10),

            ElevatedButton(
              onPressed: _isRunningTest
                  ? () => _stopMemoryMonitoring()
                  : null,
              child: Text('停止测试'),
            ),

            SizedBox(height: 20),

            // 测试说明
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('测试说明',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    SizedBox(height: 8),
                    Text('1. 测试将分批加载 ${_productsPerBatch * _totalBatches} 个复杂产品对象'),
                    Text('2. 每个产品包含多个变体和大量属性数据'),
                    Text('3. 加载完成后会模拟随机访问部分产品'),
                    Text('4. 图表展示传统方法与SmartCacheManager的内存使用对比'),
                    Text('5. SmartCacheManager会自动压缩不常用的数据，减少内存占用'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 内存使用数据模型
class MemoryUsage {
  final int time; // 时间点
  final double usage; // 内存使用量(KB)

  MemoryUsage(this.time, this.usage);
}

// 使用fl_chart的内存使用图表
class MemoryUsageChart extends StatelessWidget {
  final List<MemoryUsage> traditionalUsage;
  final List<MemoryUsage> smartUsage;

  const MemoryUsageChart({
    Key? key,
    required this.traditionalUsage,
    required this.smartUsage,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 16.0, top: 16.0, bottom: 12.0),
      child: LineChart(
        LineChartData(
          gridData: FlGridData(
            show: true,
            horizontalInterval: 1000,
            drawVerticalLine: true,
            getDrawingHorizontalLine: (value) {
              return FlLine(
                color: Colors.grey.withOpacity(0.3),
                strokeWidth: 1,
              );
            },
            getDrawingVerticalLine: (value) {
              return FlLine(
                color: Colors.grey.withOpacity(0.3),
                strokeWidth: 1,
              );
            },
          ),
          titlesData: FlTitlesData(
            show: true,
            rightTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 30,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  // 控制横坐标，最多显示 5 个点
                  int idx = value.toInt();
                  if (idx % ((traditionalUsage.length / 5).ceil()) != 0) {
                    return SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    space: 8.0,
                    meta: meta,
                    child: Text(
                      '批次${value.toInt()}',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                      ),
                    ),
                  );
                },
              ),
              axisNameWidget: Text(
                '加载批次',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                ),
              ),
              axisNameSize: 25,
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 1000,
                getTitlesWidget: (value, meta) {
                  return SideTitleWidget(
                    meta: meta,
                    space: 8.0,
                    child: Text(
                      '${meta.formattedValue}KB',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                      ),
                    ),
                  );
                },
                reservedSize: 40,
              ),
              axisNameWidget: Text(
                '内存使用量 (KB)',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                ),
              ),
              axisNameSize: 25,
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border.all(color: const Color(0xff37434d), width: 1),
          ),
          minX: 0,
          maxX: traditionalUsage.isNotEmpty ? traditionalUsage.length - 1.0 : 10,
          minY: 0,
          maxY: traditionalUsage.isNotEmpty
              ? traditionalUsage.map((e) => e.usage).reduce(max) * 1.2
              : 5000,
          lineBarsData: [
            // 传统缓存的线
            LineChartBarData(
              spots: traditionalUsage.map((point) {
                return FlSpot(point.time.toDouble(), point.usage);
              }).toList(),
              isCurved: true,
              color: Colors.blue,
              barWidth: 3,
              isStrokeCapRound: true,
              dotData: FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.blue.withOpacity(0.3),
              ),
            ),
            // SmartCache的线
            LineChartBarData(
              spots: smartUsage.map((point) {
                return FlSpot(point.time.toDouble(), point.usage);
              }).toList(),
              isCurved: true,
              color: Colors.green,
              barWidth: 3,
              isStrokeCapRound: true,
              dotData: FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.green.withOpacity(0.3),
              ),
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (List<LineBarSpot> touchedSpots) {
                return touchedSpots.map((spot) {
                  final String label = spot.barIndex == 0 ? '传统缓存' : 'SmartCache';
                  return LineTooltipItem(
                    '$label: ${spot.y.toStringAsFixed(1)} KB',
                    TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  );
                }).toList();
              },
            ),
            handleBuiltInTouches: true,
          ),
        ),
      ),
    );
  }
}
