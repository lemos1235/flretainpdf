import 'package:flutter/material.dart';

import 'api/api_client.dart';
import 'home/home_page.dart';
import 'settings/settings_page.dart';
import 'widgets/menu_bar.dart';

/// 应用外壳：左侧窄导航栏 + 右侧页面。
///
/// 页面之间切换不重建，所以主页的任务轮询和表单里填了一半的内容都不会丢。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.api});

  final ApiClient api;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppSection _section = AppSection.home;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppMenuBar(
            current: _section,
            onSelect: (section) => setState(() => _section = section),
          ),
          Expanded(
            child: IndexedStack(
              index: _section.index,
              sizing: StackFit.expand,
              children: [HomePage(api: widget.api), const SettingsPage()],
            ),
          ),
        ],
      ),
    );
  }
}
