# Adds the two UI-test targets used by fastlane snapshot: one drives the
# Capacitor iPhone app and one drives the embedded watchOS companion. Safe to
# re-run; existing targets, source membership and shared schemes are updated.
#
# Run from the repository root with the bundled Ruby toolchain:
#   bundle exec ruby scripts/add_screenshot_targets.rb
require "xcodeproj"

PROJECT_PATH = File.expand_path("../ios/App/App.xcodeproj", __dir__)
project = Xcodeproj::Project.open(PROJECT_PATH)

sources_group = project.main_group.children.find do |child|
  child.respond_to?(:path) && child.path == "ScreenshotTests"
end
sources_group ||= project.main_group.new_group("ScreenshotTests", "ScreenshotTests")

def source_reference(group, filename)
  group.files.find { |file| file.path == filename } || group.new_file(filename)
end

helper_ref = source_reference(sources_group, "SnapshotHelper.swift")
iphone_ref = source_reference(sources_group, "SendmeterScreenshots.swift")
watch_ref = source_reference(sources_group, "SendmeterWatchScreenshots.swift")

def configure_ui_test_target(project:, name:, platform:, deployment:, host:, bundle_id:, sources:)
  target = project.targets.find { |candidate| candidate.name == name }
  target ||= project.new_target(:ui_test_bundle, name, platform, deployment)

  unless target.dependencies.any? { |dependency| dependency.target == host }
    target.add_dependency(host)
  end

  sources.each do |source|
    next if target.source_build_phase.files_references.include?(source)
    target.source_build_phase.add_file_reference(source)
  end

  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
    settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
    settings["GENERATE_INFOPLIST_FILE"] = "YES"
    settings["CODE_SIGN_STYLE"] = "Automatic"
    settings["DEVELOPMENT_TEAM"] = "9244PWFYD7"
    settings["SWIFT_VERSION"] = "5.0"
    settings["TEST_TARGET_NAME"] = host.name
    settings["SKIP_INSTALL"] = "YES"
    settings["CURRENT_PROJECT_VERSION"] = "1"
    settings["MARKETING_VERSION"] = "1.0"

    if platform == :watchos
      settings["SDKROOT"] = "watchos"
      settings["WATCHOS_DEPLOYMENT_TARGET"] = deployment
      settings["TARGETED_DEVICE_FAMILY"] = "4"
      settings["SUPPORTED_PLATFORMS"] = "watchos watchsimulator"
    else
      settings["SDKROOT"] = "iphoneos"
      settings["IPHONEOS_DEPLOYMENT_TARGET"] = deployment
      settings["TARGETED_DEVICE_FAMILY"] = "1"
      settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
    end
  end

  target
end

app = project.targets.find { |target| target.name == "App" } or abort "App target not found"
watch = project.targets.find { |target| target.name == "SendLogWatch Watch App" } \
  or abort "watch app target not found"

iphone_tests = configure_ui_test_target(
  project: project,
  name: "SendmeterScreenshots",
  platform: :ios,
  deployment: "16.0",
  host: app,
  bundle_id: "com.jirathip.sendlog.screenshots",
  sources: [helper_ref, iphone_ref]
)

watch_tests = configure_ui_test_target(
  project: project,
  name: "SendmeterWatchScreenshots",
  platform: :watchos,
  deployment: "10.0",
  host: watch,
  bundle_id: "com.jirathip.sendlog.watchkitapp.screenshots",
  sources: [helper_ref, watch_ref]
)

project.save

{
  "Sendmeter Screenshots" => [app, iphone_tests],
  "Sendmeter Watch Screenshots" => [watch, watch_tests],
}.each do |name, (host, tests)|
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(host, tests, launch_target: true)
  scheme.save_as(PROJECT_PATH, name, true)
end

puts "Configured iPhone + watchOS screenshot UI-test targets and shared schemes"
