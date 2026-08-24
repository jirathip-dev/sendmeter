#!/usr/bin/env ruby
# frozen_string_literal: true

# Static contract for the generated native watch graph. This intentionally
# opens the generated pbxproj rather than compiling it: the Xcode lane remains
# serialized elsewhere, while source/resource membership and copy-file
# destinations are deterministic project wiring that can be checked cheaply.
#
# Run after `xcodegen generate`:
#   GEM_PATH=/opt/homebrew/Cellar/cocoapods/*/libexec \
#     /opt/homebrew/opt/ruby/bin/ruby scripts/assert-native-watch-project.rb

require "xcodeproj"

REPO = File.expand_path("..", __dir__).freeze
PROJECT_PATH = File.join(REPO, "native/SendmeterNative/SendmeterNative.xcodeproj").freeze

def fail_check(message)
  warn "native-watch-project: #{message}"
  exit 1
end

fail_check("generated project is missing: #{PROJECT_PATH}") unless File.exist?(PROJECT_PATH)

project = Xcodeproj::Project.open(PROJECT_PATH)

def target!(project, name)
  project.targets.find { |target| target.name == name } || fail_check("target is missing: #{name}")
end

def setting!(target, configuration, key)
  config = target.build_configurations.find { |candidate| candidate.name == configuration }
  fail_check("#{target.name} has no #{configuration} configuration") unless config
  value = config.build_settings[key]
  fail_check("#{target.name} #{configuration} is missing #{key}") if value.nil?
  value
end

def real_paths(phase)
  phase.files.filter_map do |build_file|
    reference = build_file.file_ref
    reference&.real_path&.to_s
  end
end

def assert_exact_membership(label, actual, expected)
  missing = expected - actual
  extra = actual - expected
  fail_check("#{label} is missing #{missing.inspect}") unless missing.empty?
  fail_check("#{label} has unexpected entries #{extra.inspect}") unless extra.empty?
end

def assert_contains(label, actual, expected)
  missing = expected - actual
  fail_check("#{label} is missing #{missing.inspect}") unless missing.empty?
end

def swift_files(directory)
  Dir[File.join(directory, "**", "*.swift")].map { |path| File.expand_path(path) }.sort
end

def resource_files(target)
  real_paths(target.resources_build_phase).sort
end

def copy_phase!(target, name)
  target.copy_files_build_phases.find { |phase| phase.name == name } ||
    fail_check("#{target.name} is missing copy phase #{name.inspect}")
end

app = target!(project, "SendmeterNative")
watch = target!(project, "SendLogWatch Watch App")
watch_widgets = target!(project, "SendLogWatchWidgets")
phone_widgets = target!(project, "SendmeterNativeWidgets")

watch_root = File.join(REPO, "ios/App/SendLogWatch Watch App")
watch_widgets_root = File.join(REPO, "ios/App/SendLogWatchWidgets")

assert_exact_membership(
  "watch Swift sources",
  real_paths(watch.source_build_phase).select { |path| path.end_with?(".swift") }.sort,
  swift_files(watch_root)
)
assert_exact_membership(
  "watch-widget Swift sources",
  real_paths(watch_widgets.source_build_phase).select { |path| path.end_with?(".swift") }.sort,
  swift_files(watch_widgets_root)
)

assert_exact_membership(
  "watch resources",
  resource_files(watch),
  [
    File.join(watch_root, "Assets.xcassets"),
    File.join(watch_root, "PrivacyInfo.xcprivacy"),
    File.join(watch_root, "Resources/SupabaseConfig.plist"),
  ].sort
)
assert_exact_membership(
  "watch-widget resources",
  resource_files(watch_widgets),
  [File.join(watch_widgets_root, "PrivacyInfo.xcprivacy")]
)

