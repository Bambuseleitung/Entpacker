platform :ios, '16.0'
use_frameworks!

# Pods werden von XcodeGen nicht erzeugt: erst `xcodegen`, dann `pod install`.
target 'Entpacker' do
  pod 'MobileVLCKit', '3.7.5'  # spielt praktisch jedes Video-/Audioformat
  pod 'UnrarKit', '2.9'        # RAR, mit Passwort, streamt auf die Platte
  pod 'SSZipArchive', '2.6.0'  # ZIP, mit Passwort (ZipCrypto und AES), streamt auf die Platte
  # 7z, mit Passwort und verschlüsselten Dateilisten, streamt auf die Platte; 1.5.1 ist nicht im Trunk, daher per Git
  pod 'PLzmaSDK/Swift', :git => 'https://github.com/OlehKulykov/PLzmaSDK.git', :tag => '1.5.1'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0' }
  end
end
