import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:tuple/tuple.dart';

import '../../../constants/brightness_theme_data.dart';
import '../../../constants/resources.dart';
import '../../../utils/extension/extension.dart';
import '../../../utils/load_balancer_utils.dart';
import '../../../utils/logger.dart';
import '../../../utils/platform.dart';
import '../../../utils/system/clipboard.dart';
import '../../../widgets/action_button.dart';
import '../../../widgets/buttons.dart';
import '../../../widgets/cache_image.dart';
import '../../../widgets/dash_path_border.dart';
import '../../../widgets/dialog.dart';
import '../bloc/conversation_cubit.dart';
import 'image_editor.dart';

Future<void> showFilesPreviewDialog(
    BuildContext context, List<XFile> files) async {
  await showMixinDialog(
    context: context,
    child: _FilesPreviewDialog(
      initialFiles: await Future.wait(files.map(
        (e) async => _File(e, await e.length(), null),
      )),
    ),
  );
}

/// We need this view object to keep the value of file#length.
class _File {
  _File(this.file, this.length, this.imageEditorSnapshot);

  static Future<_File> createFromPath(String path) {
    final file = File(path);
    return createFromFile(file);
  }

  static Future<_File> createFromFile(File file) async =>
      _File(file.xFile, await file.length(), null);

  final XFile file;

  final ImageEditorSnapshot? imageEditorSnapshot;

  String get path => file.path;

  String? get mimeType => file.mimeType;

  final int length;

  bool get isImage => file.isImage;
}

typedef _ImageEditedCallback = void Function(_File, ImageEditorSnapshot);

const _kDefaultArchiveName = 'Archive.zip';

enum _TabType { image, files, zip }

class _FilesPreviewDialog extends HookWidget {
  const _FilesPreviewDialog({
    Key? key,
    required this.initialFiles,
  }) : super(key: key);

  final List<_File> initialFiles;

