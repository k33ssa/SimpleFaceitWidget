# FACEIT Data API v4: что есть на самом деле (для CS2-приложения)

Собрано 14.11.2026. Ключа FACEIT пока нет, поэтому авторизованные запросы не делались.

**Статусы:**
- **[СПЕК]** — подтверждено спецификацией: `https://open.faceit.com/data/v4/docs/swagger.json`, Swagger 2.0, host `open.faceit.com`, basePath `/data/v4`; скачано 14.11.2026, sha256 начинается с `eca5037299969123`; локальная копия делалась во временной папке, в репозиторий не входит.
- **[ЖИВОЙ ОТВЕТ]** — ключи взяты из настоящих ответов API, которые записали другие люди. Источник 1 — фикстуры репозитория `ArturCzopek/mixer`, коммит `ebe9ecc`, записаны 25.09.2026. Источник 2 — фикстура `Dexr1te/FACEIT-CS2-FUT-Card-Generator`, записана 13.09.2026. Это реальные ответы API, а не наша догадка, но сами мы их не получали.
- **[ЧУЖОЙ КОД]** — видно только в чужом коде.
- **[НЕ НАЙДЕНО]** — не найдено.
- **[ВЫВОД]** — наш вывод или расчёт.

> Главное про схему: в swagger поля статистики объявлены как свободные словари (`"additionalProperties": {}`). Это `PlayerStats.lifetime`, `PlayerStats.segments[]`, `PlayerStatsForMatch.stats`, `RoundStats.round_stats`, `PlayerStatsSimple.player_stats` и `TeamStatsSimple.team_stats`. **Имён ключей вроде "ADR" или "K/D Ratio" в спецификации нет**, они известны только по живым ответам. Почти все значения внутри этих словарей — **строки** (`"104.2"`, `"1"`). Исключение — `"Match Finished At"`: это число, эпоха в миллисекундах. Поэтому декодировать нужно в `[String: JSONValue]` с мягким приведением типов, а не в жёсткие `Codable`-структуры.

---

## 0. Сводная таблица

| Метрика для приложения | Эндпоинт | Поле (путь) | Статус |
|---|---|---|---|
| Поиск по нику (точный) | `GET /players?nickname=&game=cs2` | `player_id`, `nickname`, `avatar`, `country`, `faceit_url` | [СПЕК] |
| Текущий ELO | `GET /players?nickname=` или `GET /players/{player_id}` | `games.cs2.faceit_elo` (int) | [СПЕК] |
| Уровень 1–10 | то же | `games.cs2.skill_level` (int) | [СПЕК] |
| Регион | то же | `games.cs2.region` (**не** на верхнем уровне!) | [СПЕК] |
| Поиск по подстроке | `GET /search/players?nickname=` | `items[].player_id/nickname/avatar/country/status/verified`, `items[].games[].name`, `items[].games[].skill_level` (**строка**) | [СПЕК] |
| Место в рейтинге региона/страны | `GET /rankings/games/cs2/regions/{region}/players/{player_id}[?country=]` | `position`, `items[].faceit_elo` | [СПЕК] |
| Последние 20 матчей: K, D, A, K/D, K/R, HS%, ADR, MVP, карта, счёт, W/L | `GET /players/{id}/games/cs2/stats?limit=20` | `items[].stats["Kills"/"Deaths"/"Assists"/"K/D Ratio"/"K/R Ratio"/"Headshots %"/"ADR"/"MVPs"/"Map"/"Score"/"Result"/"Match Id"/"Match Finished At"]` | эндпоинт [СПЕК], ключи [ЖИВОЙ ОТВЕТ] |
| Урон за матч (Damage) | то же | `stats["Damage"]` | [ЖИВОЙ ОТВЕТ] (нет у старых матчей) |
| Мультикиллы | то же | `"Double Kills"`, `"Triple Kills"`, `"Quadro Kills"`, `"Penta Kills"` | [ЖИВОЙ ОТВЕТ] |
| Раунды в матче | то же | `"Rounds"` | [ЖИВОЙ ОТВЕТ] |
| **ELO за матч / изменение ELO за матч** | — | — | **[НЕ НАЙДЕНО] в официальном API** (см. §7) |
| ELO по матчам (неофициально) | `GET https://api.faceit.com/stats/v1/stats/time/users/{id}/games/cs2?page=&size=` | `elo`, `elo_delta` (строки) | [ЧУЖОЙ КОД], **НЕОФИЦИАЛЬНО**; из curl закрыто Cloudflare (403, 14.11.2026) |
| Lifetime: матчи, победы, WR, K/D, HS%, ADR, серии, последние 5 | `GET /players/{id}/stats/cs2` | `lifetime["Matches"/"Wins"/"Win Rate %"/"Average K/D Ratio"/"Average Headshots %"/"ADR"/"Current Win Streak"/"Longest Win Streak"/"Recent Results"]` | эндпоинт [СПЕК], ключи [ЖИВОЙ ОТВЕТ] |
| Статистика по картам | то же | `segments[]` с `type="Map"`, `mode="5v5"`, `label="Ancient"`, `stats{…}` | [ЖИВОЙ ОТВЕТ] |
| Список матчей (составы, счёт, турнир) | `GET /players/{id}/history?game=cs2&from=&to=&offset=&limit=` | `items[].match_id/started_at/finished_at/results.winner/results.score/teams.faction1.players[]…` | [СПЕК] |
| Подробная статистика матча (entry, клатчи, утилити) | `GET /matches/{match_id}/stats` | `rounds[].teams[].players[].player_stats["First Kills"/"Entry Wins"/"1v1Wins"/"Utility Damage"/…]` | эндпоинт [СПЕК], ключи [ЧУЖОЙ КОД] (несколько независимых источников) |
| Средний ELO команды перед матчем | `GET /matches/{match_id}` | `teams.faction1.stats.rating`, `.skillLevel.average`, `.winProbability` | поля [СПЕК], смысл [ВЫВОД] |
| HLTV Rating 2.0/3.0 | — | — | **[НЕ НАЙДЕНО]**, только приближённый расчёт (§8) |
| KAST | — | — | **[НЕ НАЙДЕНО]** ни в одном ответе |

