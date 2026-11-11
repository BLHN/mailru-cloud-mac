# Облачко: window design v2

Owner's verdict on the two mockups (10.11.2026): the calm native layout (sidebar + Finder-like list) is the
one to build. The dark-glass variant with glows, gradients and a giant speed number was rejected as slop.
What he asked for on top of the calm layout: one distinctive touch, micro-interactions and good-looking,
interesting animations.

## Principles

1. It must look like a first-party macOS app: system materials, system colors, SF Symbols, standard
   controls, real Finder file icons. Light and dark appearance both, following the system.
2. No gradients, no glow, no neon, no drop-shadow decoration, no custom "glass" panels, no hero numbers,
   no card grids. Dense lists use plain rows with hairline separators, not rounded cards.
3. One accent: the app tint `Color(red: 0, green: 0.47, blue: 1)` (Mail.ru blue). Direction is told by the
   symbol (arrow up / arrow down), not by a second colour. Green is only for "verified / done", orange for
   "needs attention", red for errors.
4. Character comes from motion and from three signature touches (below), not from decoration.
5. Text: conversational Russian, sentence case, no long dash, no exclamation marks in system copy.
   Numbers that change use monospaced digits.

## Structure

One window, `NavigationSplitView`: sidebar 200-220 pt, content to the right. Default size 920x600,
minimum 760x480. Transparent title bar with full-size content (the sidebar material runs to the top).

Sidebar (top to bottom):
- «Передачи» `arrow.up.arrow.down`, badge = number of active jobs (hidden at 0).
- «Облако» `cloud`.
- «Копия Мака» `checkmark.shield`, trailing status dot: green = all in the cloud, accent = syncing,
  orange = needs attention, gray = supervisor silent.
- Pinned to the bottom: the cloud gauge (signature 1) and a «Настройки» row (`gearshape`).

### Передачи

- Empty queue: the content area is one calm drop invitation, centered: `icloud.and.arrow.up` (48 pt,
  hierarchical, secondary), «Перетащи сюда файлы или папки», a caption «Улетят в Облако, в «<folder>»»,
  a link button «Выбрать в Finder…».
- Above the list, one compact options line: destination chip «в <folder>» (click opens the folder picker),
  a tortoise toggle «Тихий режим», a toggle «Освобождать место» (same help texts as today).
- Non-empty queue: sections «Сейчас» (running, queued, paused), «Нужно внимание» (failed, blocked,
  refused), «Готово» (done, cancelled; with «Очистить» on the section header). Empty sections are hidden.
- Row: real icon (uploads: `NSWorkspace.shared.icon(forFile:)`; downloads: icon for the file type or the
  generic folder icon) 32 pt with a small direction badge (arrow up / down) at its corner; name (medium);
  one secondary line (route: «в Облако · Mac/Входящие» / «на Мак · Загрузки»; while running also
  «214 из 380 файлов»); a 4 pt capsule progress bar; trailing: percent and speed.
  All existing states, notes, phases and error texts of `JobRowView` must stay reachable: nothing the row
  says today may be lost, only laid out better.
- Hover on a row: the trailing stats cross-fade into the row's action buttons (pause, cancel, retry,
  «Показать в Finder», «Открыть в Облаке», remove). Without hover the actions are also in a context menu.

### Облако

- A Finder-like list of the current cloud folder: columns «Имя», «Размер», «Изменён». Folders first.
  Folder size is unknown from the listing: leave the size cell of folders empty and compute the size
  lazily for the selection only (bottom bar).
- Header line: back button, clickable breadcrumb («Облако › Mac › Movies»), a filter field
  («Фильтр по имени», filters the loaded folder), refresh.
- The actions live in the window toolbar (top right); the header line holds back, breadcrumb, filter and refresh. Actions: «Скачать на Мак» (prominent, enabled with a selection), «Загрузить
  сюда» (file picker, uploads into the shown folder), «Новая папка», «Открыть в браузере» (icon only).
  The same actions in the row context menu, plus «Загружать сюда по умолчанию».
