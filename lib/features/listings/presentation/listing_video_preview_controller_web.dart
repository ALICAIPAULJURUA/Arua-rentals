import 'dart:html' as html;

import 'package:video_player/video_player.dart';

import '../data/media_uploader.dart';
import 'listing_video_controller.dart';

ListingVideoController createLocalVideoPreview(PickedMediaFile file) {
  String blobType() {
    final explicit = file.mimeType?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final lower = file.name.toLowerCase();
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    return 'application/octet-stream';
  }

  final source = html.Url.createObjectUrlFromBlob(
    html.Blob(<Object>[file.bytes], blobType()),
  );
  return ListingVideoController(
    controller: VideoPlayerController.networkUrl(Uri.parse(source)),
    releaseSource: () => html.Url.revokeObjectUrl(source),
  );
}
