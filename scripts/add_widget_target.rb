# Adds the SendmeterWidgets app-extension target (Live Activities) to
# ios/App/App.xcodeproj. One-shot; safe to re-run (bails if the target
# already exists). Run with:
#   GEM_PATH=/opt/homebrew/Cellar/cocoapods/1.17.0/libexec \
#     /opt/homebrew/opt/ruby/bin/ruby scripts/add_widget_target.rb
require "xcodeproj"

PROJ = File.expand_path("../ios/App/App.xcodeproj", __dir__)
proj = Xcodeproj::Project.open(PROJ)

if proj.targets.any? { |t| t.name == "SendmeterWidgets" }
  puts "SendmeterWidgets target already exists — nothing to do"
  exit 0
end

app_target = proj.targets.find { |t| t.name == "App" } or abort "App target not found"

# 1. The extension target (creates configs + product ref + empty phases).
widget = proj.new_target(:app_extension, "SendmeterWidgets", :ios, "17.0")

# 2. Filesystem-synced sources, same shape as the watch target — future
#    Swift file adds/removes need no pbxproj edits.
grp = proj.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
grp.path = "SendmeterWidgets"
grp.source_tree = "<group>"
proj.main_group << grp
widget.file_system_synchronized_groups << grp

# 3. Build settings.
widget.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = "com.jirathip.sendlog.widgets"
  s["PRODUCT_NAME"] = "$(TARGET_NAME)"
  s["INFOPLIST_FILE"] = "SendmeterWidgets-Info.plist"
  s["GENERATE_INFOPLIST_FILE"] = "YES"
  s["INFOPLIST_KEY_CFBundleDisplayName"] = "Sendmeter"
  s["CODE_SIGN_ENTITLEMENTS"] = "SendmeterWidgets/SendmeterWidgets.entitlements"
  s["CODE_SIGN_STYLE"] = "Automatic"
  s["DEVELOPMENT_TEAM"] = "9244PWFYD7"
  s["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  s["SKIP_INSTALL"] = "YES"
  s["SWIFT_VERSION"] = "5.0"
  s["CURRENT_PROJECT_VERSION"] = "1"
  s["MARKETING_VERSION"] = "1.0"
  s["TARGETED_DEVICE_FAMILY"] = "1,2"
  s["SWIFT_EMIT_LOC_STRINGS"] = "YES"
end

# 4. Embed into App: dependency + PlugIns copy phase.
app_target.add_dependency(widget)
embed = app_target.new_copy_files_build_phase("Embed Foundation Extensions")
embed.dst_subfolder_spec = "13" # PlugIns
embed.dst_path = ""
bf = embed.add_file_reference(widget.product_reference)
bf.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

# 5. LiveActivityIntents.swift into the App target's explicit Sources
#    (LiveActivityIntent implementations must live in the app target).
app_group = proj.main_group.children.find { |c| c.display_name == "App" && c.isa == "PBXGroup" }
abort "App group not found" unless app_group
intents_ref = app_group.new_reference("App/LiveActivityIntents.swift")
intents_ref.source_tree = "<group>"
intents_ref.path = "LiveActivityIntents.swift"
app_target.source_build_phase.add_file_reference(intents_ref)

proj.save
puts "Added SendmeterWidgets target + embedded into App + LiveActivityIntents.swift wired"
