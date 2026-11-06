# Hashes e tamanhos exatos

Gerado a partir de `models-repo/manifest.json` (release `models-lfm3-suite-v1`).
Os links de download por bundle estão em [`modelos.md`](modelos.md); os GGUF/mmproj
existem no release do espelho e os ONNX no Hugging Face oficial.

> Unidades: bytes decimais, sem separadores (para pesquisa literal). SHA-256 completo;
> onde o manifesto não tinha SHA, fica `—`.

## lfm3-1.7b-q4_0 — LFM3-1.7B · QAD-Q4_0 (essencial)

Tipo: `gguf` · total: **1049615680 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `LFM3-1.7B-QAD-Q4_0.gguf` | 1049615680 | `43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452` |

## lfm3-1.7b-q4_k_m — LFM3-1.7B · Q4_K_M (qualidade+)

Tipo: `gguf` · total: **1099627808 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `LFM3-1.7B-Q4_K_M.gguf` | 1099627808 | `3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4` |

## lfm3-1.7b-q8_0 — LFM3-1.7B · Q8_0 (máxima qualidade)

Tipo: `gguf` · total: **1846238496 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `LFM3-1.7B-Q8_0.gguf` | 1846238496 | `8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6` |

## lfm3-vl-2b-q4_k_m — LFM3-VL-2B · Q4_K_M + mmproj Q8_0

Tipo: `gguf` · total: **1302659680 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `LFM3-VL-2B-Q4_K_M.gguf` | 1099627808 | `56dac2e192ff0d9ab8507f4f1aeb4aed0463449bbbefaac79497f041c95f21eb` |
| `mmproj-LFM3-VL-2B-Q8_0.gguf` | 203031872 | `c5c5b58d544a18da919172d2d0368090ea1a4a351b6feb7f8a326a264a5918ab` |

## lfm3-audio-2b-q4_k_m — LFM3-Audio-2B · Q4_K_M + mmproj Q8_0

Tipo: `gguf` · total: **1403437856 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `LFM3-Audio-2B-Q4_K_M.gguf` | 1099626016 | `9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2` |
| `mmproj-LFM3-Audio-2B-Q8_0.gguf` | 303811840 | `2b6648b1fd48af16aa0877b0592b144d15070783673e038a379fdbc51d40e365` |

## lfm3-omni-2b-q4_k_m — LFM3-Omni-2B · Q4_K_M + mmproj Q4_K_M

Tipo: `gguf` · total: **1391216800 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `LFM3-Omni-2B-Q4_K_M.gguf` | 1099630080 | `9f8d30e9d4fd7a9349d586e077988229b3ca0a0e4ad730897563d1eccc9893e2` |
| `mmproj-LFM3-Omni-2B-Q4_K_M.gguf` | 291586720 | `0a746c0794782a16d4456b230c2a0b5888a2d94a6677211edbed7d7a4177a39a` |

## d1-2b-q4_k_m — d1-2B · Q4_K_M + mmproj Q8_0 (System One)

Tipo: `gguf` · total: **1302661472 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `d1-2B-Q4_K_M.gguf` | 1099629888 | `adca5789ad30ae6027e8e936749bb9f19673097492ab26fa1c5b69643ca50b4b` |
| `mmproj-d1-2B-Q8_0.gguf` | 203031584 | `62cc6d74fd1e5b1d6b48518566bf4c0cfd2468079a0c096ea323b74eed01e0d1` |

## d1-omni-2b-q8_0 — d1-Omni-2B · Q8_0 + mmproj Q8_0

Tipo: `gguf` · total: **2172345280 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `d1-Omni-2B-Q8_0.gguf` | 1846241184 | `aedf1a7c341b4281979423dbc39e9c3d3ad1da8834156c8e75af5399ca3b0861` |
| `mmproj-d1-Omni-2B-Q8_0.gguf` | 326104096 | `31778160ac0ec70f9b59f296aa1c8e70cbd1eb7e3a3ff873d695aaa4c7b8d674` |

