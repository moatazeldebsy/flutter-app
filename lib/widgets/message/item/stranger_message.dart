import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import '../../../enum/encrypt_category.dart';
import '../../../utils/extension/extension.dart';
import '../../../utils/uri_utils.dart';
import '../../../utils/webview.dart';
import '../../interactive_decorated_box.dart';
import '../../toast.dart';
import '../message.dart';

class StrangerMessage extends StatelessWidget {
  const StrangerMessage({
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final isBotConversation =
        useMessageConverter(converter: (state) => state.appId != null);

    return Column(
      children: [
        Text(
          isBotConversation
              ? context.l10n.botInteractInfo
              : context.l10n.strangerFromMessage,
          style: TextStyle(
            fontSize: MessageItemWidget.primaryFontSize,
            color: context.theme.text,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _StrangerButton(
              isBotConversation
                  ? context.l10n.botInteractOpen
                  : context.l10n.block,
              onTap: () async {
                final message = context.message;
                if (isBotConversation) {
                  final app =
                      await context.database.appDao.findAppById(message.appId!);
                  if (app == null) return;
                  if (kIsSupportWebView) {
                    await openBotWebViewWindow(context, app,
                        conversationId: message.conversationId);
                  } else {
                    await openUri(context, app.homeUri);
                  }
                } else {
                  await runFutureWithToast(
                    context,
                    context.accountServer.blockUser(message.userId),
                  );
                }
              },
            ),
            const SizedBox(width: 16),
            _StrangerButton(
              isBotConversation
                  ? context.l10n.botInteractHi
                  : context.l10n.addContact,
              onTap: () {
                final message = context.message;
                if (isBotConversation) {
                  context.accountServer.sendTextMessage(
                      'Hi', EncryptCategory.plain,
                      conversationId: message.conversationId);
                } else {
                  context.accountServer
                      .addUser(message.userId, message.userFullName);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _StrangerButton extends StatelessWidget {
  const _StrangerButton(
    this.text, {
    Key? key,
    this.onTap,
  }) : super(key: key);

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InteractiveDecoratedBox.color(
        onTap: onTap,
        decoration: BoxDecoration(
          color: context.theme.primary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 162,
            minHeight: 36,
            maxHeight: 36,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            child: Center(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: MessageItemWidget.primaryFontSize,
                  color: context.theme.accent,
                ),
              ),
            ),
          ),
        ),
      );
}