---

## 1. Игрок по нику и поиск

### `GET /players` (operationId `getPlayerFromLookup`) — [СПЕК]
- Параметры (все query, ни один не помечен как required): `nickname`, `game`, `game_player_id` (Steam ID64 при `game=cs2`).
- Ответ — `Player`: `player_id`, `nickname`, `avatar`, `country`, `cover_image`, `faceit_url`, `friends_ids[]`, `games{…}`, `memberships[]`, `new_steam_id`, `steam_id_64`, `steam_nickname`, `platforms{}`, `settings.language`, `verified`, `activated_at` (date-time). Помечены как Deprecated: `cover_featured_image`, `membership_type`, `infractions`.
- `games` — словарь `map<string, GameDetail>` с ключами `"cs2"`, `"csgo"` и т. д. Поля `GameDetail`: `faceit_elo` (int64), `skill_level` (int64), `region`, `game_player_id`, `game_player_name`. Deprecated: `skill_level_label`, `game_profile_id`, `regions`.
- **Поля `region` на верхнем уровне нет**, регион лежит в `games.cs2.region`.
- `faceit_url` содержит плейсхолдер: `https://www.faceit.com/{lang}/players/<nick>`. Перед открытием `{lang}` нужно заменить, например на `en`. Источник — [ЖИВОЙ ОТВЕТ] в фикстуре mixer.
- Если игрок ни разу не играл в CS2, ключа `games.cs2` нет. Так обрабатывает `mxgic1337/faceit-stats-widget`: «This player never played CS2 on FACEIT.» — [ЧУЖОЙ КОД].
- Регистр ника имеет значение: `s1mple` и `S1mple` — разные запросы. В `sansblues/faceitperf` (`apps/web/functions/preview/players/[username].js`) сказано: «FACEIT's lookup is case-sensitive». Там перебирают варианты написания, а если не нашлось — идут в `/search/players`. Статус — [ЧУЖОЙ КОД].
- `GET /players/{player_id}` (`getPlayer`) возвращает ту же схему `Player` — [СПЕК].

### `GET /search/players` (`searchPlayers`) — [СПЕК]
- Параметры: `nickname` (**required**), `game`, `country` (ISO 3166-1), `offset` (по умолчанию 0), `limit` (по умолчанию 20, **максимум 100**).
- Ответ — `UsersSearchList{start, end, items[UserSearch]}`. Поля `UserSearch`: `player_id`, `nickname`, `avatar`, `country`, `status`, `verified`, `games[GameUserSearch{name, skill_level}]`.
- `skill_level` здесь **строка**. В спецификации так и написано: «we return SkillLevel as string even if it is an int». **ELO поиск не отдаёт**, за ним нужен второй запрос `/players/{id}`.

