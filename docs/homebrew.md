# Homebrew packaging

An author-maintained Homebrew tap would remove the clone/build/PATH setup for
CLI users. [`Formula/native-space-kit.rb`](../Formula/native-space-kit.rb) is a
ready-to-review source formula for the existing `v0.1.0` tag, including its
archive SHA-256. It installs `nsk`, the public header, the static library, and
the C example. It has no service, GUI-session test, or runtime dependencies.

**No author tap is published by this change.** The maintainer must choose and
create the tap repository, copy in the formula, and publish it before the
installation command below is available. No release credentials or extra
workflow permissions are needed for a manually maintained tap.

## Maintainer setup

Following Homebrew's [tap guide](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap):

1. Create `Fjx-dylanZ/homebrew-tap` (or choose another tap name).
2. Copy this formula to `Formula/native-space-kit.rb` in that repository.
3. Validate it on macOS with the commands below, commit, and publish the tap.
4. Only then advertise `brew install Fjx-dylanZ/tap/native-space-kit` in the README.
   Adjust that command if a different repository name was chosen.

The formula compiles from source using Xcode Command Line Tools or Xcode.
It does not supply bottles or establish compatibility with untested OS versions.
Private API availability and the project's verified-scope limits still apply.

## Local review before publishing a tap

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
The formula test checks JSON output, pre-initialization argument rejection, and
links/runs a C consumer against the installed header/library. It never submits
a native write or requires a logged-in GUI session.

## Updating a release

For each new source tag, update `url` and `sha256` together in the tap formula
and this reference copy. Download the exact URL and run `shasum -a 256` on the
archive; never guess the checksum or rewrite an existing release tag. Repeat
the build, audit, and formula test, then publish the formula update in the tap.
The version is inferred from the tagged archive URL.

This deliberately starts with manual publication. Bottles and automated tap
updates can be added later once the maintainer chooses the release process and
explicitly configures access to the tap. See the
[Formula Cookbook](https://docs.brew.sh/Formula-Cookbook) for the packaging DSL.
