# SimpleFaceitWidget — карта проекта

Нативное приложение + виджеты статистики FACEIT CS2 для **macOS** (Small/Medium/Large) и **iOS** (главный — Small).
Swift / SwiftUI / WidgetKit / App Intents / Swift Charts, хранение — SQLite + JSON в общем App Group.
Репозиторий: `github.com/k33ssa/SimpleFaceitWidget` (публиковать туда). Задачи — в `TODO.md`.

## Где что лежит

| путь | что |
|---|---|
| `Packages/FaceitKit/Sources/FaceitKit` | общий слой данных: `API/` (клиент Data API v4, DTO), `Model/`, `Stats/` (метрики, рейтинг, ELO), `Storage/` (SQLite, App Group, ключ, настройки), `Sync/StatsRepository.swift` (единая точка обновления) |
| `Packages/FaceitKit/Sources/FaceitUI` | общий SwiftUI: тема, компоненты (лента, кривая, кольцо уровня), раскладки виджетов 3 стиля × 3 размера |
| `Packages/FaceitKit/Sources/SnapshotTool` | рендер всех виджетов в PNG **на живых данных** (и иконки) — работает без Xcode |
| `Packages/FaceitKit/Tests` | тесты (swift-testing) + `Fixtures/` — настоящие ответы API игрока shmeeel от 14.11.2026 |
| `App/Shared` | код приложения (общий для macOS и iOS), ассеты, иконка |
| `App/macOS`, `App/iOS` | Info.plist / entitlements (генерирует XcodeGen) |
| `Widget/` | виджет-расширение: провайдер таймлайна, выбор стиля (AppIntent), кнопка «обновить» |
| `project.yml` | спецификация XcodeGen → `SimpleFaceitWidget.xcodeproj` (в git не кладётся) |
| `Config/Base.xcconfig` | общие настройки; `Config/Secrets.xcconfig` (в .gitignore) — `FACEIT_API_KEY` для личных сборок |
| `docs/API_RESEARCH.md` | что есть в FACEIT API, что нет (с источниками) |
| `docs/METRICS.md` | каждая метрика: источник, формула, период, пропуски; как считается ELO за 20 |
| `docs/ARCHITECTURE.md` | устройство обновления, кэша, дедупликации, хранения ключа |
| `docs/design/` | концепции дизайна и рендеры виджетов |

## Как запускать

```bash
# тесты и рендер виджетов — достаточно Command Line Tools
cd Packages/FaceitKit && swift test
FACEIT_API_KEY=$(cat ~/.config/faceit/api_key) swift run SnapshotTool --player shmeeel --out /tmp/snap   # → widgets-dark/light.png
swift run SnapshotTool --icon --out /tmp/icon

# macOS-приложение + виджет БЕЗ Xcode (основной путь на этом Маке): собрать, подписать, поставить в /Applications
./build.sh                       # ключ для личной сборки берётся из Config/Secrets.xcconfig (в .gitignore)

# приложения через Xcode (iOS и полная версия виджета с выбором стиля) — на GitHub Actions (.github/workflows/ci.yml)
# или локально, если когда-нибудь поставят Xcode:
hdiutil attach /Volumes/KINGSTON/xcode-dev/XcodeSSD.sparsebundle -nobrowse   # если не смонтирован
export DEVELOPER_DIR=/Volumes/XcodeSSD/Xcode-16.4.0.app/Contents/Developer       # путь уточнить по факту
xcodegen generate
xcodebuild -scheme SimpleFaceit-macOS -destination 'platform=macOS' -derivedDataPath /Volumes/XcodeSSD/DerivedData build
xcodebuild -scheme SimpleFaceit-iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /Volumes/XcodeSSD/DerivedData build
```

## Свой сервер (с 14.11.2026) — основной источник данных

* `server/` — Cloudflare Worker `https://simplefaceit.simplefaceit-server.workers.dev` (аккаунт пользователя, account id
  `557b316e8a30d7761f00ecf371d6fe9c`), база D1 `simplefaceit`. Прокси официального API (`/v1/data/<путь>`, белый список,
  кэш 45 с / матчи сутки), точный ELO `/v1/elo/<player_id>`, cron каждую минуту опрашивает отслеживаемых игроков и пишет
  «ELO после игры». Ключ FACEIT — только секрет воркера; приложение шлёт `Bearer APP_TOKEN`.
