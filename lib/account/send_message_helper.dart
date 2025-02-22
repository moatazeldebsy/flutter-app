import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:cross_file/cross_file.dart';
import 'package:drift/drift.dart';
import 'package:extended_image/extended_image.dart';
import 'package:image/image.dart';
import 'package:mime/mime.dart';
import 'package:mixin_bot_sdk_dart/mixin_bot_sdk_dart.dart';
import 'package:uuid/uuid.dart';

import '../blaze/vo/pin_message_minimal.dart';
import '../blaze/vo/pin_message_payload.dart';
import '../blaze/vo/recall_message.dart';
import '../blaze/vo/transcript_minimal.dart';
import '../constants/constants.dart';
import '../db/dao/job_dao.dart';
import '../db/dao/message_dao.dart';
import '../db/dao/message_mention_dao.dart';
import '../db/dao/participant_dao.dart';
import '../db/dao/pin_message_dao.dart';
import '../db/dao/transcript_message_dao.dart';
import '../db/dao/user_dao.dart';
import '../db/database.dart';
import '../db/mixin_database.dart';
import '../enum/encrypt_category.dart';
import '../enum/media_status.dart';
import '../enum/message_category.dart';
import '../utils/attachment/attachment_util.dart';
import '../utils/extension/extension.dart';
import '../utils/load_balancer_utils.dart';
import '../utils/logger.dart';
import '../utils/reg_exp_utils.dart';
import 'show_pin_message_key_value.dart';

const _kEnableImageBlurHashThumb = true;

class SendMessageHelper {
  SendMessageHelper(
    this._database,
    this._attachmentUtil,
  );

  final Database _database;
  late final MessageDao _messageDao = _database.messageDao;
  late final MessageMentionDao _messageMentionDao = _database.messageMentionDao;
  late final ParticipantDao _participantDao = _database.participantDao;
  late final JobDao _jobDao = _database.jobDao;
  late final PinMessageDao _pinMessageDao = _database.pinMessageDao;
  late final UserDao _userDao = _database.userDao;
  late final TranscriptMessageDao _transcriptMessageDao =
      _database.transcriptMessageDao;
  final AttachmentUtil _attachmentUtil;

  Future<void> sendTextMessage(
    String conversationId,
    String senderId,
    EncryptCategory encryptCategory,
    String content, {
    String? quoteMessageId,
    bool silent = false,
  }) async {
    var category = encryptCategory.toCategory(MessageCategory.plainText,
        MessageCategory.signalText, MessageCategory.encryptedText);
    final quoteMessage =
        await _messageDao.findMessageItemByMessageId(quoteMessageId);

    String? recipientId;
    final botNumber = botNumberStartRegExp.firstMatch(content)?[0];
    if (botNumber?.isNotEmpty == true) {
      recipientId = await _participantDao
          .userIdByIdentityNumber(conversationId, botNumber!)
          .getSingleOrNull();
      category = recipientId != null ? MessageCategory.plainText : category;
    }

    final message = Message(
      messageId: const Uuid().v4(),
      conversationId: conversationId,
      userId: senderId,
      category: category,
      content: content,
      status: MessageStatus.sending,
      quoteMessageId: quoteMessageId,
      quoteContent: quoteMessage?.toJson(),
      createdAt: DateTime.now(),
    );

    await _messageDao.insert(message, senderId);
    await _jobDao.insertSendingJob(
      message.messageId,
      conversationId,
      recipientId: recipientId,
      silent: silent,
    );
  }

