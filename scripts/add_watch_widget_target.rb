# Adds the SendLogWatchWidgets watchOS app-extension target (watch-face
# complications + Smart-Stack widgets) to ios/App/App.xcodeproj, embedded into
# the "SendLogWatch Watch App" target. One-shot; safe to re-run (bails if the
# target already exists). Run with:
#   GEM_PATH=/opt/homebrew/Cellar/cocoapods/*/libexec \
#     /opt/homebrew/opt/ruby/bin/ruby scripts/add_watch_widget_target.rb
require "xcodeproj"

PROJ = File.expand_path("../ios/App/App.xcodeproj", __dir__)
proj = Xcodeproj::Project.open(PROJ)

TARGET = "SendLogWatchWidgets"
watch = proj.targets.find { |t| t.name == "SendLogWatch Watch App" } \
  or abort "watch app target not found"

widget = proj.targets.find { |t| t.name == TARGET }
new_target = widget.nil?
if new_target
  # 1. The watchOS extension target (creates configs + product ref + phases).
  widget = proj.new_target(:app_extension, TARGET, :watchos, "10.0")

  # 2. Filesystem-synced sources — add/remove Swift files by touching the dir.
  grp = proj.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
  grp.path = TARGET
  grp.source_tree = "<group>"
  proj.main_group << grp
  widget.file_system_synchronized_groups << grp
end

# 3. Build settings (watchOS widget extension). Re-applied on every run so
#    signing fixes land even when the target already exists.
widget.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = "com.jirathip.sendlog.watchkitapp.widgets"
  s["PRODUCT_NAME"] = "$(TARGET_NAME)"
  s["INFOPLIST_FILE"] = "SendLogWatchWidgets-Info.plist"
  s["GENERATE_INFOPLIST_FILE"] = "YES"
  s["INFOPLIST_KEY_CFBundleDisplayName"] = "Sendmeter"
  s["CODE_SIGN_ENTITLEMENTS"] = "SendLogWatchWidgets/SendLogWatchWidgets.entitlements"
  # AUTOMATIC signing, identical to the phone-widget target so the archive
  # signs the appex with the SAME certificate as its parent watch app (manual
  # Distribution here caused an "embedded binary not signed with the same cert"
  # mismatch). A brand-new App ID has no cached Development profile, so
  # `fastlane beta` pre-fetches + installs one for it (see Fastfile) — the only
  # thing this App ID lacked vs. the working phone widget.
  s["CODE_SIGN_STYLE"] = "Automatic"
  s.delete("CODE_SIGN_IDENTITY")
  s.delete("PROVISIONING_PROFILE_SPECIFIER")
  s["DEVELOPMENT_TEAM"] = "9244PWFYD7"
  s["SDKROOT"] = "watchos"
  s["WATCHOS_DEPLOYMENT_TARGET"] = "10.0"
  s["TARGETED_DEVICE_FAMILY"] = "4"
  s["SKIP_INSTALL"] = "YES"
  s["SWIFT_VERSION"] = "5.0"
  s["CURRENT_PROJECT_VERSION"] = "1"
  s["MARKETING_VERSION"] = "1.0"
  s["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  s["LD_RUNPATH_SEARCH_PATHS"] = [
    "$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks",
  ]
end

# 4. Embed into the watch app: dependency + PlugIns copy phase (creation only).
if new_target
  watch.add_dependency(widget)
  embed = watch.new_copy_files_build_phase("Embed Foundation Extensions")
  embed.dst_subfolder_spec = "13" # PlugIns
  embed.dst_path = ""
  bf = embed.add_file_reference(widget.product_reference)
  bf.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
end

proj.save
puts new_target \
  ? "Added #{TARGET} watchOS widget target + embedded into SendLogWatch Watch App" \
  : "Updated #{TARGET} build settings (manual signing)"