---

## 2. Lifetime и статистика по картам: `GET /players/{player_id}/stats/{game_id}`

- operationId `getPlayerStats`. Ответ — `PlayerStats{player_id, game_id, lifetime: object(any), segments: [object(any)]}` — [СПЕК]. Ключи в спецификации **не описаны**.
- Ключи `lifetime` для CS2 — [ЖИВОЙ ОТВЕТ] из фикстуры mixer `lifetime/*.json` от 25.09.2026. Набор совпадает с моделью `CSLifetimeStats` в `zombyacoff/faceit-python` (`src/faceit/models/players/general.py`). Всего 41 ключ:
  - **Основные:** `Matches`, `Wins`, `Win Rate %`, `Average K/D Ratio`, `K/D Ratio`, `Average Headshots %`, `Total Headshots %`, `ADR`, `Total Damage`, `Current Win Streak`, `Longest Win Streak`, `Recent Results`.
  - **Расширенные:** `Total Matches` (число матчей, по которым есть расширенная статистика, это меньше, чем `Matches`), `Total Rounds with extended stats`, `Total Kills with extended stats`, `Entry Rate`, `Entry Success Rate`, `Total Entry Count`, `Total Entry Wins`, `1v1 Win Rate`, `1v2 Win Rate`, `Total 1v1 Count`, `Total 1v1 Wins`, `Total 1v2 Count`, `Total 1v2 Wins`, `Sniper Kill Rate`, `Sniper Kill Rate per Round`, `Total Sniper Kills`, `Flash Success Rate`, `Flashes per Round`, `Enemies Flashed per Round`, `Total Flash Count`, `Total Flash Successes`, `Total Enemies Flashed`, `Utility Damage per Round`, `Utility Damage Success Rate`, `Utility Success Rate`, `Utility Usage per Round`, `Total Utility Count`, `Total Utility Damage`, `Total Utility Successes`.
- Все значения — строки, кроме `Recent Results`. Это массив из **5** строк `"1"`/`"0"`, например `["0","1","1","0","0"]`. Последних 20 результатов **здесь нет**.
- **В lifetime нет:** ELO, Kills, Deaths, Assists, Rounds, KAST, рейтинга.
- `segments[]` — [ЖИВОЙ ОТВЕТ]. Каждый элемент: `{type:"Map", mode:"5v5", label:"Ancient", img_small, img_regular, stats{…}}`. В `stats` к ключам lifetime добавляются абсолютные значения и средние: `Kills`, `Deaths`, `Assists`, `Rounds`, `Headshots`, `MVPs`, `K/R Ratio`, `Triple Kills`/`Quadro Kills`/`Penta Kills`, `Average Kills`, `Average Deaths`, `Average Assists`, `Average K/R Ratio`, `Average MVPs`, `Average Triple Kills`, `Average Quadro Kills`, `Average Penta Kills`, `Headshots per Match`. В записанном ответе все сегменты были типа Map/5v5 (10 карт).

---

## 3. История матчей: `GET /players/{player_id}/history` — [СПЕК]

- Параметры:
  - `game` — **required**.
  - `from` — «The timestamp (Unix time) as lower bound… **1 month ago if not specified**».
  - `to` — «Current timestamp if not specified».
  - `offset` — 0..**1000**.
  - `limit` — 1..**100**, по умолчанию 20.
- **Ловушка 1:** без `from` возвращаются только матчи за последний месяц. Если игрок давно не играл, ответ будет пустым. Для «последних 20 матчей» надо передавать `from=0` или другую старую дату. Это [ВЫВОД] из описания в спецификации, на живом ответе не проверено.
- **Ловушка 2:** `from`/`to` здесь в **секундах**, а в `/games/{game_id}/stats` — в **миллисекундах**. Источники: спецификация («Unix time» против «epoch milliseconds») и spike-отчёт mixer: «seconds silently return 0 items».
- Ответ — `MatchHistoryList{start, end, from, to, items[MatchHistory]}`.
- Поля `MatchHistory`: `match_id`, `game_id`, `game_mode` (`"5v5"`), `match_type`, `competition_id`, `competition_name` (`"Europe 5v5 Queue"`), `competition_type` (`"matchmaking"`), `organizer_id`, `region`, `status` (`"finished"`), `started_at` / `finished_at` (int64, секунды), `max_players`, `teams_size`, `playing_players[]`, `faceit_url` (с `{lang}`), `results{winner: "faction1"|"faction2", score{faction1: int, faction2: int}}`, `teams{faction1|faction2: {team_id, nickname, avatar, type, players[{player_id, nickname, avatar, skill_level (int), game_player_id, game_player_name, faceit_url}]}}`.
- **ELO здесь нет**, ни до матча, ни после, ни изменения. У игроков есть только `skill_level`.
- Чтобы понять, выиграл ли наш игрок, нужно найти, в какой фракции его `player_id`, и сравнить её с `results.winner`.