watch_info_path = File.join(REPO, "native/SendmeterNative/Resources/WatchInfo.plist")
watch_info = File.exist?(watch_info_path) ? File.read(watch_info_path) : ""
%w[
  $(MARKETING_VERSION)
  $(CURRENT_PROJECT_VERSION)
  $(WATCH_COMPANION_APP_BUNDLE_IDENTIFIER)
].each do |placeholder|
  fail_check("WatchInfo.plist is missing #{placeholder}") unless watch_info.include?(placeholder)
end
capacitor_watch_info_path = File.join(REPO, "ios/App/SendLogWatch Watch App-Info.plist")
fail_check("Capacitor watch Info.plist is missing: #{capacitor_watch_info_path}") unless
  File.exist?(capacitor_watch_info_path)
native_watch_info = Xcodeproj::Plist.read_from_path(watch_info_path)
capacitor_watch_info = Xcodeproj::Plist.read_from_path(capacitor_watch_info_path)
fail_check("native and Capacitor watch Info.plists have different key sets") unless
  native_watch_info.keys.sort == capacitor_watch_info.keys.sort

intentional_watch_info_differences = {
  "CFBundleShortVersionString" => ["$(MARKETING_VERSION)", "1.0"],
  "CFBundleVersion" => ["$(CURRENT_PROJECT_VERSION)", "1"],
  "WKCompanionAppBundleIdentifier" => [
    "$(WATCH_COMPANION_APP_BUNDLE_IDENTIFIER)",
    "com.jirathip.sendlog",
  ],
}
actual_watch_info_differences = native_watch_info.keys.sort.filter_map do |key|
  next if native_watch_info[key] == capacitor_watch_info[key]

  [key, [native_watch_info[key], capacitor_watch_info[key]]]
end.to_h
fail_check(
  "native and Capacitor watch Info.plists differ outside their three intentional values: " \
  "#{actual_watch_info_differences.inspect}"
) unless actual_watch_info_differences == intentional_watch_info_differences
fail_check("watch target does not use the native versioned Info.plist") unless
  setting!(watch, "Release", "INFOPLIST_FILE") == "Resources/WatchInfo.plist"

[app, watch, watch_widgets, phone_widgets].each do |target|
  build_paths = real_paths(target.source_build_phase) + resource_files(target)
  entitlements = build_paths.select { |path| path.end_with?(".entitlements") }
  fail_check("#{target.name} includes entitlements in a build phase: #{entitlements.inspect}") unless entitlements.empty?
end

assert_contains(
  "watch package links",
  watch.package_product_dependencies.map(&:product_name),
  %w[Supabase SendLogWatchCore]
)
assert_contains(
  "watch-widget package links",
  watch_widgets.package_product_dependencies.map(&:product_name),
  ["SendLogWatchCore"]
)

watch_embed = copy_phase!(app, "Embed Watch Content")
fail_check("Embed Watch Content has the wrong destination") unless
  watch_embed.dst_path == "$(CONTENTS_FOLDER_PATH)/Watch" && watch_embed.dst_subfolder_spec.to_s == "16"
assert_exact_membership(
  "native app watch embed",
  watch_embed.files.filter_map { |file| file.file_ref&.path },
  ["SendLogWatch Watch App.app"]
)

phone_widget_embed = copy_phase!(app, "Embed Foundation Extensions")
fail_check("native widget embed has the wrong destination") unless
  phone_widget_embed.dst_path.to_s.empty? && phone_widget_embed.dst_subfolder_spec.to_s == "13"
assert_exact_membership(
  "native app widget embed",
  phone_widget_embed.files.filter_map { |file| file.file_ref&.path },
  ["SendmeterNativeWidgets.appex"]
)

watch_widget_embed = copy_phase!(watch, "Embed Foundation Extensions")
fail_check("watch widget embed has the wrong destination") unless
  watch_widget_embed.dst_path.to_s.empty? && watch_widget_embed.dst_subfolder_spec.to_s == "13"
assert_exact_membership(
  "watch app widget embed",
  watch_widget_embed.files.filter_map { |file| file.file_ref&.path },
  ["SendLogWatchWidgets.appex"]
)