  Future<void> sendImageMessage({
    required String conversationId,
    required String senderId,
    XFile? file,
    Uint8List? bytes,
    required String category,
    String? quoteMessageId,
    AttachmentResult? attachmentResult,
  }) async {
    final messageId = const Uuid().v4();
    final mimeType =
        file?.mimeType ?? lookupMimeType(file?.path ?? '') ?? 'image/jpeg';

    var attachment = _attachmentUtil.getAttachmentFile(
      category,
      conversationId,
      messageId,
      file?.name,
      mimeType: mimeType,
    );

    final _bytes = bytes ?? await file!.readAsBytes();

    // Only retrieve image bounds info.
    final buffer = await ui.ImmutableBuffer.fromUint8List(_bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);

    final imageWidth = descriptor.width;
    final imageHeight = descriptor.height;

    attachment = await attachment.create(recursive: true);

    await attachment.writeAsBytes(_bytes.toList());

    final attachmentSize = await attachment.length();
    final quoteMessage =
        await _messageDao.findMessageItemByMessageId(quoteMessageId);
    final fileName = file?.name ?? '$messageId.png';
    final message = Message(
      messageId: messageId,
      conversationId: conversationId,
      userId: senderId,
      content: '',
      category: category,
      mediaUrl: attachment.pathBasename,
      mediaMimeType: mimeType,
      mediaSize: await attachment.length(),
      mediaWidth: imageWidth,
      mediaHeight: imageHeight,
      name: fileName,
      mediaStatus: MediaStatus.pending,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
      quoteMessageId: quoteMessageId,
      quoteContent: quoteMessage?.toJson(),
    );
    await _messageDao.insert(message, senderId);

    String? thumbImage;
    final stopwatch = Stopwatch()..start();

    final image = await _getSmallImage(attachment.path);

    stopwatch.stop();
    d('_getSmallImage duration: ${stopwatch.elapsedMilliseconds}');
    stopwatch.start();

    thumbImage = await runLoadBalancer(
      _getImageThumbnailString,
      image,
    );
    stopwatch.stop();
    d('thumbImage: $thumbImage');
    d('_getImageThumbnailString duration: ${stopwatch.elapsedMilliseconds}, _kEnableImageBlurHashThumb: $_kEnableImageBlurHashThumb');

    if (await _attachmentUtil.isNotPending(messageId)) return;

    attachmentResult ??=
        await _attachmentUtil.uploadAttachment(attachment, messageId, category);
    if (attachmentResult == null) return;
    final attachmentMessage = AttachmentMessage(
      attachmentResult.keys,
      attachmentResult.digest,
      attachmentResult.attachmentId,
      mimeType,
      attachmentSize,
      null,
      imageWidth,
      imageHeight,
      thumbImage,
      null,
      null,
      null,
      attachmentResult.createdAt,
    );

    final encoded = await jsonBase64EncodeWithIsolate(attachmentMessage);
    await _messageDao.updateAttachmentMessageContentAndStatus(
        messageId, encoded);
    await _jobDao.insertSendingJob(messageId, conversationId);
  }

  Future<void> sendVideoMessage(
    String conversationId,
    String senderId,
    XFile file,
    String category,
    String? quoteMessageId, {
    AttachmentResult? attachmentResult,
    int? mediaWidth,
    int? mediaHeight,
    String? thumbImage,
    String? mediaDuration,
  }) async {
    final messageId = const Uuid().v4();
    final mimeType = file.mimeType ?? lookupMimeType(file.path) ?? 'video/mp4';
    final attachment = _attachmentUtil.getAttachmentFile(
      category,
      conversationId,
      messageId,
      file.name,
      mimeType: mimeType,
    );
    await attachment.create(recursive: true);
    await File(file.path).copy(attachment.path);
    final attachmentSize = await attachment.length();
    final quoteMessage =
        await _messageDao.findMessageItemByMessageId(quoteMessageId);
    final message = Message(
      messageId: messageId,
      conversationId: conversationId,
      userId: senderId,
      content: '',
      category: category,
      mediaUrl: attachment.pathBasename,
      mediaMimeType: mimeType,
      mediaSize: await attachment.length(),
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
      thumbImage: thumbImage,
      mediaDuration: mediaDuration,
      name: file.name,
      mediaStatus: MediaStatus.pending,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
      quoteMessageId: quoteMessageId,
      quoteContent: quoteMessage?.toJson(),
    );
    await _messageDao.insert(message, senderId);
    // ignore: parameter_assignments
    attachmentResult ??=
        await _attachmentUtil.uploadAttachment(attachment, messageId, category);
    if (attachmentResult == null) return;
    final attachmentMessage = AttachmentMessage(
      attachmentResult.keys,
      attachmentResult.digest,
      attachmentResult.attachmentId,
      mimeType,
      attachmentSize,
      file.name,
      mediaWidth,
      mediaHeight,
      thumbImage,
      mediaDuration == null ? null : int.tryParse(mediaDuration),
      null,
      null,
      attachmentResult.createdAt,
    );

    final encoded = await jsonBase64EncodeWithIsolate(attachmentMessage);
    await _messageDao.updateAttachmentMessageContentAndStatus(
        messageId, encoded);
    await _jobDao.insertSendingJob(messageId, conversationId);
  }

