import '../data/media_uploader.dart';
import 'listing_video_controller.dart';
import 'listing_video_preview_controller_stub.dart'
    if (dart.library.html) 'listing_video_preview_controller_web.dart'
    as platform;

ListingVideoController createLocalVideoPreview(PickedMediaFile file) =>
    platform.createLocalVideoPreview(file);
