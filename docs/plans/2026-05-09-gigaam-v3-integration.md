# Интеграция GigaAM v3 в VoiceInk

## Overview

Добавить GigaAM v3 E2E RNN-T (Sber, MIT) как четвёртого локального транскрипционного провайдера наряду с Whisper, Parakeet (FluidAudio) и Apple Speech. Цель — качественное офлайн-распознавание русского языка с пунктуацией и капитализацией. Runtime — sherpa-onnx через SwiftPM, веса ~327 МБ скачиваются по запросу из настроек (тот же паттерн, что у Whisper и FluidAudio). Это demo-уровень для локальной проверки качества; production-полировка вне scope.

Полный архитектурный дизайн и обоснование решения — в `PLAN.md` в корне репозитория.

## Context

- Опорный референс: `govorun-lite/` (Android, использует sherpa-onnx + GigaAM v3 в проде) — конфиг копируется один-в-один
- Шаблон для всех новых файлов: `VoiceInk/Transcription/FluidAudio/*` + `VoiceInk/Views/AI Models/FluidAudioModelCardView.swift`
- Файлы для модификации:
  - `VoiceInk/Models/TranscriptionModel.swift` (enum `ModelProvider`, новая структура `GigaAMModel`)
  - `VoiceInk/Models/TranscriptionModelRegistry.swift` (добавить инстанс в `predefinedModels`)
  - `VoiceInk/Models/LanguageDictionary.swift` (ветка `.gigaAM` → только `ru`)
  - `VoiceInk/Transcription/Engine/TranscriptionServiceRegistry.swift` (lazy сервис + ветка switch)
  - `VoiceInk/Transcription/Engine/TranscriptionModelManager.swift` (поле `gigaAMModelManager`, ветка `usableModels`)
  - `VoiceInk/VoiceInk.swift` (`VoiceInkApp` — `@StateObject`, прокидывание `environmentObject`)
  - `VoiceInk/Views/AI Models/ModelCardView.swift` (ветка switch)
  - `VoiceInk/Views/AI Models/ModelManagementView.swift` (расширение `.local`-фильтра)
- Новые файлы:
  - `VoiceInk/Transcription/GigaAM/GigaAMModelManager.swift`
  - `VoiceInk/Transcription/GigaAM/GigaAMTranscriptionService.swift`
  - `VoiceInk/Views/AI Models/GigaAMModelCardView.swift`
- Внешние зависимости: `https://github.com/k2-fsa/sherpa-onnx` (SwiftPM, версия 1.13.0); веса с `https://huggingface.co/istupakov/gigaam-v3-onnx` (публичные, без gating)

## Development Approach

- **Тестирование**: ручная верификация через smoke-test (этот проект — macOS-приложение с внешними ML-зависимостями; unit-тесты для интеграции SDK не информативны). Каждая задача завершается успешной сборкой `make all`. Финальная верификация — пошаговый smoke-test (Task 7, повторяет раздел «Верификация» из PLAN.md).
- Делать задачи строго по порядку — каждая следующая опирается на предыдущую.
- Не трогать: AI Enhancement, Power Mode, hotkeys, Recorder, MenuBar, SwiftData, streaming pipeline, `Makefile`, `LocalBuild.xcconfig`, entitlements.
- Демка работает только для русского языка; стриминг отключён (`supportsStreaming = false`).
- **CRITICAL: каждая задача завершается успешной сборкой `make all` перед переходом к следующей.**

## Implementation Steps

### Task 1: Подключить sherpa-onnx через SwiftPM

**Files:**
- Modify: `VoiceInk.xcodeproj/project.pbxproj` (через Xcode UI: File → Add Packages…)

- [x] ~~В Xcode добавить package `https://github.com/k2-fsa/sherpa-onnx`, версия от `1.13.0`~~ — k2-fsa/sherpa-onnx не публикует Package.swift, перешли на fallback (см. ниже)
- [x] ~~Подключить SPM-продукт `sherpa-onnx` к таргету `VoiceInk`~~ — заменено на xcframework reference в project.pbxproj
- [x] Создать минимальный probe в любом существующем файле: `import SherpaOnnx` + один вызов фабрики (`SherpaOnnxGetVersionStr`); удалён после проверки сборки
- [x] `make all` — сборка проходит
- [x] Fallback применён: `Scripts/setup-sherpa-onnx.sh` скачивает prebuilt `sherpa-onnx-v1.13.0-macos-xcframework-static.tar.bz2` + `onnxruntime-osx-universal2-static_lib-1.24.4.zip`, объединяет `.a`-библиотеки через `libtool`, кладёт в `~/VoiceInk-Dependencies/sherpa-onnx/sherpa-onnx.xcframework/` и пишет туда `module.modulemap` (`module SherpaOnnx`). Run Script Build Phase «Setup sherpa-onnx» в проекте запускает скрипт перед компиляцией.

