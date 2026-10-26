# ScanPal (starter)
1. `flutter create --platforms=android,ios .` inside this folder (generates android/ios), keep lib/ and pubspec.yaml.
2. `flutter pub get`, then `flutter run`.
3. iOS: add NSCameraUsageDescription and NSPhotoLibraryUsageDescription to ios/Runner/Info.plist.
4. Android: minSdk 21+ (ML Kit text recognition needs it); camera permission is handled by the scanner plugin.
5. RevenueCat: create an entitlement named `pro`, an offering with an annual package, then paste the public SDK keys at the top of lib/main.dart.
6. In debug builds a switch in the app bar toggles Pro so you can test gating without store setup.
