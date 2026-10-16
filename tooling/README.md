# Offline dependency vendoring

Some environments (like this VM) can't reach pub.dev from Dart's HTTP
client — the egress proxy drops non-curl TLS handshakes, so `dart pub get`
hangs forever in "Resolving dependencies...".

Workaround used for this repo:

1. Resolve versions via the pub.dev API with curl (works fine):
   `python3 tooling/resolve_pub.py tooling/roots.yaml`
   (`roots.yaml` pins the union of app + Flutter SDK package constraints.)
2. Download each tarball:
   `https://pub.dev/api/archives/<name>-<version>.tar.gz`
   and extract to `~/.pub-cache/hosted/pub.dev/<name>-<version>/`.
3. Hand-write `.dart_tool/package_config.json` mapping every package
   (plus `flutter`, `flutter_test`, `sky_engine` from the local SDK).

`dart analyze` and `dart compile` then work without any network.
The `flutter` CLI additionally needs its own `flutter_tools` dependencies
vendored the same way before `flutter pub get` / `flutter build` will run.