### Task 2: Расширить базовые типы и реестр

**Files:**
- Modify: `VoiceInk/Models/TranscriptionModel.swift`
- Modify: `VoiceInk/Models/TranscriptionModelRegistry.swift`
- Modify: `VoiceInk/Models/LanguageDictionary.swift`

- [x] В enum `ModelProvider` добавить `case gigaAM = "GigaAM"`
- [x] Создать структуру `GigaAMModel: TranscriptionModel` по образцу `FluidAudioModel`: `provider = .gigaAM`, `size = "327 MB"`, `supportsStreaming = false`, `isMultilingualModel = false`, `supportedLanguages = ["ru": "Russian"]`
- [x] Добавить `static let gigaAmV3RnntInt8 = GigaAMModel(name: "gigaam-v3-rnnt-int8", displayName: "GigaAM v3 (Russian)", ...)`
- [x] В `TranscriptionModelRegistry.predefinedModels` добавить `GigaAMModel.gigaAmV3RnntInt8` после блока FluidAudio
- [x] В `LanguageDictionary.forProvider` добавить ветку `.gigaAM` → `["ru": "Russian"]`
- [x] `make all` — сборка проходит

### Task 3: Менеджер модели (загрузка / проверка / удаление)

**Files:**
- Create: `VoiceInk/Transcription/GigaAM/GigaAMModelManager.swift`

- [x] Создать `@MainActor final class GigaAMModelManager: ObservableObject` по шаблону `FluidAudioModelManager.swift`
- [x] `gigaAMModelDirectory()` → `~/Library/Application Support/com.prakashjoshipax.VoiceInk/Models/GigaAM/<modelName>/` (унифицировано с существующей конвенцией; план описывал упрощённый путь)
- [x] Прямая загрузка 4 файлов через `URLSession` с `https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/main/<filename>`. Точные имена сверены через WebFetch: `v3_e2e_rnnt_encoder.int8.onnx`, `v3_e2e_rnnt_decoder.onnx`, `v3_e2e_rnnt_joint.onnx`, `v3_e2e_rnnt_vocab.txt`
- [x] API: `isGigaAMModelDownloaded(named:) -> Bool`, `downloadGigaAMModel(_:) async throws`, `deleteGigaAMModel(_:)`, `cancelDownload(for:)`
- [x] `@Published downloadStatuses: [String: GigaAMDownloadStatus]`, `@Published downloadProgress: [String: Double]`
- [x] Callbacks `onModelDeleted`, `onModelsChanged` (как в `FluidAudioModelManager`)
- [x] SHA-256 проверка скачанных файлов (хеши взяты у govorun-lite mirror, который ребэндит файлы без изменения байт; считаются через `CryptoKit.SHA256` поточно, без загрузки в память)
- [x] `make all` — сборка проходит

### Task 4: Сервис транскрипции

**Files:**
- Create: `VoiceInk/Transcription/GigaAM/GigaAMTranscriptionService.swift`

- [x] Создать `@MainActor final class GigaAMTranscriptionService: TranscriptionService` по шаблону `FluidAudioTranscriptionService.swift`
- [x] `ensureLoaded(modelName:)`: построить `SherpaOnnxOfflineRecognizerConfig` с `transducer` (encoder/decoder/joiner), `tokens`, `num_threads: 2`, `model_type: "nemo_transducer"`, провайдер `"coreml"` с fallback на `"cpu"` (после возврата `nil` из `SherpaOnnxCreateOfflineRecognizer`)
- [x] `transcribe(audioURL:model:)`: прочитать PCM16LE → Float32 [-1,1] @ 16 kHz mono; `SherpaOnnxCreateOfflineStream` → `SherpaOnnxAcceptWaveformOffline` → `SherpaOnnxDecodeOfflineStream` → `SherpaOnnxGetOfflineStreamResult().text`. Тяжёлый decode выведен в `Task.detached(priority: .userInitiated)`, чтобы не блокировать main actor.
- [x] Прогнать результат через `TextNormalizer.shared.normalizeSentence(...)` (импорт из FluidAudio пакета)
- [x] Уточнено по факту: Swift импортирует C-API напрямую (модуль `SherpaOnnx`), типы handle-ов — `OpaquePointer?`. Swift-обёртка sherpa-onnx отсутствует, поэтому используем сырые `SherpaOnnx*` функции; имена строго PascalCase из `c-api.h`.
- [x] VAD-чанкинг не делаем; sherpa-onnx проглатывает длинный буфер
- [x] `make all` — сборка проходит

