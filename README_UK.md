# ProxRescue

[English](README.md) | [Русский](README_RU.md) | Українська

**Скрипт в один файл, який встановлює Proxmox на виділений сервер Hetzner прямо з rescue-системи.**

Якщо ви хоч раз намагалися поставити Proxmox VE/PBS/PMG/PDM на сервер Hetzner, то знаєте, як це буває: завантажуєшся в rescue, мучишся з QEMU, щоб запустити графічний інсталятор, сам налаштовуєш доступ через VNC/noVNC, а потім ще вручну правиш мережу, репозиторії та прибираєш нагадування про підписку. ProxRescue бере на себе всю цю обв'язку — він запускає офіційний ISO Proxmox у QEMU і дає посилання на noVNC, а сам інсталятор Proxmox (розмітка дисків, паролі тощо) ви проходите як зазвичай через браузер. Після цього скрипт сам налаштовує мережу та застосовує пост-інсталяційні правки.

Тобто це не повністю автоматичне встановлення «в один клік» — сам інсталятор Proxmox ви проходите вручну, — але скрипт прибирає всю рутину навколо нього.

## Що робить скрипт

- Запускає офіційний установчий ISO Proxmox у QEMU і дає посилання на noVNC, щоб пройти встановлення у браузері як зазвичай.
- Автоматично обирає режим завантаження (UEFI або Legacy BIOS) на основі прошивки rescue-системи.
- Після того як ви завершите встановлення, налаштовує мережу на щойно встановленій системі (міст `vmbr0`, правильні IP та шлюз), щоб вона одразу завантажилася з доступом по мережі.
- За бажанням застосовує стандартні пост-інсталяційні правки: перемикання на no-subscription репозиторії, видалення нагадування про підписку, виправлення джерел Debian, повне оновлення, вимкнення HA на single-node установках.
- Може запустити вже встановлену систему назад у QEMU, якщо потрібно знову в неї потрапити.

## Швидкий старт

ProxRescue — це єдиний самодостатній скрипт: клонувати репозиторій не потрібно, потрібен лише один файл.

Запуск безпосередньо в rescue-системі Hetzner:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh)"
```

Хочете одразу передати прапорці в цьому варіанті запуску? Додайте `_` як заглушку для `$0`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh)" _ -pve -auto -dns 8.8.8.8
```

Або завантажте скрипт один раз і запускайте його з потрібними прапорцями, коли знадобиться:

```bash
curl -fsSL -o ProxRescue.sh https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh && chmod +x ProxRescue.sh
./ProxRescue.sh -pve -auto -dns 8.8.8.8
```

## Вимоги

У rescue-системі знадобляться такі пакунки:

- `curl`
- `sshpass`
- `dialog`
- `git`

Не хвилюйтеся, якщо їх немає — скрипт встановить їх сам.

## Використання

Запустіть скрипт без аргументів, щоб отримати інтерактивне меню, або передайте прапорці, щоб одразу перейти до встановлення.

### Встановлення

| Прапорець | Що встановлює |
| --- | --- |
| `-pve` | Proxmox Virtual Environment |
| `-pbs` | Proxmox Backup Server |
| `-pmg` | Proxmox Mail Gateway |
| `-pdm` | Proxmox Datacenter Manager |

### Пост-інсталяційні правки

| Прапорець | Що робить |
| --- | --- |
| `-fix-sources` | Виправити базові джерела Debian на deb.debian.org |
| `-no-sub` | Перемкнути Enterprise-репозиторії на no-subscription і прибрати нагадування про підписку |
| `-upgrade` | Виконати `apt update && apt dist-upgrade` (потребує `-no-sub`) |
| `-disable-ha` | Вимкнути служби HA (лише для single-node PVE) |
| `-auto` | Застосувати все вищезазначене без підтвердження |

Якщо ці прапорці не вказані, після встановлення скрипт запитає для кожного з них, чи застосувати його.

### Підключення та інше

| Прапорець | Що робить |
| --- | --- |
| `-p`, `--password PASSWORD` | Задати пароль для VNC |
| `-vport PORT` | Задати порт noVNC (за замовчуванням `8080`) |
| `-dns DNS_SERVER[,DNS_SERVER...]` | Задати один або кілька DNS-серверів через кому (за замовчуванням: автовизначення з rescue-системи, fallback `1.1.1.1`) |
| `-uefi` / `-legacy` | Примусово задати режим завантаження замість автовизначення |
| `-h`, `--help` | Показати довідку |

