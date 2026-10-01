import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../widgets/common.dart';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayLabel(DateTime local) {
  final now = DateTime.now();
  if (_sameDay(local, now)) return 'Today';
  if (_sameDay(local, now.subtract(const Duration(days: 1)))) return 'Yesterday';
  return fmtDate(local);
}

/// Reversed list (newest at the bottom, anchored there) with day separators
/// and sender names at the start of each run of messages.
class ChatMessageList extends StatelessWidget {
  const ChatMessageList({
    super.key,
    required this.controller,
    required this.messages,
    required this.myId,
    required this.loadingOlder,
    required this.hasMore,
  });

  final ScrollController controller;
  final List<ChatMessage> messages; // oldest first
  final int? myId;
  final bool loadingOlder;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    final n = messages.length;
    return ListView.builder(
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: n + 1,
      itemBuilder: (context, i) {
        if (i == n) return _HistoryEdge(loading: loadingOlder, hasMore: hasMore);
        final index = n - 1 - i;
        final m = messages[index];
        final prev = index > 0 ? messages[index - 1] : null;
        final local = m.createdAt.toLocal();
        final newDay = prev == null || !_sameDay(prev.createdAt.toLocal(), local);
        final newRun = newDay || prev.sender.id != m.sender.id;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay) _DaySeparator(_dayLabel(local)),
            ChatBubble(message: m, mine: m.sender.id == myId, showSender: newRun),
          ],
        );
      },
    );
  }
}

class _HistoryEdge extends StatelessWidget {
  const _HistoryEdge({required this.loading, required this.hasMore});
  final bool loading;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    if (loading || hasMore) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text('Start of the conversation',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted)),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message, required this.mine, required this.showSender});
  final ChatMessage message;
  final bool mine;
  final bool showSender;

  static final _time = DateFormat('HH:mm');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final bg = mine ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    const r = Radius.circular(16);

    return Padding(
      padding: EdgeInsets.only(top: showSender ? 8 : 2),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showSender && !mine)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 2),
              child: Text(message.sender.username,
                  style: t.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.only(
                  topLeft: r,
                  topRight: r,
                  bottomLeft: mine ? r : const Radius.circular(4),
                  bottomRight: mine ? const Radius.circular(4) : r,
                ),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                SelectableText(message.body, style: t.bodyMedium?.copyWith(color: fg)),
                const SizedBox(height: 2),
                Text(_time.format(message.createdAt.toLocal()),
                    style: t.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7), fontSize: 10)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Text field + send button pinned under the message list.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.sending,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).cardTheme.color ?? scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  hintText: 'Message',
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final canSend = enabled && !sending && value.text.trim().isNotEmpty;
                return IconButton.filled(
                  tooltip: 'Send',
                  onPressed: canSend ? onSend : null,
                  icon: sending
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send),
                );
              },
            ),
          ]),
        ),
      ),
    );
  }
}
