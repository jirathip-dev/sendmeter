#!/usr/bin/env ruby
# Verify the XcodeGen spec owns the retained phone and Watch source trees.
require "yaml"

repo = File.expand_path("..", __dir__)
spec_path = File.join(repo, "native/SendmeterNative/project.yml")
spec = YAML.load_file(spec_path)
targets = spec.fetch("targets")

required = {
  "SendmeterNative" => ["Sources/App", "Sources/Data", "Sources/Platform", "Sources/Features", "Sources/Shared"],
  "SendLogWatch Watch App" => ["../../ios/App/SendLogWatch Watch App"],
  "SendLogWatchWidgets" => ["../../ios/App/SendLogWatchWidgets"],
}
required.each do |target, paths|
  sources = targets.fetch(target).fetch("sources").map { |entry| entry.is_a?(String) ? entry : entry.fetch("path") }
  paths.each do |path|
    abort "#{target} does not consume #{path}" unless sources.include?(path)
  end
end

abort "legacy Capacitor project is still referenced" if spec.to_s.match?(/CapApp-SPM|ios\/App\/App\.xcodeproj|Capacitor/)
puts "native-watch-project: native phone + Watch source ownership verified"
