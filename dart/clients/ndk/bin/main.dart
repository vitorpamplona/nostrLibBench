import 'package:ndk/ndk.dart';
void main() {
  final ndk = Ndk(NdkConfig(eventVerifier: Bip340EventVerifier(), cache: MemCacheManager()));
  print(ndk.runtimeType);
}
