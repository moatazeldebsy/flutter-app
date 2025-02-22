import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../../utils/extension/extension.dart';
import '../../../cache_image.dart';
import '../../../interactive_decorated_box.dart';
import '../../message.dart';
import '../../message_bubble.dart';
import '../../message_datetime_and_status.dart';
import 'transfer_page.dart';

class TransferMessage extends HookWidget {
  const TransferMessage({
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final assetIcon =
        useMessageConverter(converter: (state) => state.assetIcon ?? '');
    final snapshotAmount =
        useMessageConverter(converter: (state) => state.snapshotAmount);
    final assetSymbol =
        useMessageConverter(converter: (state) => state.assetSymbol ?? '');
    return MessageBubble(
      outerTimeAndStatusWidget: const MessageDatetimeAndStatus(),
      child: InteractiveDecoratedBox(
        onTap: () {
          final snapshotId = context.message.snapshotId;
          if (snapshotId == null) return;
          showTransferDialog(context, snapshotId);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipOval(
              child: CacheImage(
                assetIcon,
                width: 40,
                height: 40,
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Builder(builder: (context) {
                        if (snapshotAmount?.isEmpty ?? true) {
                          return const SizedBox();
                        }

                        return Text(
                          snapshotAmount!.numberFormat(),
                          style: TextStyle(
                            color: context.theme.text,
                            fontSize: MessageItemWidget.secondaryFontSize,
                          ),
                        );
                      }),
                    ),
                  ],
                ),
                Text(
                  assetSymbol,
                  style: TextStyle(
                    color: context.theme.secondaryText,
                    fontSize: MessageItemWidget.tertiaryFontSize,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