Якщо не вказати `-uefi` або `-legacy`, ProxRescue визначить режим завантаження за прошивкою rescue-системи. Те саме з DNS — якщо не задати `-dns`, скрипт прочитає `/etc/resolv.conf` і візьме те, що там знайде (з резервним значенням `1.1.1.1`, якщо нічого придатного немає).

## Приклади

Встановити Proxmox VE та задати пароль VNC:

```bash
./ProxRescue.sh -pve -p yourVNCpassword
```

Встановити Proxmox VE, застосувати всі пост-інсталяційні правки та вказати свій DNS:

```bash
./ProxRescue.sh -pve -auto -dns 8.8.8.8
```

Встановити Proxmox Backup Server, перемкнутися на no-subscription репозиторії та оновитися:

```bash
./ProxRescue.sh -pbs -no-sub -upgrade
```

Встановити Proxmox VE з довільним набором пост-інсталяційних виправлень:

```bash
./ProxRescue.sh -pve -fix-sources -no-sub -upgrade -disable-ha
```

## Головне меню

Запустіть скрипт без прапорців — і побачите таке меню:

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

Поточний режим завантаження показано прямо вгорі.

## Можливості

**Самооновлення** — під час запуску скрипт перевіряє GitHub на наявність нової версії та пропонує оновитися на місці, перезапустившись із тими самими аргументами.

**Автоматичне завантаження ISO** — обираєте продукт, скрипт бере останній ISO напряму з download.proxmox.com, перевіряє SHA256 і завантажує його в QEMU. За бажанням можна обрати старішу версію зі списку. Сам процес встановлення (розмітка дисків, паролі тощо) ви проходите вручну через noVNC, як і за звичайної установки Proxmox.

**Пост-інсталяційні оптимізації** — виправлення джерел Debian, перемикання на no-subscription репозиторії та видалення нагадування про підписку (веб- та мобільний інтерфейс), повне оновлення через `apt upgrade`, вимкнення служб HA на single-node установках. Можна застосовувати по одній або всі одразу через `-auto`.

**VNC та noVNC** — пароль VNC генерується випадковим чином (або задайте свій), а noVNC дає доступ через браузер — просто відкрийте `http://<ip-сервера>:8080`.

**Режим завантаження** — автовизначення UEFI чи Legacy BIOS за прошивкою rescue-системи, або примусово через `-uefi`/`-legacy`.

**Налаштування DNS** — автовизначення всіх DNS-серверів із rescue-системи (з коректною обробкою stub-резолвера systemd-resolved на 127.0.0.53), або перевизначення через `-dns 8.8.8.8,1.1.1.1`. Усе визначене/задане записується в `/etc/resolv.conf` на встановленій системі.

**Мережа** — після встановлення скрипт налаштовує `vmbr0` з реальним IP та шлюзом сервера, щоб система одразу була доступна по мережі. Для цього знадобиться ввести пароль root, заданий під час встановлення — скрипт підключиться по SSH і застосує конфігурацію.

**Керування перезавантаженням** — перезавантаження з меню з коректним завершенням QEMU та noVNC.

**Вибір дисків** — за замовчуванням усі диски передаються в QEMU, але можна обрати конкретні через меню.

## На що звернути увагу

- Скрипт завершує всі сесії noVNC та надсилає `quit` монітору QEMU під час кожного запуску й виходу.
- Потрібен KVM (`/dev/kvm`), наявність перевіряється під час старту.
- **Поки працює інсталятор Proxmox (всередині noVNC/VNC), не чіпайте налаштування мережі/IP** — залиште їх за замовчуванням. ProxRescue налаштує мережу сам після встановлення, а ручна зміна IP під час встановлення зламає крок автоматичного налаштування мережі та виконання пост-інсталяційних правок.

## Подяки

Частина пост-інсталяційної логіки (перемикання репозиторіїв та видалення нагадування про підписку) адаптована з [community-scripts.org](https://community-scripts.org).

## Ліцензія

MIT — див. нижче.

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

## Спільнота та підтримка

- Telegram: [Proxmox_UA](https://t.me/Proxmox_UA)
- GitHub: [Proxmoxinfo/ProxMoxRescueHelper](https://github.com/Proxmoxinfo/ProxMoxRescueHelper)
- Сайт: [proxmox.info](https://proxmox.info)
