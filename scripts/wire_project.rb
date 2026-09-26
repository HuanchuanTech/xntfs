#!/usr/bin/env ruby
# Wires libntfs-3g + the C bridge into the ntfs3g extension target, and sets the
# app target's entitlements. Idempotent.
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
proj = Xcodeproj::Project.open(File.join(ROOT, 'xntfs.xcodeproj'))

def merge(settings, key, values)
  cur = settings[key]
  arr = cur.nil? ? ['$(inherited)'] : (cur.is_a?(Array) ? cur.dup : [cur])
  values.each { |v| arr << v unless arr.include?(v) }
  settings[key] = arr
end

ext = proj.targets.find { |t| t.name == 'ntfs3g' }
raise 'ntfs3g target not found' unless ext
ext.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['SWIFT_OBJC_BRIDGING_HEADER'] = 'ntfs3g/ntfs3g-Bridging-Header.h'
  s['SWIFT_VERSION'] = '5.0'
  s['CLANG_ENABLE_MODULES'] = 'YES'
  s.delete('ARCHS')
  s.delete('VALID_ARCHS')
  merge(s, 'HEADER_SEARCH_PATHS', ['$(SRCROOT)/ntfs-3g', '$(SRCROOT)/ntfs-3g/include'])
  generated_headers = '$(SRCROOT)/build/libntfs-universal'
  s['HEADER_SEARCH_PATHS'] = [generated_headers] + Array(s['HEADER_SEARCH_PATHS']).reject { |path| path == generated_headers }
  merge(s, 'GCC_PREPROCESSOR_DEFINITIONS', ['HAVE_CONFIG_H=1'])
  old_library = '$(SRCROOT)/ntfs-3g/libntfs-3g/.libs/libntfs-3g.a'
  s['OTHER_LDFLAGS'] = Array(s['OTHER_LDFLAGS']).reject { |flag| flag == old_library }
  merge(s, 'OTHER_LDFLAGS', ['$(SRCROOT)/build/libntfs-universal/libntfs-3g.a', '-framework', 'CoreFoundation'])
end

app = proj.targets.find { |t| t.name == 'xntfs' }
if app
  app.build_configurations.each do |cfg|
    cfg.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'xntfs/xntfs.entitlements'
  end
end

# Localization: register Simplified Chinese.
regions = proj.root_object.known_regions || []
regions << 'zh-Hans' unless regions.include?('zh-Hans')
proj.root_object.known_regions = regions

proj.save
puts "Wired ntfs3g build settings; app entitlements set."
ext.build_configurations.each do |c|
  puts "  [#{c.name}] OTHER_LDFLAGS=#{c.build_settings['OTHER_LDFLAGS'].inspect}"
end
