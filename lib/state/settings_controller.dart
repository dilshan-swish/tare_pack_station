import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_store.dart';
import '../models/foodics_settings.dart';
import '../models/headoffice_settings.dart';
import '../models/serial_settings.dart';
import '../models/weight_source_type.dart';

/// Provides the concrete [SettingsStore].
final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());

/// Overridden in [main] with the settings loaded from disk before the app
/// starts. Reading it without an override is a programming error.
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => throw UnimplementedError('initialSettingsProvider must be overridden'),
);

/// The live application settings. Every mutation persists through the store;
/// a persistence failure is swallowed inside the store so the session keeps
/// its in-memory value.
final settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

class SettingsController extends Notifier<AppSettings> {
  SettingsStore get _store => ref.read(settingsStoreProvider);

  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  void setWeightSourceType(WeightSourceType type) {
    state = state.copyWith(weightSourceType: type);
    _store.saveWeightSource(type);
  }

  void setSerial(SerialSettings serial) {
    state = state.copyWith(serial: serial);
    _store.saveSerial(serial);
  }

  void setFoodics(FoodicsSettings foodics) {
    state = state.copyWith(foodics: foodics);
    _store.saveFoodics(foodics);
  }

  void setHeadOffice(HeadOfficeSettings headOffice) {
    state = state.copyWith(headOffice: headOffice);
    _store.saveHeadOffice(headOffice);
  }
}
