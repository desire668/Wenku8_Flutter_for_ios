import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'library_state.dart';

/// Separate from the legacy API/JNI contract. Only explicit user file actions
/// open the Android picker; the normal reader does not alter system settings.
abstract final class LocalPlatform {
  static const channel = MethodChannel('org.mewx.wenku8/local_tools');
  static bool get android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get keepScreenChannelReady =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  static Future<bool> exportBackup(String text, String name) async =>
      await channel.invokeMethod<bool>('exportBackup', {
        'text': text,
        'name': name,
      }) ??
      false;
  static Future<String?> importBackup() =>
      channel.invokeMethod<String>('importBackup');
  static Future<Map<Object?, Object?>?> importLegacyData() =>
      channel.invokeMapMethod<Object?, Object?>('importLegacyData');
  static Future<void> shareText(String text) =>
      channel.invokeMethod<void>('shareText', {'text': text});
  static final Set<Object> _awakeOwners = {};
  static bool _requestedAwake = false;

  static void keepScreen(Object owner, bool enabled) {
    if (enabled && keepScreenChannelReady) {
      _awakeOwners.add(owner);
    } else {
      _awakeOwners.remove(owner);
    }
    final awake = _awakeOwners.isNotEmpty;
    if (awake == _requestedAwake) return;
    _requestedAwake = awake;
    // No polling, permanent ticker, global timeout change or wake lock.
    channel.invokeMethod<void>('keepScreenOn', awake).catchError((Object _) {});
  }
}

/// Route/lifecycle notifications rebuild only this zero-size binding, not the
/// reader's article. Covering/leaving the page or backgrounding releases it.
class ReaderScreenBinding extends StatefulWidget {
  const ReaderScreenBinding({super.key, required this.state});
  final LibraryState state;
  @override
  State<ReaderScreenBinding> createState() => _ReaderScreenBindingState();
}

class _ReaderScreenBindingState extends State<ReaderScreenBinding>
    with WidgetsBindingObserver {
  bool _foreground = true;
  bool _current = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.readerBehaviorChanges.addListener(_update);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  void _update() => LocalPlatform.keepScreen(
    this,
    mounted && _foreground && _current && widget.state.keepScreenOn,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _current = ModalRoute.isCurrentOf(context) ?? true;
    _update();
  }

  @override
  void didUpdateWidget(ReaderScreenBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.readerBehaviorChanges.removeListener(_update);
      widget.state.readerBehaviorChanges.addListener(_update);
      _update();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  @override
  void dispose() {
    widget.state.readerBehaviorChanges.removeListener(_update);
    WidgetsBinding.instance.removeObserver(this);
    LocalPlatform.keepScreen(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