  @override
  Widget build(BuildContext context) {
    final files = useState(initialFiles);

    final hasImage = useMemoized(
      () => files.value.indexWhere((e) => e.isImage) != -1,
      [identityHashCode(files.value)],
    );

    final showZipTab = files.value.length > 1;

    final currentTab = useState(_TabType.files);

    final onFileAddedStream = useStreamController<int>();
    final onFileRemovedStream = useStreamController<Tuple2<int, _File>>();

    void removeFile(_File file) {
      final index = files.value.indexOf(file);
      files.value = (files.value..removeAt(index)).toList();
      onFileRemovedStream.add(Tuple2(index, file));
      if (files.value.isEmpty) {
        Navigator.pop(context);
      }
    }

    final previousTab = usePrevious(currentTab.value);

    useEffect(() {
      if (previousTab == null && hasImage) {
        currentTab.value = _TabType.image;
      } else if (previousTab == null && !hasImage) {
        currentTab.value = _TabType.files;
      } else if (!hasImage && currentTab.value == _TabType.image) {
        currentTab.value = _TabType.files;
      } else if (!showZipTab && currentTab.value == _TabType.zip) {
        currentTab.value = _TabType.files;
      }
    }, [hasImage, showZipTab]);

    final showAsBigImage = useState(hasImage);

    useEffect(() {
      if (hasImage && currentTab.value == _TabType.image) {
        showAsBigImage.value = true;
      } else {
        showAsBigImage.value = false;
      }
    }, [hasImage, currentTab.value]);

    return Material(
      child: Container(
          width: 480,
          height: 600,
          color: context.theme.popUp,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.only(left: 15),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Tab(
                          assetName: Resources.assetsImagesFilePreviewImagesSvg,
                          tooltip: context.l10n.sendQuick,
                          onTap: () => currentTab.value = _TabType.image,
                          selected: currentTab.value == _TabType.image,
                          show: hasImage,
                        ),
                        _Tab(
                          assetName: Resources.assetsImagesFilePreviewFilesSvg,
                          tooltip: context.l10n.sendWithoutCompression,
                          onTap: () => currentTab.value = _TabType.files,
                          selected: currentTab.value == _TabType.files,
                        ),
                        _Tab(
                          assetName: Resources.assetsImagesFilePreviewZipSvg,
                          tooltip: context.l10n.sendArchived,
                          onTap: () => currentTab.value = _TabType.zip,
                          selected: currentTab.value == _TabType.zip,
                          show: showZipTab,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: _FileInputOverlay(
                      onFileAdded: (fileAdded) {
                        final currentFiles =
                            files.value.map((e) => e.path).toSet();
                        fileAdded
                            .removeWhere((e) => currentFiles.contains(e.path));
                        files.value = (files.value..addAll(fileAdded)).toList();
                        for (var i = 0; i < fileAdded.length; i++) {
                          onFileAddedStream.add(currentFiles.length + i);
                        }
                      },
                      child: IndexedStack(
                        sizing: StackFit.expand,
                        index: currentTab.value == _TabType.zip ? 1 : 0,
                        children: [
                          _AnimatedListBuilder(
                              files: files.value,
                              onFileAdded: onFileAddedStream.stream,
                              onFileDeleted: onFileRemovedStream.stream,
                              builder: (context, file, animation) =>
                                  _AnimatedFileTile(
                                    key: ValueKey(file),
                                    file: file,
                                    animation: animation,
                                    onDelete: removeFile,
                                    showBigImage: showAsBigImage,
                                    onImageEdited: (file, image) async {
                                      final index = files.value.indexOf(file);
                                      if (index == -1) {
                                        e('failed to found file');
                                        return;
                                      }
                                      final list = files.value.toList();
                                      final newFile = File(image.imagePath);
                                      list[index] = _File(newFile.xFile,
                                          await newFile.length(), image);
                                      files.value = list;
                                    },
                                  )),
                          const _PageZip(),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Align(
                    child: ElevatedButton(
                      onPressed: () async {
                        if (currentTab.value != _TabType.zip) {
                          for (final file in files.value) {
                            unawaited(_sendFile(context, file));
                          }
                          Navigator.pop(context);
                        } else {
                          final zipFilePath =
                              await runLoadBalancer(_archiveFiles, [
                            (await getTemporaryDirectory()).path,
                            ...files.value.map((e) => e.path),
                          ]);
                          unawaited(_sendFile(
                            context,
                            await _File.createFromPath(zipFilePath),
                          ));
                          Navigator.pop(context);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.only(
                            left: 32, top: 18, bottom: 18, right: 32),
                        primary: context.theme.accent,
                      ),
                      child: Text(context.l10n.send.toUpperCase()),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
              const Align(
                alignment: AlignmentDirectional.topEnd,
                child: Padding(
                  padding: EdgeInsets.all(22),
                  child: MixinCloseButton(),
                ),
              )
            ],
          )),
    );
  }
}

Future<String> _archiveFiles(List<String> paths) async {
  assert(paths.length > 1, 'paths[0] should be temp file dir');
  final outPath = path.join(
      paths[0], 'mixin_archive_${DateTime.now().millisecondsSinceEpoch}.zip');
  final encoder = ZipFileEncoder()..create(outPath);
  paths.removeAt(0);
  for (final filePath in paths) {
    encoder.addFile(File(filePath), path.basename(filePath));
  }
  encoder.close();
  return outPath;
}

Future<void> _sendFile(BuildContext context, _File file) async {
  final conversationItem = context.read<ConversationCubit>().state;
  if (conversationItem == null) return;
  final xFile = file.file;
  if (xFile.isImage) {
    return context.accountServer.sendImageMessage(
      conversationItem.encryptCategory,
      file: xFile,
      conversationId: conversationItem.conversationId,
      recipientId: conversationItem.userId,
    );
  } else if (xFile.isVideo) {
    return context.accountServer.sendVideoMessage(
      xFile,
      conversationItem.encryptCategory,
      conversationId: conversationItem.conversationId,
      recipientId: conversationItem.userId,
    );
  }
  await context.accountServer.sendDataMessage(
    xFile,
    conversationItem.encryptCategory,
    conversationId: conversationItem.conversationId,
    recipientId: conversationItem.userId,
  );
}

class _AnimatedFileTile extends HookWidget {
  const _AnimatedFileTile({
    Key? key,
    required this.file,
    required this.animation,
    this.onDelete,
    required this.showBigImage,
    this.onImageEdited,
  }) : super(key: key);

  final _File file;
  final Animation<double> animation;

  final void Function(_File)? onDelete;

  final _ImageEditedCallback? onImageEdited;

  final ValueNotifier<bool> showBigImage;

  @override
  Widget build(BuildContext context) {
    final big = useValueListenable(showBigImage);
    return SizeTransition(
      sizeFactor: animation,
      child: FadeTransition(
        opacity: animation,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: file.isImage
              ? AnimatedCrossFade(
                  firstChild: _TileBigImage(
                    file: file,
                    onDelete: () => onDelete?.call(file),
                    onEdited: (file, snapshot) =>
                        onImageEdited?.call(file, snapshot),
                  ),
                  secondChild: _TileNormalFile(
                    file: file,
                    onDelete: () => onDelete?.call(file),
                  ),
                  crossFadeState: big
                      ? CrossFadeState.showFirst
                      : CrossFadeState.showSecond,
                  firstCurve: Curves.easeInOut,
                  secondCurve: Curves.easeInOut,
                  sizeCurve: Curves.easeInOut,
                  duration: const Duration(milliseconds: 300))
              : _TileNormalFile(
                  file: file,
                  onDelete: () => onDelete?.call(file),
                ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    Key? key,
    required this.assetName,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.show = true,
  }) : super(key: key);

  final String assetName;

  final String tooltip;

  final VoidCallback onTap;

  final bool selected;

  final bool show;

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        child: show
            ? GestureDetector(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(15),
                  child: Tooltip(
                      message: tooltip,
                      textStyle: const TextStyle(
                        color: Colors.white,
                      ),
                      child: SvgPicture.asset(
                        assetName,
                        color: selected
                            ? context.theme.accent
                            : context.theme.icon,
                        width: 24,
                        height: 24,
                      )),
                ),
              )
            : const SizedBox(),
      );
}

class _PageZip extends StatelessWidget {
  const _PageZip({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 30),
              const _FileIcon(extension: 'ZIP'),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _kDefaultArchiveName,
                      style: TextStyle(
                        color: context.theme.text,
                        fontSize: 16,
                        height: 1.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.archivedFolder,
                      style: TextStyle(
                        color: context.theme.secondaryText,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 30),
            ],
          )
        ],
      );
}

class _AnimatedListBuilder extends HookWidget {
  const _AnimatedListBuilder({
    Key? key,
    required this.files,
    required this.onFileAdded,
    required this.onFileDeleted,
    required this.builder,
  }) : super(key: key);

  final List<_File> files;
  final Stream<int> onFileAdded;
  final Stream<Tuple2<int, _File>> onFileDeleted;

  final Widget Function(BuildContext, _File, Animation<double>) builder;

  @override
  Widget build(BuildContext context) {
    final animatedListKey = useMemoized(() => GlobalKey<AnimatedListState>(
          debugLabel: 'file_preview_dialog',
        ));
    useEffect(() {
      final subscription = onFileAdded.listen((event) {
        animatedListKey.currentState?.insertItem(event);
      });
      return subscription.cancel;
    }, [onFileAdded]);
    useEffect(() {
      final subscription = onFileDeleted.listen((event) {
        animatedListKey.currentState?.removeItem(
          event.item1,
          (context, animation) => builder(context, event.item2, animation),
        );
      });
      return subscription.cancel;
    }, [onFileDeleted]);
    return AnimatedList(
      initialItemCount: files.length,
      key: animatedListKey,
      itemBuilder: (context, index, animation) =>
          builder(context, files[index], animation),
    );
  }
}

class _TileBigImage extends HookWidget {
  const _TileBigImage({
    Key? key,
    required this.file,
    required this.onDelete,
    required this.onEdited,
  }) : super(key: key);

  final _File file;

  final VoidCallback onDelete;

  final _ImageEditedCallback onEdited;

  @override
  Widget build(BuildContext context) {
    assert(file.isImage);

    final showDelete = useState(false);

    return MouseRegion(
      onEnter: (_) => showDelete.value = true,
      onExit: (_) => showDelete.value = false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 420,
                  minWidth: 420,
                  maxWidth: 420,
                ),
                child: Image(
                  image: MixinFileImage(File(file.path)),
                  fit: BoxFit.fitWidth,
                  errorBuilder: (_, __, ___) => const SizedBox(),
                ),
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox(),
                alignment: Alignment.center,
                secondChild: Container(
                  height: 50,
                  decoration: BoxDecoration(
                      gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.28),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  )),
                  child: Row(
                    children: [
                      const Spacer(),
                      ActionButton(
                        color: Colors.white,
                        name: Resources.assetsImagesEditImageSvg,
                        padding: const EdgeInsets.all(10),
                        onTap: () async {
                          ImageEditorSnapshot? snapshot;
                          if (file.imageEditorSnapshot != null) {
                            snapshot = await showImageEditor(
                              context,
                              path: file.imageEditorSnapshot!.rawImagePath,
                              snapshot: file.imageEditorSnapshot,
                            );
                          } else {
                            snapshot = await showImageEditor(
                              context,
                              path: file.path,
                            );
                          }
                          if (snapshot == null) {
                            return;
                          }
                          onEdited.call(file, snapshot);
                        },
                      ),
                      ActionButton(
                        color: Colors.white,
                        name: Resources.assetsImagesDeleteSvg,
                        padding: const EdgeInsets.all(10),
                        onTap: onDelete,
                      ),
                    ],
                  ),
                ),
                crossFadeState: !showDelete.value
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                duration: const Duration(milliseconds: 150),
              )
            ],
          ),
        ),
      ),
    );
  }
}

