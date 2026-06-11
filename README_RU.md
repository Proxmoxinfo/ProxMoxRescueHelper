# ProxRescue

[English](README.md) | Русский | [Українська](README_UK.md)

**Скрипт в один файл, который ставит Proxmox на выделенный сервер Hetzner прямо из rescue-системы.**

Если вы хоть раз пытались поставить Proxmox VE/PBS/PMG/PDM на сервер Hetzner, то знаете, как это бывает: грузишься в rescue, мучаешься с QEMU, чтобы запустить графический инсталлятор, сам настраиваешь доступ через VNC/noVNC, а потом ещё вручную правишь сеть, репозитории и убираешь напоминание о подписке. ProxRescue берёт на себя всю эту обвязку — он запускает официальный ISO Proxmox в QEMU и даёт ссылку на noVNC, а сам инсталлятор Proxmox (разметка дисков, пароли и т.д.) вы проходите как обычно через браузер. После этого скрипт сам настраивает сеть и применяет пост-установочные правки.

То есть это не полностью автоматическая установка "в один клик" — сам инсталлятор Proxmox вы проходите вручную, — но скрипт убирает всю рутину вокруг него.

## Что делает скрипт

- Запускает официальный установочный ISO Proxmox в QEMU и даёт ссылку на noVNC, чтобы пройти установку в браузере как обычно.
- Автоматически выбирает режим загрузки (UEFI или Legacy BIOS) на основе прошивки rescue-системы.
- После того как вы завершите установку, настраивает сеть на свежеустановленной системе (мост `vmbr0`, правильные IP и шлюз), чтобы она сразу загрузилась с доступом по сети.
- По желанию применяет стандартные пост-установочные правки: переключение на no-subscription репозитории, удаление напоминания о подписке, исправление источников Debian, полное обновление, отключение HA на single-node установках.
- Может запустить уже установленную систему обратно в QEMU, если нужно снова в неё попасть.

## Быстрый старт

ProxRescue — это единый самодостаточный скрипт: клонировать репозиторий не нужно, требуется только один файл.

Запуск напрямую в rescue-системе Hetzner:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh)"
```

Хотите сразу передать флаги в этом варианте запуска? Добавьте `_` в качестве заглушки для `$0`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh)" _ -pve -auto -dns 8.8.8.8
```

Либо скачайте скрипт один раз и запускайте его с нужными флагами когда понадобится:

```bash
curl -fsSL -o ProxRescue.sh https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh && chmod +x ProxRescue.sh
./ProxRescue.sh -pve -auto -dns 8.8.8.8
```

## Требования

В rescue-системе понадобятся следующие пакеты:

- `curl`
- `sshpass`
- `dialog`
- `git`

Не переживайте, если их нет — скрипт установит их сам.

## Использование

Запустите скрипт без аргументов, чтобы получить интерактивное меню, или передайте флаги, чтобы сразу перейти к установке.

### Установка

| Флаг | Что устанавливает |
| --- | --- |
| `-pve` | Proxmox Virtual Environment |
| `-pbs` | Proxmox Backup Server |
| `-pmg` | Proxmox Mail Gateway |
| `-pdm` | Proxmox Datacenter Manager |

### Пост-установочные правки

| Флаг | Что делает |
| --- | --- |
| `-fix-sources` | Исправить базовые источники Debian на deb.debian.org |
| `-no-sub` | Переключить Enterprise-репозитории на no-subscription и убрать напоминание о подписке |
| `-upgrade` | Выполнить `apt update && apt dist-upgrade` (требует `-no-sub`) |
| `-disable-ha` | Отключить службы HA (только для single-node PVE) |
| `-auto` | Применить всё вышеперечисленное без подтверждения |

Если эти флаги не указаны, после установки скрипт спросит для каждого из них, применить ли его.

### Подключение и прочее

| Флаг | Что делает |
| --- | --- |
| `-p`, `--password PASSWORD` | Задать пароль для VNC |
| `-vport PORT` | Задать порт noVNC (по умолчанию `8080`) |
| `-dns DNS_SERVER[,DNS_SERVER...]` | Задать один или несколько DNS-серверов через запятую (по умолчанию: автоопределение из rescue-системы, fallback `1.1.1.1`) |
| `-uefi` / `-legacy` | Принудительно задать режим загрузки вместо автоопределения |
| `-h`, `--help` | Показать справку |

