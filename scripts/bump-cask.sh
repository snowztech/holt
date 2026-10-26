#!/usr/bin/env bash
# Points the Homebrew cask in snowztech/homebrew-tap at a release, like `bump-cask.sh 0.1.1 build/Holt.dmg`.
# Writes the whole cask, so the first run creates it. TAP_DEPLOY_KEY is a deploy key with write
# access to the tap. Without it, your own git access is used.
set -euo pipefail

version="$1"
sha=$(shasum -a 256 "$2" | cut -d' ' -f1)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -n "${TAP_DEPLOY_KEY:-}" ]; then
    (umask 077 && echo "$TAP_DEPLOY_KEY" > "$work/key")
    export GIT_SSH_COMMAND="ssh -i $work/key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
fi

tap="$work/tap"
git clone -q --depth 1 git@github.com:snowztech/homebrew-tap.git "$tap"
mkdir -p "$tap/Casks"
cat > "$tap/Casks/holt.rb" <<CASK
cask "holt" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/snowztech/holt/releases/download/v#{version}/Holt.dmg"
  name "Holt"
  desc "Clipboard history, synced between your Macs"
  homepage "https://github.com/snowztech/holt"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Holt.app"

  uninstall quit: "app.holtclip.Holt"

  zap trash: [
    "~/Library/Application Support/Holt",
    "~/Library/Preferences/app.holtclip.Holt.plist",
  ]
end
CASK

git -C "$tap" add Casks/holt.rb
if git -C "$tap" diff --cached --quiet; then
    echo "cask is already at $version"
    exit 0
fi
git -C "$tap" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -qm "chore: bump holt to $version"
git -C "$tap" push -q
echo "cask bumped to $version"
