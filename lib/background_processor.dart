import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart';

// --- 数据结构定义 ---

// 发送给 Worker Isolate 的消息结构
class _WorkerTask {
  final int id; // 任务唯一 ID
  final Function function; // 要执行的函数 (必须是顶层或静态)
  final dynamic payload; // 函数参数

  _WorkerTask(this.id, this.function, this.payload);
}

// 从 Worker Isolate 返回的消息结构
class _WorkerResult {
  final int id; // 对应的任务 ID
  final dynamic result; // 任务执行结果或错误
  final bool isError; // 标记结果是否为错误

  _WorkerResult(this.id, this.result, {this.isError = false});
}

// 任务包装，包含 Completer 用于返回 Future
class _Task<R> {
  final int id;
  final Completer<R> completer;
  final _WorkerTask taskData;

  _Task(this.id, this.completer, this.taskData);
}

// --- 后台处理器 ---

class BackgroundProcessor {
  final int poolSize;
  late final List<_WorkerController> _workers;
  late final ReceivePort _resultPort;
  late final StreamSubscription _resultSubscription;
  final Map<int, _Task> _pendingTasks = {}; // 等待结果的任务
  final List<_Task> _taskQueue = []; // 等待执行的任务队列
  final List<_WorkerController> _idleWorkers = []; // 空闲的 Worker 列表

  int _taskIdCounter = 0;
  bool _isDisposed = false;
  Completer<void>? _initCompleter; // 用于等待所有 worker 初始化完成

  /// 创建一个后台处理器
  /// [poolSize] 指定后台 Isolate 的数量
  BackgroundProcessor({this.poolSize = 1}) {
    if (poolSize <= 0) {
      throw ArgumentError('poolSize must be positive');
    }
    _workers = List.generate(poolSize, (_) => _WorkerController());
    _initCompleter = Completer<void>();
    _initialize();
  }

  /// 等待所有 Worker Isolate 初始化完成
  Future<void> get ready => _initCompleter?.future ?? Future.value();

  Future<void> _initialize() async {
    _resultPort = ReceivePort();
    _resultSubscription = _resultPort.listen(_handleResultMessage);

    int workersReady = 0;
    final initPorts = <ReceivePort>[];

    for (final worker in _workers) {
      final initPort = ReceivePort();
      initPorts.add(initPort);

      try {
        // 传递：用于 Worker 发回其 SendPort 的端口，以及主 Isolate 接收结果的端口
        worker.isolate = await Isolate.spawn(
          _workerEntryPoint,
          [initPort.sendPort, _resultPort.sendPort],
          errorsAreFatal: true, // 让严重错误能冒泡
          debugName: 'Worker-${_workers.indexOf(worker)}',
        );

        // 等待 Worker 发回它的 SendPort
        initPort.listen((message) {
          if (message is SendPort) {
            worker.sendPort = message;
            worker.isInitialized = true;
            _idleWorkers.add(worker); // 初始化完成，加入空闲列表
            workersReady++;
            debugPrint('Worker ${_workers.indexOf(worker)} initialized.');
            if (workersReady == poolSize) {
              _initCompleter?.complete();
              _initCompleter = null; // 完成后置空
              for (var p in initPorts) {
                p.close();
              } // 关闭所有初始化端口
              debugPrint('BackgroundProcessor initialized with $poolSize workers.');
              _tryDispatch(); // 尝试处理队列中可能已有的任务
            }
          }
          initPort.close(); // 收到消息后即可关闭
        });
      } catch (e, s) {
        debugPrint('Failed to spawn worker: $e\n$s');
        worker.isInitialized = false; // 标记为失败
        workersReady++; // 也要计数，避免死锁
        if (workersReady == poolSize) {
          if (!_initCompleter!.isCompleted) _initCompleter!.completeError(e, s);
          _initCompleter = null;
          for (var p in initPorts) {
            p.close();
          }
        }
        initPort.close();
      }
    }
  }

  /// 处理从 Worker Isolate 返回的结果
  void _handleResultMessage(dynamic message) {
    if (_isDisposed) return;

    if (message is _WorkerResult) {
      final task = _pendingTasks.remove(message.id);
      if (task != null) {
        final worker = _workers.firstWhere((w) => w.currentTaskId == message.id, orElse: () => _WorkerController()); // 找到执行此任务的 worker
        worker.currentTaskId = null; // 标记任务完成
        _idleWorkers.add(worker);

        if (message.isError) {
          task.completer.completeError(message.result);
        } else {
          try{
            task.completer.complete(message.result);
          } catch (e,s){
            debugPrint('Error completing task: $e\n$s');
            task.completer.completeError(e,s); // Handle type cast errors
          }
        }
        _tryDispatch(); // 尝试执行队列中的下一个任务
      }
    } else {
      debugPrint('BackgroundProcessor received unexpected message: $message');
    }
  }

