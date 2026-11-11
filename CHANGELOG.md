# Changelog

## 2.0.0

Первый публичный релиз.

- Вход внутри приложения: почта и пароль для внешнего приложения Mail.ru, пароль хранится в связке ключей.
- Встроенный rclone v1.75.2, Homebrew и Терминал не нужны. Если у вас уже настроен rclone с remote `mailru`, приложение работает через него.
- Пошаговое подключение с подсказками и понятными ошибками, перенос в «Программы» при первом запуске.
- После входа с вставленным паролем приложение убирает его из буфера обмена.
- Файлы релиза называются латиницей: `Oblachko-<версия>.dmg` и `.zip`, приложение внутри по-прежнему «Облачко».
- Загрузка перетаскиванием, просмотр Облака, скачивание на Мак, освобождение места с ярлыками `.mailcloud`.
- Universal-сборка для Apple Silicon и Intel, macOS 14 и новее.

First public release: in-app sign-in with a Mail.ru app password kept in the Keychain, bundled rclone,
guided onboarding, uploads, cloud browser, downloads and freeing up space with placeholders.
