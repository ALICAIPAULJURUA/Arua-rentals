import 'package:video_player/video_player.dart';

class ListingVideoController {
  const ListingVideoController({
    required this.controller,
    this.releaseSource,
  });

  final VideoPlayerController controller;
  final void Function()? releaseSource;

  Future<void> dispose() async {
    await controller.dispose();
    releaseSource?.call();
  }
}