  /// 尝试从队列中分发任务给空闲 Worker
  void _tryDispatch() {
    if (_isDisposed || _taskQueue.isEmpty || _idleWorkers.isEmpty) {
      return;
    }

    while (_taskQueue.isNotEmpty && _idleWorkers.isNotEmpty) {
      final worker = _idleWorkers.removeAt(0); // 取出一个空闲 worker
      final task = _taskQueue.removeAt(0); // 取出等待队列的第一个任务

      if (worker.sendPort != null) {
        worker.currentTaskId = task.id; // 标记 worker 正在处理此任务
        _pendingTasks[task.id] = task; // 加入等待结果的 map
        try {
          worker.sendPort!.send(task.taskData);
        } catch (e, s) {
          // 发送失败，任务无法执行
          task.completer.completeError(e, s);
          worker.currentTaskId = null; // 重置 worker 状态
          _idleWorkers.add(worker); // 放回空闲列表
        }
      } else {
        // Worker 的 SendPort 无效，可能初始化失败或已关闭
        debugPrint("Worker sendPort is null, cannot dispatch task ${task.id}");
        // 将任务放回队列前端，尝试交给下一个 worker
        _taskQueue.insert(0, task);
        // 这个 worker 可能有问题，暂时不放回 idle 列表 (或者可以实现更复杂的错误处理/替换逻辑)
      }
    }
  }

  /// 在后台 Isolate 中执行一个函数
  /// [function] 必须是顶层函数或静态方法
  /// [payload] 是传递给函数的参数
  Future<R> execute<Q, R>(Function(Q) function, Q payload) {
    if (_isDisposed) {
      return Future.error(StateError('BackgroundProcessor is disposed'));
    }
    if (_initCompleter != null) {
      // 如果还没初始化完成，先等待
      return _initCompleter!.future.then((_) => execute(function, payload));
    }

    final taskId = _taskIdCounter++;
    final completer = Completer<R>();
    final taskData = _WorkerTask(taskId, function, payload);
    final task = _Task<R>(taskId, completer, taskData);

    _taskQueue.add(task); // 加入任务队列
    _tryDispatch(); // 尝试立即分发

    return completer.future;
  }

  /// 关闭所有后台 Isolate 并释放资源
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    debugPrint('Disposing BackgroundProcessor...');

    _initCompleter = null; // 取消等待初始化

    // 清空任务队列，拒绝新任务 (可以选择性地完成错误)
    for (final task in _taskQueue) {
      task.completer.completeError(StateError('Processor disposed before task execution'));
    }
    _taskQueue.clear();

    // 给所有 worker 发送关闭信号 (null 作为信号)
    for (final worker in _workers) {
      if (worker.sendPort != null && worker.isInitialized) {
        try {
          worker.sendPort!.send(null); // null 作为关闭信号
        } catch (e) {
          debugPrint("Error sending dispose signal to worker: $e");
        }
      }
      // 立即杀死可能卡住的 isolate (可选，看是否需要强制)
      // worker.isolate?.kill(priority: Isolate.immediate);
    }

    // 等待一小段时间让 isolate 处理关闭信号 (可选)
    // await Future.delayed(Duration(milliseconds: 100));

    // 关闭主 Isolate 的接收端口和订阅
    await _resultSubscription.cancel();
    _resultPort.close();


    // 最终清理
    _pendingTasks.forEach((id, task) {
      if (!task.completer.isCompleted) {
        task.completer.completeError(StateError('Processor disposed while task $id was pending'));
      }
    });
    _pendingTasks.clear();
    _idleWorkers.clear();
    _workers.clear(); // 清理 worker 控制器列表

    debugPrint('BackgroundProcessor disposed.');
  }

  // --- Worker Isolate 入口点 ---
  static void _workerEntryPoint(List<dynamic> args) async {
    final SendPort initSendPort = args[0]; // 用于发回自身 SendPort
    final SendPort resultSendPort = args[1]; // 用于发回结果
    final ReceivePort taskReceivePort = ReceivePort(); // 用于接收任务

    // 1. 将自己的 SendPort 发回给主 Isolate
    initSendPort.send(taskReceivePort.sendPort);

    // 2. 监听来自主 Isolate 的任务
    await for (final message in taskReceivePort) {
      if (message == null) { // null 是关闭信号
        debugPrint('Worker received dispose signal. Shutting down.');
        taskReceivePort.close(); // 关闭端口，退出循环
        break;
      }

      if (message is _WorkerTask) {
        dynamic taskResult;
        bool isError = false;
        try {
          // 执行实际的任务函数
          taskResult = await message.function(message.payload); // 支持 async 函数
        } catch (e, s) {
          taskResult = '$e\n$s'; // 或者更结构化的错误对象
          isError = true;
        }
        // 将结果（或错误）连同 ID 发回主 Isolate
        resultSendPort.send(_WorkerResult(message.id, taskResult, isError: isError));
      } else {
        debugPrint("Worker received unexpected message: $message");
      }
    }
    Isolate.current.kill(); // 确保 Isolate 退出
    debugPrint('Worker isolate finished.');
  }
}

// 辅助类，用于管理单个 Worker Isolate 的状态
class _WorkerController {
  Isolate? isolate;
  SendPort? sendPort;
  bool isInitialized = false;
  int? currentTaskId; // 正在处理的任务 ID，null 表示空闲

  bool get isIdle => isInitialized && currentTaskId == null;
}