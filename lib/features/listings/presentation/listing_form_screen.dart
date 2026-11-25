import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/admin_widgets.dart';
import '../../../core/widgets/app_network_image.dart';
import '../../../core/utils/phone_normalizer.dart';
import '../../../core/widgets/error_view.dart';
import '../../../core/widgets/loading_view.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/app_config.dart';
import '../data/media_uploader.dart';
import '../../admin/presentation/admin_copy.dart';
import 'app_config_providers.dart';
import '../data/listing.dart';
import 'listing_copy.dart';
import 'listings_providers.dart';
import 'listing_video_player.dart';

class ListingFormScreen extends ConsumerStatefulWidget {
  const ListingFormScreen({this.listing, this.adminMode = false, super.key});

  final Listing? listing;
  final bool adminMode;

  @override
  ConsumerState<ListingFormScreen> createState() => _ListingFormScreenState();
}

class _ListingFormScreenState extends ConsumerState<ListingFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _bedroomsController = TextEditingController();
  final _bathroomsController = TextEditingController();
  final _phoneController = TextEditingController();
  final _imageUrlsController = TextEditingController();
  final _ownerIdController = TextEditingController();
  final _amenityController = TextEditingController();
  final _amenities = <String>[];
  final _selectedImages = <PickedMediaFile>[];
  final _imageUploadProgress = <int, double>{};
  PickedMediaFile? _selectedVideo;
  bool _removeExistingVideo = false;
  double? _videoUploadProgress;
  CancelToken? _videoCancelToken;
  String? _videoStatusMessage;
  late ListingType _type;
  late ListingPriceUnit _priceUnit;
  String? _category;
  String? _area;
  bool _isSaving = false;
  bool _isDirty = false;
  Listing? _currentListing;

  bool get _isEditing => _currentListing != null;

  @override
  void initState() {
    super.initState();
    _currentListing = widget.listing;
    final listing = widget.listing;
    _titleController.text = listing?.title ?? '';
    _descriptionController.text = listing?.description ?? '';
    _priceController.text = listing?.priceUgx.toString() ?? '';
    _bedroomsController.text = listing?.bedrooms?.toString() ?? '';
    _bathroomsController.text = listing?.bathrooms?.toString() ?? '';
    _phoneController.text = listing?.ownerPhone ?? '';
    _imageUrlsController.text = listing?.imageUrls.join('\n') ?? '';
    _ownerIdController.text = listing?.ownerId ?? '';
    _amenities.addAll(listing?.amenities ?? const []);
    _type = listing?.type ?? ListingType.property;
    _priceUnit = listing?.priceUnit ?? ListingPriceUnit.month;
    _category = listing?.category;
    _area = listing?.area;
    for (final controller in [
      _titleController,
      _descriptionController,
      _priceController,
      _bedroomsController,
      _bathroomsController,
      _phoneController,
      _ownerIdController,
    ]) {
      controller.addListener(_markDirty);
    }
    _imageUrlsController.addListener(_markImageUrlsDirty);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _bedroomsController.dispose();
    _bathroomsController.dispose();
    _phoneController.dispose();
    _imageUrlsController.dispose();
    _ownerIdController.dispose();
    _amenityController.dispose();
    _videoCancelToken?.cancel('Listing form closed.');
    super.dispose();
  }

  void _markDirty() {
    if (!_isDirty && mounted) setState(() => _isDirty = true);
  }

  void _markImageUrlsDirty() {
    if (mounted) setState(() => _isDirty = true);
  }


  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(currentAppUserProvider).asData?.value;
    final isAdmin = widget.adminMode && currentUser?.canAccessAdmin == true;
    return PopScope(
      canPop: !_isDirty && !_isSaving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _isSaving || !_isDirty) return;
        final discard = await _confirmDiscard();
        if (!context.mounted) return;
        if (discard) context.pop(false);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _isEditing ? ListingCopy.editTitle : ListingCopy.createTitle,
          ),
        ),
        body: ref
            .watch(appConfigProvider)
            .when(
              loading: () => widget.adminMode
                  ? const AdminLoadingList(itemCount: 4)
                  : const LoadingView(),
              error: (error, stackTrace) {
                final message = error is AppException
                    ? error.message
                    : ListingCopy.invalidOwner;
                return widget.adminMode
                    ? AdminErrorState(
                        message: message,
                        retryLabel: ListingCopy.retry,
                        onRetry: () => ref.invalidate(appConfigProvider),
                      )
                    : ErrorView(
                        message: message,
                        retryLabel: ListingCopy.retry,
                        onRetry: () => ref.invalidate(appConfigProvider),
                      );
              },
              data: (config) => widget.adminMode
                  ? _adminForm(config, isAdmin)
                  : _legacyForm(config, isAdmin),
            ),
      ),
    );
  }

  Widget _adminForm(AppConfig config, bool isAdmin) => Form(
    key: _formKey,
    child: Column(
      children: [
        Expanded(
          child: AdminContent(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= AppLayout.wideBreakpoint
                    ? 2
                    : 1;
                final width = columns == 1
                    ? constraints.maxWidth
                    : (constraints.maxWidth - AppSpacing.md) / columns;
                return ListView(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  children: [
                    Wrap(
                      spacing: AppSpacing.md,
                      runSpacing: AppSpacing.md,
                      children: [
                        SizedBox(width: width, child: _basicsSection()),
                        SizedBox(width: width, child: _priceSection()),
                        SizedBox(width: width, child: _locationSection(config)),
                        SizedBox(width: width, child: _detailsSection()),
                        SizedBox(
                          width: width,
                          child: _photosSection(allowDeviceUpload: true),
                        ),
                        SizedBox(width: width, child: _contactSection(isAdmin)),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Material(
            elevation: AppElevation.medium,
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: AppInsets.phonePage,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isSaving ? null : _cancel,
                      child: const Text(ListingCopy.cancel),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: FilledButton(
                      onPressed: _isSaving ? null : () => _save(isAdmin),
                      child: _isSaving
                          ? const SizedBox.square(
                              dimension: AppSpacing.lg,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text(ListingCopy.save),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _legacyForm(AppConfig config, bool isAdmin) => Form(
    key: _formKey,
    child: ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _basicsFields(),
        _listingTypeField(),
        _categoryField(config),
        _areaField(config),
        _priceField(),
        _priceUnitField(),
        _bedroomFields(),
        _amenitiesEditor(),
        _phoneField(),
        _photosEditor(allowDeviceUpload: true),
        if (isAdmin && !_isEditing) _ownerIdField(),
        if (isAdmin && !_isEditing)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.xxs),
            child: Text(ListingCopy.adminCreateApproved),
          ),
        FilledButton(
          onPressed: _isSaving ? null : () => _save(isAdmin),
          child: _isSaving
              ? const CircularProgressIndicator()
              : const Text(ListingCopy.save),
        ),
      ],
    ),
  );

  Widget _basicsSection() =>
      AdminSectionCard(title: AdminCopy.basics, child: _basicsFields());

  Widget _basicsFields() => Column(
    children: [
      _textField(
        controller: _titleController,
        label: ListingCopy.title,
        maxLength: 100,
        validator: _required,
      ),
      _textField(
        controller: _descriptionController,
        label: ListingCopy.description,
        maxLength: 3000,
        maxLines: 5,
        validator: _required,
      ),
    ],
  );

  Widget _priceSection() => AdminSectionCard(
    title: AdminCopy.priceAndType,
    child: Column(
      children: [_listingTypeField(), _priceField(), _priceUnitField()],
    ),
  );

  Widget _locationSection(AppConfig config) => AdminSectionCard(
    title: AdminCopy.location,
    child: Column(children: [_categoryField(config), _areaField(config)]),
  );

  Widget _detailsSection() => AdminSectionCard(
    title: AdminCopy.details,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_bedroomFields(), _amenitiesEditor()],
    ),
  );

  Widget _photosSection({required bool allowDeviceUpload}) => AdminSectionCard(
    title: AdminCopy.photos,
    child: _photosEditor(allowDeviceUpload: allowDeviceUpload),
  );

  Widget _contactSection(bool isAdmin) => AdminSectionCard(
    title: AdminCopy.contact,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _phoneField(),
        if (isAdmin && !_isEditing) ...[
          _ownerIdField(),
          Text(
            ListingCopy.adminCreateApproved,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    ),
  );

  Widget _listingTypeField() => DropdownButtonFormField<ListingType>(
    initialValue: _type,
    decoration: const InputDecoration(labelText: ListingCopy.type),
    items: const [
      DropdownMenuItem(
        value: ListingType.property,
        child: Text(ListingCopy.property),
      ),
      DropdownMenuItem(
        value: ListingType.service,
        child: Text(ListingCopy.service),
      ),
    ],
    onChanged: _isSaving
        ? null
        : (value) {
            if (value == null) return;
            setState(() {
              _type = value;
              _isDirty = true;
            });
          },
  );

  Widget _categoryField(AppConfig config) => DropdownButtonFormField<String>(
    initialValue: _validOrNull(_category, config.activeCategoryLabels),
    decoration: const InputDecoration(labelText: ListingCopy.category),
    validator: (value) => value == null ? ListingCopy.required : null,
    items: [
      for (final category in config.activeCategoryLabels)
        DropdownMenuItem(value: category, child: Text(category)),
    ],
    onChanged: _isSaving
        ? null
        : (value) => setState(() {
            _category = value;
            _isDirty = true;
          }),
  );

  Widget _areaField(AppConfig config) => DropdownButtonFormField<String>(
    initialValue: _validOrNull(_area, config.activeAreaLabels),
    decoration: const InputDecoration(labelText: ListingCopy.area),
    validator: (value) => value == null ? ListingCopy.required : null,
    items: [
      for (final area in config.activeAreaLabels)
        DropdownMenuItem(value: area, child: Text(area)),
    ],
    onChanged: _isSaving
        ? null
        : (value) => setState(() {
            _area = value;
            _isDirty = true;
          }),
  );

  Widget _priceField() => _textField(
    controller: _priceController,
    label: ListingCopy.price,
    keyboardType: TextInputType.number,
    validator: (value) {
      final parsed = int.tryParse(value?.trim() ?? '');
      return parsed == null || parsed <= 0 ? ListingCopy.invalidPrice : null;
    },
  );

  Widget _priceUnitField() => DropdownButtonFormField<ListingPriceUnit>(
    initialValue: _priceUnit,
    decoration: const InputDecoration(labelText: ListingCopy.priceUnit),
    items: [
      for (final unit in ListingPriceUnit.values)
        DropdownMenuItem(value: unit, child: Text(unit.name)),
    ],
    onChanged: _isSaving
        ? null
        : (value) {
            if (value == null) return;
            setState(() {
              _priceUnit = value;
              _isDirty = true;
            });
          },
  );

  Widget _bedroomFields() => _type == ListingType.property
      ? Column(
          children: [
            _textField(
              controller: _bedroomsController,
              label: ListingCopy.bedrooms,
              keyboardType: TextInputType.number,
              validator: _optionalPositiveInt,
            ),
            _textField(
              controller: _bathroomsController,
              label: ListingCopy.bathrooms,
              keyboardType: TextInputType.number,
              validator: _optionalPositiveInt,
            ),
          ],
        )
      : const SizedBox.shrink();

  Widget _amenitiesEditor() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        ListingCopy.amenities,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _amenityController,
              decoration: const InputDecoration(
                labelText: ListingCopy.addAmenity,
              ),
              onSubmitted: (_) => _addAmenity(),
            ),
          ),
          IconButton(
            tooltip: ListingCopy.addAmenity,
            onPressed: _isSaving ? null : _addAmenity,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          for (final amenity in _amenities)
            InputChip(
              label: Text(amenity),
              onDeleted: _isSaving
                  ? null
                  : () => setState(() {
                      _amenities.remove(amenity);
                      _isDirty = true;
                    }),
            ),
        ],
      ),
    ],
  );

  Widget _phoneField() => _textField(
    controller: _phoneController,
    label: ListingCopy.contactPhone,
    keyboardType: TextInputType.phone,
    validator: (value) => normalizeUgandanPhone(value ?? '') == null
        ? ListingCopy.invalidPhone
        : null,
  );

  Widget _imageUrlsField() => _textField(
    controller: _imageUrlsController,
    label: ListingCopy.imageUrls,
    helperText: ListingCopy.imageUrlHelp,
    maxLines: 3,
  );

  Widget _photosEditor({required bool allowDeviceUpload}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _imageUrlsField(),
      if (allowDeviceUpload) ...[
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            OutlinedButton.icon(
              onPressed: _isSaving ? null : _pickImages,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text(ListingCopy.addImages),
            ),
            OutlinedButton.icon(
              onPressed: _isSaving ? null : _pickVideo,
              icon: const Icon(Icons.video_library_outlined),
              label: const Text(ListingCopy.addVideo),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: AppSpacing.xs),
          child: Text(ListingCopy.dragDropHint),
        ),
      ],
      if (_existingImageUrls.isEmpty && _selectedImages.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Text(ListingCopy.noImagesSelected),
        ),
      if (_existingImageUrls.isNotEmpty || _selectedImages.isNotEmpty)
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (var index = 0; index < _existingImageUrls.length; index++)
              _existingImageCard(index, _existingImageUrls[index]),
            for (var index = 0; index < _selectedImages.length; index++)
              _selectedImageCard(index, _selectedImages[index]),
          ],
        ),
      const SizedBox(height: AppSpacing.md),
      if (_selectedVideo == null &&
          !_removeExistingVideo &&
          _currentListing?.videoUrl != null) ...[
        Text(
          ListingCopy.currentVideo,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        ListingVideoPlayer(
          videoUrl: _currentListing!.videoUrl,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _isSaving ? null : _removeCurrentVideo,
            icon: const Icon(Icons.delete_outline),
            label: const Text(ListingCopy.removeVideo),
          ),
        ),
      ],
      if (_selectedVideo case final video?) ...[
        Text(
          '${video.name} (${_formatFileSize(video.sizeInBytes)})',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        ListingVideoPlayer(selectedFile: video),
        if (_videoUploadProgress case final progress?) ...[
          const SizedBox(height: AppSpacing.xs),
          LinearProgressIndicator(value: progress.clamp(0, 1)),
          Text('${ListingCopy.uploadingVideo} ${(progress * 100).round()}%'),
          TextButton.icon(
            onPressed: _isSaving ? () => _videoCancelToken?.cancel() : null,
            icon: const Icon(Icons.cancel_outlined),
            label: const Text(ListingCopy.cancelUpload),
          ),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _isSaving ? null : _removeSelectedVideo,
              icon: const Icon(Icons.close),
              label: const Text(ListingCopy.removeSelection),
            ),
          ),
      ],
      if (_videoStatusMessage case final message?) ...[
        const SizedBox(height: AppSpacing.xs),
        Text(
          message,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    ],
  );

  List<String> get _existingImageUrls => _imageUrlsController.text
      .split(RegExp(r'[\r\n]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .take(ListingMediaValidator.maxImages)
      .toList(growable: false);

  Widget _existingImageCard(int index, String url) => SizedBox(
    width: AppLayout.imagePreviewSize + 48,
    child: Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: AppNetworkImage(
            imageUrl: url,
            semanticLabel: AdminCopy.imagePreview,
            width: AppLayout.imagePreviewSize + 48,
            height: AppLayout.imagePreviewSize,
          ),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            IconButton(
              tooltip: ListingCopy.moveImageEarlier,
              onPressed: !_isSaving && index > 0
                  ? () => _moveExistingImage(index, index - 1)
                  : null,
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton(
              tooltip: ListingCopy.removeImage,
              onPressed: _isSaving ? null : () => _removeExistingImage(index),
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              tooltip: ListingCopy.moveImageLater,
              onPressed: !_isSaving && index < _existingImageUrls.length - 1
                  ? () => _moveExistingImage(index, index + 1)
                  : null,
              icon: const Icon(Icons.arrow_forward),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _selectedImageCard(int index, PickedMediaFile image) => SizedBox(
    width: AppLayout.imagePreviewSize + 48,
    child: Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Image.memory(
            image.bytes,
            width: AppLayout.imagePreviewSize + 48,
            height: AppLayout.imagePreviewSize,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => SizedBox(
              width: AppLayout.imagePreviewSize + 48,
              height: AppLayout.imagePreviewSize,
              child: const Icon(Icons.broken_image_outlined),
            ),
          ),
        ),
        Text(image.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (_imageUploadProgress[index] case final progress?) ...[
          const SizedBox(height: AppSpacing.xxs),
          LinearProgressIndicator(value: progress.clamp(0, 1)),
          Text('${(progress * 100).round()}%'),
        ],
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            IconButton(
              tooltip: ListingCopy.moveImageEarlier,
              onPressed: !_isSaving && index > 0
                  ? () => _moveSelectedImage(index, index - 1)
                  : null,
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton(
              tooltip: ListingCopy.removeImage,
              onPressed: _isSaving ? null : () => _removeSelectedImage(index),
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              tooltip: ListingCopy.moveImageLater,
              onPressed: !_isSaving && index < _selectedImages.length - 1
                  ? () => _moveSelectedImage(index, index + 1)
                  : null,
              icon: const Icon(Icons.arrow_forward),
            ),
          ],
        ),
      ],
    ),
  );

  void _moveExistingImage(int from, int to) {
    final urls = _existingImageUrls.toList();
    final image = urls.removeAt(from);
    urls.insert(to, image);
    _imageUrlsController.text = urls.join('\n');
  }

  void _removeExistingImage(int index) {
    final urls = _existingImageUrls.toList()..removeAt(index);
    _imageUrlsController.text = urls.join('\n');
  }

  void _moveSelectedImage(int from, int to) {
    setState(() {
      final image = _selectedImages.removeAt(from);
      _selectedImages.insert(to, image);
      final progress = _imageUploadProgress.remove(from);
      if (progress != null) _imageUploadProgress[to] = progress;
      _isDirty = true;
    });
  }

  void _removeSelectedImage(int index) {
    setState(() {
      _selectedImages.removeAt(index);
      _imageUploadProgress.remove(index);
      _isDirty = true;
    });
  }

  void _removeCurrentVideo() {
    setState(() {
      _removeExistingVideo = true;
      _videoStatusMessage = null;
      _isDirty = true;
    });
  }

  void _removeSelectedVideo() {
    setState(() {
      _selectedVideo = null;
      _videoUploadProgress = null;
      _videoStatusMessage = null;
      _isDirty = true;
    });
  }

  String _formatFileSize(int bytes) {
    final mebibytes = bytes / (1024 * 1024);
    return '${mebibytes.toStringAsFixed(1)} MiB';
  }

  Future<void> _pickImages() async {
    try {
      final selected = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      );
      if (!mounted || selected.isEmpty) return;
      final currentUrlCount = _imageUrlsController.text
          .split(RegExp(r'[\r\n]+'))
          .where((url) => url.trim().isNotEmpty)
          .length;
      final hiddenImageCount = _currentListing?.imageStoragePaths
              .whereType<String>()
              .length ??
          0;
      if (currentUrlCount +
              hiddenImageCount +
              _selectedImages.length +
              selected.length >
          ListingMediaValidator.maxImages) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text(ListingCopy.maxImages)));
        return;
      }
      final files = <PickedMediaFile>[];
      for (final file in selected) {
        final picked = PickedMediaFile(
          name: file.name,
          path: file.path,
          bytes: await file.readAsBytes(),
        );
        ListingMediaValidator.imageFormat(picked);
        files.add(picked);
      }
      setState(() {
        _selectedImages.addAll(files);
        _isDirty = true;
      });
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(ListingCopy.imagePickerError)),
        );
      }
    }
  }

  Future<void> _pickVideo() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['mp4', 'webm'],
      );
      if (!mounted || file == null) return;
      final selected = PickedMediaFile(
        name: file.name,
        path: file.path,
        bytes: await file.readAsBytes(),
      );
      ListingMediaValidator.videoFormat(selected);
      setState(() {
        _selectedVideo = selected;
        _removeExistingVideo = false;
        _videoUploadProgress = null;
        _isDirty = true;
      });
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(ListingCopy.videoPickerError)),
        );
      }
    }
  }

  Widget _ownerIdField() => _textField(
    controller: _ownerIdController,
    label: ListingCopy.ownerId,
    validator: (value) =>
        value == null || value.trim().isEmpty ? ListingCopy.invalidOwner : null,
  );

  Future<void> _cancel() async {
    if (_isSaving) return;
    if (!_isDirty) {
      context.pop(false);
      return;
    }
    final discard = await _confirmDiscard();
    if (!mounted) return;
    if (discard) context.pop(false);
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    String? helperText,
    int? maxLength,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: TextFormField(
      controller: controller,
      enabled: !_isSaving,
      maxLength: maxLength,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        border: const OutlineInputBorder(),
      ),
      validator: validator,
    ),
  );

  void _addAmenity() {
    final value = _amenityController.text.trim();
    if (value.isEmpty || _amenities.contains(value)) return;
    setState(() {
      _amenities.add(value);
      _amenityController.clear();
      _isDirty = true;
    });
  }

  Future<void> _save(bool isAdmin) async {
    if (!_formKey.currentState!.validate()) return;
    final normalizedPhone = normalizeUgandanPhone(_phoneController.text);
    if (normalizedPhone == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(ListingCopy.invalidPhone)),
      );
      return;
    }

    setState(() {
      _isSaving = true;
      _videoStatusMessage = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final uploader = ref.read(mediaUploaderProvider);
      final repository = ref.read(listingsRepositoryProvider);
      final normalizedImageUrls = await uploader.uploadImages(
        _imageUrlsController.text
            .split(RegExp(r'[\r\n]+'))
            .map((url) => url.trim())
            .where((url) => url.isNotEmpty)
            .toList(),
      );

      final oldListing = _currentListing;
      final storagePathsByUrl = <String, String>{};
      final hiddenStoragePaths = <String>[];
      if (oldListing != null) {
        for (var index = 0; index < oldListing.imageUrls.length; index++) {
          if (index >= oldListing.imageStoragePaths.length) continue;
          final path = oldListing.imageStoragePaths[index];
          if (path == null) continue;
          final url = oldListing.imageUrls[index];
          if (url.isEmpty) {
            hiddenStoragePaths.add(path);
          } else {
            storagePathsByUrl[url] = path;
          }
        }
      }
      if (normalizedImageUrls.length +
              hiddenStoragePaths.length +
              _selectedImages.length >
          ListingMediaValidator.maxImages) {
        throw const FormatException(ListingCopy.maxImages);
      }

      final previousImagePaths =
          oldListing?.imageStoragePaths.whereType<String>().toSet() ??
          const <String>{};
      final retainedStoragePaths = [
        for (final url in normalizedImageUrls) storagePathsByUrl[url],
        ...hiddenStoragePaths,
      ];
      final listingImageUrls = [
        ...normalizedImageUrls,
        ...List<String>.filled(hiddenStoragePaths.length, ''),
      ];

      var workingListing = Listing(
        id: oldListing?.id ?? '',
        ownerId: oldListing?.ownerId ??
            (isAdmin ? _ownerIdController.text.trim() : ''),
        ownerName: oldListing?.ownerName ?? '',
        ownerPhone: normalizedPhone,
        type: _type,
        category: _category!,
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        priceUgx: int.parse(_priceController.text.trim()),
        priceUnit: _priceUnit,
        area: _area!,
        address: oldListing?.address,
        geo: oldListing?.geo,
        bedrooms: _type == ListingType.property
            ? int.tryParse(_bedroomsController.text.trim())
            : null,
        bathrooms: _type == ListingType.property
            ? int.tryParse(_bathroomsController.text.trim())
            : null,
        amenities: List.unmodifiable(_amenities),
        imageUrls: listingImageUrls,
        imageStoragePaths: retainedStoragePaths,
        thumbnailUrl: normalizedImageUrls.isEmpty ? '' : normalizedImageUrls.first,
        videoUrl: oldListing?.videoUrl,
        videoStoragePath: oldListing?.videoStoragePath,
        status: ListingStatus.pending,
        rejectionReason: oldListing?.rejectionReason,
        ratingAvg: oldListing?.ratingAvg ?? 0,
        ratingCount: oldListing?.ratingCount ?? 0,
        searchKeywords: const [],
        isFeatured: oldListing?.isFeatured ?? false,
        createdAt: oldListing?.createdAt,
        updatedAt: oldListing?.updatedAt,
      );

      if (!_isEditing) {
        workingListing = await repository.create(
          workingListing,
          ownerId: isAdmin ? _ownerIdController.text.trim() : null,
        );
        if (mounted) {
          setState(() => _currentListing = workingListing);
        } else {
          _currentListing = workingListing;
        }
      }

      setState(() => _imageUploadProgress.clear());
      final uploadedImages = _selectedImages.isEmpty
          ? const <UploadedListingImage>[]
          : await uploader.uploadPickedImages(
              List<PickedMediaFile>.from(_selectedImages),
              listingId: workingListing.id,
              ownerId: workingListing.ownerId,
              onUploadStarted: (index, _) {
                if (!mounted) return;
                setState(() => _imageUploadProgress[index] = 0);
              },
              onProgress: (index, _, progress) {
                if (!mounted) return;
                setState(() => _imageUploadProgress[index] = progress);
              },
            );

      UploadedListingVideo? uploadedVideo;
      final shouldUploadVideo = _selectedVideo != null;
      final previousVideoPath = oldListing?.videoStoragePath;
      if (shouldUploadVideo) {
        final video = _selectedVideo!;
        _videoCancelToken = CancelToken();
        if (mounted) {
          setState(() => _videoUploadProgress = 0);
        }
        try {
          uploadedVideo = await uploader.uploadPickedVideo(
            video,
            listingId: workingListing.id,
            ownerId: workingListing.ownerId,
            cancelToken: _videoCancelToken!,
            onProgress: (progress) {
              if (!mounted) return;
              setState(() => _videoUploadProgress = progress);
            },
          );
        } finally {
          _videoCancelToken = null;
          if (mounted) setState(() => _videoUploadProgress = null);
        }
      }

      var nextVideoStoragePath = workingListing.videoStoragePath;
      var clearVideo = false;
      if (uploadedVideo != null) {
        nextVideoStoragePath = uploadedVideo.storagePath;
      } else if (_removeExistingVideo) {
        nextVideoStoragePath = null;
        clearVideo = previousVideoPath != null ||
            (oldListing?.videoUrl?.trim().isNotEmpty ?? false);
      }

      final finalImageUrls = [
        ...workingListing.imageUrls,
        ...uploadedImages.map((_) => ''),
      ];
      final finalImageStoragePaths = [
        ...workingListing.imageStoragePaths,
        ...uploadedImages.map((image) => image.storagePath),
      ];
      final completeListing = workingListing.copyWith(
        imageUrls: finalImageUrls,
        imageStoragePaths: finalImageStoragePaths,
        thumbnailUrl: normalizedImageUrls.isEmpty
            ? ''
            : normalizedImageUrls.first,
        videoUrl: uploadedVideo?.storagePath ?? nextVideoStoragePath,
        videoStoragePath: nextVideoStoragePath,
        clearVideo: clearVideo,
      );

      final hasNewMedia =
          uploadedImages.isNotEmpty || uploadedVideo != null || _removeExistingVideo;
      final needsUpdate = oldListing != null || hasNewMedia;
      var persistedListing = completeListing;
      if (needsUpdate) {
        try {
          persistedListing = await repository.update(completeListing);
        } catch (error, stackTrace) {
          final cleanup = <Future<void>>[];
          if (uploadedImages.isNotEmpty) {
            cleanup.add(
              uploader.deleteImages(
                uploadedImages.map((image) => image.storagePath).toList(),
              ),
            );
          }
          if (uploadedVideo != null) {
            cleanup.add(uploader.deleteVideo(uploadedVideo.storagePath));
          }
          if (cleanup.isNotEmpty) {
            await Future.wait(
              cleanup.map((future) => future.catchError((_) {})),
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      }

      final removedImagePaths = previousImagePaths
          .difference(
            persistedListing.imageStoragePaths.whereType<String>().toSet(),
          )
          .toList();
      final cleanupWarnings = <String>[];
      if (removedImagePaths.isNotEmpty) {
        try {
          await uploader.deleteImages(removedImagePaths);
        } on AppException catch (error) {
          cleanupWarnings.add(
            '${ListingCopy.imageCleanupWarning} ${error.message}',
          );
        }
      }
      final shouldDeletePreviousVideo = previousVideoPath != null &&
          previousVideoPath != persistedListing.videoStoragePath &&
          (uploadedVideo != null || _removeExistingVideo);
      if (shouldDeletePreviousVideo) {
        try {
          await uploader.deleteVideo(previousVideoPath);
        } on AppException catch (error) {
          cleanupWarnings.add(
            '${ListingCopy.videoCleanupWarning} ${error.message}',
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _selectedImages.clear();
        _imageUploadProgress.clear();
        _selectedVideo = null;
        _removeExistingVideo = false;
        _videoUploadProgress = null;
        _videoStatusMessage = null;
        _currentListing = persistedListing;
        _isDirty = false;
      });
      final baseMessage = oldListing != null
          ? ListingCopy.updated
          : ListingCopy.created;
      if (cleanupWarnings.isNotEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text('$baseMessage ${cleanupWarnings.join(' ')}')),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text(baseMessage)));
      }
      context.pop(true);
    } on AppException catch (error) {
      if (mounted) {
        setState(() => _videoStatusMessage = error.message);
        messenger.showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _videoStatusMessage = error.message);
        messenger.showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (error) {
      if (mounted) {
        const message =
            'Unable to save this listing. Check your connection and try again.';
        setState(() => _videoStatusMessage = message);
        messenger.showSnackBar(const SnackBar(content: Text(message)));
      }
    } finally {
      _videoCancelToken = null;
      if (mounted) {
        setState(() {
          _isSaving = false;
          _videoUploadProgress = null;
        });
      }
    }
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? ListingCopy.required : null;

  String? _optionalPositiveInt(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parsed = int.tryParse(value.trim());
    return parsed == null || parsed <= 0 ? ListingCopy.invalidCount : null;
  }

  String? _validOrNull(String? value, List<String> values) =>
      values.contains(value) ? value : null;

  Future<bool> _confirmDiscard() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(ListingCopy.confirmDiscardTitle),
          content: const Text(ListingCopy.confirmDiscardMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(ListingCopy.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(ListingCopy.confirm),
            ),
          ],
        ),
      ) ??
      false;
}
