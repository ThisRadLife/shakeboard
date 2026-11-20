cask "shakeboard" do
  version "0.0.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/ThisRadLife/shakeboard/releases/download/v#{version}/ShakeBoard-#{version}.dmg"
  name "ShakeBoard"
  desc "Local macOS drag shelf and clipboard history"
  homepage "https://github.com/ThisRadLife/shakeboard"

  depends_on macos: ">= :sonoma"

  app "ShakeBoard.app"

  # Enable once Sparkle ships.
  # auto_updates true

  zap trash: [
    "~/Library/Application Support/ShakeBoard",
    "~/Library/Containers/com.thisradlife.shakeboard.share",
    "~/Library/Preferences/com.thisradlife.shakeboard.plist",
  ]
end
