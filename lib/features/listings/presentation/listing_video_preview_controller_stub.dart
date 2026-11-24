import 'dart:io';

import 'package:video_player/video_player.dart';

import '../data/media_uploader.dart';
import 'listing_video_controller.dart';

ListingVideoController createLocalVideoPreview(PickedMediaFile file) {
  final path = file.path;
  if (path == null || path.isEmpty) {
    throw UnsupportedError('The selected video has no local file path.');
  }
  return ListingVideoController(
    controller: VideoPlayerController.file(File(path)),
  );
}
