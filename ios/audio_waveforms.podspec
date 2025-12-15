#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint audio_waveforms.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'audio_waveforms'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter project.'
  s.description      = <<-DESC
A new Flutter project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.prefix_header_file = 'Classes/audio_waveforms-Prefix.pch'

  s.dependency 'Flutter'
  s.vendored_frameworks = 'Frameworks/webrtc_audio_processing.xcframework'
  s.platform = :ios, '8.0'  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
  'DEFINES_MODULE' => 'YES',
  'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Frameworks/webrtc_audio_processing.xcframework/ios-arm64/webrtc_audio_processing.framework/Headers" "${PODS_TARGET_SRCROOT}/Frameworks/webrtc_audio_processing.xcframework/ios-arm64/webrtc_audio_processing.framework/Headers/webrtc-audio-processing-1"',
   }
  s.swift_version = '5.0'
end
