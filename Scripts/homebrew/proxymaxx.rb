# Rendered by .github/workflows/release.yml on every vX.Y.Z tag, then pushed to
# AgiMaulana/homebrew-proxymaxx as Casks/proxymaxx.rb. Edit this file, not the tap.
cask "proxymaxx" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/AgiMaulana/ProxyMaxx/releases/download/v#{version}/ProxyMaxx-v#{version}.dmg"
  name "ProxyMaxx"
  desc "Native macOS HTTP/HTTPS debugging proxy"
  homepage "https://github.com/AgiMaulana/ProxyMaxx"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "ProxyMaxx.app"

  # ProxyMaxx is ad-hoc signed and not notarised, and Homebrew quarantines every cask
  # download it fetches, so macOS would refuse to launch the installed copy. Clear the
  # attribute on the copy we just installed; this runs once per install and per upgrade.
  # The cask sandbox already permits writes under the app directory.
  #
  # `brew audit` rejects this stanza in homebrew/cask. In a private tap it is the
  # difference between an app that opens and one that does not.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/ProxyMaxx.app"]
  end

  uninstall quit: "com.proxymaxx.app"

  zap trash: [
    "~/Library/Application Support/ProxyMaxx",
    "~/Library/Caches/com.proxymaxx.app",
    "~/Library/Preferences/com.proxymaxx.app.plist",
    "~/Library/Saved Application State/com.proxymaxx.app.savedState",
  ]
end