* Деплой: `cd server && CLOUDFLARE_API_TOKEN=$(cat ~/.config/cloudflare/api_token) CLOUDFLARE_ACCOUNT_ID=557b316e8a30d7761f00ecf371d6fe9c npx wrangler deploy`.
  Токен Cloudflare — `~/.config/cloudflare/api_token` (600; не печатать). Вход `wrangler login` через браузер у пользователя
  падает с `request_forbidden: No CSRF value` — использовать API-токен.
* Адрес сервера и токен приложения — `Config/Secrets.xcconfig` (`FS_SERVER_URL`, `FS_APP_TOKEN`, в .gitignore);
  `//` в xcconfig пишется как `/$()/`. Без них приложение работает напрямую с FACEIT по ключу пользователя.
* Точный ELO копится с начала отслеживания (14.11.2026 06:31); раньше — только WebKit-импорт с faceit.com (на Маке).

## Соглашения и грабли

* **Xcode на этом Маке нет** (пользователь не стал входить в Apple ID, 14.11.2026). macOS собирается через CLT:
  корневой `Package.swift` + `build.sh`. Грабля: у расширения-виджета точка входа должна быть `_NSExtensionMain`
  (`-Xlinker -e -Xlinker _NSExtensionMain`), иначе процесс сразу выходит с кодом 0 и галерея виджет не показывает.
  В CLT нет обработчика метаданных App Intents → в CLT-сборке (`CLT_BUILD`) три статических виджета (стиль выбирается
  в галерее) и нет кнопки обновления; в Xcode-сборке — один виджет с выбором стиля в «Изменить виджет».
* iOS проверяется только на GitHub Actions (сборка под симулятор), на телефон без Apple ID в Xcode не поставить.
* Точный ELO: неофициальный `www.faceit.com/api/stats/v1/stats/time/users/{id}/games/cs2` работает **только из WebKit**
  (`App/Shared/EloWebSync.swift`, скрытый WKWebView на странице игрока); из URLSession/curl — 403 Cloudflare.
  Пользователь просил сделать его единым — нельзя: виджеты не могут WebKit, а перенос cookie браузера = обход защиты.
  Решение: приложение на macOS — в строке меню (MenuBarExtra) + автозапуск (SMAppService), синхронизирует само.
* Время обновления в виджетах убрано по просьбе пользователя (14.11.2026); остаётся ⚠︎ при устаревших данных.
  Вместо голого региона — место в рейтинге региона («EU #74 689»).
* Диагностика виджета: `/usr/bin/log show --predicate 'process == "chronod"'` (в zsh `log` — встроенная команда!).

* **Xcode и всё тяжёлое — только на SSD** (просьба пользователя): KINGSTON — exFAT, Xcode там не работает, поэтому
  APFS-образ `/Volumes/KINGSTON/xcode-dev/XcodeSSD.sparsebundle` → `/Volumes/XcodeSSD` (Xcode, DerivedData, загрузки).
  Xcode выбирать через `DEVELOPER_DIR`, `xcode-select -s` требует sudo. Xcode 16.4 — последний под macOS 15.5.
* **API-ключ** пользователя: `~/.config/faceit/api_key` (600). Не печатать, в git/доки/память не писать.
* **Официальный API не отдаёт ELO по матчам.** Изменение за 20 = снимки ELO (точно) + оценка по `winProbability` (≈)
  + по желанию импорт с faceit.com через WebKit (неофициально). Подробно — `docs/METRICS.md`. Не выдавать оценку за точное.
* Ключи статистики FACEIT — свободные словари со **строковыми** значениями; отсутствие ключа — норма (ADR нет до
  ~06.2024). Пропуск ≠ 0.
* `/players/{id}/games/cs2/stats` — новые сверху; на экране лента **старые слева → новые справа**.
* `Score` "a / b" идёт в порядке фракций, счёт своей команды — `Final Score`.
* App Group: macOS `3P6X2MU65Y.com.k33ssa.simplefaceit` (с префиксом команды — без профиля), iOS
  `group.com.k33ssa.simplefaceit` (нужен профиль). Читается из Info.plist `FSAppGroupIdentifier`.
* Никаких демо-чисел: плейсхолдер виджета показывает кэш или пустое состояние.
* Дизайн утверждён пользователем 14.11.2026: три стиля Arena / Pulse / Rank, выбор в «Изменить виджет», шрифт — системный SF
  (Compressed/Expanded), кит 9ONE не обязателен.
* Git: без упоминаний ИИ-ассистента где угодно (глобальное правило), коммиты — по явным путям, сообщение для правок доков — «add fixes».
