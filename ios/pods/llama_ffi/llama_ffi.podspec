Pod::Spec.new do |s|
  s.name         = 'llama_ffi'
  s.version      = '1.0.0'
  s.summary      = 'llama.cpp b11217 estatico para offline-ai-mobile'
  s.homepage     = 'https://github.com/frederico-kluser/offline-ai-mobile'
  s.license      = { :type => 'MIT' }
  s.author       = 'offline-ai-mobile'
  s.source       = { :path => '.' }
  s.platform     = :ios, '16.0'
  s.vendored_frameworks = 'llama.xcframework'
  s.static_framework = true
  s.libraries    = 'c++'
  s.frameworks   = 'Foundation', 'Metal', 'MetalKit', 'Accelerate'
  # O link do arquivo estatico e forcado no Podfile (force_load por SDK):
  # o vendored_frameworks com .a dentro de xcframework nao entra na linha
  # de link do CocoaPods.
end
