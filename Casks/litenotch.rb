# Homebrew cask for LiteNotch. The release workflow
# (.github/workflows/release.yml) rewrites `version` and `sha256` for every
# tagged release, so edit the rest by hand and leave those two to CI.
cask "litenotch" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/tangnatta/LiteNotch/releases/download/v#{version}/LiteNotch-#{version}-arm64.zip"
  name "LiteNotch"
  desc "Lightweight notch utility for focus, media, clipboard and Claude Code"
  homepage "https://github.com/tangnatta/LiteNotch"

  # Every Mac with a notch is Apple silicon.
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "LiteNotch.app"
  binary "#{appdir}/LiteNotch.app/Contents/Helpers/litenotch"

  # The app is ad-hoc signed, not notarized: without this, Gatekeeper refuses
  # to open a downloaded copy.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/LiteNotch.app"]
  end

  uninstall quit: "dev.litenotch.app"

  zap trash: "~/Library/Application Support/LiteNotch"

  caveats <<~EOS
    LiteNotch is not notarized yet. The cask removes the quarantine flag so it
    can open; if you prefer, build it from source instead (see the README).

    To show Claude Code approvals in the notch:
      litenotch hooks install
  EOS
end