  Future<void> sendStickerMessage(String conversationId, String senderId,
      StickerMessage stickerMessage, String category) async {
    final encoded = await jsonBase64EncodeWithIsolate(stickerMessage);

    final message = Message(
      messageId: const Uuid().v4(),
      conversationId: conversationId,
      userId: senderId,
      category: category,
      content: encoded,
      stickerId: stickerMessage.stickerId,
      albumId: stickerMessage.albumId,
      name: stickerMessage.name,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
    );

    await _messageDao.insert(message, senderId);
    await _jobDao.insertSendingJob(message.messageId, conversationId);
  }

  Future<void> sendDataMessage(
    String conversationId,
    String senderId,
    XFile file,
    String category,
    String? quoteMessageId, {
    AttachmentResult? attachmentResult,
    String? name,
  }) async {
    final messageId = const Uuid().v4();
    final mimeType = file.mimeType ??
        lookupMimeType(file.path) ??
        'application/octet-stream';
    final attachment = _attachmentUtil.getAttachmentFile(
      category,
      conversationId,
      messageId,
      file.name,
      mimeType: mimeType,
    );

    await attachment.create(recursive: true);
    await File(file.path).copy(attachment.path);
    final attachmentSize = await attachment.length();
    final quoteMessage =
        await _messageDao.findMessageItemByMessageId(quoteMessageId);
    final message = Message(
      messageId: messageId,
      conversationId: conversationId,
      userId: senderId,
      content: '',
      category: category,
      mediaUrl: attachment.pathBasename,
      mediaMimeType: mimeType,
      mediaSize: await attachment.length(),
      name: name ?? file.name,
      mediaStatus: MediaStatus.pending,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
      quoteMessageId: quoteMessageId,
      quoteContent: quoteMessage?.toJson(),
    );
    await _messageDao.insert(message, senderId);
    // ignore: parameter_assignments
    attachmentResult ??=
        await _attachmentUtil.uploadAttachment(attachment, messageId, category);
    if (attachmentResult == null) return;
    final attachmentMessage = AttachmentMessage(
      attachmentResult.keys,
      attachmentResult.digest,
      attachmentResult.attachmentId,
      mimeType,
      attachmentSize,
      name ?? file.name,
      null,
      null,
      null,
      null,
      null,
      null,
      attachmentResult.createdAt,
    );

    final encoded = await jsonBase64EncodeWithIsolate(attachmentMessage);
    await _messageDao.updateAttachmentMessageContentAndStatus(
        messageId, encoded);
    await _jobDao.insertSendingJob(messageId, conversationId);
  }

  Future<void> sendContactMessage(
    String conversationId,
    String senderId,
    ContactMessage contactMessage,
    String? shareUserFullName, {
    EncryptCategory encryptCategory = EncryptCategory.plain,
    String? quoteMessageId,
  }) async {
    final category = encryptCategory.toCategory(MessageCategory.plainContact,
        MessageCategory.signalContact, MessageCategory.encryptedContact);
    final encoded = await jsonBase64EncodeWithIsolate(contactMessage);

    final quoteMessage =
        await _messageDao.findMessageItemByMessageId(quoteMessageId);
    final message = Message(
      messageId: const Uuid().v4(),
      conversationId: conversationId,
      userId: senderId,
      category: category,
      content: encoded,
      sharedUserId: contactMessage.userId,
      name: shareUserFullName,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
      quoteMessageId: quoteMessageId,
      quoteContent: quoteMessage?.toJson(),
    );
    await _messageDao.insert(message, senderId);
    await _jobDao.insertSendingJob(message.messageId, conversationId);
  }