## d1-omni-600m-legacy-q8_0 — d1-omni-600M · Q8_0 (legado LFM2)

Tipo: `gguf` · total: **669998816 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `d1-omni-600M-Q8_0.gguf` | 407207584 | `cd94463f4cac9c700ec6750df8df005bb6846de410e159d1f5e985e1171693d3` |
| `mmproj-d1-omni-600M-Q8_0.gguf` | 262791232 | `df887978550cdbb45f0f57d7b436a0f844689f9f561395a144ced500606c3a89` |

## d1-2b-onnx-q4 — d1-2B-ONNX · q4 + visão q8 (todas as primitivas)

Tipo: `onnx` · total: **1956370411 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `decoder_q4.onnx` | 358945 | `00b77894a36d92c0d455db07f39743c0fa814f5855aa060b75b8dace1654065f` |
| `decoder_q4.onnx_data` | 1741806592 | `e72031f1b00e3273e286b4125d1b58c20b59c7e031bd791796277e0fab65b14b` |
| `vision_encoder_q8.onnx` | 126353 | `ea9421f2a7fa8bc401bee96b1077be522b8d448e82e46c9117f2bc90eb01caac` |
| `vision_encoder_q8.onnx_data` | 196153344 | `baff3c8cf1dd0b4d8dd3108850558a7f26fafb55367be7bcf98d02739c162d1d` |
| `tokenizer.json` | 17908258 | `a39eed58008cbcbc09e5b629b81338a654269c64cd13348aaa6090f4db75c7e7` |
| `processor_config.json` | 1254 | `37396ef3370083a04381ef25f9e1b50dec184b8cdcf08cf718feb8944ad8f3bc` |
| `chat_template.jinja` | 12762 | `17f33d44f7bd01aa94623dd8bf8e4e0ef80580a725ef8b71dc6b78f6bcc11700` |
| `config.json` | 2903 | `ffdc4c996152d23dbe8a2659a8c6aabe2992aa3fa3a41601dd0fca8771d6f332` |

## d1-omni-2b-onnx-q4 — d1-Omni-2B-ONNX · q4 + visão/áudio (áudio + voz)

Tipo: `onnx` · total: **2211713082 bytes**

| Ficheiro | Bytes | SHA-256 |
|---|---:|---|
| `decoder_q4.onnx` | 360831 | `d3d54dfb740c761e21ffc4eec0e3546c2f0b7453d4514f357191786585a67681` |
| `decoder_q4.onnx_data` | 1741806592 | `59df2ee2430b3973edab00ba14771e3da849f476251ada487949cd09e8314d10` |
| `vision_encoder_q8.onnx` | 126353 | `5447beba4d5c66315fc561372d71f7d56c6a201c966639c8f029e53f6c0dd483` |
| `vision_encoder_q8.onnx_data` | 196153344 | `f55c525bd4502ad0f748836bc119e02e7126d6e7c698ca74365c2785d3cd2122` |
| `audio_encoder_fp16.onnx` | 163115 | `20a7c84d1f3b5ca39e6f1903b9482ec68bc16a841b637d4684b72c679036110e` |
| `audio_encoder_fp16.onnx_data` | 255173120 | `d7d67ea09bda583fe346097af9f06ba03c92e47870e475f1c65604677581b878` |
| `tokenizer.json` | 17908634 | `41927bd314d17d7d7fadb44e10cd0919f7b71528d7741596d8cbd15c6945ec44` |
| `processor_config.json` | 1928 | `2288d34b7c0579593258b1c083de4ab8328a842fdb0190977363e573dbdcd0e5` |
| `chat_template.jinja` | 13363 | `—` |
| `config.json` | 5802 | `—` |

## Licença

`LICENSE` — 10574 bytes — `4d28ca14dedc0b3d0fcc2b3339f0e79931faa33874f3d24f522183a8fc70068c`
