import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_tokens.dart';
import '../data/media_uploader.dart';
import 'listing_video_controller.dart';
import 'listing_video_preview_controller.dart';

class ListingVideoPlayer extends StatefulWidget {
  const ListingVideoPlayer({
    this.videoUrl,
    this.selectedFile,
    this.onRetry,
    super.key,
  });

  final String? videoUrl;
  final PickedMediaFile? selectedFile;
  final VoidCallback? onRetry;

  @override
  State<ListingVideoPlayer> createState() => _ListingVideoPlayerState();
}

class _ListingVideoPlayerState extends State<ListingVideoPlayer> {
  ListingVideoController? _localPreview;
  VideoPlayerController? _networkController;
  VideoPlayerController? get _controller =>
      _localPreview?.controller ?? _networkController;

  Future<void>? _initializeFuture;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant ListingVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl ||
        oldWidget.selectedFile != widget.selectedFile) {
      _initialize();
    }
  }

  void _initialize() {
    final oldPreview = _localPreview;
    final oldController = _networkController;
    if (oldPreview != null) unawaited(oldPreview.dispose());
    if (oldController != null) unawaited(oldController.dispose());

    _localPreview = null;
    _networkController = null;
    final file = widget.selectedFile;
    final url = widget.videoUrl;
    if (file != null) {
      try {
        _localPreview = createLocalVideoPreview(file);
        _initializeFuture = _localPreview!.controller.initialize();
      } on UnsupportedError catch (error) {
        _initializeFuture = Future<void>.error(error);
      }
    } else if (url != null && url.isNotEmpty) {
      _networkController = VideoPlayerController.networkUrl(Uri.parse(url));
      _initializeFuture = _networkController!.initialize();
    } else {
      _initializeFuture = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final preview = _localPreview;
    final networkController = _networkController;
    if (preview != null) unawaited(preview.dispose());
    if (networkController != null) unawaited(networkController.dispose());
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final initializeFuture = _initializeFuture;
    if (controller == null || initializeFuture == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<void>(
      future: initializeFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError || controller.value.hasError) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Video preview is unavailable.'),
              if (widget.onRetry != null)
                TextButton(onPressed: widget.onRetry, child: const Text('Retry')),
            ],
          );
        }
        if (snapshot.connectionState != ConnectionState.done ||
            !controller.value.isInitialized) {
          return const AspectRatio(
            aspectRatio: 16 / 9,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: controller.value.isPlaying ? 'Pause video' : 'Play video',
                  onPressed: _togglePlayback,
                  icon: Icon(
                    controller.value.isPlaying
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                  ),
                ),
                Expanded(
                  child: VideoProgressIndicator(
                    controller,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
