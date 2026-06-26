# MacCam — Security-камера на базе веб-камеры Mac. Дизайн / спека

**Дата:** 2026-06-26
**Статус:** утверждено к реализации
**Источник требований:** `TZ_MacCam_security_camera.md`

## 1. Цель и границы

Нативное macOS-приложение, превращающее Mac в камеру наблюдения. Захват видео с
максимального доступного разрешения камеры, детекция движения, запись клипов на диск
при движении, полностью офлайн, живёт в меню-баре, минимальная нагрузка на CPU/батарею.

**В объёме v1 (MVP):** все критерии приёмки §9 ТЗ — захват с выбором max-формата,
детекция движения, запись с FSM, ротация, настройки, меню-бар, папка+bookmark,
аудио (по флагу), pre-roll (реализован, по умолчанию выкл.), guard-режим при блокировке
экрана, запуск при логине.

**Вне объёма v1:** зоны детекции, JPEG-снимки, локальные уведомления, несколько камер
одновременно, таймлапс, парольная защита (раздел §10 ТЗ — расширения).

## 2. Платформа, сборка, верификация

- **Min OS:** macOS 13.0 (Ventura). Цель — Apple Silicon (arm64).
- **Стек:** Swift 5.9+, SwiftUI (окно настроек) + AppKit `NSStatusItem` (меню-бар) через
  `NSApplicationDelegateAdaptor`. AVFoundation (захват/запись), Accelerate/vImage (детекция),
  ServiceManagement `SMAppService` (логин). Только системные фреймворки, без SPM-зависимостей.
- **Проект:** рукописный `MacCam.xcodeproj` (один app-таргет, без зависимостей). Открывается
  в Xcode, собирается `xcodebuild`. App Sandbox включён.
- **Подпись:** локальная ad-hoc/dev. Запуск собранного `.app` из CLI для проверки.
- **Верификация:**
  1. `xcodebuild ... build` → `BUILD SUCCEEDED`.
  2. Запуск `.app`: в лог печатается выбранное устройство и формат; в Settings отображается
     `WxH @ Nfps`.
  3. Детекция: движение в кадре → создаётся `.mov`; файл валиден, играется, кодек hevc
     (проверка через AVFoundation/`ffprobe`).
  4. Ротация по `maxClipLength`; остановка по cooldown; имена с timestamp.
  5. CPU в простое — единицы процентов.
  - Тесты, требующие физической камеры/выдачи TCC-доступа, выполняются с участием
    пользователя (один раз выдать доступ к камере в System Settings).

## 3. Архитектура

Один конвейер захвата обслуживает и детекцию, и запись.

```
AVCaptureSession
  ├── AVCaptureDeviceInput (камера, activeFormat = max)
  ├── AVCaptureDeviceInput (микрофон)            [если audioEnabled]
  ├── AVCaptureVideoDataOutput ──► CaptureDelegate (queue "capture.video")
  │        каждый видео CMSampleBuffer:
  │          1) RingBuffer.push(buffer)           [если preRollEnabled]
  │          2) motion = MotionDetector.analyze(buffer)   [throttle ~10–12 Гц]
  │          3) RecordingController.handle(video: buffer, motion: motion)
  └── AVCaptureAudioDataOutput ──► CaptureDelegate (queue "capture.audio") [если audioEnabled]
           каждый аудио CMSampleBuffer → RecordingController.handle(audio: buffer)
```

### Компоненты (файлы)

| Компонент | Ответственность | Зависит от |
|---|---|---|
| `MacCamApp` | `@main`, `NSApplicationDelegateAdaptor` | AppDelegate |
| `AppDelegate` | lifecycle, запрос прав, связывание компонентов, activationPolicy(.accessory) | все |
| `CameraManager` | конфиг `AVCaptureSession`, discovery, выбор устройства и max-формата, target FPS, старт/стоп, обработка disconnect/runtime-error | SettingsStore |
| `CaptureDelegate` | реализация video/audio sample buffer delegate, маршрутизация буферов | MotionDetector, RingBuffer, RecordingController |
| `MotionDetector` | даунскейл→grayscale→diff на vImage, доля изменившихся пикселей, маппинг чувствительности | SettingsStore |
| `RingBuffer` | кольцевой буфер последних `preRoll` секунд видеокадров (pre-roll) | — |
| `RecordingController` | FSM Idle/Recording, `AVAssetWriter`+инпуты, ротация, имена файлов, очистка | SettingsStore, FileStore, RingBuffer |
| `FileStore` | папка по умолчанию, NSOpenPanel-выбор, security-scoped bookmark, автоочистка старых клипов | — |
| `SettingsStore` | `ObservableObject`/`UserDefaults`, `@Published`, атомарный снимок параметров | — |
| `MenuBarController` | `NSStatusItem`, иконка состояний, меню Start/Stop/Open/Settings/Login/Quit | CameraManager, RecordingController |
| `LockMonitor` | `DistributedNotificationCenter` screen lock/unlock → guard-режим | — |
| `LaunchAtLogin` | `SMAppService.mainApp` register/unregister/status | — |

