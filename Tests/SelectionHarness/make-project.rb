# Generate an isolated simulator test project (requires the xcodeproj Ruby gem).
# ruby Tests/SelectionHarness/make-project.rb /tmp/selection-qa
# xcodebuild -project /tmp/selection-qa/SelectionHarness.xcodeproj -scheme SelectionHarness \
#   -destination 'platform=iOS Simulator,id=<dedicated-simulator-UDID>' test
# Uses production sources directly. No application databases, entitlements or network clients.
require 'xcodeproj'
require 'fileutils'
root=File.expand_path('../..', __dir__)
out=File.expand_path(ARGV.fetch(0))
FileUtils.mkdir_p(out)
p=Xcodeproj::Project.new(out+'/SelectionHarness.xcodeproj')
a=p.new_target(:application,'SelectionHarness',:ios,'17.0')
t=p.new_target(:ui_test_bundle,'SelectionHarnessUITests',:ios,'17.0')
t.add_dependency(a)
[a,t].each do |target|
 target.build_configurations.each do |c|
  c.build_settings.merge!({'SWIFT_VERSION'=>'5.0','GENERATE_INFOPLIST_FILE'=>'YES','CODE_SIGNING_ALLOWED'=>'NO','PRODUCT_BUNDLE_IDENTIFIER'=>'com.alvarofranz.moshroom.selection-tests'+(target==t ? '.uitests' : ''),'TARGETED_DEVICE_FAMILY'=>'1,2','SUPPORTED_PLATFORMS'=>'iphonesimulator','IPHONEOS_DEPLOYMENT_TARGET'=>'17.0'})
 end
end
a.build_configurations.each{|c| c.build_settings.merge!({'INFOPLIST_KEY_UILaunchScreen_Generation'=>'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations'=>'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight','INFOPLIST_KEY_CFBundleDisplayName'=>'Selection QA'})}
t.build_configurations.each{|c|c.build_settings['TEST_TARGET_NAME']='SelectionHarness'}
['Moshroom/WebKit/TerminalSelection.swift','Moshroom/WebKit/WKWebView.swift','Moshroom/UIKit/UIColor.swift','Moshroom/UIKit/UIGestureRecognizer.swift'].each{|f|a.source_build_phase.add_file_reference(p.main_group.new_file(root+'/'+f))}
a.source_build_phase.add_file_reference(p.main_group.new_file(root+'/Tests/SelectionHarness/App.swift'))
t.source_build_phase.add_file_reference(p.main_group.new_file(root+'/Tests/SelectionHarness/SelectionUITests.swift'))
FileUtils.mkdir_p(out+'/TerminalResources')
Dir.glob(root+'/Resources/*').select{|f|File.file?(f)}.each{|f|FileUtils.cp(f,out+'/TerminalResources')}
a.resources_build_phase.add_file_reference(p.main_group.new_file(out+'/TerminalResources'))
s=Xcodeproj::XCScheme.new
s.add_build_target(a)
s.set_launch_target(a)
s.add_test_target(t)
s.save_as(p.path,'SelectionHarness',true)
p.save