  Future<void> sendAudioMessage(
    String conversationId,
    String senderId,
    XFile file,
    String category,
    String? quoteMessageId, {
    AttachmentResult? attachmentResult,
    String? mediaDuration,
    String? mediaWaveform,
  }) async {
    final messageId = const Uuid().v4();
    final mimeType = file.mimeType ?? lookupMimeType(file.path) ?? 'audio/ogg';
    final attachment = _attachmentUtil.getAttachmentFile(
      category,
      conversationId,
      messageId,
      file.name,
      mimeType: mimeType,
    );

    await attachment.create(recursive: true);
    await File(file.path).copy(attachment.path);
    final attachmentSize = await attachment.length();
    final quoteMessage =
        await _messageDao.findMessageItemByMessageId(quoteMessageId);
    final message = Message(
      messageId: messageId,
      conversationId: conversationId,
      userId: senderId,
      content: '',
      category: category,
      mediaUrl: attachment.pathBasename,
      mediaMimeType: mimeType,
      mediaSize: await attachment.length(),
      mediaDuration: mediaDuration,
      mediaWaveform: mediaWaveform,
      name: file.name,
      mediaStatus: MediaStatus.pending,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
      quoteMessageId: quoteMessageId,
      quoteContent: quoteMessage?.toJson(),
    );
    await _messageDao.insert(message, senderId);
    // ignore: parameter_assignments
    attachmentResult ??=
        await _attachmentUtil.uploadAttachment(attachment, messageId, category);
    if (attachmentResult == null) return;
    final attachmentMessage = AttachmentMessage(
      attachmentResult.keys,
      attachmentResult.digest,
      attachmentResult.attachmentId,
      mimeType,
      attachmentSize,
      file.name,
      null,
      null,
      null,
      int.tryParse(mediaDuration ?? ''),
      mediaWaveform,
      null,
      attachmentResult.createdAt,
    );

    final encoded = await jsonBase64EncodeWithIsolate(attachmentMessage);
    await _messageDao.updateAttachmentMessageContentAndStatus(
        messageId, encoded);
    await _jobDao.insertSendingJob(messageId, conversationId);
  }

  Future<void> _sendLiveMessage(
      String conversationId,
      String senderId,
      String content,
      String mediaUrl,
      String thumbUrl,
      int mediaWidth,
      int mediaHeight,
      EncryptCategory encryptCategory) async {
    final category = encryptCategory.toCategory(MessageCategory.plainLive,
        MessageCategory.signalLive, MessageCategory.encryptedLive);
    final message = Message(
      messageId: const Uuid().v4(),
      conversationId: conversationId,
      userId: senderId,
      category: category,
      content: content,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
      mediaUrl: mediaUrl,
      thumbUrl: thumbUrl,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
    );

    await _messageDao.insert(message, senderId);
    await _jobDao.insertSendingJob(message.messageId, conversationId);
  }

  Future<void> sendPostMessage(String conversationId, String senderId,
      String content, EncryptCategory encryptCategory) async {
    final category = encryptCategory.toCategory(MessageCategory.plainPost,
        MessageCategory.signalPost, MessageCategory.encryptedPost);
    final message = Message(
      messageId: const Uuid().v4(),
      conversationId: conversationId,
      userId: senderId,
      category: category,
      content: content,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
    );

    await _messageDao.insert(message, senderId);
    await _jobDao.insertSendingJob(message.messageId, conversationId);
  }

  Future<void> _sendLocationMessage(String conversationId, String senderId,
      String content, EncryptCategory encryptCategory) async {
    final category = encryptCategory.toCategory(MessageCategory.plainLocation,
        MessageCategory.signalLocation, MessageCategory.encryptedLocation);
    final message = Message(
      messageId: const Uuid().v4(),
      conversationId: conversationId,
      userId: senderId,
      category: category,
      content: content,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
    );

    await _messageDao.insert(message, senderId);
    await _jobDao.insertSendingJob(message.messageId, conversationId);
  }

  Future<void> _sendAppCardMessage(
      String conversationId, String senderId, String content) async {
    const category = MessageCategory.appCard;
    final message = Message(
      messageId: const Uuid().v4(),
      conversationId: conversationId,
      userId: senderId,
      category: category,
      content: content,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
    );

    await _messageDao.insert(message, senderId);
    await _jobDao.insertSendingJob(message.messageId, conversationId);
  }

