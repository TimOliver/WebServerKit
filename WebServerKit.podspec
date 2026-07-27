Pod::Spec.new do |s|
  s.name     = 'WebServerKit'
  s.version  = '4.0.0'
  s.author   = [ 'Pierre-Olivier Latour', 'Tim Oliver' ]
  s.license  = { :type => 'BSD', :file => 'LICENSE' }
  s.homepage = 'https://github.com/TimOliver/WebServerKit'
  s.summary  = 'Embedded HTTP, WebDAV and file-upload server for macOS, iOS and tvOS. A hardened fork of GCDWebServer.'

  s.source   = { :git => 'https://github.com/TimOliver/WebServerKit.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.tvos.deployment_target = '15.0'
  s.requires_arc = true

  s.default_subspec = 'Core'

  # Paths are relative to the repository root, where the sources live under "Sources/".
  # The framework links the same set of system libraries on every platform (see
  # OTHER_LDFLAGS in WebServerKit.xcodeproj), so the declarations below are not
  # per-platform either.
  s.subspec 'Core' do |cs|
    cs.source_files = 'Sources/WebServerKit/**/*.{h,m}'
    # include/ holds symlinks to the public headers so SwiftPM can expose them as the
    # WebServerKit module (see Package.swift). CocoaPods reads the real files directly and
    # would otherwise see each header twice.
    cs.exclude_files = 'Sources/WebServerKit/include/**/*'
    cs.private_header_files = 'Sources/WebServerKit/Core/WSKPrivate.h'
    cs.requires_arc = true
    cs.library = 'z'
    # UniformTypeIdentifiers is present on every OS this ships against, so it is a hard
    # link rather than a weak one, and the CoreServices MIME fallback it replaced is gone.
    cs.frameworks = 'CFNetwork', 'SystemConfiguration', 'UniformTypeIdentifiers'
  end

  s.subspec 'WebDAV' do |cs|
    cs.dependency 'WebServerKit/Core'
    cs.source_files = 'Sources/WebServerKitDAV/*.{h,m}'
    cs.requires_arc = true
    cs.library = 'xml2'
    cs.compiler_flags = '-I$(SDKROOT)/usr/include/libxml2'
  end

  s.subspec 'WebUploader' do |cs|
    cs.dependency 'WebServerKit/Core'
    cs.source_files = 'Sources/WebServerKitUploader/*.{h,m}'
    # Implementation detail of the SSE endpoint, not part of the public API.
    cs.private_header_files = 'Sources/WebServerKitUploader/WSKWebUploaderSSEChannel.h'
    cs.requires_arc = true
    cs.resources = 'Sources/WebServerKitUploader/WSKWebUploader.bundle'
  end
end
