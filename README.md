# GlucoseWatch

Приложение и complication для Apple Watch (watchOS 11+): текущий сахар, тренд, прогноз, активные инсулин и углеводы, сводка дня. Только для часов (`WKWatchOnly`), без приложения на iPhone.

## Откуда данные

Часы читают один файл: `https://glucose.gistrec.cloud/now.json` (`Shared/Glucose.swift`, `Feed.url`). Его публикует соседний проект [GlucoseStat](https://github.com/gistrec/GlucoseStat): это выжимка снимка, которую он пишет рядом с `data.json`.

- Удачный ответ кэшируется: без сети часы показывают последнее известное значение с его возрастом.
- Замер старше 15 минут считается устаревшим: цифра серая, прогноза нет.
- В Debug-сборке источник подменяется аргументом запуска `-feed URL`.

## Сборка

Проект `GlucoseWatch.xcodeproj`, открыть в Xcode. Таргеты:

| Таргет | Что это | Bundle ID |
|---|---|---|
| `GlucoseWatch` | контейнер watch-only приложения | `cloud.gistrec.GlucoseWatch` |
| `GlucoseWatch Watch App` | само приложение | `cloud.gistrec.GlucoseWatch.watchkitapp` |
| `GlucoseComplicationExtension` | complication (WidgetKit) | `cloud.gistrec.GlucoseWatch.watchkitapp.GlucoseComplication` |

Схемы: `GlucoseWatch Watch App` и `GlucoseComplicationExtension`.

Подпись автоматическая, в проекте прописана команда `7M742BNTH2`, для своей сборки замените на свою команду и bundle ID. Оба таргета используют App Group `group.cloud.gistrec.GlucoseWatch` (`Entitlements/`): через неё приложение видит журнал пробуждений complication.

Аргументы запуска для скриншотов (только Debug): `-page N` открывает страницу N (с нуля), `-complications` показывает complication вместо приложения, `-feed URL` подменяет источник.

## Приложение

Три вертикальные страницы, листаются колёсиком (`GlucoseWatch Watch App/ContentView.swift`):

1. Без заголовка: цифра в ммоль/л, стрелка тренда, давность замера, оценка «по крови» (если есть смещение сенсора от глюкометра) и график. У графика окна 3/6/12/24 ч, на нём прогноз, еда и болюсы, под ним «обычный день».
2. «Прогноз»: предупреждение о падении ниже порога за полчаса, прогноз через 30 и 60 минут, активные инсулин и углеводы, разбор последней еды (подъём, итог через 4 ч).
3. «День»: время в диапазоне и ниже, среднее, вариабельность, GMI, эпизоды ниже/выше диапазона с полуночи, последняя ночь, срок сенсора, как часто обновляется циферблат.

Пока экран активен, приложение запрашивает `now.json` раз в минуту. При открытии и на каждом новом замере перезагружает complication.

## Complication

`GlucoseComplication/GlucoseComplication.swift`:

| Название | Что показывает | Семейства |
|---|---|---|
| Глюкоза | сахар, тренд, когда были последние инсулин и еда | rectangular, circular, corner, inline |
| График | кривая за 6 ч с порогами и прогнозом | rectangular |
| График и обычный день | та же кривая, под ней коридор и медиана за две недели | rectangular |
| Инсулин | сколько болюсного инсулина ещё действует | circular, corner |
| Углеводы | сколько углеводов ещё всасывается | circular, corner |

Когда обновлять, решает система. Timeline просит следующее обновление к ожидаемому замеру, но не раньше чем через 5 минут, и до него кладёт записи каждые 5 минут. Через 15 минут после замера цифра гаснет.

## Формат now.json

Модель описана в `struct Now` (`Shared/Glucose.swift`). Ключи в snake_case (декодер с `convertFromSnakeCase`), глюкоза в mg/dL, время в unix-секундах. Если обязательное поле пропадёт или сменит тип, декодирование упадёт целиком и часы останутся на кэше.

Обязательные:

- `generated_at`: когда собран снимок.
- `collector.last_success` (может быть null): последний удачный опрос сборщика.
- `target.low` / `mid` / `high`: пороги зон.
- `active.insulin`, `active.carbs` (могут быть null): `left`, `of`, `until`: остаток, исходная доза, конец действия.

Необязательные (старый сервер их не слал, без них часть экрана пропадает):

- `latest`: `t`, `mgdl`, `rate` (mg/dL в минуту за 15 минут).
- `forecast`: `made_at`, `points` (`[t, mgdl]`), `lower` (нижняя граница, 9 из 10).
- `series.day`: `step`, `points` (`[t, mgdl]`).
- `events`: `meals` и `bolus`, пары `[t, количество]`.
- `sensor`: `started`, `ends`, `bias` (`mgdl`, `pairs`, `agree`, `from`, `to`): смещение сенсора от глюкометра.
- `today`: сводка с местной полуночи, `covered` (с), `tir`, `below` (%), `avg`, `cv`.
- `profile`: «обычный день», `tz`, `slot_min`, `days`, `slots` (`[q25, медиана, q75, дней]` или null; читаются первые три).
- `nights`: `tz`, `to`, `counted`, `hypo_nights`, `hypo_mgdl`, `nights[]` (`date`, `end`, `count`, `coverage`, `partial`, `min`, `hypo`, `low_minutes`, `low_count`, `drift`).
- `analysis`: разбор еды за 4 ч, `targets.rise`, `meals[]` (`t`, `carbs`, `dose.units`, `peak_min`, `rise`, `ret`, `hypo`, `from_hypo`, `cut`, `complete`).
- `lows`, `highs`: эпизоды вне диапазона: `start`, `end`, `minutes`.
- `gmi`: `value`, `days`.

Внутри необязательного блока поля без `?` в модели обязательны: например, если в `latest` пропадёт `mgdl`, не разберётся весь файл.

## Иконка

`tools/make-icon.swift` перерисовывает в квадрате 1024 значок страницы GlucoseStat
(`web/favicon.svg` в репозитории GlucoseStat, сам файл скрипт не читает):

```sh
xcrun swift tools/make-icon.swift "GlucoseWatch Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
```