  Future<void> sendRecallMessage(
      String conversationId, List<String> messageIds) async {
    messageIds.forEach((messageId) async {
      final message = await _messageDao.findMessageByMessageId(messageId);
      if (message?.category.isAttachment == true) {
        final file = File(message!.mediaUrl!);
        final exists = file.existsSync();
        if (exists) {
          await file.delete();
        }
      }

      final futures = [
        _messageDao.recallMessage(messageId),
        _messageDao.deleteFtsByMessageId(messageId),
        _messageMentionDao.deleteMessageMentionByMessageId(messageId),
        _jobDao.insert(Job(
          conversationId: conversationId,
          jobId: const Uuid().v4(),
          action: kRecallMessage,
          priority: 5,
          blazeMessage: await jsonEncodeWithIsolate(RecallMessage(messageId)),
          createdAt: DateTime.now(),
          runCount: 0,
        )),
      ];

      final quoteMessage =
          await _messageDao.findMessageItemById(conversationId, messageId);

      if (quoteMessage != null) {
        futures.add(_messageDao.updateQuoteContentByQuoteId(
            conversationId, messageId, quoteMessage.toJson()));
      }

      await Future.wait(futures);
    });
  }

  Future<void> forwardMessage(
      String conversationId, String senderId, String forwardMessageId,
      {EncryptCategory encryptCategory = EncryptCategory.plain}) async {
    final message = await _messageDao.findMessageByMessageId(forwardMessageId);
    if (message == null) {
      return;
    } else if (message.category.isText) {
      await sendTextMessage(
        conversationId,
        senderId,
        encryptCategory,
        message.content!,
      );
    } else if (message.category.isImage) {
      final category = encryptCategory.toCategory(MessageCategory.plainImage,
          MessageCategory.signalImage, MessageCategory.encryptedImage);
      AttachmentResult? attachmentResult;
      if (message.category == category && message.content != null) {
        attachmentResult = await _checkAttachment(message.content!);
      } else {
        attachmentResult = null;
      }
      await sendImageMessage(
        conversationId: conversationId,
        senderId: senderId,
        file: XFile(_attachmentUtil.convertAbsolutePath(
          category: message.category,
          conversationId: message.conversationId,
          fileName: message.mediaUrl,
        )),
        category: category,
        attachmentResult: attachmentResult,
      );
    } else if (message.category.isVideo) {
      final category = encryptCategory.toCategory(MessageCategory.plainVideo,
          MessageCategory.signalVideo, MessageCategory.encryptedVideo);
      AttachmentResult? attachmentResult;
      if (message.category == category && message.content != null) {
        attachmentResult = await _checkAttachment(message.content!);
      } else {
        attachmentResult = null;
      }
      await sendVideoMessage(
        conversationId,
        senderId,
        XFile(_attachmentUtil.convertAbsolutePath(
          category: message.category,
          conversationId: message.conversationId,
          fileName: message.mediaUrl,
        )),
        category,
        null,
        attachmentResult: attachmentResult,
        mediaDuration: message.mediaDuration,
        mediaHeight: message.mediaHeight,
        mediaWidth: message.mediaWidth,
        thumbImage: message.thumbImage,
      );
    } else if (message.category.isAudio) {
      final category = encryptCategory.toCategory(MessageCategory.plainAudio,
          MessageCategory.signalAudio, MessageCategory.encryptedAudio);
      AttachmentResult? attachmentResult;
      if (message.category == category && message.content != null) {
        attachmentResult = await _checkAttachment(message.content!);
      } else {
        attachmentResult = null;
      }
      await sendAudioMessage(
        conversationId,
        senderId,
        XFile(_attachmentUtil.convertAbsolutePath(
          category: message.category,
          conversationId: message.conversationId,
          fileName: message.mediaUrl,
        )),
        category,
        null,
        attachmentResult: attachmentResult,
        mediaDuration: message.mediaDuration,
        mediaWaveform: message.mediaWaveform,
      );
    } else if (message.category.isData) {
      final category = encryptCategory.toCategory(MessageCategory.plainData,
          MessageCategory.signalData, MessageCategory.encryptedData);
      AttachmentResult? attachmentResult;
      if (message.category == category && message.content != null) {
        attachmentResult = await _checkAttachment(message.content!);
      } else {
        attachmentResult = null;
      }

      await sendDataMessage(
        conversationId,
        senderId,
        XFile(_attachmentUtil.convertAbsolutePath(
          category: message.category,
          conversationId: message.conversationId,
          fileName: message.mediaUrl,
        )),
        category,
        null,
        attachmentResult: attachmentResult,
        name: message.name,
      );
    } else if (message.category.isSticker) {
      await sendStickerMessage(
          conversationId,
          senderId,
          StickerMessage(message.stickerId!, null, null),
          encryptCategory.toCategory(MessageCategory.encryptedSticker,
              MessageCategory.signalSticker, MessageCategory.encryptedSticker));
    } else if (message.category.isContact) {
      await sendContactMessage(
        conversationId,
        senderId,
        ContactMessage(message.sharedUserId!),
        message.name,
        encryptCategory: encryptCategory,
      );
    } else if (message.category.isLive) {
      final liveMessage = LiveMessage(
          message.mediaWidth!,
          message.mediaHeight!,
          // TODO shareable?
          message.thumbUrl ?? '',
          message.mediaUrl!,
          true);
      final encoded = await jsonBase64EncodeWithIsolate(liveMessage);
      await _sendLiveMessage(
          conversationId,
          senderId,
          encoded,
          message.mediaUrl!,
          message.thumbUrl ?? '',
          message.mediaWidth!,
          message.mediaHeight!,
          encryptCategory);
    } else if (message.category.isPost) {
      await sendPostMessage(
          conversationId, senderId, message.content!, encryptCategory);
    } else if (message.category.isLocation) {
      await _sendLocationMessage(
          conversationId, senderId, message.content!, encryptCategory);
    } else if (message.category == MessageCategory.appCard) {
      await _sendAppCardMessage(conversationId, senderId, message.content!);
    } else if (message.category.isTranscript) {
      final transcripts = await _transcriptMessageDao
          .transcriptMessageByTranscriptId(message.messageId)
          .get();
      await _sendTranscriptMessage(
        conversationId: conversationId,
        senderId: senderId,
        transcripts: transcripts,
        encryptCategory: encryptCategory,
      );
    }
  }

