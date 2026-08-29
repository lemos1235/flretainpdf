import 'dart:async';

import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/settings/app_settings.dart';
import 'package:flretainpdf/settings/settings_page.dart';
import 'package:flretainpdf/settings/task_concurrency.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `/api/config` 只答一个并发上限，其余字段缺省。
ApiClient _api({int? maxConcurrentTasks}) {
  // apiToken 平时由 BackendService 在 spawn 时设，这里没有子进程，自己填一个。
  return ApiClient(
    client: MockClient((request) async {
      final body = maxConcurrentTasks == null
          ? '{}'
          : '{"max_concurrent_tasks": $maxConcurrentTasks}';
      return http.Response(
        body,
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  )..apiToken = 'test-token';
}

void main() {
  test('没存过并发上限时取默认值，越界的值被夹回区间', () async {
    SharedPreferences.setMockInitialValues({});
    final empty = await SharedPreferences.getInstance();
    expect(readMaxConcurrentTasks(empty), kDefaultMaxConcurrentTasks);
    // prefs 还没就绪（服务比设置先启动）也要给得出一个值。
    expect(readMaxConcurrentTasks(null), kDefaultMaxConcurrentTasks);

    SharedPreferences.setMockInitialValues({kMaxConcurrentTasksKey: 999});
    expect(
      readMaxConcurrentTasks(await SharedPreferences.getInstance()),
      kMaxMaxConcurrentTasks,
    );

    SharedPreferences.setMockInitialValues({kMaxConcurrentTasksKey: 0});
    expect(
      readMaxConcurrentTasks(await SharedPreferences.getInstance()),
      kMinMaxConcurrentTasks,
    );
  });

  test('改并发上限会存下来，下次启动读得回来', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings();
    addTearDown(settings.dispose);
    await settings.load(_api());

    settings.maxConcurrentTasks = 6;
    expect(settings.maxConcurrentTasks, 6);
    expect(readMaxConcurrentTasks(await SharedPreferences.getInstance()), 6);

    // 超出区间的值不写进去，存的还是上一个合法值。
    settings.maxConcurrentTasks = kMaxMaxConcurrentTasks + 5;
    expect(settings.maxConcurrentTasks, kMaxMaxConcurrentTasks);
  });

  test('本地值和服务进程当前用的不一致时提示重启', () async {
    SharedPreferences.setMockInitialValues({kMaxConcurrentTasksKey: 5});
    final settings = AppSettings();
    addTearDown(settings.dispose);

    // 服务是按 5 起来的，一致，不该提示。
    await settings.load(_api(maxConcurrentTasks: 5));
    expect(settings.activeMaxConcurrentTasks, 5);
    expect(settings.maxConcurrentTasksNeedsRestart, isFalse);

    settings.maxConcurrentTasks = 2;
    expect(settings.maxConcurrentTasksNeedsRestart, isTrue);
  });

  test('服务没报并发上限时不提示重启', () async {
    SharedPreferences.setMockInitialValues({kMaxConcurrentTasksKey: 5});
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await settings.load(_api());
    expect(settings.activeMaxConcurrentTasks, 0);
    expect(settings.maxConcurrentTasksNeedsRestart, isFalse);
  });

  testWidgets('设置页的步进器能改并发上限，并提示要重启', (tester) async {
    SharedPreferences.setMockInitialValues({kMaxConcurrentTasksKey: 3});
    final settings = AppSettings();
    addTearDown(settings.dispose);
    await settings.load(_api(maxConcurrentTasks: 3));

    // 设置页比默认的 800×600 测试画布高，整卡片放不下就点不到步进器。
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: AppSettingsScope(
          settings: settings,
          child: ListenableBuilder(
            listenable: settings,
            builder: (context, _) => const Scaffold(body: SettingsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('任务并发'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('重启应用后生效'), findsNothing);

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();

    expect(settings.maxConcurrentTasks, 4);
    expect(find.text('4'), findsOneWidget);
    // 服务进程还按 3 跑着，得提示一句。
    expect(find.textContaining('重启应用后生效'), findsOneWidget);
  });

  test('load 还在等 /api/config 时改的并发上限不会被冲掉', () async {
    SharedPreferences.setMockInitialValues({kMaxConcurrentTasksKey: 3});
    // 卡住 fetchConfig，把「服务已就绪、配置还没回来」这个窗口撑开。
    final gate = Completer<void>();
    final api = ApiClient(
      client: MockClient((request) async {
        await gate.future;
        return http.Response(
          '{"max_concurrent_tasks": 3}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    )..apiToken = 'test-token';

    final settings = AppSettings();
    addTearDown(settings.dispose);
    final loading = settings.load(api);
    await pumpEventQueue(); // 让 load 跑到 fetchConfig 上挂住。

    // 用户这时进设置页把并发调到 8。
    settings.maxConcurrentTasks = 8;

    gate.complete();
    await loading;

    expect(settings.maxConcurrentTasks, 8, reason: '不该被 load 的后半段刷回 3');
    expect(
      readMaxConcurrentTasks(await SharedPreferences.getInstance()),
      8,
      reason: '这次修改也得真的落盘',
    );
  });
}
