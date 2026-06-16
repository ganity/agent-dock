import 'package:image_picker/image_picker.dart';

class PickedImageAttachment {
  const PickedImageAttachment({
    required this.filename,
    required this.contentType,
    required this.bytes,
  });

  final String filename;
  final String contentType;
  final List<int> bytes;
}

enum ImageAttachmentSource { gallery, camera }

abstract class ImageAttachmentPicker {
  Future<PickedImageAttachment?> pickImage({
    ImageAttachmentSource source = ImageAttachmentSource.gallery,
  });
}

class GalleryImageAttachmentPicker implements ImageAttachmentPicker {
  GalleryImageAttachmentPicker({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedImageAttachment?> pickImage({
    ImageAttachmentSource source = ImageAttachmentSource.gallery,
  }) async {
    final file = await _picker.pickImage(source: _imagePickerSource(source));
    if (file == null) {
      return null;
    }

    return PickedImageAttachment(
      filename: file.name,
      contentType: _contentTypeForFilename(file.name),
      bytes: await file.readAsBytes(),
    );
  }
}

ImageSource _imagePickerSource(ImageAttachmentSource source) {
  return switch (source) {
    ImageAttachmentSource.gallery => ImageSource.gallery,
    ImageAttachmentSource.camera => ImageSource.camera,
  };
}

String _contentTypeForFilename(String filename) {
  final lower = filename.toLowerCase();
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  return 'image/jpeg';
}