Если не указать `-uefi` или `-legacy`, ProxRescue определит режим загрузки по прошивке rescue-системы. То же самое с DNS — если не задать `-dns`, скрипт прочитает `/etc/resolv.conf` и возьмёт то, что там найдёт (с резервным значением `1.1.1.1`, если ничего подходящего нет).

## Примеры

Установить Proxmox VE и задать пароль VNC:

```bash
./ProxRescue.sh -pve -p yourVNCpassword
```

Установить Proxmox VE, применить все пост-установочные правки и указать свой DNS:

```bash
./ProxRescue.sh -pve -auto -dns 8.8.8.8
```

Установить Proxmox Backup Server, переключиться на no-subscription репозитории и обновиться:

```bash
./ProxRescue.sh -pbs -no-sub -upgrade
```

Установить Proxmox VE с произвольным набором пост-установочных исправлений:

```bash
./ProxRescue.sh -pve -fix-sources -no-sub -upgrade -disable-ha
```

## Главное меню

Запустите скрипт без флагов — и увидите такое меню:

```
1) Select disks for QEMU
2) Install Proxmox (PVE, PBS, PMG, PDM)
3) Run installed System in QEMU
4) Toggle boot mode (current: ...)
5) Change VNC Password
6) Change DNS server(s)
7) Reboot
8) Exit
```

Текущий режим загрузки показан прямо вверху.

## Возможности

**Самообновление** — при запуске скрипт проверяет GitHub на наличие новой версии и предлагает обновиться на месте, перезапустившись с теми же аргументами.

**Автоматическая загрузка ISO** — выбираете продукт, скрипт берёт последний ISO напрямую с download.proxmox.com, проверяет SHA256 и загружает его в QEMU. При желании можно выбрать более старую версию из списка. Сам процесс установки (разметка дисков, пароли и т.д.) вы проходите вручную через noVNC, как при обычной установке Proxmox.

**Пост-установочные оптимизации** — исправление источников Debian, переключение на no-subscription репозитории и удаление напоминания о подписке (веб- и мобильный интерфейс), полное обновление через `apt upgrade`, отключение служб HA на single-node установках. Можно применять по одной или все сразу через `-auto`.

**VNC и noVNC** — пароль VNC генерируется случайным образом (или задайте свой), а noVNC даёт доступ через браузер — просто откройте `http://<ip-сервера>:8080`.

**Режим загрузки** — автоопределение UEFI или Legacy BIOS по прошивке rescue-системы, либо принудительно через `-uefi`/`-legacy`.

**Настройка DNS** — автоопределение всех DNS-серверов из rescue-системы (с корректной обработкой stub-резолвера systemd-resolved на 127.0.0.53), либо переопределение через `-dns 8.8.8.8,1.1.1.1`. Всё определённое/заданное записывается в `/etc/resolv.conf` на установленной системе.

**Сеть** — после установки скрипт настраивает `vmbr0` с реальным IP и шлюзом сервера, чтобы система сразу была доступна по сети. Для этого понадобится ввести пароль root, заданный во время установки — скрипт подключится по SSH и применит конфигурацию.

**Управление перезагрузкой** — перезагрузка из меню с корректным завершением QEMU и noVNC.

**Выбор дисков** — по умолчанию все диски передаются в QEMU, но можно выбрать конкретные через меню.

## На что обратить внимание

- Скрипт завершает все сессии noVNC и отправляет `quit` монитору QEMU при каждом запуске и выходе.
- Требуется KVM (`/dev/kvm`), наличие проверяется при старте.
- **Пока работает инсталлятор Proxmox (внутри noVNC/VNC), не трогайте настройки сети/IP** — оставьте их по умолчанию. ProxRescue настроит сеть сам после установки, а ручное изменение IP во время установки сломает шаг автоматической настройки сети и выполнение пост-установочных правок.

## Благодарности

Часть пост-установочной логики (переключение репозиториев и удаление напоминания о подписке) адаптирована из [community-scripts.org](https://community-scripts.org).

## Лицензия

MIT — см. ниже.

```
Copyright (c) 2026 Proxmox UA

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Сообщество и поддержка

- Telegram: [Proxmox_UA](https://t.me/Proxmox_UA)
- GitHub: [Proxmoxinfo/ProxMoxRescueHelper](https://github.com/Proxmoxinfo/ProxMoxRescueHelper)
- Сайт: [proxmox.info](https://proxmox.info)