### Модель потоков и синхронизация

- Видео-кадры — последовательная очередь `capture.video`. На ней: throttle детекции (по PTS),
  pre-roll push, вызов FSM. Тяжёлой работы нет (детекция на 320×180, запись — аппаратный HEVC).
- Аудио-кадры — очередь `capture.audio`.
- `RecordingController` имеет внутренний lock: видео- и аудио-очереди безопасно аппендят в
  один writer; `startSession(atSourceTime:)` ставится по PTS первого видео-буфера.
- `SettingsStore` читается на очереди захвата через атомарный снимок (struct `Settings`),
  чтобы изменения из UI не рвали кадровую обработку.

## 4. Детектор движения

Алгоритм (vImage, на даунскейл-кадре):

1. `CVPixelBuffer` из `CMSampleBuffer`.
2. Даунскейл до 320×180 + grayscale (`vImageScale_*` + извлечение luminance / `vImageConvert`).
3. Хранить предыдущий уменьшенный grayscale-кадр. Считать попиксельную абсолютную разность
   (`vImageAbsoluteDifference_Planar8`).
4. Пиксель «изменился», если разность > `pixelDelta` (по умолчанию 25/255). Доля изменившихся
   пикселей = changed/total.
5. Движение, если доля > `motionThreshold`.
6. Чувствительность 0–4 → `motionThreshold` (логарифмическая шкала между 8% при 0 и 0.5% при 4).
7. Игнорировать первые 1–2 кадра после старта (нет предыдущего/прогрев).
8. Throttle: анализ ≤ ~10–12 Гц через сравнение PTS (пропуск кадров, попавших в окно < интервала).

Возврат `analyze` → `Bool` (есть движение) + опционально доля (для лога/калибровки).

## 5. Логика записи (RecordingController FSM)

- **Idle** + кадр `motion == true` → **Recording**: создать `AVAssetWriter`, video-инпут
  (+audio-инпут если включено), имя `MacCam_YYYY-MM-DD_HH-mm-ss.mov` локального времени в папке
  назначения. Если pre-roll вкл. — сначала записать кадры из `RingBuffer`, затем live.
- **Recording**:
  - аппендить все видео/аудио буферы (проверка `isReadyForMoreMediaData`);
  - сбрасывать таймер тишины при каждом новом движении;
  - нет движения дольше `postMotionCooldown` (по умолч. 5с) → finish, → **Idle**.
- **Ограничения длины:** `minClipLength` (5с) — слишком короткие клипы дописываются до минимума
  перед закрытием; `maxClipLength` (60с) — по достижении закрыть текущий файл и сразу открыть
  следующий (бесшовная ротация). Pre-roll применяется только к первому файлу серии.

### Параметры AVAssetWriter

- Контейнер `.mov`. Видео:
  ```
  AVVideoCodecKey: hevc            // h264 как опция
  AVVideoWidthKey / HeightKey: capture W/H
  AVVideoCompressionPropertiesKey:
      AVVideoAverageBitRateKey: bitrate(preset, resolution)
      AVVideoExpectedSourceFrameRateKey: fps
  ```
- Битрейт-пресеты: low/medium/high. Ориентир 1080p ≈ 6/9/12 Mbps, 4K ≈ 18/26/35 Mbps
  (масштаб от площади кадра).
- `expectsMediaDataInRealTime = true`. `startSession(atSourceTime:)` по PTS первого буфера.
- Аудио (если включено): AAC, привязка к тем же тайм-кодам.

## 6. Хранение файлов (FileStore)

- Папка по умолчанию `~/Movies/MacCam/` (создать при первом запуске).
- Выбор папки через `NSOpenPanel`; хранить как **security-scoped bookmark** (доступ между
  запусками в песочнице). `startAccessingSecurityScopedResource()` на время работы.
- Имя `MacCam_YYYY-MM-DD_HH-mm-ss.mov` (локальное время).
- Автоочистка: удалять клипы старше N дней (по умолчанию выкл.).
- Никакого сетевого кода.

## 7. Режимы работы

