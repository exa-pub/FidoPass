# FidoPass (macOS, Swift + libfido2)

Генератор паролей, использующий аппаратный FIDO2-ключ и расширение **hmac-secret**. Ничего секретного в файловой системе не хранит: все секреты деривируются ключом на лету. Локально сохраняются только метаданные (credentialId, rpId, политика, путь устройства) в **macOS Keychain**.

## Установка

```bash
brew install libfido2 pkg-config
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH" # при необходимости
swift build
swift run fidopass --help
```

Скрипт `build_app.sh` при упаковке `.app` копирует динамические библиотеки `libfido2`, `libcbor` и `libcrypto` внутрь бандла и выполняет ad-hoc `codesign`, поэтому полученный `.app`/DMG запускается на машине без установленного Homebrew (нужна лишь ручная разблокировка Gatekeeper). CLI по‑прежнему требует наличия `libfido2` в системе.

## Быстрый старт

1) Вставьте ключ, убедитесь, что на нём установлен PIN (рекомендуется).
2) Привяжите учётку (создаст resident/discoverable credential с hmac-secret):

```bash
swift run fidopass enroll --account demo --rp fidopass.local --user "Demo User" --uv
```

3) Сгенерируйте пароль для метки (обычно домен сайта):

```bash
swift run fidopass gen --account demo --label example.com --len 20 --copy
```

При каждой генерации будет запрошено прикосновение к ключу и, при необходимости, PIN.

## Работа с несколькими ключами

Команда просмотра устройств:
```bash
swift run fidopass devices
```
Пример вывода:
```
- path=/dev/hidraw3 | Yubico YubiKey 5
- path=/dev/hidraw5 | Nitrokey 3
```

Enroll на конкретном ключе:
```bash
swift run fidopass enroll --account demo2 --device /dev/hidraw5 --uv
```

Если старая учётка была создана до поддержки нескольких устройств (без сохранённого devicePath), можно указать ключ один раз при генерации — путь сохранится:
```bash
swift run fidopass gen --account old --label example.org --device /dev/hidraw3
```

## Графическое приложение (SwiftUI)

Добавлен отдельный продукт `FidoPassApp` (macOS 12+).

Сборка и запуск:
```bash
swift build --product FidoPassApp
swift run FidoPassApp
```

Функции текущей версии:
* Список учёток (Keychain) с возможностью создания и удаления.
* Группировка учёток по физическому FIDO устройству (секции). Legacy-учётки без `devicePath` отдельным блоком.
* Создание resident credential на выбранном ключе (если подключено несколько — выбор из меню).
* Генерация пароля по введённой метке (label) с использованием подключённого FIDO2 ключа.
* Поле PIN при создании и отдельное поле PIN для генерации (можно очистить для временного отключения).
* Копирование пароля в буфер обмена.
* Автоматическая адаптация к светлой / тёмной теме.

Принципы соответствия современным Human Interface Guidelines:
* SwiftUI: декларативные, доступные компоненты; поддержка Dynamic Type (масштабирование шрифтов системно управляется).
* Ясная иерархия: список (слева) + детальная панель (справа) через `NavigationView` для совместимости macOS 12.
* Минимум визуального шума: второстепенные тексты окрашены в secondary.
* Клавиатурные сокращения: Cmd+N — создание учётки.
* Доступность: системные SF Symbols (`key`, `trash`, `plus`) — корректны для VoiceOver.
* Состояния ошибок показываются через стандартный `Alert`.

Планы улучшений UI:
* Настройка политики паролей (редактирование длины, классов символов).
* Автообновление списка устройств (хот-плаги) без ручного Reload.
* История / недавно используемые метки.
* Поиск по списку учёток и дополнительная фильтрация.
* Прогресс-индикатор с отдельными шагами (ожидание PIN / касание).
* Локализация (en, ru) через ресурсный пакет.
* Меню для экспорта/импорта метаданных.

> Замечание: при первом использовании GUI убедитесь, что ключ вставлен и доступен. Ошибки низкого уровня libfido2 отображаются локализованным текстом.

## CLI Справка по ключевым командам

```bash
swift run fidopass devices                # список подключённых ключей
swift run fidopass enroll --account X --device /dev/hidraw5 --uv
swift run fidopass gen --account X --label example.com --copy
swift run fidopass list
swift run fidopass remove --account X
```

Опции:
* `--device PATH` — выбрать конкретный ключ (при enroll/ gen). При gen добавляет путь в legacy-запись.
* `--rk` в `enroll` теперь ОТКЛЮЧАЕТ resident credential (по умолчанию включено).
* `--uv` — требовать PIN/UV.

## Как это работает (коротко)
- При *enroll* делаем `makeCredential` с `FIDO_EXT_HMAC_SECRET`, включён `rk` (discoverable) по умолчанию.
- При *gen* делаем `getAssertion` с тем же RP ID и allowList (credentialId), включаем `hmac-secret` и передаём **salt**, детерминированно вычисленный из `label`+`rpId`+`accountId`.
- Ключ возвращает 32-байтовый секрет → через HKDF → маппим в пароль по заданной политике.

## Ограничения
- Нужен ключ **CTAP2/FIDO2** с поддержкой `hmac-secret`.
- Некоторые ключи требуют обязательный PIN/UV для `hmac-secret` — включайте `--uv` или в GUI введите PIN.
- В дистрибуции App Store доступ к USB HID может потребовать настроек песочницы. Для локального использования ограничений нет.

## Лицензия
MIT для данного примера кода. На `libfido2` действует BSD-2-Clause.
