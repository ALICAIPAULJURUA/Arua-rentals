import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/media_uploader.dart';
import '../data/supabase_listings_repository.dart';

final listingsRepositoryProvider = Provider<SupabaseListingsRepository>(
  (ref) => SupabaseListingsRepository(),
);

final mediaUploaderProvider = Provider<MediaUploader>(
  (ref) => SupabaseMediaUploader(),
);