- Double click or Return on a folder opens it; Cmd+Up goes to the parent; multi-selection works.
- Bottom bar while something is selected: «<name>» or «Выбрано: N», kind, and for folders the lazily
  computed «40 779 файлов · 82,4 ГБ» (a small spinner while `rclone size` runs).
- «Скачать на Мак» opens an `NSOpenPanel` for the destination (starts in the last used folder, default
  ~/Downloads), then queues one download per selected item.
- Dropping files on the list uploads them into the shown folder; dropping on a folder row uploads into
  that folder (the row highlights while targeted).
- States: loading = redacted placeholder rows with a soft shimmer, not a lone spinner; empty folder =
  «Папка пустая» with «Загрузить сюда»; error = the humanized message with «Повторить».
- The app never deletes, renames or moves anything in the cloud. Do not offer such actions.

### Копия Мака

Read-only view of an optional background upload supervisor (`~/Library/Logs/cloudsup_status.json`, see
`SupervisorStatus`; extend the decoder with the fields the file really has). The section, its menu bar line and
every background read exist only on a Mac where that file exists.
- Summary line on top: shield symbol + one sentence: «Всё в Облаке» / «Выгружается: осталось N файлов»
  / «Нужно внимание» / «Супервизор молчит с HH:MM» (status older than 60 s). Caption: last completed
  check, current link speed while active, the supervisor's last event.
- One row per protected folder: folder icon, name, local path, state text («в Облаке, сверено вчера в
  17:54» / «выгружается» with a progress bar and files left / «ждёт диск» / «ошибка: <note>»).
  A job whose volume is not mounted is shown dimmed with «диск не подключён».
- While workers are active: an indented list of the files being sent with their speeds.
- Alerts from the status file in an orange «Нужно внимание» block.
- No pause, add-folder or edit controls in this version (they come with the stability work).

### Настройки

A section opened from the sidebar's bottom row (and by Cmd+,): «Тихий режим», «Освобождать место после
загрузки», «Запускать при входе» (with the existing hint), notifications state read from
`UNUserNotificationCenter.getNotificationSettings` («Уведомления разрешены» / «Уведомления выключены
в macOS» + button «Открыть настройки уведомлений»), default cloud folder for uploads, default local
folder for downloads, «Показать журнал». A grouped `Form`.

### Menu bar popover

Same vocabulary, compact: active transfers (name, thin bar, percent), one line about the Mac copy,
a small drop target, «Открыть окно». Settings toggles move out of the popover into Настройки except
«Тихий режим».

### First run (onboarding)

While no account is set up (no app password in the Keychain, no remote "mailru" in the user's own
rclone.conf) the window shows the onboarding instead of the sidebar layout: a 520 pt column, a 56 pt
hierarchical accent symbol, title (.title2 semibold), secondary text, buttons at the bottom right
(primary = prominent, Return). Step dots «Пароль · Вход · Готово» at the top left. Steps slide in from
the trailing edge (back: from the leading edge) in 0.25 s; cross-fade with reduce motion.
- 0 «Перенесём приложение в Программы» only when the bundle runs outside /Applications and
  ~/Applications (or translocated): copy, quarantine off, open the copy, old copies to the Trash.
- 1 welcome, 2 «Нужен пароль для приложения» (e-mail with domain chips, five steps as a numbered list
  drawn with system elements, never screenshots of Mail.ru), 2B «Сначала привяжите телефон»,
  3 «Вход в Облако» (live check with three marks «Связь с Облаком · Пароль · Место в Облаке», problem
  plaques 3.1 to 3.8 whose symbol shakes once), 4 «Облако подключено» (the cloud gauge at 72 pt).
- 2A: after «Открыть Mail.ru» a small non-activating floating panel (280 x 360) at the right edge of
  the screen repeats the steps. It watches only the clipboard's change count and types (plus the
  system's pattern detection, which excludes links, e-mails and phone numbers); the clipboard is read
  once, on the user's click, and the password is never shown or logged.