  Future<void> _sendTranscriptMessage({
    required String conversationId,
    required String senderId,
    required List<TranscriptMessage> transcripts,
    EncryptCategory encryptCategory = EncryptCategory.plain,
  }) async {
    final messageId = const Uuid().v4();

    final category = encryptCategory.toCategory(
      MessageCategory.plainTranscript,
      MessageCategory.signalTranscript,
      MessageCategory.encryptedTranscript,
    );

    final hasAttachments =
        transcripts.any((element) => element.category.isAttachment);

    final transcriptMessages = transcripts.map((e) {
      var mediaUrl = e.mediaUrl;
      var mediaStatus = e.mediaStatus;

      if (e.category.isAttachment) {
        mediaStatus = MediaStatus.canceled;
        if (e.mediaUrl == null) mediaUrl = null;
      }
      return e.copyWith(
        transcriptId: messageId,
        mediaUrl: Value(mediaUrl),
        mediaStatus: Value(mediaStatus),
      );
    }).toList();

    final transcriptMinimals = transcriptMessages
        .map((e) => TranscriptMinimal(
              name: e.userFullName ?? '',
              category: encryptCategory.asCategory(e.category),
              content: e.content,
            ).toJson())
        .toList();

    final message = Message(
      messageId: messageId,
      conversationId: conversationId,
      userId: senderId,
      category: category,
      content: await jsonEncodeWithIsolate(transcriptMinimals),
      createdAt: DateTime.now(),
      status: MessageStatus.sending,
      mediaStatus: hasAttachments ? MediaStatus.canceled : null,
    );

    Future<void> insertFts() async {
      final contents = await Future.wait(transcriptMessages.where((transcript) {
        final category = transcript.category;
        return category.isText ||
            category.isPost ||
            category.isData ||
            category.isContact;
      }).map((transcript) async {
        final category = transcript.category;
        if (category.isData) {
          return transcript.mediaName;
        }

        if (category.isContact &&
            (transcript.sharedUserId?.isNotEmpty ?? false)) {
          return _userDao
              .userFullNameByUserId(transcript.sharedUserId!)
              .getSingleOrNull();
        }

        return transcript.content;
      }));

      final join = contents.whereNotNull().join(' ');
      await _messageDao.insertFts(
        messageId,
        conversationId,
        join,
        DateTime.now(),
        senderId,
      );
    }

    await Future.wait([
      _transcriptMessageDao.insertAll(transcriptMessages),
      insertFts(),
      _messageDao.insert(message, senderId),
    ]);

    if (hasAttachments) {
      await reUploadTranscriptAttachment(message.messageId);
    } else {
      await _jobDao.insertSendingJob(
        message.messageId,
        conversationId,
      );
    }
  }

