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
  # FFI via DynamicLibrary.process() exige os simbolos vivos no binario:
  # sem referencia nativa o linker dead-strip o arquivo estatico e o dlsym
  # falha (llama_backend_init: symbol not found). Forca a resolucao de todos
  # os simbolos usados pelo motor Dart.
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '-Wl,-u,_llama_backend_init -Wl,-u,_llama_batch_free -Wl,-u,_llama_batch_init -Wl,-u,_llama_context_default_params -Wl,-u,_llama_decode -Wl,-u,_llama_free -Wl,-u,_llama_get_logits_ith -Wl,-u,_llama_get_memory -Wl,-u,_llama_init_from_model -Wl,-u,_llama_memory_clear -Wl,-u,_llama_memory_seq_rm -Wl,-u,_llama_model_default_params -Wl,-u,_llama_model_free -Wl,-u,_llama_model_get_vocab -Wl,-u,_llama_model_load_from_file -Wl,-u,_llama_model_n_embd -Wl,-u,_llama_n_ctx -Wl,-u,_llama_sampler_accept -Wl,-u,_llama_sampler_chain_add -Wl,-u,_llama_sampler_chain_default_params -Wl,-u,_llama_sampler_chain_init -Wl,-u,_llama_sampler_free -Wl,-u,_llama_sampler_init_dist -Wl,-u,_llama_sampler_init_dry -Wl,-u,_llama_sampler_init_greedy -Wl,-u,_llama_sampler_init_min_p -Wl,-u,_llama_sampler_init_penalties -Wl,-u,_llama_sampler_init_temp -Wl,-u,_llama_sampler_init_top_k -Wl,-u,_llama_sampler_init_top_p -Wl,-u,_llama_sampler_sample -Wl,-u,_llama_set_n_threads -Wl,-u,_llama_tokenize -Wl,-u,_llama_token_to_piece -Wl,-u,_llama_vocab_eos -Wl,-u,_llama_vocab_is_eog -Wl,-u,_llama_vocab_n_tokens' }
end