---

## 4. Статистика по матчам пачкой: `GET /players/{player_id}/games/{game_id}/stats` — ГЛАВНЫЙ ЭНДПОИНТ

- **Есть в спецификации** — [СПЕК]. operationId `getPlayerStats`, summary: «Retrieve statistics of a player for a given amount of matches».
- Параметры:
  - `offset` — 0..**200**.
  - `limit` — 1..**100**, по умолчанию 20.
  - `from` / `to` — «Expected value is date ("items.stats.Match Finished At") in epoch **milliseconds**».
- Ответ — `PlayerStatsForMatchesList{start, end, items[PlayerStatsForMatch{stats: object(any)}]}`.
- Ключи `items[].stats` — [ЖИВОЙ ОТВЕТ] по 370 записям 4 игроков из фикстур mixer, сентябрь 2026. Всего 36 ключей, `Game="cs2"`, `Game Mode="5v5"`:
  - Идентификация: `Match Id`, `Player Id`, `Nickname`, `Competition Id`, `Game`, `Game Mode`, `Region`, `Team`, `Winner` (id команды-победителя).
  - Время: `Match Finished At` (**int, ms**), `Created At` и `Updated At` (ISO-строки).
  - Результат: `Result` (`"1"` — победа, `"0"` — поражение), `Map` (`"de_mirage"`), `Score` (`"13 / 8"`), `Final Score`, `First Half Score`, `Second Half Score`, `Overtime score` (с маленькой «s»), `Rounds`, `Best Of`, `Match Round`.
  - Игрок: `Kills`, `Deaths`, `Assists`, `K/D Ratio`, `K/R Ratio`, `Headshots`, `Headshots %`, `MVPs`, `ADR`, `Damage`, `Double Kills`, `Triple Kills`, `Quadro Kills`, `Penta Kills`.
- Ключей **`Elo` / `Elo Change` / `elo_delta` нет** — [ЖИВОЙ ОТВЕТ, 36 ключей из 36 проверены].
- `ADR`, `Damage`, `Double Kills` есть не всегда: в 24 из 370 старых записей (2023 — начало 2024) их не было. По README `faceitperf`, «FACEIT added ADR and double kills in late June 2024». Значит, эти поля должны быть опциональными.
- Расширенных ключей (`First Kills`, `Entry Count`, `1v1Wins`, `Utility Damage` и т. п.) в записи 2026 года **нет**. Они есть в TS-типе `Sunquist/twitch-overlay`, но этот тип датирован августом 2024 и не проверен. В приложении на них рассчитывать нельзя, они бывают только в `/matches/{id}/stats`.
- Одна запись — одна карта: у BO3 будет несколько записей с одним `Match Id` и разными `Match Round`.
- Пагинация: максимальный `offset` — 200, поэтому дальше листать курсором. Берём `to = "Match Finished At"` последней записи и повторяем запрос. Так делает `faceitperf`. «Последние 20 матчей» — это один запрос `?limit=20`; порядок от новых к старым ([ЧУЖОЙ КОД]: mxgic берёт `items[0]` как последний матч).

---

## 5. `GET /matches/{match_id}/stats` — [СПЕК] + [ЧУЖОЙ КОД]

