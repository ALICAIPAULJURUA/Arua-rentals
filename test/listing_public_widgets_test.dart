import 'package:arua_rentals/features/listings/data/listing.dart';
import 'package:arua_rentals/features/listings/data/listing_sort.dart';
import 'package:arua_rentals/features/listings/presentation/listing_card.dart';
import 'package:arua_rentals/features/listings/presentation/listing_empty_state.dart';
import 'package:arua_rentals/features/listings/presentation/public_listings_screen.dart';
import 'package:arua_rentals/features/listings/presentation/listings_browse_provider.dart';
import 'package:arua_rentals/features/listings/presentation/app_config_providers.dart';
import 'package:arua_rentals/features/listings/data/app_config.dart';
import 'package:arua_rentals/features/auth/presentation/auth_providers.dart';
import 'package:arua_rentals/features/auth/data/app_user.dart';
import 'package:arua_rentals/features/auth/data/auth_repository.dart';
import 'package:arua_rentals/features/chat/presentation/chat_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

void main() {
  testWidgets('listing card shows the listing title and formatted UGX price', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseAuthStateProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 376,
                child: ListingCard(listing: _listing(ownerVerified: true)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Two-bedroom rental'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('UGX 350,000 / month'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
  });

  testWidgets('signed-out browse shows denormalized Verified badge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseAuthStateProvider.overrideWith((ref) => Stream.value(null)),
          currentAppUserProvider.overrideWith((ref) async => null),
          appConfigProvider.overrideWith(
            (ref) async => const AppConfig(categories: [], areas: []),
          ),
          featuredListingsProvider.overrideWith((ref) async => []),
          listingsBrowseProvider.overrideWith(_LoadedBrowseController.new),
        ],
        child: const MaterialApp(home: PublicListingsScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Verified'), findsOneWidget);
  });

  testWidgets('empty state offers a clear-filters action', (tester) async {
    var cleared = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListingEmptyState(onClearFilters: () => cleared = true),
        ),
      ),
    );

    expect(find.text('No listings match your search'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    expect(cleared, isTrue);
  });

  testWidgets('public listing grid fits phone and wide layouts', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(360, 800), const Size(1280, 900)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(size),
          overrides: [
            currentAppUserProvider.overrideWith((ref) async => null),
            appConfigProvider.overrideWith(
              (ref) async => const AppConfig(categories: [], areas: []),
            ),
            featuredListingsProvider.overrideWith((ref) async => []),
            listingsBrowseProvider.overrideWith(_LoadedBrowseController.new),
          ],
          child: const MaterialApp(home: PublicListingsScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Two-bedroom rental'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('home shows featured and public landing sections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseAuthStateProvider.overrideWith((ref) => Stream.value(null)),
          currentAppUserProvider.overrideWith((ref) async => null),
          appConfigProvider.overrideWith(
            (ref) async => const AppConfig(
              categories: [
                ConfigOption(id: 'rentals', label: 'Rentals', active: true),
              ],
              areas: [],
            ),
          ),
          featuredListingsProvider.overrideWith(
            (ref) async => [_listing(ownerVerified: true)],
          ),
          listingsBrowseProvider.overrideWith(_LoadedBrowseController.new),
        ],
        child: const MaterialApp(home: PublicListingsScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Find a place to call home in Arua'), findsOneWidget);
    expect(find.text('Rentals'), findsWidgets);
    expect(find.text('Featured'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Latest listings'), findsOneWidget);
    expect(find.text('Are you a landlord or provider?'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('List with us lets a signed-in tenant submit a role request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _RecordingAuthRepository();
    final authUser = supabase.User.fromJson({
      'id': 'tenant-id',
      'aud': 'authenticated',
      'role': 'authenticated',
      'email': 'tenant@example.com',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
      'created_at': '2026-01-01T00:00:00.000Z',
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(repository),
          supabaseAuthStateProvider.overrideWith(
            (ref) => Stream.value(authUser),
          ),
          currentAppUserProvider.overrideWith(
            (ref) async => const AppUser(
              uid: 'tenant-id',
              name: 'Arua Tenant',
              email: 'tenant@example.com',
              phone: '+256701234567',
              role: UserRole.tenant,
            ),
          ),
          totalUnreadChatsProvider.overrideWith((ref) => 0),
          appConfigProvider.overrideWith(
            (ref) async => const AppConfig(categories: [], areas: []),
          ),
          featuredListingsProvider.overrideWith((ref) async => []),
          listingsBrowseProvider.overrideWith(_LoadedBrowseController.new),
        ],
        child: const MaterialApp(home: PublicListingsScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('List with us'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Request listing access'), findsOneWidget);
    await tester.tap(find.text('Request service provider access'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(repository.requestedRole, RoleRequest.provider);
    expect(
      find.text(
        'Request submitted. You can list after an administrator approves it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'a claimed super admin can use List with us despite an old request',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _publicListingRouter();
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseAuthStateProvider.overrideWith(
              (ref) => Stream.value(
                supabase.User.fromJson({
                  'id': 'super-admin-id',
                  'aud': 'authenticated',
                  'role': 'authenticated',
                  'email': 'super@example.com',
                  'app_metadata': {'super_admin': true},
                  'user_metadata': <String, dynamic>{},
                  'created_at': '2026-01-01T00:00:00.000Z',
                }),
              ),
            ),
            currentAppUserProvider.overrideWith(
              (ref) async => const AppUser(
                uid: 'super-admin-id',
                name: 'Super Admin',
                email: 'super@example.com',
                phone: '+256701234567',
                role: UserRole.superAdmin,
                roleRequest: RoleRequest.provider,
                hasSuperAdminClaim: true,
              ),
            ),
            totalUnreadChatsProvider.overrideWith((ref) => 0),
            appConfigProvider.overrideWith(
              (ref) async => const AppConfig(categories: [], areas: []),
            ),
            featuredListingsProvider.overrideWith((ref) async => []),
            listingsBrowseProvider.overrideWith(_LoadedBrowseController.new),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('List with us'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(router.routeInformationProvider.value.uri.path, '/provider');
      expect(
        find.text(
          'Your listing access request is awaiting administrator approval.',
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a super admin profile without its claim gets a clear message', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = _publicListingRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseAuthStateProvider.overrideWith(
            (ref) => Stream.value(
              supabase.User.fromJson({
                'id': 'super-admin-id',
                'aud': 'authenticated',
                'role': 'authenticated',
                'email': 'super@example.com',
                'app_metadata': <String, dynamic>{},
                'user_metadata': <String, dynamic>{},
                'created_at': '2026-01-01T00:00:00.000Z',
              }),
            ),
          ),
          currentAppUserProvider.overrideWith(
            (ref) async => const AppUser(
              uid: 'super-admin-id',
              name: 'Super Admin',
              email: 'super@example.com',
              phone: '+256701234567',
              role: UserRole.superAdmin,
              roleRequest: RoleRequest.provider,
            ),
          ),
          totalUnreadChatsProvider.overrideWith((ref) => 0),
          appConfigProvider.overrideWith(
            (ref) async => const AppConfig(categories: [], areas: []),
          ),
          featuredListingsProvider.overrideWith((ref) async => []),
          listingsBrowseProvider.overrideWith(_LoadedBrowseController.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('List with us'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.text(
        'Super-admin access is not active. Verify app_metadata.super_admin in Supabase Auth, then sign out and back in.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Your listing access request is awaiting administrator approval.',
      ),
      findsNothing,
    );
  });
}

GoRouter _publicListingRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const PublicListingsScreen(),
    ),
    GoRoute(
      path: '/provider',
      builder: (context, state) =>
          const Scaffold(body: Text('Listing workspace opened')),
    ),
    GoRoute(
      path: '/admin',
      builder: (context, state) =>
          const Scaffold(body: Text('Admin dashboard opened')),
    ),
  ],
);

class _RecordingAuthRepository implements AuthRepository {
  RoleRequest? requestedRole;

  @override
  Stream<supabase.User?> get authStateChanges => const Stream.empty();

  @override
  Stream<supabase.AuthState> get authEvents => const Stream.empty();

  @override
  supabase.User? get currentUser => null;

  @override
  Future<AppUser?> loadUser(
    String uid, {
    bool hasAdminClaim = false,
    bool hasSuperAdminClaim = false,
    String? authEmail,
  }) => throw UnimplementedError();

  @override
  Future<AppUser> loadOrCreateUser(supabase.User authUser) =>
      throw UnimplementedError();

  @override
  Future<RegistrationResult> register({
    required String email,
    required String password,
    required String name,
    required String phone,
    RoleRequest? roleRequest,
  }) => throw UnimplementedError();

  @override
  Future<void> login({required String email, required String password}) =>
      throw UnimplementedError();

  @override
  Future<void> refreshSession() async {}

  @override
  Future<void> logout() async {}

  @override
  Future<void> sendPasswordResetEmail(String email) =>
      throw UnimplementedError();

  @override
  Future<void> updatePassword(String password) => throw UnimplementedError();

  @override
  Future<AppUser> updateProfile({
    required String name,
    required String phone,
  }) => throw UnimplementedError();

  @override
  Future<void> requestRole({
    required AppUser profile,
    required RoleRequest requestedRole,
  }) async {
    this.requestedRole = requestedRole;
  }
}

class _LoadedBrowseController extends ListingsBrowseController {
  @override
  Future<ListingsBrowseState> build() async => ListingsBrowseState(
    items: [_listing(ownerVerified: true)],
    category: null,
    area: null,
    keyword: null,
    sort: ListingSort.newest,
    hasMore: false,
  );
}

Listing _listing({bool ownerVerified = false}) => Listing(
  id: 'listing-id',
  ownerId: 'owner-id',
  ownerName: 'Arua Rentals',
  ownerPhone: '+256700000000',
  type: ListingType.property,
  category: 'Rentals',
  title: 'Two-bedroom rental',
  description: 'A comfortable rental home.',
  priceUgx: 350000,
  priceUnit: ListingPriceUnit.month,
  area: 'Oli',
  amenities: const [],
  imageUrls: const [],
  thumbnailUrl: 'https://example.test/listing.jpg',
  searchKeywords: const [],
  status: ListingStatus.approved,
  ratingAvg: 0,
  ratingCount: 0,
  isFeatured: false,
  ownerVerified: ownerVerified,
);
