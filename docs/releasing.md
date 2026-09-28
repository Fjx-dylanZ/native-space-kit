# Releasing

1. Set `NSK_VERSION` in `include/native_space_kit.h`, merge to `main`, and wait
   for CI.
2. Tag the merge commit and publish a GitHub release:

   ```sh
   git tag -a vX.Y.Z -m "native-space-kit X.Y.Z"
   git push origin vX.Y.Z
   gh release create vX.Y.Z --title vX.Y.Z --notes "..."
   ```

3. Update the formula in
   [Fjx-dylanZ/homebrew-tap](https://github.com/Fjx-dylanZ/homebrew-tap):

   ```sh
   brew tap Fjx-dylanZ/tap
   brew bump-formula-pr --write-only --commit \
     --url https://github.com/Fjx-dylanZ/native-space-kit/archive/refs/tags/vX.Y.Z.tar.gz \
     Fjx-dylanZ/tap/native-space-kit
   brew install --build-from-source Fjx-dylanZ/tap/native-space-kit
   brew test Fjx-dylanZ/tap/native-space-kit
   brew audit --strict --online Fjx-dylanZ/tap/native-space-kit
   git -C "$(brew --repository Fjx-dylanZ/tap)" push
   ```
