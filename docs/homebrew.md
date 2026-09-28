# Homebrew packaging

The author-maintained tap
[`Fjx-dylanZ/homebrew-tap`](https://github.com/Fjx-dylanZ/homebrew-tap)
publishes a source formula for the `v0.1.0` tag:

```sh
brew install Fjx-dylanZ/tap/native-space-kit
```

[`Formula/native-space-kit.rb`](../Formula/native-space-kit.rb) is the reference
copy of the tap's `Formula/native-space-kit.rb`, including the archive SHA-256;
keep the two identical. It installs `nsk`, the public header, the static
library, and the C example. It has no service, GUI-session test, or runtime
dependencies. Installing by the fully qualified name also satisfies Homebrew's
[tap trust](https://docs.brew.sh/Tap-Trust) for that formula.

The formula compiles from source using Xcode Command Line Tools or Xcode.
It does not supply bottles or establish compatibility with untested OS versions.
Private API availability and the project's verified-scope limits still apply.

## Tap maintenance

The tap follows Homebrew's
[tap guide](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap) and is
maintained manually: formula changes are validated locally, then committed to
the tap's `main` branch. It has no CI workflows, bottles, or release
credentials.

## Local review before publishing a formula change

Use a disposable local tap to test the formula from this checkout:

```sh
brew tap-new local/nsk-review
cp Formula/native-space-kit.rb "$(brew --repository local/nsk-review)/Formula/"
brew audit --strict local/nsk-review/native-space-kit
brew install --build-from-source --skip-link local/nsk-review/native-space-kit
brew test --force local/nsk-review/native-space-kit
"$(brew --prefix native-space-kit)/bin/nsk" --version
brew uninstall native-space-kit
brew untap local/nsk-review
```

Use a fresh test installation; do not uninstall an existing user installation
to run this recipe. `--skip-link` avoids changing which `nsk` is found on PATH.
`brew test --force` permits testing that unlinked keg; it does not link it.
`brew tap-new` and `brew test` turn on Homebrew developer mode; run
`brew developer off` afterwards if it was off before.
The formula test checks JSON output, pre-initialization argument rejection, and
links/runs a C consumer against the installed header/library. It never submits
a native write or requires a logged-in GUI session.

## Updating a release

For each new source tag, update `url` and `sha256` together in the tap formula
and this reference copy. Download the exact URL and run `shasum -a 256` on the
archive; never guess the checksum or rewrite an existing release tag. Repeat
the build, audit, and formula test, then commit the formula update to the tap
and confirm `brew install Fjx-dylanZ/tap/native-space-kit` builds the new
version. The version is inferred from the tagged archive URL; update the
release named in the README's Homebrew section.

Bottles and automated tap updates can be added later once the maintainer
chooses the release process and explicitly configures access to the tap. See
the [Formula Cookbook](https://docs.brew.sh/Formula-Cookbook) for the packaging
DSL.
