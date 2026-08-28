#!/usr/bin/env ruby
# Verify the generated XcodeGen graph owns the retained phone and Watch surfaces.
require "yaml"

repo = File.expand_path("..", __dir__)
spec_path = File.join(repo, "native/SendmeterNative/project.yml")
project_dir = File.join(repo, "native/SendmeterNative")
spec = YAML.load_file(spec_path)
targets = spec.fetch("targets")
pbx = File.read(File.join(project_dir, "SendmeterNative.xcodeproj/project.pbxproj"))

abort "generated Xcode project is missing; run xcodegen generate" unless File.file?(File.join(project_dir, "SendmeterNative.xcodeproj/project.pbxproj"))
abort "legacy Capacitor project is still referenced" if spec.to_s.match?(/CapApp-SPM|ios\/App\/App\.xcodeproj|Capacitor/)

required_sources = {
  "SendmeterNative" => %w[Sources/App Sources/Data Sources/Platform Sources/Features Sources/Shared],
  "SendLogWatch Watch App" => ["../../ios/App/SendLogWatch Watch App"],
  "SendLogWatchWidgets" => ["../../ios/App/SendLogWatchWidgets"],
}
required_sources.each do |target, paths|
  sources = targets.fetch(target).fetch("sources").map { |entry| entry.is_a?(String) ? entry : entry.fetch("path") }
  paths.each { |path| abort "#{target} does not consume #{path}" unless sources.include?(path) }
end

resources = targets.fetch("SendmeterNative").fetch("sources").select { |entry| entry.is_a?(Hash) && entry["buildPhase"] == "resources" }.map { |entry| entry.fetch("path") }
%w[Resources/PrivacyInfo.xcprivacy Resources/Assets.xcassets].each do |path|
  abort "phone resource is not in the resources phase: #{path}" unless resources.include?(path)
end

watch_sources = targets.fetch("SendLogWatch Watch App").fetch("sources")
watch_entry = watch_sources.find { |entry| entry.is_a?(Hash) && entry["path"] == "../../ios/App/SendLogWatch Watch App" }
%w[Assets.xcassets PrivacyInfo.xcprivacy Resources/SupabaseConfig.plist SendLogWatch.entitlements].each do |path|
  abort "Watch source excludes are incomplete: #{path}" unless watch_entry.fetch("excludes").include?(path)
end
watch_resources = watch_sources.select { |entry| entry.is_a?(Hash) && entry["buildPhase"] == "resources" }.map { |entry| entry.fetch("path") }
[
  "../../ios/App/SendLogWatch Watch App/Assets.xcassets",
  "../../ios/App/SendLogWatch Watch App/PrivacyInfo.xcprivacy",
  "../../ios/App/SendLogWatch Watch App/Resources/SupabaseConfig.plist",
].each { |path| abort "Watch resource is not in the resources phase: #{path}" unless watch_resources.include?(path) }

widget_entry = targets.fetch("SendLogWatchWidgets").fetch("sources").find { |entry| entry.is_a?(Hash) && entry["path"] == "../../ios/App/SendLogWatchWidgets" }
%w[PrivacyInfo.xcprivacy SendLogWatchWidgets.entitlements].each do |path|
  abort "Watch widget excludes are incomplete: #{path}" unless widget_entry.fetch("excludes").include?(path)
end

dependencies = targets.fetch("SendmeterNative").fetch("dependencies")
abort "phone does not embed Watch app" unless dependencies.any? { |entry| entry["target"] == "SendLogWatch Watch App" }
abort "phone does not embed phone widget" unless dependencies.any? { |entry| entry["target"] == "SendmeterNativeWidgets" }
%w[Supabase Auth SendmeterCore SendmeterWeather SendLogWatchCore SendLogHealthCore].each do |product|
  abort "phone package link missing #{product}" unless dependencies.any? { |entry| entry["product"] == product }
end

required_files = %w[
  Resources/PrivacyInfo.xcprivacy
  Resources/Assets.xcassets
  SendmeterNative.entitlements
  SendLogWatch.entitlements
  SendLogWatchWidgets.entitlements
  SupabaseConfig.plist
  SendmeterNativeWidgets.entitlements
]
required_files.each { |path| abort "generated project is missing #{path}" unless pbx.include?(File.basename(path)) }

%w[SendLogWatchCore SendLogHealthCore Supabase Auth SendmeterCore SendmeterWeather].each do |product|
  abort "generated project is missing package product #{product}" unless pbx.include?(product)
end

abort "Watch app is not embedded" unless pbx.include?("Embed Watch Content") && pbx.include?("SendLogWatch Watch App.app in Embed Watch Content")
abort "Watch widget is not embedded" unless pbx.include?("SendLogWatchWidgets.appex in Embed Foundation Extensions")
abort "phone widget is not embedded" unless pbx.include?("SendmeterNativeWidgets.appex in Embed Foundation Extensions")

watch_dependencies = targets.fetch("SendLogWatch Watch App").fetch("dependencies")
abort "Watch widget dependency missing" unless watch_dependencies.any? { |entry| entry["target"] == "SendLogWatchWidgets" }
%w[Supabase SendLogWatchCore SendLogHealthCore].each do |product|
  abort "Watch package link missing #{product}" unless watch_dependencies.any? { |entry| entry["product"] == product }
end

%w[
  com.jirathip.sendlog.native
  com.jirathip.sendlog
  com.jirathip.sendlog.native.watchkitapp
  com.jirathip.sendlog.watchkitapp
  com.jirathip.sendlog.native.watchkitapp.widgets
  com.jirathip.sendlog.watchkitapp.widgets
  com.jirathip.sendlog.native.widgets
  com.jirathip.sendlog.widgets
].each { |bundle_id| abort "missing bundle ID #{bundle_id}" unless pbx.include?(bundle_id) }

watch = targets.fetch("SendLogWatch Watch App").fetch("settings").fetch("configs")
%w[Debug Release].each do |config|
  companion = watch.fetch(config).fetch("base").fetch("WATCH_COMPANION_APP_BUNDLE_IDENTIFIER")
  expected = config == "Debug" ? "com.jirathip.sendlog.native" : "com.jirathip.sendlog"
  abort "Watch companion ID mismatch for #{config}" unless companion == expected
end

["SendmeterNative", "SendLogWatch Watch App"].each do |scheme|
  path = File.join(project_dir, "SendmeterNative.xcodeproj/xcshareddata/xcschemes/#{scheme}.xcscheme")
  abort "missing generated scheme #{scheme}" unless File.file?(path)
end
native_scheme = spec.fetch("schemes").fetch("SendmeterNative")
abort "native scheme misses app target" unless native_scheme.fetch("build").fetch("targets").key?("SendmeterNative")
abort "native scheme misses app tests" unless native_scheme.fetch("test").fetch("targets").any? { |entry| entry["name"] == "SendmeterNativeTests" }
watch_scheme = spec.fetch("schemes").fetch("SendLogWatch Watch App")
abort "Watch scheme misses Watch app" unless watch_scheme.fetch("build").fetch("targets").key?("SendLogWatch Watch App")
abort "Watch scheme misses Watch widget" unless watch_scheme.fetch("build").fetch("targets").key?("SendLogWatchWidgets")

puts "native-watch-project: generated phone + Watch graph ownership verified"