class _FileIcon extends StatelessWidget {
  const _FileIcon({Key? key, required this.extension}) : super(key: key);

  final String extension;

  @override
  Widget build(BuildContext context) => Container(
        height: 50,
        width: 50,
        decoration: BoxDecoration(
          color: context.theme.statusBackground,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(
            extension,
            style: TextStyle(
              fontSize: 16,
              // force light style
              color: lightBrightnessThemeData.secondaryText,
            ),
          ),
        ),
      );
}

class _TileNormalFile extends HookWidget {
  const _TileNormalFile({
    Key? key,
    required this.file,
    required this.onDelete,
  }) : super(key: key);

  final _File file;

  final VoidCallback onDelete;

  static String _getFileExtension(_File file) {
    var extension = '';
    final mimeType = lookupMimeType(file.path);
    // Only show the extension which is valid.
    if (mimeType != null) {
      extension = path.extension(file.path).trim().replaceFirst('.', '');
    }
    return extension.isEmpty ? 'FILE' : extension.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final showDelete = useState(false);
    return MouseRegion(
      onEnter: (_) => showDelete.value = true,
      onExit: (_) => showDelete.value = false,
      child: Row(
        children: [
          const SizedBox(width: 30),
          _FileIcon(extension: _getFileExtension(file)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  path.basename(file.path).overflow,
                  style: TextStyle(
                    color: context.theme.text,
                    fontSize: 16,
                    height: 1.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  filesize(file.length, 0),
                  style: TextStyle(
                    color: context.theme.secondaryText,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          if (showDelete.value)
            ActionButton(
              color: context.theme.secondaryText,
              name: Resources.assetsImagesDeleteSvg,
              padding: const EdgeInsets.all(10),
              onTap: onDelete,
            ),
          if (showDelete.value) const SizedBox(width: 10),
          if (!showDelete.value) const SizedBox(width: 30),
        ],
      ),
    );
  }
}

class _FileInputOverlay extends HookWidget {
  const _FileInputOverlay({
    Key? key,
    required this.child,
    required this.onFileAdded,
  }) : super(key: key);

  final Widget child;

  final void Function(List<_File>) onFileAdded;

  @override
  Widget build(BuildContext context) {
    final dragging = useState(false);
    return FocusableActionDetector(
      autofocus: true,
      shortcuts: {
        SingleActivator(
          LogicalKeyboardKey.keyV,
          meta: kPlatformIsDarwin,
          control: !kPlatformIsDarwin,
        ): const _PasteFileOrImageIntent(),
      },
      actions: {
        _PasteFileOrImageIntent: CallbackAction<Intent>(onInvoke: (_) async {
          final files = await getClipboardFiles();
          onFileAdded(await Future.wait(files.map(_File.createFromFile)));
        })
      },
      child: DropTarget(
        onDragEntered: (_) => dragging.value = true,
        onDragExited: (_) => dragging.value = false,
        onDragDone: (details) async {
          final files = details.files.where((xFile) {
            final file = File(xFile.path);
            return file.existsSync();
          });
          if (files.isEmpty) {
            return;
          }
          onFileAdded(await Future.wait(
            files.map(
              (file) async => _File(file, await file.length(), null),
            ),
          ));
        },
        child: Stack(
          children: [
            child,
            if (dragging.value) const _ChatDragIndicator(),
          ],
        ),
      ),
    );
  }
}

class _PasteFileOrImageIntent extends Intent {
  const _PasteFileOrImageIntent();
}

class _ChatDragIndicator extends StatelessWidget {
  const _ChatDragIndicator({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: context.theme.popUp),
        child: Container(
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: context.theme.listSelected,
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              border: DashPathBorder.all(
                borderSide: BorderSide(
                  color: context.theme.accent,
                ),
                dashArray: CircularIntervalList([4, 4]),
              )),
          child: Center(
            child: Text(
              context.l10n.chatDragMoreFile,
              style: TextStyle(
                fontSize: 14,
                color: context.theme.text,
              ),
            ),
          ),
        ),
      );
}