- Структура [СПЕК]: `MatchStats{rounds[RoundStats]}`. Один элемент `rounds[]` — это одна карта. `RoundStats{best_of, competition_id, game_id, game_mode, match_id, match_round, played, round_stats{…}, teams[TeamStatsSimple{team_id, premade, team_stats{…}, players[PlayerStatsSimple{player_id, nickname, player_stats{…}}]}]}`.
- `round_stats`: `Map`, `Score`, `Rounds`, `Winner`, `Region`. Источники: модель `ubqm/botesee` `src/clients/models/faceit/match_stats.py` и документ mixer `docs/06-external-apis.md` — [ЧУЖОЙ КОД].
- `team_stats`: `Team`, `Team Win`, `Team Headshots`, `First Half Score`, `Second Half Score`, `Overtime score`, `Final Score` — [ЧУЖОЙ КОД].
- `player_stats` для CS2 — [ЧУЖОЙ КОД]. Набор подтверждают три независимые модели: botesee, `MAJDER0/Faceit-Stats-Provider` (`Models/MatchStats.cs`) и mixer:
  - Kills, deaths, assists: `Kills`, `Deaths`, `Assists`, `K/D Ratio`, `K/R Ratio`, `Headshots`, `Headshots %`, `MVPs`, `Result`.
  - Урон: `ADR`, `Damage`.
  - Мультикиллы: `Double Kills`, `Triple Kills`, `Quadro Kills`, `Penta Kills`.
  - Entry: `First Kills`, `Entry Count`, `Entry Wins`, `Match Entry Rate`, `Match Entry Success Rate`.
  - Клатчи: `Clutch Kills`, `1v1Count`, `1v1Wins`, `1v2Count`, `1v2Wins`, `Match 1v1 Win Rate`, `Match 1v2 Win Rate`. Ключи склеены, без пробела.
  - Оружие: `Sniper Kills`, `Sniper Kill Rate per Match`, `Sniper Kill Rate per Round`, `Pistol Kills`, `Knife Kills`, `Zeus Kills`.
  - Утилити: `Utility Count`, `Utility Damage`, `Utility Enemies`, `Utility Successes`, `Utility Damage per Round in a Match`, `Utility Damage Success Rate per Match`, `Utility Success Rate per Match`, `Utility Usage per Round`, `Flash Count`, `Flash Successes`, `Enemies Flashed`, `Flash Success Rate per Match`, `Flashes per Round in a Match`, `Enemies Flashed per Round in a Match`.
- **Нет:** KAST, трейдов, выживаний по раундам, ELO. Число раундов у игрока не указывается отдельно, его берут из `round_stats.Rounds`.
- Это один запрос на каждый матч. Для 20 матчей — 20 запросов.

## 6. `GET /matches/{match_id}` — [СПЕК]

- `Match` — поля верхнего уровня: `match_id`, `version`, `game`, `region`, `competition_id`, `competition_type`, `competition_name`, `organizer_id`, `status`, `best_of`, `round`, `group`, `calculate_elo` (bool), `configured_at`, `started_at`, `finished_at`, `scheduled_at`, `broadcast_start_time`, `broadcast_start_time_label`, `chat_room_id`, `faceit_url`, `demo_url[]`, `voting`.
- Результаты:
  - `results{winner, score{}}`;
  - `detailed_results[{asc_score, winner, factions{faction1: {score}}}]` (по картам);
  - `instances[{id, round, demos[]}]`.
- `teams{faction1|faction2: Faction{faction_id, leader, name, avatar, type, substituted, roster[Roster], substitutes[], roster_v1, stats: Stats}}`.
  - `Roster`: `player_id`, `nickname`, `avatar`, `membership`, `game_player_id`, `game_player_name`, `game_skill_level` (int), `anticheat_required`.
  - `Stats`: `rating` (int64), `skillLevel{average, range{min, max}}`, `winProbability` (double).
- В спецификации у `teams.*.stats.rating` описания нет. По смыслу это средний ELO команды на момент сбора матча ([ВЫВОД], не проверено). **ELO отдельных игроков в `roster[]` нет**, там только `game_skill_level`.
- `calculate_elo=true` означает, что матч рейтинговый и влияет на ELO.

---

## 7. История ELO — главный вывод

**Официально ELO по матчам получить нельзя** — [НЕ НАЙДЕНО]. Что проверено:
1. В swagger поиском по `elo` нашлись только `faceit_elo` (у `GameDetail` и в рейтингах), `calculate_elo` (у `Match`), `min_elo`/`max_elo` (дивизионы лиг) и `Stats.rating` (у фракции). Эндпоинтов вида `*/elo*` нет: запрос `GET /players/{id}/elo-history` вернул 404 `err_nf0`.
2. В `history`, в `games/cs2/stats` (36 ключей, [ЖИВОЙ ОТВЕТ]) и в `matches/{id}/stats` полей ELO нет.
3. Вебхуки (`docs.faceit.com/docs/webhooks`) — это только события вроде `match_status_finished` для подписки на пользователя. Полей ELO в описании нет, и для них нужен свой сервер (POST на наш REST-эндпоинт).

