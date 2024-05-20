import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:jhentai/src/extension/list_extension.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/utils/file_util.dart';
import 'package:path/path.dart';

import '../model/gallery_image.dart';
import '../pages/download/grid/mixin/grid_download_page_service_mixin.dart';
import '../setting/download_setting.dart';
import '../setting/path_setting.dart';
import '../utils/log.dart';
import '../widget/loading_state_indicator.dart';
import 'archive_download_service.dart';

class LocalGallery {
  String title;
  String path;
  GalleryImage cover;

  LocalGallery({required this.title, required this.path, required this.cover});
}

class LocalGalleryParseResult {
  /// has images
  bool isLegalGalleryDir = false;

  /// has subDirectory that has images
  bool isLegalNestedGalleryDir = false;
}

/// Load galleries in download directory but is not downloaded by JHenTai
class LocalGalleryService extends GetxController with GridBasePageServiceMixin {
  static const String rootPath = '';

  LoadingState loadingState = LoadingState.idle;

  List<LocalGallery> allGallerys = [];
  Map<String, List<LocalGallery>> path2GalleryDir = {};
  Map<String, List<String>> path2SubDir = {};

  Map<int, LocalGallery> gid2EHViewerGallery = {};

  List<String> get rootDirectories => path2SubDir[rootPath] ?? [];

  static void init() {
    Get.put(LocalGalleryService(), permanent: true);
  }

  @override
  Future<void> onInit() async {
    super.onInit();

    await refreshLocalGallerys();
  }

  Future<void> refreshLocalGallerys() {
    if (loadingState == LoadingState.loading) {
      return Future.value();
    }
    loadingState = LoadingState.loading;

    int preCount = allGallerys.length;

    allGallerys.clear();
    path2GalleryDir.clear();
    path2SubDir.clear();
    update([galleryCountChangedId]);

    DateTime start = DateTime.now();
    return _loadGalleriesFromDisk().whenComplete(() {
      Log.info(
        'Refresh local gallerys, preCount:$preCount, newCount: ${allGallerys.length}, timeCost: ${DateTime.now().difference(start).inMilliseconds}ms',
      );
      loadingState = LoadingState.success;
      update([galleryCountChangedId]);
    });
  }

  List<GalleryImage> getGalleryImages(LocalGallery gallery) {
    List<File> imageFiles = Directory(gallery.path).listSync().whereType<File>().where((image) => FileUtil.isImageExtension(image.path)).toList()
      ..sort(FileUtil.naturalCompareFile);

    return imageFiles
        .map(
          (file) => GalleryImage(
            url: '',
            path: relative(file.path, from: PathSetting.getVisibleDir().path),
            downloadStatus: DownloadStatus.downloaded,
          ),
        )
        .toList();
  }

  void deleteGallery(LocalGallery gallery, String parentPath) {
    Log.info('Delete local gallery: ${gallery.title}');

    Directory dir = Directory(gallery.path);

    List<File> allFiles = dir.listSync().whereType<File>().toList();
    List<File> imageFiles = dir.listSync().whereType<File>().where((image) => FileUtil.isImageExtension(image.path)).toList();
    if (allFiles.length == imageFiles.length) {
      dir.delete(recursive: true).catchError((e) {
        Log.error('Delete local gallery error!', e);
        Log.uploadError(e);
      });
    } else {
      for (File file in imageFiles) {
        file.delete().catchError((e) {
          Log.error('Delete local gallery error!', e);
          Log.uploadError(e);
        });
      }
    }

    allGallerys.removeWhere((g) => g.title == gallery.title);
    path2GalleryDir[parentPath]?.removeWhere((g) => g.title == gallery.title);

    update([galleryCountChangedId]);
  }

  Future<void> _loadGalleriesFromDisk() {
    List<Future> futures = DownloadSetting.extraGalleryScanPath.map((path) => _parseDirectory(Directory(path), true)).toList();

    return Future.wait(futures).onError((error, stackTrace) {
      Log.error('_loadGalleriesFromDisk failed, path: ${DownloadSetting.extraGalleryScanPath}', error, stackTrace);
      return [];
    }).whenComplete(() {
      allGallerys.sort((a, b) => FileUtil.naturalCompare(a.title, b.title));
      for (List<LocalGallery> dirs in path2GalleryDir.values) {
        dirs.sort((a, b) => FileUtil.naturalCompare(a.title, b.title));
      }
    });
  }

  Future<LocalGalleryParseResult> _parseDirectory(Directory directory, bool isRootDir) {
    Completer<LocalGalleryParseResult> completer = Completer();
    LocalGalleryParseResult result = LocalGalleryParseResult();

    Future<bool> future = directory.exists();

    /// skip if it is JHenTai gallery directory -> metadata file exists
    future = future.then<bool>((success) {
      if (success) {
        return File(join(directory.path, GalleryDownloadService.metadataFileName)).exists().then((value) => !value);
      } else {
        completer.isCompleted ? null : completer.complete(result);
        return false;
      }
    }).catchError((e, stack) {
      completer.isCompleted ? null : completer.completeError(e, stack);
      return false;
    });

    future = future.then<bool>((success) {
      if (success) {
        return File(join(directory.path, ArchiveDownloadService.metadataFileName)).exists().then((value) => !value);
      } else {
        completer.isCompleted ? null : completer.complete(result);
        return false;
      }
    }).catchError((e, stack) {
      completer.isCompleted ? null : completer.completeError(e, stack);
      return false;
    });

    /// recursively list all files in directory
    future = future.then<bool>((success) {
      if (success) {
        List<Future> subFutures = [];

        String parentPath = isRootDir ? rootPath : directory.parent.path;
        directory.list().listen(
          (entity) {
            if (entity is File && FileUtil.isImageExtension(entity.path) && result.isLegalGalleryDir == false) {
              result.isLegalGalleryDir = true;
              _initGalleryInfoInMemory(directory, entity, parentPath);
            } else if (entity is Directory) {
              subFutures.add(
                _parseDirectory(entity, false).then((subResult) {
                  if (subResult.isLegalGalleryDir || subResult.isLegalNestedGalleryDir) {
                    result.isLegalNestedGalleryDir = true;
                    (path2SubDir[parentPath] ??= []).addIfNotExists(directory.path);
                    path2SubDir[parentPath]!.sort((a, b) => FileUtil.naturalCompare(basenameWithoutExtension(a), basenameWithoutExtension(b)));
                  }
                }),
              );
            }
          },
          onDone: () {
            Future.wait(subFutures).then((_) {
              completer.isCompleted ? null : completer.complete(result);
            });
          },
          onError: completer.completeError,
        );
      } else {
        completer.isCompleted ? null : completer.complete(result);
      }
      return success;
    }).catchError((e, stack) {
      completer.isCompleted ? null : completer.completeError(e, stack);
      return false;
    });

    return completer.future;
  }

  void _initGalleryInfoInMemory(Directory galleryDir, File coverImage, String parentPath) {
    LocalGallery gallery = LocalGallery(
      title: basename(galleryDir.path),
      path: galleryDir.path,
      cover: GalleryImage(
        url: '',
        path: relative(coverImage.path, from: PathSetting.getVisibleDir().path),
        downloadStatus: DownloadStatus.downloaded,
      ),
    );

    allGallerys.add(gallery);
    (path2GalleryDir[parentPath] ??= []).add(gallery);
  }
}
