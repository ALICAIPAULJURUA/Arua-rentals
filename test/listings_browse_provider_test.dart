import 'package:arua_rentals/features/listings/data/listing.dart';
import 'package:arua_rentals/features/listings/data/listing_sort.dart';
import 'package:arua_rentals/features/listings/data/supabase_listings_repository.dart';
import 'package:arua_rentals/features/listings/presentation/listings_browse_provider.dart';
import 'package:arua_rentals/features/listings/presentation/listings_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'browse provider loads the next 20-item page without duplicates',
    () async {
      final client = SupabaseClient(
        'https://test-project.supabase.co',
        'sb_publishable_test',
      );
      final repository = _PagedListingsRepository(
        items: List.generate(25, _listing),
        client: client,
      );
      final container = _container(repository);
      addTearDown(() => _dispose(container, client));

      await container.read(listingsBrowseProvider.future);
      final firstPage = container.read(listingsBrowseProvider).asData!.value;
      expect(firstPage.items, hasLength(20));
      expect(firstPage.hasMore, isTrue);
      expect(firstPage.nextCursor, isNotNull);

      await container.read(listingsBrowseProvider.notifier).loadMore();
      final secondPage = container.read(listingsBrowseProvider).asData!.value;
      expect(secondPage.loadMoreError, isNull);
      expect(secondPage.isLoadingMore, isFalse);
      expect(secondPage.items, hasLength(25));
      expect(
        secondPage.items.map((listing) => listing.id).toSet(),
        hasLength(25),
      );
      expect(secondPage.hasMore, isFalse);
    },
  );

  test('filters by category, area, and keyword, then sorts by price', () async {
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
    );
    final repository = _PagedListingsRepository(
      client: client,
      items: [
        _listing(0, title: 'Room near Oli', price: 100000),
        _listing(1, title: 'Room by Oli', price: 200000),
        _listing(2, title: 'Room in Oli', price: 300000),
        _listing(3, title: 'Room elsewhere', area: 'Ayivu', price: 900000),
        _listing(4, title: 'Room in Oli', category: 'Cleaning', price: 800000),
      ],
    );
    final container = _container(repository);
    addTearDown(() => _dispose(container, client));

    await container.read(listingsBrowseProvider.future);
    await container
        .read(listingsBrowseProvider.notifier)
        .applyFilters(
          category: 'Rentals',
          area: 'Oli',
          keyword: 'room',
          sort: ListingSort.priceHighToLow,
        );

    final result = container.read(listingsBrowseProvider).asData!.value;
    expect(result.items.map((listing) => listing.id), [
      'listing-2',
      'listing-1',
      'listing-0',
    ]);
    expect(result.category, 'Rentals');
    expect(result.area, 'Oli');
    expect(result.keyword, 'room');
    expect(result.sort, ListingSort.priceHighToLow);
  });
}

class _PagedListingsRepository extends SupabaseListingsRepository {
  _PagedListingsRepository({required this.items, required this.client})
    : super(client: client);

  final SupabaseClient client;
  final List<Listing> items;

  @override
  Future<SupabaseListingPage> getApprovedListings({
    int limit = 20,
    ListingCursor? startAfter,
    String? category,
    String? area,
    String? keyword,
    ListingSort sort = ListingSort.newest,
  }) async {
    var filtered = items.where((listing) {
      return (category == null || listing.category == category) &&
          (area == null || listing.area == area) &&
          (keyword == null ||
              listing.searchKeywords.contains(keyword.toLowerCase()));
    }).toList();
    if (sort == ListingSort.priceHighToLow) {
      filtered.sort((left, right) => right.priceUgx.compareTo(left.priceUgx));
    } else if (sort == ListingSort.priceLowToHigh) {
      filtered.sort((left, right) => left.priceUgx.compareTo(right.priceUgx));
    }
    final startIndex = startAfter == null
        ? 0
        : filtered.indexWhere((listing) => listing.id == startAfter.id) + 1;
    final pageItems = filtered.skip(startIndex).take(limit).toList();
    final nextCursor = pageItems.length < limit
        ? null
        : ListingCursor(
            id: pageItems.last.id,
            createdAt: pageItems.last.createdAt!,
            priceUgx: pageItems.last.priceUgx,
          );
    return SupabaseListingPage(items: pageItems, nextCursor: nextCursor);
  }
}

ProviderContainer _container(SupabaseListingsRepository repository) =>
    ProviderContainer(
      overrides: [listingsRepositoryProvider.overrideWithValue(repository)],
    );

Future<void> _dispose(
  ProviderContainer container,
  SupabaseClient client,
) async {
  container.dispose();
  await client.dispose();
}

Listing _listing(
  int index, {
  String? title,
  String category = 'Rentals',
  String area = 'Oli',
  int? price,
}) {
  final listingTitle = title ?? 'Room Listing $index';
  return Listing(
    id: 'listing-$index',
    ownerId: 'owner-$index',
    ownerName: 'Listing owner',
    ownerPhone: '+256700000000',
    type: ListingType.property,
    category: category,
    title: listingTitle,
    description: 'A test listing.',
    priceUgx: price ?? 100000 + index,
    priceUnit: ListingPriceUnit.month,
    area: area,
    amenities: const [],
    imageUrls: const [],
    thumbnailUrl: 'https://example.test/listing.jpg',
    searchKeywords: [listingTitle.toLowerCase(), 'room'],
    status: ListingStatus.approved,
    ratingAvg: 0,
    ratingCount: 0,
    isFeatured: false,
    createdAt: DateTime.utc(2026).add(Duration(seconds: index)),
  );
}
