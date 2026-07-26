# Adds App/PrivacyInfo.xcprivacy to the App target's Resources build phase in
# ios/App/App.xcodeproj (issue #226). Only the App target needs this: the watch
# app and both widget extensions are PBXFileSystemSynchronizedRootGroups, so
# their manifests are bundled by filesystem presence alone. Idempotent. Run:
#   GEM_PATH=/opt/homebrew/Cellar/cocoapods/1.17.0/libexec \
#     /opt/homebrew/opt/ruby/bin/ruby scripts/add_privacy_manifest.rb
require "xcodeproj"

PROJ = File.expand_path("../ios/App/App.xcodeproj", __dir__)
proj = Xcodeproj::Project.open(PROJ)

app = proj.targets.find { |t| t.name == "App" } or abort "App target not found"

if app.resources_build_phase.files_references.any? { |r| r&.path == "PrivacyInfo.xcprivacy" }
  puts "PrivacyInfo.xcprivacy already in App Resources — nothing to do"
  exit 0
end

group = proj.main_group.find_subpath("App", false) or abort "App group not found"
ref = group.files.find { |f| f.path == "PrivacyInfo.xcprivacy" } ||
      group.new_reference("PrivacyInfo.xcprivacy")
app.resources_build_phase.add_file_reference(ref)

proj.save
puts "Added PrivacyInfo.xcprivacy to the App target's Resources build phase"