### Task 5: Регистрация сервиса и менеджера в движке

**Files:**
- Modify: `VoiceInk/Transcription/Engine/TranscriptionServiceRegistry.swift`
- Modify: `VoiceInk/Transcription/Engine/TranscriptionModelManager.swift`
- Modify: `VoiceInk/VoiceInk.swift`

- [x] В `TranscriptionServiceRegistry`: `private(set) lazy var gigaAMTranscriptionService = GigaAMTranscriptionService()` и ветка `case .gigaAM: return gigaAMTranscriptionService` в `service(for:)`
- [x] В `TranscriptionModelManager`: добавить `var gigaAMModelManager: GigaAMModelManager?` и в `usableModels` ветку `case .gigaAM: return gigaAMModelManager?.isGigaAMModelDownloaded(named: model.name) ?? false`
- [x] В `VoiceInkApp` (`VoiceInk.swift`): `@StateObject var gigaAMModelManager = GigaAMModelManager()`, прокинуть в `TranscriptionModelManager`, добавить `.environmentObject(gigaAMModelManager)` ко всем нужным view (по образцу `fluidAudioModelManager`)
- [x] `make all` — сборка проходит

### Task 6: UI-карточка модели

**Files:**
- Create: `VoiceInk/Views/AI Models/GigaAMModelCardView.swift`
- Modify: `VoiceInk/Views/AI Models/ModelCardView.swift`
- Modify: `VoiceInk/Views/AI Models/ModelManagementView.swift`

- [ ] Создать `GigaAMModelCardView` по шаблону `FluidAudioModelCardView.swift`: кнопки Download / Cancel / Delete / Set as default; прогресс-бар читает `gigaAMModelManager.downloadStatuses[model.name]`
- [ ] В `ModelCardView` добавить ветку `case .gigaAM: if let m = model as? GigaAMModel { GigaAMModelCardView(model: m, ...) }`
- [ ] В `ModelManagementView.swift` (~line 320) расширить фильтр `.local`: добавить `|| $0.provider == .gigaAM`
- [ ] `make all` — сборка проходит
- [ ] `make dev` — приложение запускается, в Settings → AI Models → фильтр Local появилась карточка GigaAM v3 (Russian)

### Task 7: Smoke-test финальной интеграции

- [ ] `make all` — полная сборка без ошибок
- [ ] `make dev` — приложение запускается
- [ ] Settings → AI Models → фильтр Local — карточка «GigaAM v3 (Russian)» видна
- [ ] Нажать Download — прогресс-бар движется; в `~/Library/Application Support/VoiceInk/Models/GigaAM/v3-rnnt-int8/` появляются 4 файла суммарно ~327 МБ
- [ ] Set as Default — `UserDefaults["CurrentTranscriptionModel"]` содержит `gigaam-v3-rnnt-int8`
- [ ] Записать русскую фразу через хоткей — текст распознан с пунктуацией и заглавными буквами (маркер того, что загружен именно `e2e_rnnt`)
- [ ] Записать английскую фразу — мусор/транслитерация (ожидаемо, Russian-only)
- [ ] Нажать Delete — файлы удалены, карточка снова показывает Download
- [ ] Перезапуск приложения — выбранная модель восстановлена из `UserDefaults`

### Task 8: Финализация

- [ ] Обновить `CLAUDE.md` секцию архитектуры — добавить упоминание GigaAM как четвёртого локального провайдера
- [ ] Переместить этот план в `docs/plans/completed/`
- [ ] (Опционально, для прод-полировки — вне scope демки) добавить `LICENSE-GigaAM` (MIT) и упоминание в About