**Как правильно считать дельту официально** — [ВЫВОД]:
- Хранить снимки `games.cs2.faceit_elo` локально: в App Group, чтобы их видели и приложение, и виджет. Снимок — пара `(время, elo, id последнего матча)`.
- При каждом обновлении сравнивать текущий ELO с прошлым снимком. Матчи, которые закончились между снимками, берём из `games/cs2/stats` по `Match Finished At` и привязываем изменение к ним. Если между снимками был ровно один рейтинговый матч, дельта точная. Если матчей несколько — известна только суммарная дельта за группу.
- Точность растёт с частотой опроса, но частоту ограничивает бюджет обновлений WidgetKit. Фоновое обновление в самом приложении (BGAppRefresh) помогает лишь частично.
- **Невозможно официально:**
  - восстановить ELO по матчам, сыгранным до установки приложения;
  - получить точную дельту для каждого матча, если между двумя опросами сыграно несколько матчей;
  - получить ELO соперников до матча (есть только средний `teams.*.stats.rating` и `skillLevel`).
- Альтернатива с сервером: подписаться на вебхук `match_status_finished` для пользователя, сразу запрашивать `/players/{id}` и хранить ELO после каждого матча. Это требует бэкенда.

**Неофициальный путь** — помечен как **НЕОФИЦИАЛЬНО**, [ЧУЖОЙ КОД]:
- Запрос: `GET https://api.faceit.com/stats/v1/stats/time/users/{player_id}/games/cs2?page=0&size=…`. Встречается также через `https://www.faceit.com/api/stats/v1/...` и с параметрами `from`/`to` в мс.
- Поля: `elo` (ELO после матча, строка), `elo_delta`. У нерейтинговых матчей `elo` отсутствует.
- Кто использует: `LilStick/4esElo` (`packages/faceit/src/eloHistory.ts`, прямо подписано «NON OFFICIEL»), `melnikov1512/faceit-last10-stats-bot` (`src/services/faceitService.js`), `Bytenote/VisusGG` (`src/shared/helpers/api.js`). Поиск по GitHub находит 59 файлов с этой строкой.
- Проверено нами 14.11.2026: `curl` к обоим хостам вернул **403 «Sorry, you have been blocked» от Cloudflare**. Без браузерного контекста доступ закрыт. Обходить защиту не пробовали и не будем. Для нативного приложения этот путь ненадёжен и может нарушать правила FACEIT. В лучшем случае — опция «экспериментально», с запасным вариантом на снимки.

---

## 8. Рейтинг (HLTV-подобный)

- **Официально нет** — [НЕ НАЙДЕНО]. Ключей `Rating`, `KAST`, `Impact` нет ни в одном ответе. Поле `Stats.rating` в `/matches/{id}` относится к команде и про ELO, а не к HLTV-рейтингу.
- Какие входные данные есть по матчу ([ЖИВОЙ ОТВЕТ] для `games/cs2/stats`): Kills, Deaths, Assists, Rounds, ADR (с середины 2024), Double/Triple/Quadro/Penta Kills, Headshots, MVPs.
- **Rating 1.0** (HLTV, 2010) считается почти точно из этих полей — [ВЫВОД, формула по памяти, константы не сверены с первоисточником в этой сессии]:
  - формула: `(KPR/0.679 + 0.7·(Rounds−Deaths)/Rounds/0.317 + RMK/1.277) / 2.7`;
  - `RMK = (1K + 4·2K + 9·3K + 16·4K + 25·5K)/Rounds`;
  - `1K = Kills − 2·2K − 3·3K − 4·4K − 5·5K`;
  - `Double Kills` есть только с середины 2024 года.
- **Rating 2.0** точно не считается. Не хватает **KAST** (kill/assist/survive/traded по раундам), данных для Impact (opening kills, clutch — в `games/cs2/stats` их нет, только в `/matches/{id}/stats`), трейдов и выживаний по раундам. Самая проработанная открытая аппроксимация — `sansblues/faceitperf`, файлы `tools/rating/README.md` и `apps/web/src/features/stats.ts`:
  - `Rating ≈ 0.879 + 0.751·KPR + 0.272·APR − 0.887·DPR + 0.000417·ADR + 0.0000314·ADR² + 0.0574·MKPR`, где ADR ограничен 150, а MKPR — доля раундов с мультикиллами;
  - `KAST ≈ 80.7 + 20.2·KPR + 33.8·APR − 44.2·DPR`;
  - автор сам указывает погрешность: RMSE 0.065 на одной карте и 0.011 на карьере, и пишет, что для CS2 формулу проверить не на чем.
