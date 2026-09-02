#
# Bundles the prebuilt universal libtailcat_core.dylib (built by
# build/build_macos.sh and copied here by build/sync_libs.sh) into the app.
#
Pod::Spec.new do |s|
  s.name             = 'tailcat_core_ffi'
  s.version          = '0.1.0'
  s.summary          = 'Tailcat GUI Go core (prebuilt dylib) for dart:ffi.'
  s.description      = <<-DESC
Prebuilt Go shared library exposing the Tailcat GUI JSON command/event API.
                       DESC
  s.homepage         = 'https://github.com/tailscale/tailcat'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Tailcat GUI' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  s.vendored_libraries = 'Libraries/libtailcat_core.dylib'
  s.preserve_paths     = 'Libraries/libtailcat_core.dylib'

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '11.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
