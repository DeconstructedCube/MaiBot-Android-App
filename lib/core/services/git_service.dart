import 'dart:io';

import 'package:flutter/services.dart';

import '../constants/scripts.dart' as scripts;
import 'proot_runner.dart';

export 'proot_runner.dart' show ProotExecResult;

class GitService {
  static const String maiBotPath = '/root/MaiBot';
  static const String _gitOpsBin = '/usr/local/bin/maibot-git-ops';

  /// 检查 MaiBot 是否已克隆且具有 .git 目录
  static bool isMaiBotGitRepo() {
    final gitDir = Directory('${scripts.ubuntuPath}/root/MaiBot/.git');
    return gitDir.existsSync();
  }

  /// 确保外置的 git_ops.sh 脚本已部署到容器内 /usr/local/bin/maibot-git-ops
  static Future<void> _ensureGitOpsScriptDeployed() async {
    final hostScriptFile = File('${scripts.ubuntuPath}$_gitOpsBin');
    if (await hostScriptFile.exists()) return;
    try {
      final content = await rootBundle.loadString('assets/scripts/git_ops.sh');
      await hostScriptFile.parent.create(recursive: true);
      await hostScriptFile.writeAsString(content);
    } catch (_) {}
  }

  /// 在 PRoot 环境中执行命令并获取完整执行输出与日志
  static Future<ProotExecResult> runInProot(
    String command, {
    Function(String)? onLog,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    return await ProotRunner.runCommand(
      command,
      onLog: onLog,
      timeout: timeout,
      workingDir: maiBotPath,
    );
  }

  /// 获取当前检出的分支名或 Tag 标识
  static Future<String> getCurrentRef() async {
    if (!isMaiBotGitRepo()) return '未安装';
    await _ensureGitOpsScriptDeployed();

    final res = await runInProot(
      'bash $_gitOpsBin current_ref',
      timeout: const Duration(seconds: 10),
    );

    final ref = res.output.trim().split('\n').last.trim();
    return ref.isNotEmpty ? ref : '未知分支';
  }

  /// 动态拉取并获取所有远程分支列表（操作前全面 fetch）
  static Future<List<String>> getAvailableBranches({Function(String)? onLog}) async {
    if (!isMaiBotGitRepo()) return [];
    await _ensureGitOpsScriptDeployed();

    onLog?.call('正在从远端同步最新分支与引用信息 (git fetch)...\n');
    await runInProot(
      'bash $_gitOpsBin fetch_branches',
      onLog: onLog,
      timeout: const Duration(seconds: 40),
    );

    final res = await runInProot(
      'git branch -r --no-color',
      timeout: const Duration(seconds: 10),
    );

    final branches = <String>{};
    for (final line in res.output.split('\n')) {
      var trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.contains('->') || trimmed.contains('HEAD')) {
        continue;
      }
      if (trimmed.contains('/')) {
        trimmed = trimmed.substring(trimmed.indexOf('/') + 1);
      }
      if (trimmed.isNotEmpty) {
        branches.add(trimmed);
      }
    }

    final localRes = await runInProot(
      'git branch --format="%(refname:short)"',
      timeout: const Duration(seconds: 10),
    );
    for (final line in localRes.output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        branches.add(trimmed);
      }
    }

    final sorted = branches.toList()..sort();
    return sorted;
  }

  /// 动态获取所有 Release Tags 列表（操作前全面 fetch --tags）
  static Future<List<String>> getReleaseTags({Function(String)? onLog}) async {
    if (!isMaiBotGitRepo()) return [];
    await _ensureGitOpsScriptDeployed();

    onLog?.call('正在从远端同步 Release Tags (git fetch --tags)...\n');
    await runInProot(
      'bash $_gitOpsBin fetch_tags',
      onLog: onLog,
      timeout: const Duration(seconds: 40),
    );

    final res = await runInProot(
      'git tag -l --sort=-v:refname',
      timeout: const Duration(seconds: 10),
    );

    final tags = <String>[];
    for (final line in res.output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        tags.add(trimmed);
      }
    }

    return tags;
  }

  /// 执行 git pull 更新 MaiBot（前置全面 fetch 并自动同步依赖）
  static Future<ProotExecResult> pullMaiBot({Function(String)? onLog}) async {
    if (!isMaiBotGitRepo()) {
      return const ProotExecResult(
        success: false,
        exitCode: -1,
        stdout: '',
        stderr: 'MaiBot 目录不存在或不是有效的 Git 仓库',
        output: 'MaiBot 目录不存在或不是有效的 Git 仓库',
      );
    }
    await _ensureGitOpsScriptDeployed();

    onLog?.call('1. 正在同步远程引用与代码 (git fetch & pull)...\n');
    return await runInProot(
      'bash $_gitOpsBin pull',
      onLog: onLog,
      timeout: const Duration(minutes: 5),
    );
  }

  /// 切换分支（前置精准 fetch 目标分支、稳健检出与同步依赖）
  static Future<ProotExecResult> switchBranch(
    String branchName, {
    Function(String)? onLog,
  }) async {
    if (!isMaiBotGitRepo()) {
      return const ProotExecResult(
        success: false,
        exitCode: -1,
        stdout: '',
        stderr: 'MaiBot 仓库不存在',
        output: 'MaiBot 仓库不存在',
      );
    }
    await _ensureGitOpsScriptDeployed();

    onLog?.call('1. 正在从远端精准抓取分支: $branchName (git fetch)...\n');
    return await runInProot(
      'bash $_gitOpsBin switch_branch "$branchName"',
      onLog: onLog,
      timeout: const Duration(minutes: 5),
    );
  }

  /// 切换至指定 Release Tag（前置 fetch tags 并同步依赖）
  static Future<ProotExecResult> switchReleaseTag(
    String tagName, {
    Function(String)? onLog,
  }) async {
    if (!isMaiBotGitRepo()) {
      return const ProotExecResult(
        success: false,
        exitCode: -1,
        stdout: '',
        stderr: 'MaiBot 仓库不存在',
        output: 'MaiBot 仓库不存在',
      );
    }
    await _ensureGitOpsScriptDeployed();

    onLog?.call('1. 正在从远端拉取 Release Tag: $tagName (git fetch --tags)...\n');
    return await runInProot(
      'bash $_gitOpsBin switch_tag "$tagName"',
      onLog: onLog,
      timeout: const Duration(minutes: 5),
    );
  }
}
