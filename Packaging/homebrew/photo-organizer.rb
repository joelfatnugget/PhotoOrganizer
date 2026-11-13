cask "photo-organizer" do
  version "1.0.0"
  sha256 :no_check # Replace with the SHA256 printed by the GitHub Release workflow

  url "https://github.com/joelfatnugget/PhotoOrganizer/releases/download/v#{version}/PhotoOrganizer.dmg"
  name "PhotoOrganizer"
  desc "Offline on-device Apple Neural Engine photo and video organizer"
  homepage "https://github.com/joelfatnugget/PhotoOrganizer"

  depends_on macos: ">= :ventura"

  app "PhotoOrganizer.app"

  zap trash: [
    "~/Library/Preferences/com.photoorganizer.macos.plist",
  ]
end