- **Monitoring:** ручной Start/Stop из меню. Камера активна, идёт детекция и запись по движению.
- **Guard (по блокировке экрана):** при `com.apple.screenIsLocked` авто-старт, при
  `com.apple.screenIsUnlocked` — стоп. Переключатель в настройках. Явный Start имеет приоритет
  над guard (ручной запуск не выключается разблокировкой; guard не глушит ручной режим).
- Реализация через `DistributedNotificationCenter`.

## 8. Меню-бар и UI

- `NSStatusItem`: иконка серая (выкл) / зелёная (мониторинг) / красная мигает (запись).
- Меню: Start/Stop Monitoring; статус («Recording…»/«Idle»/«Last clip: …»); Open clips folder…;
  Settings…; Launch at login (галка); Quit.
- `NSApp.setActivationPolicy(.accessory)` — agent-приложение без Dock-иконки (`LSUIElement`).
- **Settings (SwiftUI):** выбор камеры (+показ выбранного WxH@fps), чувствительность (слайдер 0–4),
  min/max длина клипа, cooldown, pre-roll вкл+секунды, запись звука вкл, целевой FPS (15/24/30),
  качество (low/medium/high), папка (кнопка выбора), автоочистка (вкл+дни), запуск при логине,
  guard-режим при блокировке.

## 9. Производительность

- Детекция только на даунскейл-кадре, throttle ≤ ~12 Гц.
- Один общий dispatch queue для video output; без блокировок тяжёлой работой.
- HEVC через аппаратный энкодер (≈бесплатно по CPU).
- В Idle writer не открыт, лишних аллокаций нет.
- Цель: простой — единицы % CPU; запись — низкая нагрузка.

## 10. Права и entitlements

- `Info.plist`: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` (если звук),
  `LSUIElement = YES`.
- `AVCaptureDevice.requestAccess(for:)` для камеры/микрофона; обработка отказа (сообщение +
  открыть System Settings privacy).
- App Sandbox entitlements: `com.apple.security.app-sandbox`,
  `com.apple.security.device.camera`, `com.apple.security.device.microphone`,
  `com.apple.security.files.user-selected.read-write`. Сетевых entitlements нет.

## 11. Структура проекта

```
MacCam/
├── MacCam.xcodeproj
├── MacCam/
│   ├── App/{MacCamApp.swift, AppDelegate.swift}
│   ├── Capture/{CameraManager.swift, CaptureDelegate.swift}
│   ├── Motion/{MotionDetector.swift, RingBuffer.swift}
│   ├── Recording/RecordingController.swift
│   ├── Storage/FileStore.swift
│   ├── System/{LockMonitor.swift, LaunchAtLogin.swift}
│   ├── UI/{MenuBarController.swift, SettingsView.swift, SettingsStore.swift}
│   ├── Assets.xcassets
│   ├── Info.plist
│   └── MacCam.entitlements
└── README.md
```

## 12. Параметры по умолчанию (сводно)

| Параметр | Default |
|---|---|
| camera | встроенная (builtInWideAngleCamera) |
| targetFPS | 30 |
| sensitivity (0–4) | 2 |
| pixelDelta | 25 |
| postMotionCooldown | 5 с |
| minClipLength | 5 с |
| maxClipLength | 60 с |
| preRollEnabled / preRoll | false / 3 с |
| audioEnabled | false |
| codec | hevc |
| quality | medium |
| folder | ~/Movies/MacCam/ |
| autoCleanup / days | false / 14 |
| guardMode | false |
| launchAtLogin | false |

## 13. Риски и обработка edge-cases

- Камера отключена на ходу: пауза, ретрай переоткрытия по
  `AVCaptureSessionRuntimeError`/device-disconnect; статус в меню.
- Отказ в правах: понятное сообщение + кнопка в System Settings; мониторинг не стартует.
- Смена настроек на лету: применять между клипами/кадрами через снимок `Settings`; смена
  камеры/FPS — переконфигурация сессии (stop→reconfigure→start).
- Bookmark устарел/папка недоступна: фолбэк на `~/Movies/MacCam/`, уведомить в меню/лог.
- Writer-ошибка: завершить клип, вернуться в Idle, лог; не падать.

## 14. План реализации

Подробный пошаговый план — отдельный документ (writing-plans), порядок ориентируется на §8 ТЗ:
скелет-agent → CameraManager+max-формат → MotionDetector → RecordingController(базовый) →
ротация/имена/папка → Settings(Store+View) → NSOpenPanel+bookmark → аудио → pre-roll →
guard+launch-at-login → полировка иконок/отказов/disconnect.
