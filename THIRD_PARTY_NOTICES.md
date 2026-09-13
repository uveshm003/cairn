# Third-party notices

Cairn itself is MIT licensed (see [LICENSE](LICENSE)). The components below
ship *inside* the app and carry their own terms.

## Bundled fonts

Both families are redistributed in `assets/fonts/` as `.ttf` files and are
embedded in every build. Both are licensed under the **SIL Open Font License
1.1**, whose full text is in [`assets/fonts/OFL.txt`](assets/fonts/OFL.txt).
The OFL requires that the copyright notice and license accompany the fonts —
that file is how Cairn satisfies it, and it must be kept in any redistribution.

| Family | Files | Copyright | Upstream |
|---|---|---|---|
| Inter | `Inter-400.ttf`, `Inter-500.ttf`, `Inter-600.ttf` | Copyright (c) 2016–2020 The Inter Project Authors | https://github.com/rsms/inter |
| Fraunces | `Fraunces-500.ttf`, `Fraunces-600.ttf` | Copyright (c) 2020 The Fraunces Project Authors | https://github.com/undercasetype/Fraunces |

The Fraunces files are the **144pt optical cut**, instanced from the variable
font. See the `opsz` note in the README's *Design* section for why.

Neither family is modified beyond static instancing, and neither uses a
Reserved Font Name in a way OFL §3 restricts.

## Dart and Flutter dependencies

Every package in `pubspec.yaml` is fetched from pub.dev at build time and is
not vendored into this repository. Their licenses are their own; the set is
BSD-3-Clause, MIT, and Apache-2.0. Flutter generates the authoritative,
machine-collected list at runtime — it is reachable in the app itself, and
from the command line with:

```sh
flutter pub deps --style=compact
```

The first-party Flutter SDK packages (`flutter`, `flutter_test`,
`integration_test`) are BSD-3-Clause, Copyright 2014 The Flutter Authors.

## App icon and mark

The Cairn mark, the wordmark, and the launcher icon (`assets/icon/`,
`lib/ui/widgets/cairn_mark.dart`) are original work, MIT licensed with the rest
of the source. They are *not* a trademark grant — see the trademark note in
[CONTRIBUTING.md](CONTRIBUTING.md).