fail_check("watch target does not depend on SendLogWatchWidgets") unless
  watch.dependencies.any? { |dependency| dependency.target&.name == "SendLogWatchWidgets" }
fail_check("native app does not depend on the watch app") unless
  app.dependencies.any? { |dependency| dependency.target&.name == "SendLogWatch Watch App" }

%w[Debug Release].each do |configuration|
  fail_check("watch AppIcon missing in #{configuration}") unless
    setting!(watch, configuration, "ASSETCATALOG_COMPILER_APPICON_NAME") == "AppIcon"
  fail_check("watch AccentColor missing in #{configuration}") unless
    setting!(watch, configuration, "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME") == "AccentColor"
  fail_check("watch team mismatch in #{configuration}") unless
    setting!(watch, configuration, "DEVELOPMENT_TEAM") == "9244PWFYD7"
  fail_check("watch-widget team mismatch in #{configuration}") unless
    setting!(watch_widgets, configuration, "DEVELOPMENT_TEAM") == "9244PWFYD7"
end

debug_phone_id = setting!(app, "Debug", "PRODUCT_BUNDLE_IDENTIFIER")
release_phone_id = setting!(app, "Release", "PRODUCT_BUNDLE_IDENTIFIER")
debug_watch_id = setting!(watch, "Debug", "PRODUCT_BUNDLE_IDENTIFIER")
release_watch_id = setting!(watch, "Release", "PRODUCT_BUNDLE_IDENTIFIER")
debug_watch_widgets_id = setting!(watch_widgets, "Debug", "PRODUCT_BUNDLE_IDENTIFIER")
release_watch_widgets_id = setting!(watch_widgets, "Release", "PRODUCT_BUNDLE_IDENTIFIER")

fail_check("Debug watch companion does not match Debug phone") unless
  setting!(watch, "Debug", "WATCH_COMPANION_APP_BUNDLE_IDENTIFIER") == debug_phone_id
fail_check("Release watch companion does not match Release phone") unless
  setting!(watch, "Release", "WATCH_COMPANION_APP_BUNDLE_IDENTIFIER") == release_phone_id
fail_check("Debug watch ID collides with Release watch ID") if debug_watch_id == release_watch_id
fail_check("Debug watch-widget ID collides with Release watch-widget ID") if
  debug_watch_widgets_id == release_watch_widgets_id
fail_check("Debug watch IDs are not native-specific") unless
  debug_watch_id.start_with?("#{debug_phone_id}.") && debug_watch_widgets_id.start_with?("#{debug_watch_id}.")
fail_check("Release watch ID is not the shipped companion ID") unless
  release_watch_id == "com.jirathip.sendlog.watchkitapp"
fail_check("Release watch-widget ID is not the shipped companion ID") unless
  release_watch_widgets_id == "com.jirathip.sendlog.watchkitapp.widgets"

fail_check("native phone Release workaround changed optimization") unless
  setting!(app, "Release", "SWIFT_OPTIMIZATION_LEVEL") == "-O"
fail_check("watch Debug is missing DEBUG") unless
  setting!(watch, "Debug", "SWIFT_ACTIVE_COMPILATION_CONDITIONS").to_s.split.include?("DEBUG")
fail_check("watch-widget Debug is missing DEBUG") unless
  setting!(watch_widgets, "Debug", "SWIFT_ACTIVE_COMPILATION_CONDITIONS").to_s.split.include?("DEBUG")

scheme_path = File.join(
  PROJECT_PATH,
  "xcshareddata/xcschemes/SendLogWatch Watch App.xcscheme"
)
scheme = File.exist?(scheme_path) ? File.read(scheme_path) : ""
fail_check("standalone watch scheme is missing") if scheme.empty?
%w[SendLogWatch\ Watch\ App SendLogWatchWidgets].each do |name|
  fail_check("standalone watch scheme does not build #{name}") unless scheme.include?(name)
end

puts "native-watch-project: generated target/source/resource/embed/package assertions passed"
