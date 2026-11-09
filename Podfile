platform :ios, '16.0'
use_frameworks!

# Pods werden von XcodeGen nicht erzeugt: erst `xcodegen`, dann `pod install`.
target 'Entpacker' do
  pod 'MobileVLCKit', '3.7.5' # spielt praktisch jedes Video-/Audioformat
  pod 'UnrarKit', '2.9'       # RAR
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0' }
  end
end