  Future<void> reUploadTranscriptAttachment(String messageId) async {
    final message = await _messageDao.findMessageByMessageId(messageId);
    if (message == null) return;

    final status = message.mediaStatus;
    if (status == MediaStatus.done || status == MediaStatus.pending) return;
    final transcripts = await _transcriptMessageDao
        .transcriptMessageByTranscriptId(messageId)
        .get();

    if (!transcripts.any((element) => element.category.isAttachment)) {
      await _jobDao.insertSendingJob(
        message.messageId,
        message.conversationId,
      );
      return;
    }

    Future<void> uploadAttachment(TranscriptMessage transcriptMessage) async {
      if (transcriptMessage.mediaStatus == MediaStatus.done) return;
      final category = transcriptMessage.category;

      final isPlain = category.isPlain;
      final isValidAttachment = category.isAttachment &&
          ((isPlain &&
                  transcriptMessage.mediaKey == null &&
                  transcriptMessage.mediaDigest == null) ||
              (transcriptMessage.mediaKey != null &&
                  transcriptMessage.mediaDigest != null));
      final isBefore24Hours = transcriptMessage.mediaCreatedAt
              ?.isBefore(DateTime.now().subtract(const Duration(days: 1))) ??
          true;
      final encryptCategory = message.category.encryptCategory;

      var needUpload =
          encryptCategory != category.encryptCategory || isBefore24Hours;

      String? attachmentId;
      if (!needUpload) {
        Future<String?> getAttachmentId(String? content) async {
          try {
            final map = await jsonBase64DecodeWithIsolate(content ?? '');
            final attachmentMessage =
                AttachmentMessage.fromJson(map as Map<String, dynamic>);
            return attachmentMessage.attachmentId;
          } catch (_) {
            return content;
          }
        }

        if (isValidAttachment) {
          attachmentId = await getAttachmentId(transcriptMessage.content);
        } else {
          needUpload = true;
        }
      }

      if (needUpload || attachmentId == null) {
        final absolutePath = _attachmentUtil.convertAbsolutePath(
          fileName: transcriptMessage.mediaUrl,
          messageId: transcriptMessage.messageId,
          isTranscript: true,
        );
        final newCategory = encryptCategory?.asCategory(category) ?? category;
        final attachmentResult = await _attachmentUtil.uploadAttachment(
          File(absolutePath),
          messageId,
          newCategory,
          transcriptId: transcriptMessage.transcriptId,
        );
        attachmentId = attachmentResult!.attachmentId;

        await _transcriptMessageDao.updateTranscript(
          transcriptId: transcriptMessage.transcriptId,
          messageId: transcriptMessage.messageId,
          attachmentId: attachmentId,
          category: newCategory,
          key: attachmentResult.keys,
          digest: attachmentResult.digest,
          mediaStatus: MediaStatus.done,
          mediaCreatedAt: DateTime.tryParse(attachmentResult.createdAt ?? '') ??
              DateTime.now(),
        );
      } else {
        await _transcriptMessageDao.updateTranscript(
          transcriptId: transcriptMessage.transcriptId,
          messageId: transcriptMessage.messageId,
          attachmentId: attachmentId,
          category: transcriptMessage.category,
          key: transcriptMessage.mediaKey,
          digest: transcriptMessage.mediaDigest,
          mediaStatus: MediaStatus.done,
          mediaCreatedAt: transcriptMessage.mediaCreatedAt,
        );
      }
    }

    try {
      await _messageDao.updateMediaStatus(
        message.messageId,
        MediaStatus.pending,
      );
      final attachmentTranscripts =
          transcripts.where((element) => element.category.isAttachment);
      if (attachmentTranscripts.isNotEmpty) {
        await Future.wait(attachmentTranscripts.map(uploadAttachment));
      }

      await _messageDao.updateMediaStatus(
        message.messageId,
        MediaStatus.done,
      );
      await _jobDao.insertSendingJob(
        message.messageId,
        message.conversationId,
      );
    } catch (_) {
      await _messageDao.updateMediaStatus(
        message.messageId,
        MediaStatus.canceled,
      );
    }
  }