- **Rating 2.1/3.0** невозможны: нужны entry duels, clutches, saves, данные по раундам.
- Рекомендация [ВЫВОД]: называть метрику честно, например «Rating (оценка, ~HLTV 2.0)», и показывать её на агрегате 20 матчей, а не на одной карте.

---

## 9. Ключи, авторизация, лимиты, ошибки

- **Заголовок:** `Authorization: Bearer <api_key>`. Источник — `docs.faceit.com/docs/data-api/`: «Header example: Authorization = Bearer + api_key». В swagger это `securityDefinitions.key: apiKey, name "Authorization", in header` — [СПЕК].
- **Как получить ключ:** войти на `developers.faceit.com` → App Studio → создать App → панель «API Keys» в деталях приложения. У одного App может быть несколько ключей. Источники: docs.faceit.com, страницы `getting-started/intro/start-here` и `getting-started/authentication/api-keys`.
- **Типы ключей:**
  - Server side — ключ живёт на сервере.
  - Client side — для кода, который уходит пользователю. Документация предупреждает: «your API Keys can be copied by others». Для client-side ключей в App Studio есть «additional restrictions», но какие именно — в документации не раскрыто.
  - Нативное приложение — это клиентский код, ключ из бинарника можно извлечь.
- **Права:** «Using the Data API, you can access all publicly available information on faceit.com». Данные доступны не от имени пользователя, OAuth не нужен.
- **Rate limit** в документации **не описан** — [НЕ НАЙДЕНО].
  - Измерено нами 14.11.2026 по заголовкам шлюза: `ratelimit-limit: 20, 20;w=1`, `ratelimit-remaining`, `ratelimit-reset`, `x-faceit-ratelimit-name: gateway-open-faceit-ratelimit`. Это 20 запросов в секунду.
  - Тот же заголовок с настоящим ключом записан в spike-отчёте mixer от 25.09.2026.
  - Лимит «10 000 в час, затем 429 до начала следующего часа» встречается только в чужом документе со ссылкой на форум FACEIT — [ЧУЖОЙ КОД], не подтверждено.
- **Ошибки** — коды из swagger [СПЕК]: 400, 401, 403, 404, 429, 503, default. Что видели вживую (14.11.2026):
  - без заголовка → **403** `{"errors":[{"message":"You are not authorized to perform this action.","code":"err_f0","http_status":403,"parameters":[]}]}` (а не 401);
  - неверный Bearer → **400** `{"error":"invalid_token","error_description":"Token was not recognised"}`;
  - несуществующий путь → **404** `{"errors":[{"code":"err_nf0",…}]}`.
- В ответах шлюза `cache-control: max-age=14400` (видели на 405 для HEAD). Свой кэш нужен всё равно.

## 10. game_id и смешение с CS:GO

- `game_id` = `"cs2"`, для старой игры — `"csgo"`. Так в коде всех проектов и в живых ответах: `Game: "cs2"`, `history.items[].game_id: "cs2"`. Список игр отдаёт `GET /games` — [СПЕК]. Есть ещё `GET /games/{game_id}/parent`, видимо для связи cs2 и csgo ([ВЫВОД]).
- Запросы с `cs2` не возвращают матчи CS:GO: в 370 записях `games/cs2/stats` все с `Game="cs2"` ([ЖИВОЙ ОТВЕТ]). История CS:GO — отдельные запросы с `csgo` (так делает `faceitperf`: `GameVersions = ["cs2","csgo"]`). ELO и уровень — отдельно в `games.cs2` и `games.csgo`. По наблюдению в `faceit-python`, у `csgo` бывает `skill_level=0` ([ЧУЖОЙ КОД]).
- Границы уровней CS2 (у `faceit-python` в `constants.py`, [ЧУЖОЙ КОД]): 1 ≤500, 2 — 501–750, 3 — 751–900, 4 — 901–1050, 5 — 1051–1200, 6 — 1201–1350, 7 — 1351–1530, 8 — 1531–1750, 9 — 1751–2000, 10 — 2001+. Уровень всё равно приходит готовым в `skill_level`.

---

## Открытые проекты FACEIT (проверены 14.11.2026)