- The compact sign-in sheet (Settings, a password the cloud stopped accepting) is screen 3 in a sheet.
- «macOS спросит пароль от Мака»: a sheet before the first Keychain read of a new ad-hoc signed build
  and after a denied read.

## Signature touches

1. **The cloud is the gauge.** At the bottom of the sidebar a cloud outline (about 44 pt wide) is filled
   from the bottom up to the used share of the cloud storage (a `cloud.fill` masked by a level
   rectangle over a `cloud` outline, accent tint at moderate opacity). Next to it: «Свободно 612 ГБ»
   and a caption «из 1 ТБ». On appear the level rises from zero with a soft spring; after a finished
   upload it settles to the new level; on hover the text switches to «Занято 388 ГБ · 39 %».
2. **Files fly.** Dragging files over the window turns the whole window into the target: the content
   dims under a thin material, a cloud symbol scales in with a spring and the label says «Отпускай».
   On drop the overlay collapses toward the «Передачи» sidebar row and its badge bounces. Queuing a
   download from «Облако» does the same toward «Передачи». Then the sidebar selection stays where the
   user is; a small inline toast («Скачивается в Загрузки · Показать») offers the jump.
3. **Done means a mark.** When a job finishes verified, its progress bar completes, fades, and the row's
   status becomes a `checkmark.circle.fill` that bounces once (`symbolEffect(.bounce)`), with the text
   «сверено с Облаком». A failure shakes the row's icon once (small horizontal keyframe) and turns the
   status orange/red. One gentle `NSHapticFeedbackManager` tick on completion.

## Micro-interactions and motion

- Changing numbers (percent, speed, sizes, counters, badge) use `.contentTransition(.numericText())`.
- Progress bars animate between values (`.animation(.smooth)`), never jump; while rclone is still
  listing, the bar shows an indeterminate slow sweep instead of a frozen value.
- Section membership changes (running to done) animate with a move + fade, not a list reload.
- Sidebar status dot of «Копия Мака» breathes (opacity 0.5 to 1) only while syncing.
- The menu bar icon and the «Передачи» sidebar symbol use `symbolEffect(.variableColor.iterative)` only
  while a transfer runs.
- Folder navigation in «Облако» slides: forward pushes from the trailing edge, back from the leading
  edge, about 0.25 s; the breadcrumb updates with a cross-fade.
- Buttons and chips give press feedback (scale 0.97, 0.12 s). Hover highlights are instant in, 0.15 s out.
- Dock tile: a progress bar on the app icon while transfers run (overall fraction), removed when idle.
- Springs: response 0.35, damping 0.82 for layout; 0.25 for small things. Nothing loops while idle.
- `accessibilityReduceMotion`: all moves and flights become plain cross-fades, loops stop.

## Dev aids required for visual QA

- `--dev-demo`: fills the queue with fake jobs in every state (running upload at 62 %, running download
  at 43 %, queued, paused, failed with a long message, blocked, refused, done upload, done verified
  download, done evict with placeholder) without starting rclone, and animates the two running ones.
- `--dev-section transfers|cloud|backup|settings` selects the section at launch.
- `--dev-appearance light|dark` forces the appearance.
- `--dev-play drop|done|fail|download` plays that choreography two seconds after launch.
- `--dev-onboarding move|move-error|welcome|password|phone|signin|done`, `--dev-onboarding-error
  3.1|3.1b|3.2|...|3.8|checking|clipboard|warning`, `--dev-guide-panel waiting|copied`,
  `--dev-keychain-sheet before|denied`, `--dev-signin-sheet`: onboarding screens and states for
  screenshots (sheet contents also open as a plain window at the back, since a sheet of a background
  window is not captured). `--dev-move-now` runs the move into `CLOUDMAIL_DEV_MOVE_TARGET` only.
- All of this only in the dev bundle (`ru.blhn.cloudmail.dev`).