  Future<void> reUploadAttachment(
    String conversationId,
    String messageId,
    String category,
    File file,
    String? name,
    String mediaMimeType,
    int mediaSize,
    int? mediaWidth,
    int? mediaHeight,
    String? thumbImage,
    String? mediaDuration,
    dynamic mediaWaveform,
    String? content,
  ) async {
    AttachmentResult? attachmentResult;
    if (content != null) {
      attachmentResult = await _checkAttachment(content);
    }
    attachmentResult ??=
        await _attachmentUtil.uploadAttachment(file, messageId, category);
    if (attachmentResult == null) return;
    final duration = mediaDuration != null ? int.parse(mediaDuration) : null;
    final attachmentMessage = AttachmentMessage(
      attachmentResult.keys,
      attachmentResult.digest,
      attachmentResult.attachmentId,
      mediaMimeType,
      mediaSize,
      name,
      mediaWidth,
      mediaHeight,
      thumbImage,
      duration,
      mediaWaveform,
      null,
      attachmentResult.createdAt,
    );
    final encoded = await jsonBase64EncodeWithIsolate(attachmentMessage);
    await _messageDao.updateAttachmentMessageContentAndStatus(
        messageId, encoded);
    await _jobDao.insertSendingJob(messageId, conversationId);
  }

  Future<AttachmentResult?> _checkAttachment(String content) async {
    AttachmentMessage? attachmentMessage;
    try {
      attachmentMessage = AttachmentMessage.fromJson(
          await jsonBase64DecodeWithIsolate(content) as Map<String, dynamic>);
    } catch (e) {
      attachmentMessage = null;
    }
    if (attachmentMessage == null) {
      return null;
    }
    final createdAt = attachmentMessage.createdAt;
    if (createdAt != null) {
      final date = DateTime.tryParse(createdAt);
      if (date?.isToady == true) {
        return AttachmentResult(
          attachmentMessage.attachmentId,
          attachmentMessage.key as String?,
          attachmentMessage.digest as String?,
          attachmentMessage.createdAt,
        );
      }
    }
    return null;
  }

  Future<void> sendPinMessage({
    required String conversationId,
    required String senderId,
    required List<PinMessageMinimal> pinMessageMinimals,
    required bool pin,
  }) async {
    if (pinMessageMinimals.isEmpty) return;

    final pinMessagePayload = PinMessagePayload(
      action: pin ? PinMessagePayloadAction.pin : PinMessagePayloadAction.unpin,
      messageIds: pinMessageMinimals.map((e) => e.messageId).toList(),
    );
    final encoded = await jsonEncodeWithIsolate(pinMessagePayload);
    if (pin) {
      await Future.forEach<PinMessageMinimal>(pinMessageMinimals,
          (pinMessageMinimal) async {
        await _pinMessageDao.insert(
          PinMessage(
            messageId: pinMessageMinimal.messageId,
            conversationId: conversationId,
            createdAt: DateTime.now(),
          ),
        );

        await _messageDao.insert(
          Message(
            messageId: const Uuid().v4(),
            conversationId: conversationId,
            userId: senderId,
            status: MessageStatus.read,
            content: await jsonEncodeWithIsolate(pinMessageMinimal),
            createdAt: DateTime.now(),
            category: MessageCategory.messagePin,
            quoteMessageId: pinMessageMinimal.messageId,
          ),
          senderId,
        );
      });
      unawaited(ShowPinMessageKeyValue.instance.show(conversationId));
    } else {
      await _pinMessageDao
          .deleteByIds(pinMessageMinimals.map((e) => e.messageId).toList());
    }

    _messageDao.notifyMessageInsertOrReplaced(
        pinMessageMinimals.map((e) => e.messageId));

    await _jobDao.insert(
      Job(
        conversationId: conversationId,
        jobId: const Uuid().v4(),
        action: kPinMessage,
        priority: 5,
        blazeMessage: encoded,
        createdAt: DateTime.now(),
        runCount: 0,
      ),
    );
  }
}

Future<Image> _getSmallImage(String path) async {
  final fileImage = FileImage(File(path));
  final imageProvider = ExtendedResizeImage(fileImage, maxBytes: 128 << 10);
  final image = await imageProvider.toImage();

  return Image.fromBytes(image.width, image.height, (await image.toBytes())!);
}

Future<String?> _getImageThumbnailString(Image image) async {
  String? thumbImage;
  if (_kEnableImageBlurHashThumb) {
    thumbImage = BlurHash.encode(image).hash;
  } else {
    thumbImage = base64Encode(encodeJpg(image, quality: 50));
  }
  return thumbImage;
}