| Проект | Стек | Что показывает | Эндпоинты |
|---|---|---|---|
| [sansblues/faceitperf](https://github.com/sansblues/faceitperf) ★61, faceitperf.pro | TS/React, Cloudflare Functions | Профиль «как на HLTV»: Rating ~2.0, KAST-оценка, K/D, ADR; CS2 и CS:GO | Официальные: `players?nickname`, `players/{id}`, `players/{id}/games/cs2/stats` (курсор по `to`), `rankings`. **Неофициальные**: `api.faceit.com/democracy/v1/match/{id}/history` (вето), `api.faceit.com/match/v2/match/{id}` |
| [mxgic1337/faceit-stats-widget](https://github.com/mxgic1337/faceit-stats-widget) ★32 | TS (Vite) | Виджет для стримеров: ELO, уровень, K/D, HS%, W/L за N матчей, место в рейтинге | Только официальные: `players`, `players/{id}/games/cs2/stats?limit=100`, `rankings/games/cs2/regions/{r}/players/{id}` |
| [zombyacoff/faceit-python](https://github.com/zombyacoff/faceit-python) ★21 | Python, pydantic | Типизированная обёртка Data API: лучший справочник по ключам (`CS2MatchPlayerStats`, `CSLifetimeStats`) | Официальные |
| [ArturCzopek/mixer](https://github.com/ArturCzopek/mixer) | Next.js | Балансировка миксов. В `docs/06-external-apis.md` записан реальный «spike» API с фикстурами | Официальные |
| [LilStick/4esElo](https://github.com/LilStick/4esElo) | TS | График ELO по матчам | **НЕОФИЦИАЛЬНЫЙ** `api.faceit.com/stats/v1/stats/time/users/{id}/games/cs2` |
| [Bytenote/VisusGG](https://github.com/Bytenote/VisusGG) ★14 | JS, расширение браузера | Винрейт соперников в лобби | **НЕОФИЦИАЛЬНЫЕ** `/api/stats/v1/...`, `/api/searcher/v1/...` на faceit.com, плюс `/api/data/v4/...history` |

Нативных Swift-приложений для FACEIT заметного размера нет: по `gh search repos faceit --language=Swift` нашлись только учебные «FaceIt» Stanford CS193P и `Robinjakobsson/FaceitApp` с 0★.

## Примеры виджетов для iOS/macOS с открытым кодом

- [pawello2222/WidgetExamples](https://github.com/pawello2222/WidgetExamples) ★1111, Swift — каталог приёмов WidgetKit: timeline, App Group, интерактивные и настраиваемые виджеты (AppIntent), сетевые запросы.
- [latelunchapps/github-contributions-ios](https://github.com/latelunchapps/github-contributions-ios) ★403, обновлялся 12.11.2026 — самый близкий аналог: статистика внешнего API в виджетах iOS.
- [DeluxeAlonso/UpcomingMovies](https://github.com/DeluxeAlonso/UpcomingMovies) ★597 — клиент REST API (TMDb) с чистой архитектурой и виджетом.

---

## Открытые риски

1. **Где хранить ключ.** Документация называет client-side ключи копируемыми. В нативном приложении ключ из бинарника можно извлечь. Варианты: client-side ключ с ограничениями App Studio (какие ограничения есть, неизвестно) или свой прокси. Решает пользователь.
2. **Нет официального ELO по матчам.** Дельта ELO только через локальные снимки: неточно при нескольких матчах между опросами и без прошлого до установки. Неофициальный `stats/v1` закрыт Cloudflare и может нарушать правила.
3. **Ключи статистики не входят в контракт.** Это свободные словари со строковыми значениями, состав менялся: ADR и Double Kills с 2024 года, расширенные поля то появляются, то пропадают. Декодер должен быть мягким, отсутствие ключа — нормальная ситуация.
4. **Лимиты известны частично.** 20 запросов в секунду видно по заголовку. Часовой лимит не подтверждён. Для `/matches/{id}/stats` нужен отдельный запрос на каждый матч.
5. **Ловушки параметров:**
   - `history` без `from` возвращает только последний месяц, а `from`/`to` там в секундах;
   - в `games/cs2/stats` время в миллисекундах, максимальный offset 200;
   - поиск по нику чувствителен к регистру;
   - в `faceit_url` есть `{lang}`.
6. **Условия использования** (developers.faceit.com/terms: хранение и кэширование данных, брендинг) в этой сессии не читались — их нужно прочитать до публикации приложения.
7. **Всё «живое» в этом файле записано чужими ключами** (сентябрь 2026). После получения своего ключа нужно один раз записать собственные фикстуры для `/players`, `/history`, `/games/cs2/stats`, `/stats/cs2`, `/matches/{id}` и `/matches/{id}/stats` и сверить с этим файлом.
