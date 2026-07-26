/// Tim2Tox Dart Package
///
/// This package provides Dart bindings and SDK platform implementation
/// for the Tim2Tox framework.

// Models
export 'models/chat_message.dart';

// Service layer (includes Tim2ToxFfi)
export 'service/ffi_chat_service.dart';

// FFI bindings (hide Tim2ToxFfi to avoid conflict with service layer)
export 'ffi/tim2tox_ffi.dart' hide Tim2ToxFfi;

// Instance-scoped context for multi-instance
export 'instance/tim2tox_instance.dart';

// SDK platform
export 'sdk/tim2tox_sdk_platform.dart';

// Interfaces
export 'interfaces/preferences_service.dart';
export 'interfaces/extended_preferences_service.dart';
export 'interfaces/logger_service.dart';
export 'interfaces/bootstrap_service.dart';
export 'interfaces/event_bus.dart';
export 'interfaces/event_bus_provider.dart';
export 'interfaces/conversation_manager_provider.dart';
export 'interfaces/scratch_file_service.dart';

// Models
export 'models/fake_models.dart';
