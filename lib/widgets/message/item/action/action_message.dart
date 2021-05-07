import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import '../../../../db/mixin_database.dart';
import '../../../../utils/action_utils.dart';
import '../../../../utils/color_utils.dart';
import '../../../../utils/uri_utils.dart';
import '../../../brightness_observer.dart';
import '../../../interacter_decorated_box.dart';
import '../../message_bubble.dart';
import 'action_data.dart';

class ActionMessage extends StatelessWidget {
  const ActionMessage({
    Key? key,
    required this.message,
    required this.isCurrentUser,
  }) : super(key: key);

  final MessageItem message;
  final bool isCurrentUser;

  @override
  Widget build(BuildContext context) => MessageBubble(
        isCurrentUser: isCurrentUser,
        showBubble: false,
        padding: EdgeInsets.zero,
        child: Wrap(
          spacing: 10,
          runSpacing: 8,
          children: List<Widget>.from(
            // ignore: avoid_dynamic_calls
            jsonDecode(message.content!).map((e) => ActionData.fromJson(e)).map(
                  (e) => InteractableDecoratedBox.color(
                    onTap: () {
                      // ignore: avoid_dynamic_calls
                      if (context.openAction(e.action)) return;
                      // ignore: avoid_dynamic_calls
                      openUri(e.action);
                    },
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: BrightnessData.themeOf(context).primary,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        // ignore: avoid_dynamic_calls
                        e.label,
                        style: TextStyle(
                          fontSize: 15,
                          // ignore: avoid_dynamic_calls
                          color: colorHex(e.color) ?? Colors.black,
                        ),
                      ),
                    ),
                  ),
                ),
          ),
        ),
      );
}
